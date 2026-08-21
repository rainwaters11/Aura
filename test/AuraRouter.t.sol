// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {AuraRouter} from "../src/AuraRouter.sol";
import {AuraOrderData} from "../src/types/AuraTypes.sol";

contract AuraRouterPoolManagerMock {
    using PoolIdLibrary for PoolKey;

    address public lastSwapSender;
    PoolId public lastPoolId;
    bool public lastZeroForOne;
    int256 public lastAmountSpecified;
    bytes private _lastHookData;
    uint256 public settledValue;

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta)
    {
        lastSwapSender = msg.sender;
        lastPoolId = key.toId();
        lastZeroForOne = params.zeroForOne;
        lastAmountSpecified = params.amountSpecified;
        _lastHookData = hookData;
        return BalanceDeltaLibrary.ZERO_DELTA;
    }

    function lastHookData() external view returns (bytes memory) {
        return _lastHookData;
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        settledValue = msg.value;
        return msg.value;
    }
}

contract AuraRouterTest is Test {
    using PoolIdLibrary for PoolKey;

    AuraRouter internal router;
    AuraRouterPoolManagerMock internal poolManager;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal poolKey;

    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");

    uint128 internal constant AMOUNT_IN = 1 ether;
    uint128 internal constant MIN_AMOUNT_OUT = 0.9 ether;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        poolManager = new AuraRouterPoolManagerMock();
        poolKey = PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(makeAddr("auraHook"))
        );
        router = new AuraRouter(IPoolManager(address(poolManager)), poolKey);

        token0.mint(owner, type(uint128).max);
        token1.mint(owner, type(uint128).max);
        vm.prank(owner);
        token0.approve(address(router), type(uint256).max);
        vm.prank(owner);
        token1.approve(address(router), type(uint256).max);
    }

    function test_placeOrderAuthenticatesOwnerDefaultsRecipientAndBindsPool() public {
        uint64 deadline = uint64(block.timestamp + router.MIN_ORDER_LIFETIME_SECONDS());

        vm.prank(owner);
        router.placeOrder(true, AMOUNT_IN, MIN_AMOUNT_OUT, address(0), deadline);

        AuraOrderData memory order = abi.decode(poolManager.lastHookData(), (AuraOrderData));
        assertEq(order.version, router.ORDER_DATA_VERSION());
        assertEq(order.owner, owner);
        assertEq(order.recipient, owner);
        assertEq(order.nonce, 0);
        assertEq(order.deadline, deadline);
        assertEq(order.minAmountOut, MIN_AMOUNT_OUT);
        assertEq(poolManager.lastSwapSender(), address(router));
        assertEq(PoolId.unwrap(poolManager.lastPoolId()), PoolId.unwrap(poolKey.toId()));
        assertTrue(poolManager.lastZeroForOne());
        assertEq(poolManager.lastAmountSpecified(), -int256(uint256(AMOUNT_IN)));
        assertEq(token0.balanceOf(address(poolManager)), AMOUNT_IN);
    }

    function test_placeOrderUsesSpecifiedRecipientAndIncrementsNonce() public {
        uint64 deadline = uint64(block.timestamp + router.MIN_ORDER_LIFETIME_SECONDS());

        vm.startPrank(owner);
        router.placeOrder(false, AMOUNT_IN, MIN_AMOUNT_OUT, recipient, deadline);
        router.placeOrder(false, AMOUNT_IN, MIN_AMOUNT_OUT, recipient, deadline);
        vm.stopPrank();

        AuraOrderData memory order = abi.decode(poolManager.lastHookData(), (AuraOrderData));
        assertEq(order.owner, owner);
        assertEq(order.recipient, recipient);
        assertEq(order.nonce, 1);
        assertEq(router.nextNonce(owner), 2);
        assertFalse(poolManager.lastZeroForOne());
        assertEq(token1.balanceOf(address(poolManager)), AMOUNT_IN * 2);
    }

    function test_placeOrderRejectsInvalidInputAndDeadline() public {
        uint64 validDeadline = uint64(block.timestamp + router.MIN_ORDER_LIFETIME_SECONDS());

        vm.startPrank(owner);
        vm.expectRevert(AuraRouter.InvalidAmount.selector);
        router.placeOrder(true, 0, MIN_AMOUNT_OUT, recipient, validDeadline);

        vm.expectRevert(AuraRouter.InvalidAmount.selector);
        router.placeOrder(true, uint128(type(int128).max) + 1, MIN_AMOUNT_OUT, recipient, validDeadline);

        vm.expectRevert(AuraRouter.InvalidMinimumOutput.selector);
        router.placeOrder(true, AMOUNT_IN, 0, recipient, validDeadline);

        vm.expectRevert(AuraRouter.InvalidMinimumOutput.selector);
        router.placeOrder(true, AMOUNT_IN, uint128(type(int128).max) + 1, recipient, validDeadline);

        vm.expectRevert(AuraRouter.InvalidDeadline.selector);
        router.placeOrder(
            true,
            AMOUNT_IN,
            MIN_AMOUNT_OUT,
            recipient,
            uint64(block.timestamp + router.MIN_ORDER_LIFETIME_SECONDS() - 1)
        );
        vm.stopPrank();
    }

    function test_placeOrderRejectsDirectUnlock() public {
        vm.expectRevert(AuraRouter.UnauthorizedUnlockCallback.selector);
        router.unlockCallback("");
    }

    function test_placeOrderSettlesNativeInput() public {
        AuraRouterPoolManagerMock nativePoolManager = new AuraRouterPoolManagerMock();
        PoolKey memory nativePoolKey = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token1)), 3000, 60, IHooks(makeAddr("nativeHook"))
        );
        AuraRouter nativeRouter = new AuraRouter(IPoolManager(address(nativePoolManager)), nativePoolKey);
        uint64 deadline = uint64(block.timestamp + nativeRouter.MIN_ORDER_LIFETIME_SECONDS());

        vm.deal(owner, AMOUNT_IN);
        vm.prank(owner);
        nativeRouter.placeOrder{value: AMOUNT_IN}(true, AMOUNT_IN, MIN_AMOUNT_OUT, recipient, deadline);

        assertEq(nativePoolManager.settledValue(), AMOUNT_IN);
    }

    function testFuzz_placeOrderBindsCallerAndNonce(uint128 amountIn, address fuzzRecipient) public {
        amountIn = uint128(bound(amountIn, 1, uint128(type(int128).max)));
        vm.assume(fuzzRecipient != address(0));

        uint64 deadline = uint64(block.timestamp + router.MIN_ORDER_LIFETIME_SECONDS());
        vm.prank(owner);
        router.placeOrder(true, amountIn, 1, fuzzRecipient, deadline);

        AuraOrderData memory order = abi.decode(poolManager.lastHookData(), (AuraOrderData));
        assertEq(order.owner, owner);
        assertEq(order.recipient, fuzzRecipient);
        assertEq(order.nonce, 0);
        assertEq(poolManager.lastAmountSpecified(), -int256(uint256(amountIn)));
    }
}
