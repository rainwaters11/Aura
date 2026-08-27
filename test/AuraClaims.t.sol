// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {AuraHook} from "../src/AuraHook.sol";
import {AuraClearingMath} from "../src/libraries/AuraClearingMath.sol";
import {IAuraSettlementSource} from "../src/interfaces/IAuraSettlementSource.sol";
import {BatchSolution, ParkedOrder, OrderStatus, BatchStatus} from "../src/types/AuraTypes.sol";
import {AuraSettlementTest} from "./AuraSettlement.t.sol";

interface ITokenTransferCallback {
    function onTokenTransfer(address token, uint256 amount) external;
}

contract CallbackERC20 is MockERC20 {
    error CallbackRejected();

    constructor() MockERC20("Callback Token", "CALLBACK", 18) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to.code.length != 0) {
            (bool success,) = to.call(abi.encodeCall(ITokenTransferCallback.onTokenTransfer, (address(this), amount)));
            if (!success) revert CallbackRejected();
        }
        return super.transfer(to, amount);
    }
}

contract ReentrantClaimRecipient is ITokenTransferCallback {
    bytes4 internal constant REENTRANCY_SELECTOR = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    AuraHook internal immutable hook;
    PoolId internal immutable poolId;
    Currency internal immutable token;
    uint256 internal immutable reentryAmount;

    bool public callbackAttempted;
    bool public reentrySucceeded;
    bytes4 public reentryRevertSelector;

    constructor(AuraHook hook_, PoolId poolId_, Currency token_, uint256 reentryAmount_) {
        hook = hook_;
        poolId = poolId_;
        token = token_;
        reentryAmount = reentryAmount_;
    }

    function claim(uint256 amount) external {
        hook.claimTokens(poolId, token, address(this), amount);
    }

    function onTokenTransfer(address, uint256) external {
        callbackAttempted = true;
        bytes memory callData = abi.encodeCall(AuraHook.claimTokens, (poolId, token, address(this), reentryAmount));
        bytes memory returnData;
        (reentrySucceeded, returnData) = address(hook).call(callData);
        if (returnData.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(returnData, 0x20))
            }
            reentryRevertSelector = selector;
        }
    }

    function reentrancySelector() external pure returns (bytes4) {
        return REENTRANCY_SELECTOR;
    }
}

contract RevertingRecipient is ITokenTransferCallback {
    function onTokenTransfer(address, uint256) external pure {
        revert("RECIPIENT_REVERTED");
    }
}

contract AuraClaimsTest is AuraSettlementTest {
    using CurrencyLibrary for Currency;

    function test_claimsToChosenRecipientAndRejectsReplay() public {
        address account = makeAddr("claim-account");
        address recipient = makeAddr("chosen-recipient");
        BatchSolution memory solution =
            _closedSolutionForRecipients(10 ether, 10 ether, 10 ether, 10 ether, account, owner);
        hook.settleBatch(address(this), solution);
        uint256 recipientBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(recipient);

        vm.prank(account);
        hook.claimTokens(poolId, currency1, recipient, 4 ether);

        assertEq(hook.claimableBalances(poolId, account, currency1), 6 ether);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(recipient), recipientBefore + 4 ether);
        vm.prank(account);
        hook.claimTokens(poolId, currency1, recipient, 6 ether);
        assertEq(hook.claimableBalances(poolId, account, currency1), 0);

        vm.prank(account);
        vm.expectRevert(AuraHook.InsufficientClaimBalance.selector);
        hook.claimTokens(poolId, currency1, recipient, 1);
    }

    function test_claimRejectsForeignAccountWrongCurrencyZeroRangeAndOverBalance() public {
        address account = makeAddr("claim-account");
        BatchSolution memory solution =
            _closedSolutionForRecipients(10 ether, 10 ether, 10 ether, 10 ether, account, owner);
        hook.settleBatch(address(this), solution);

        vm.prank(makeAddr("foreign-account"));
        vm.expectRevert(AuraHook.InsufficientClaimBalance.selector);
        hook.claimTokens(poolId, currency1, account, 1);
        assertEq(hook.claimableBalances(poolId, account, currency1), 10 ether);

        vm.startPrank(account);
        vm.expectRevert(AuraHook.InvalidClaim.selector);
        hook.claimTokens(poolId, Currency.wrap(address(0xCAFE)), account, 1);
        vm.expectRevert(AuraHook.InvalidClaim.selector);
        hook.claimTokens(poolId, currency1, account, 0);
        vm.expectRevert(AuraHook.InvalidClaim.selector);
        hook.claimTokens(poolId, currency1, account, uint256(uint128(type(int128).max)) + 1);
        vm.expectRevert(AuraHook.InsufficientClaimBalance.selector);
        hook.claimTokens(poolId, currency1, account, 10 ether + 1);
        vm.stopPrank();

        assertEq(hook.claimableBalances(poolId, account, currency1), 10 ether);
    }

    function test_claimUsesExplicitTransientReentrancyGuard() public {
        ReentrantClaimRecipient account = new ReentrantClaimRecipient(hook, poolId, currency1, 1 ether);
        BatchSolution memory solution =
            _closedSolutionForRecipients(10 ether, 10 ether, 10 ether, 10 ether, address(account), owner);
        hook.settleBatch(address(this), solution);
        CallbackERC20 callbackImplementation = new CallbackERC20();
        vm.etch(Currency.unwrap(currency1), address(callbackImplementation).code);

        account.claim(5 ether);

        assertTrue(account.callbackAttempted());
        assertFalse(account.reentrySucceeded());
        assertEq(account.reentryRevertSelector(), account.reentrancySelector());
        assertEq(hook.claimableBalances(poolId, address(account), currency1), 5 ether);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(account)), 5 ether);
    }

    function test_revertingRecipientRollsBackWithoutBlockingAnotherAccount() public {
        address account0 = makeAddr("account-zero");
        address account1 = makeAddr("account-one");
        BatchSolution memory solution =
            _closedSolutionForRecipients(10 ether, 10 ether, 10 ether, 10 ether, account0, account1);
        hook.settleBatch(address(this), solution);
        CallbackERC20 callbackImplementation = new CallbackERC20();
        vm.etch(Currency.unwrap(currency1), address(callbackImplementation).code);
        RevertingRecipient revertingRecipient = new RevertingRecipient();
        uint256 token1Backing = poolManager.balanceOf(address(hook), currency1.toId());

        vm.prank(account0);
        vm.expectRevert();
        hook.claimTokens(poolId, currency1, address(revertingRecipient), 10 ether);

        assertEq(hook.claimableBalances(poolId, account0, currency1), 10 ether);
        assertEq(poolManager.balanceOf(address(hook), currency1.toId()), token1Backing);

        vm.prank(account1);
        hook.claimTokens(poolId, currency0, account1, 10 ether);
        assertEq(hook.claimableBalances(poolId, account1, currency0), 0);

        vm.prank(account0);
        hook.claimTokens(poolId, currency1, account0, 10 ether);
        assertEq(hook.claimableBalances(poolId, account0, currency1), 0);
    }

    function test_accumulatedBalanceRedeemsThroughRepeatedSignedRangeClaims() public {
        uint128 maxChunk = uint128(type(int128).max);
        hook.settleBatch(address(this), _closedSolutionForBatch(1, maxChunk, owner));
        hook.settleBatch(address(this), _closedSolutionForBatch(2, maxChunk, owner));
        assertEq(hook.claimableBalances(poolId, owner, currency0), uint256(maxChunk) * 2);
        uint256 beforeBalance = MockERC20(Currency.unwrap(currency0)).balanceOf(owner);

        vm.startPrank(owner);
        hook.claimTokens(poolId, currency0, owner, maxChunk);
        hook.claimTokens(poolId, currency0, owner, maxChunk);
        vm.stopPrank();

        assertEq(hook.claimableBalances(poolId, owner, currency0), 0);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(owner), beforeBalance + uint256(maxChunk) * 2);
        assertEq(poolManager.balanceOf(address(hook), currency0.toId()), 0);
    }

    function test_permissionlessRefundIsFixedToOwnerAndRecipientFailureIsIsolated() public {
        address secondOwner = makeAddr("second-order-owner");
        MockERC20 inputToken = MockERC20(Currency.unwrap(currency0));
        inputToken.mint(secondOwner, AMOUNT);
        vm.prank(secondOwner);
        inputToken.approve(address(router), type(uint256).max);

        _place(true, AMOUNT, MINIMUM);
        vm.prank(secondOwner);
        router.placeOrder(
            true, AMOUNT, MINIMUM, makeAddr("irrelevant-output-recipient"), uint64(block.timestamp + 13 hours)
        );
        bytes32[] memory ids = hook.batchOrderIds(1);
        vm.roll(uint256(hook.openedAtBlock(1)) + hook.MAX_BATCH_WINDOW() + 1);
        hook.closeBatch(1);

        vm.mockCallRevert(
            address(inputToken),
            abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), owner, uint256(AMOUNT)),
            "BLACKLISTED"
        );
        vm.prank(makeAddr("refund-keeper"));
        vm.expectRevert();
        hook.cancelExpiredOrder(ids[0]);
        assertEq(uint8(_storedOrder(ids[0]).status), uint8(OrderStatus.PARKED));

        uint256 secondOwnerBefore = inputToken.balanceOf(secondOwner);
        vm.prank(makeAddr("second-refund-keeper"));
        hook.cancelExpiredOrder(ids[1]);
        assertEq(uint8(_storedOrder(ids[1]).status), uint8(OrderStatus.CANCELLED));
        assertEq(inputToken.balanceOf(secondOwner), secondOwnerBefore + AMOUNT);

        vm.clearMockedCalls();
        vm.prank(makeAddr("recovery-keeper"));
        hook.cancelExpiredOrder(ids[0]);
        assertEq(inputToken.balanceOf(owner), type(uint128).max);
        assertEq(poolManager.balanceOf(address(hook), currency0.toId()), 0);
    }

    function test_refundCannotRaceBoundaryOrRefundSettledOrder() public {
        _place(true, AMOUNT, MINIMUM);
        bytes32 orderId = hook.batchOrderIds(1)[0];
        uint256 boundary = uint256(hook.openedAtBlock(1)) + hook.MAX_BATCH_WINDOW();

        vm.roll(boundary);
        vm.expectRevert(AuraHook.BatchWindowActive.selector);
        hook.closeBatch(1);
        vm.expectRevert(AuraHook.BatchNotRefundable.selector);
        hook.cancelExpiredOrder(orderId);

        vm.roll(boundary + 1);
        hook.closeBatch(1);
        hook.cancelExpiredOrder(orderId);
        vm.expectRevert(AuraHook.OrderNotParked.selector);
        hook.cancelExpiredOrder(orderId);

        BatchSolution memory solution = _closedSolutionForBatch(2, 10 ether, owner);
        hook.settleBatch(address(this), solution);
        bytes32 settledOrderId = hook.batchOrderIds(2)[0];
        vm.expectRevert(AuraHook.OrderNotParked.selector);
        hook.cancelExpiredOrder(settledOrderId);
    }

    function _closedSolutionForBatch(uint64 batchId, uint128 amount, address recipient)
        internal
        returns (BatchSolution memory solution)
    {
        _placeForRecipient(true, amount, amount, recipient);
        _placeForRecipient(false, amount, amount, recipient);
        vm.roll(uint256(hook.openedAtBlock(batchId)) + hook.MAX_BATCH_WINDOW() + 1);
        hook.closeBatch(batchId);

        bytes32[] memory ids = hook.batchOrderIds(batchId);
        ParkedOrder[] memory parked = new ParkedOrder[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            parked[i] = _storedOrder(ids[i]);
        }
        AuraClearingMath.Computation memory computed = AuraClearingMath.compute(parked);
        solution = BatchSolution({
            batchId: batchId,
            deadline: parked[0].deadline,
            priceNumerator: computed.priceNumerator,
            priceDenominator: computed.priceDenominator,
            residualZeroForOne: computed.residualZeroForOne,
            residualAmountIn: computed.residualAmountIn,
            sqrtPriceLimitX96: 0,
            solutionHash: bytes32(0),
            orderIds: ids,
            payouts: computed.payouts
        });
        solution.solutionHash = AuraClearingMath.computeSolutionHash(
            solution, AuraClearingMath.Domain(block.chainid, address(hook), PoolId.unwrap(poolId))
        );
    }

    function _storedOrder(bytes32 orderId) internal view returns (ParkedOrder memory) {
        return IAuraSettlementSource(address(hook)).orders(orderId);
    }
}

contract AuraClaimsInvariant is AuraSettlementTest {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    address internal recipient0;
    address internal recipient1;
    bytes32 internal refundOrderId;

    function setUp() public override {
        super.setUp();
        recipient0 = makeAddr("claim-invariant-recipient-0");
        recipient1 = makeAddr("claim-invariant-recipient-1");
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = this.exerciseClaimAndRefundLifecycle.selector;
        targetContract(address(this));
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    function exerciseClaimAndRefundLifecycle(uint8 stage) public {
        if (hook.batchStatus(1) == BatchStatus.NONE) {
            BatchSolution memory solution =
                _closedSolutionForRecipients(10 ether, 10 ether, 10 ether, 10 ether, recipient0, recipient1);
            hook.settleBatch(address(this), solution);
        }
        if (stage == 0) return;

        uint256 balance0 = hook.claimableBalances(poolId, recipient0, currency1);
        if (balance0 != 0) {
            vm.prank(recipient0);
            hook.claimTokens(poolId, currency1, recipient0, balance0 > 1 ether ? 1 ether : balance0);
        }
        uint256 balance1 = hook.claimableBalances(poolId, recipient1, currency0);
        if (balance1 != 0) {
            vm.prank(recipient1);
            hook.claimTokens(poolId, currency0, recipient1, balance1 > 1 ether ? 1 ether : balance1);
        }
        if (stage == 1) return;

        if (hook.batchStatus(2) == BatchStatus.NONE) {
            _place(true, AMOUNT, MINIMUM);
            refundOrderId = hook.batchOrderIds(2)[0];
            vm.roll(uint256(hook.openedAtBlock(2)) + hook.MAX_BATCH_WINDOW() + 1);
            hook.closeBatch(2);
        }
        if (stage == 2) return;

        if (_storedOrder(refundOrderId).status == OrderStatus.PARKED) {
            vm.prank(makeAddr("invariant-refund-keeper"));
            hook.cancelExpiredOrder(refundOrderId);
        }
    }

    function invariant_claimsDustAndParkedInputsEqualCompleteBacking() public view {
        uint256 liability0 = hook.claimableBalances(poolId, recipient0, currency0)
            + hook.claimableBalances(poolId, recipient1, currency0) + hook.claimableBalances(poolId, owner, currency0)
            + hook.protocolDust(poolId, currency0);
        uint256 liability1 = hook.claimableBalances(poolId, recipient0, currency1)
            + hook.claimableBalances(poolId, recipient1, currency1) + hook.claimableBalances(poolId, owner, currency1)
            + hook.protocolDust(poolId, currency1);

        for (uint64 batchId = 1; batchId <= 2; ++batchId) {
            bytes32[] memory ids = hook.batchOrderIds(batchId);
            for (uint256 i; i < ids.length; ++i) {
                ParkedOrder memory order = _storedOrder(ids[i]);
                if (order.status == OrderStatus.PARKED) {
                    if (order.zeroForOne) liability0 += order.amountIn;
                    else liability1 += order.amountIn;
                }
            }
        }

        assertEq(liability0, poolManager.balanceOf(address(hook), currency0.toId()));
        assertEq(liability1, poolManager.balanceOf(address(hook), currency1.toId()));
        assertEq(poolManager.currencyDelta(address(hook), currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), currency1), 0);
    }

    function _storedOrder(bytes32 orderId) internal view returns (ParkedOrder memory) {
        return IAuraSettlementSource(address(hook)).orders(orderId);
    }
}
