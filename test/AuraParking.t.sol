// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {AuraHook} from "../src/AuraHook.sol";
import {AuraRouter} from "../src/AuraRouter.sol";
import {AuraOrderData, OrderStatus, BatchStatus} from "../src/types/AuraTypes.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

abstract contract AuraParkingBase is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
    uint128 internal constant AMOUNT = 1 ether;
    uint128 internal constant MINIMUM = 0.9 ether;

    AuraHook internal hook;
    AuraRouter internal router;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal key;
    PoolId internal poolId;
    address internal owner = makeAddr("owner");

    function setUp() public virtual {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes memory args = abi.encode(poolManager, predictedRouter, currency0, currency1, uint24(3000), int24(60));
        (address mined, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(AuraHook).creationCode, args);

        key = PoolKey(currency0, currency1, 3000, 60, IHooks(mined));
        router = new AuraRouter(poolManager, key);
        assertEq(address(router), predictedRouter);
        hook = new AuraHook{salt: salt}(poolManager, router, currency0, currency1, 3000, 60);
        assertEq(address(hook), mined);
        poolId = key.toId();

        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(key.tickSpacing);
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), 100 ether
        );
        positionManager.mint(
            key, lower, upper, 100 ether, amount0 + 1, amount1 + 1, address(this), block.timestamp + 1, ""
        );

        MockERC20(Currency.unwrap(currency0)).mint(owner, type(uint128).max);
        MockERC20(Currency.unwrap(currency1)).mint(owner, type(uint128).max);
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _place(bool zeroForOne, uint128 amount, uint128 minimum) internal {
        uint64 deadline = uint64(block.timestamp + router.MIN_ORDER_LIFETIME_SECONDS());
        vm.prank(owner);
        router.placeOrder(zeroForOne, amount, minimum, owner, deadline);
    }

    function _data(uint64 nonce) internal view returns (bytes memory) {
        return abi.encode(
            AuraOrderData({
                version: 1,
                owner: owner,
                recipient: owner,
                nonce: nonce,
                deadline: uint64(block.timestamp + 13 hours),
                minAmountOut: MINIMUM
            })
        );
    }
}

contract AuraParkingTest is AuraParkingBase {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function test_permissionsAndMinedAddress() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.beforeSwapReturnDelta);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
    }

    function test_parksCurrency0WithExactBackingAndNoCurveMovement() public {
        _assertParking(true);
    }

    function test_parksCurrency1WithExactBackingAndNoCurveMovement() public {
        _assertParking(false);
    }

    function test_recordsImmutableOrderAndReadyTransition() public {
        _place(true, AMOUNT, MINIMUM);
        _place(false, AMOUNT, MINIMUM);
        bytes32[] memory ids = hook.batchOrderIds(1);
        assertEq(ids.length, 2);
        (address storedOwner,,,,, bool direction, uint128 amount,, OrderStatus status) = hook.orders(ids[0]);
        assertEq(storedOwner, owner);
        assertTrue(direction);
        assertEq(amount, AMOUNT);
        assertEq(uint8(status), uint8(OrderStatus.PARKED));
        assertEq(uint8(hook.batchStatus(1)), uint8(BatchStatus.READY));
    }

    function test_rejectsSpoofedRouter() public {
        vm.prank(address(poolManager));
        vm.expectRevert(AuraHook.UnauthorizedRouter.selector);
        hook.beforeSwap(address(this), key, _params(true, -int256(uint256(AMOUNT))), _data(0));
    }

    function test_rejectsWrongPool() public {
        PoolKey memory wrong = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.prank(address(poolManager));
        vm.expectRevert(AuraHook.InvalidPool.selector);
        hook.beforeSwap(address(router), wrong, _params(true, -int256(uint256(AMOUNT))), _data(0));
    }

    function test_rejectsExactOutputAndMalformedData() public {
        vm.startPrank(address(poolManager));
        vm.expectRevert(AuraHook.ExactOutputUnsupported.selector);
        hook.beforeSwap(address(router), key, _params(true, int256(uint256(AMOUNT))), _data(0));
        vm.expectRevert(AuraHook.MalformedOrderData.selector);
        hook.beforeSwap(address(router), key, _params(true, -int256(uint256(AMOUNT))), hex"01");
        vm.stopPrank();
    }

    function test_rejectsExpiredInvalidAndOverflowOrders() public {
        AuraOrderData memory data = abi.decode(_data(0), (AuraOrderData));
        data.deadline = uint64(block.timestamp);
        vm.prank(address(poolManager));
        vm.expectRevert(AuraHook.ExpiredOrder.selector);
        hook.beforeSwap(address(router), key, _params(true, -int256(uint256(AMOUNT))), abi.encode(data));

        vm.prank(address(poolManager));
        vm.expectRevert(AuraHook.AmountOverflow.selector);
        hook.beforeSwap(address(router), key, _params(true, -int256(type(int128).max) - 1), _data(0));

        data = abi.decode(_data(0), (AuraOrderData));
        data.minAmountOut = 0;
        vm.prank(address(poolManager));
        vm.expectRevert(AuraHook.InvalidOrder.selector);
        hook.beforeSwap(address(router), key, _params(true, -int256(uint256(AMOUNT))), abi.encode(data));
    }

    function test_rejectsReplayAndEnforcesDirectionalCapacity() public {
        _place(true, AMOUNT, MINIMUM);
        bytes32 id = hook.batchOrderIds(1)[0];
        AuraOrderData memory replay = abi.decode(_data(0), (AuraOrderData));
        vm.prank(address(poolManager));
        vm.expectRevert(AuraHook.OrderReplay.selector);
        hook.beforeSwap(address(router), key, _params(true, -int256(uint256(AMOUNT))), abi.encode(replay));
        (,,,,,,,, OrderStatus replayStatus) = hook.orders(id);
        assertEq(uint8(replayStatus), uint8(OrderStatus.PARKED));

        _place(true, AMOUNT, MINIMUM);
        _place(true, AMOUNT, MINIMUM);
        vm.prank(owner);
        vm.expectRevert();
        router.placeOrder(true, AMOUNT, MINIMUM, owner, uint64(block.timestamp + 13 hours));
        _place(false, AMOUNT, MINIMUM);
        assertEq(hook.batchOrderCount(1), hook.MAX_BATCH_ORDERS());
    }

    function test_rejectsIncompatibleLimits() public {
        _place(true, AMOUNT, 2 ether);
        vm.prank(owner);
        vm.expectRevert();
        router.placeOrder(false, AMOUNT, MINIMUM, owner, uint64(block.timestamp + 13 hours));
    }

    function test_oneSidedTimeoutRefundBurnsClaimAndReturnsExactInput() public {
        uint256 ownerBefore = MockERC20(Currency.unwrap(currency0)).balanceOf(owner);
        _place(true, AMOUNT, MINIMUM);
        bytes32 orderId = hook.batchOrderIds(1)[0];
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(owner), ownerBefore - AMOUNT);

        vm.roll(uint256(hook.openedAtBlock(1)) + hook.MAX_BATCH_WINDOW() + 1);
        hook.closeBatch(1);
        assertEq(uint8(hook.batchStatus(1)), uint8(BatchStatus.REFUNDABLE));

        vm.prank(owner);
        hook.cancelExpiredOrder(orderId);
        (,,,,,,,, OrderStatus status) = hook.orders(orderId);
        assertEq(uint8(status), uint8(OrderStatus.CANCELLED));
        assertEq(poolManager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(owner), ownerBefore);
        assertEq(poolManager.currencyDelta(address(hook), currency0), 0);

        _place(false, AMOUNT, MINIMUM);
        assertEq(hook.activeBatchId(), 2);
        assertEq(hook.batchOrderCount(2), 1);
    }

    function test_timeoutBoundaryIsStrictAndCloseIsPermissionless() public {
        _place(true, AMOUNT, MINIMUM);
        uint256 boundary = uint256(hook.openedAtBlock(1)) + hook.MAX_BATCH_WINDOW();
        vm.roll(boundary);
        vm.expectRevert(AuraHook.BatchWindowActive.selector);
        hook.closeBatch(1);

        vm.roll(boundary + 1);
        vm.prank(makeAddr("closer"));
        hook.closeBatch(1);
        assertEq(uint8(hook.batchStatus(1)), uint8(BatchStatus.REFUNDABLE));
    }

    function test_refundRejectsEarlyWrongOwnerReplayAndDirectCallback() public {
        _place(true, AMOUNT, MINIMUM);
        bytes32 orderId = hook.batchOrderIds(1)[0];
        vm.prank(owner);
        vm.expectRevert(AuraHook.BatchNotRefundable.selector);
        hook.cancelExpiredOrder(orderId);

        vm.roll(uint256(hook.openedAtBlock(1)) + hook.MAX_BATCH_WINDOW() + 1);
        hook.closeBatch(1);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(AuraHook.UnauthorizedOrderOwner.selector);
        hook.cancelExpiredOrder(orderId);

        vm.prank(owner);
        hook.cancelExpiredOrder(orderId);
        vm.prank(owner);
        vm.expectRevert(AuraHook.OrderNotParked.selector);
        hook.cancelExpiredOrder(orderId);

        vm.expectRevert(AuraHook.UnauthorizedUnlockCallback.selector);
        hook.unlockCallback(abi.encode(orderId));
        vm.prank(address(poolManager));
        vm.expectRevert(AuraHook.InvalidRefundContext.selector);
        hook.unlockCallback(abi.encode(orderId));
    }

    function test_readyBatchCannotUseOneSidedTimeoutClose() public {
        _place(true, AMOUNT, MINIMUM);
        _place(false, AMOUNT, MINIMUM);
        vm.roll(uint256(hook.openedAtBlock(1)) + hook.MAX_BATCH_WINDOW() + 1);
        vm.expectRevert(AuraHook.BatchNotOpen.selector);
        hook.closeBatch(1);
    }

    function _assertParking(bool zeroForOne) internal {
        Currency input = zeroForOne ? currency0 : currency1;
        uint256 claimsBefore = poolManager.balanceOf(address(hook), input.toId());
        uint256 custodyBefore = MockERC20(Currency.unwrap(input)).balanceOf(address(poolManager));
        (uint160 sqrtBefore, int24 tickBefore,,) = poolManager.getSlot0(poolId);
        uint128 liquidityBefore = poolManager.getLiquidity(poolId);
        _place(zeroForOne, AMOUNT, MINIMUM);
        assertEq(poolManager.balanceOf(address(hook), input.toId()) - claimsBefore, AMOUNT);
        assertEq(MockERC20(Currency.unwrap(input)).balanceOf(address(poolManager)) - custodyBefore, AMOUNT);
        (uint160 sqrtAfter, int24 tickAfter,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtAfter, sqrtBefore);
        assertEq(tickAfter, tickBefore);
        assertEq(poolManager.getLiquidity(poolId), liquidityBefore);
        assertEq(poolManager.currencyDelta(address(router), input), 0);
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }
}

contract AuraParkingInvariant is AuraParkingBase {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        _place(true, AMOUNT, MINIMUM);
        _place(false, AMOUNT, MINIMUM);
    }

    function invariant_claimBackingIsCurrencyScopedAndExact() public view {
        assertEq(poolManager.balanceOf(address(hook), currency0.toId()), hook.aggregateToken0Input(1));
        assertEq(poolManager.balanceOf(address(hook), currency1.toId()), hook.aggregateToken1Input(1));
    }

    function invariant_batchWorkIsBoundedAndPoolUnchanged() public view {
        assertLe(hook.batchOrderCount(1), hook.MAX_BATCH_ORDERS());
        (uint160 sqrtPrice, int24 tick,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtPrice, Constants.SQRT_PRICE_1_1);
        assertEq(tick, 0);
    }
}
