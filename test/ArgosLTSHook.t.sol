// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {ArgosLTSHook} from "../src/ArgosLTSHook.sol";

/// @title ArgosLTSHookTest
/// @notice Full coverage test suite for ArgosLTSHook v2.
///         Tests are ordered to match the spec requirements exactly.
contract ArgosLTSHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint160 internal constant FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
    uint128 internal constant SEED_LIQUIDITY = 100e18;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    PoolId poolId;

    ArgosLTSHook hook;

    address sensor; // simulated Reactive Network sensor

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        deployArtifactsAndLabel();

        sensor = makeAddr("reactiveSensor");
        (currency0, currency1) = deployCurrencyPair();

        // Deploy hook at a flags-encoded address (required by Uniswap V4 validation)
        address flags = address(FLAGS ^ (0x5555 << 144));
        bytes memory args = abi.encode(poolManager, sensor, address(this));
        deployCodeTo("ArgosLTSHook.sol:ArgosLTSHook", args, flags);
        hook = ArgosLTSHook(flags);

        // Initialize the pool and seed liquidity
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            SEED_LIQUIDITY
        );

        positionManager.mint(
            poolKey, tickLower, tickUpper, SEED_LIQUIDITY, amt0 + 1, amt1 + 1, address(this), block.timestamp, ""
        );

        // Enable PARK mode on the default pool
        hook.setParkingMode(poolKey, true);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Normal swap passes through
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A non-flagged address swaps normally — no parking, base fee applied.
    function test_normalSwap_passesThrough() public {
        uint256 amountIn = 1e18;

        uint256 preBal = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        BalanceDelta delta = _swapExactInput(amountIn);
        uint256 postBal = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // Full input was consumed
        assertEq(int256(delta.amount0()), -int256(amountIn), "amount0 should be -amountIn");
        // Some output was received (normal swap)
        assertGt(postBal, preBal, "should receive currency1 output");
        // No parking occurred
        assertEq(hook.parkedClaims(address(swapRouter), currency0.toId()), 0, "no claims");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Toxic address swap is parked
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Flagging an address and then swapping parks the input as ERC-6909.
    function test_toxicAddress_swapParked() public {
        uint256 amountIn = 1e18;
        uint256 currencyId = currency0.toId();

        // Flag the router (which is the sender in V4's beforeSwap)
        vm.prank(sensor);
        hook.flagToxicAddress(address(swapRouter));

        // Verify flag is active
        assertGt(hook.toxicExpiry(address(swapRouter)), block.timestamp, "flag should be set");

        uint256 preHookClaim = poolManager.balanceOf(address(hook), currencyId);

        // Execute swap — should be intercepted & parked
        vm.expectEmit(true, true, true, true, address(hook));
        emit ArgosLTSHook.SwapParked(address(swapRouter), currencyId, amountIn);

        BalanceDelta delta = _swapExactInput(amountIn);

        // Input was consumed (delta0 = -amountIn)
        assertEq(int256(delta.amount0()), -int256(amountIn), "amount0 = -amountIn");
        // No output was produced (swap was suppressed)
        assertEq(int256(delta.amount1()), 0, "amount1 = 0 (swap suppressed)");

        // Hook's ERC-6909 balance in PoolManager increased
        uint256 postHookClaim = poolManager.balanceOf(address(hook), currencyId);
        assertEq(postHookClaim - preHookClaim, amountIn, "hook ERC-6909 balance increased");

        // Hook's internal ledger records the parked claim
        assertEq(hook.parkedClaims(address(swapRouter), currencyId), amountIn, "parkedClaims tracked");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Parked claim can be redeemed
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice After parking, redeemParkedClaim() returns tokens to the user.
    function test_parkedClaim_redeemed() public {
        uint256 amountIn = 1e18;
        uint256 currencyId = currency0.toId();

        // Park a claim
        vm.prank(sensor);
        hook.flagToxicAddress(address(swapRouter));
        _swapExactInput(amountIn);

        assertEq(hook.parkedClaims(address(swapRouter), currencyId), amountIn);

        // Capture pre-redemption balance of the swapRouter
        uint256 preBal = MockERC20(Currency.unwrap(currency0)).balanceOf(address(swapRouter));

        // Redeem — must be called by the parked user (swapRouter in V4 test infra)
        vm.expectEmit(true, true, true, true, address(hook));
        emit ArgosLTSHook.ParkedClaimRedeemed(address(swapRouter), currencyId, amountIn);

        vm.prank(address(swapRouter));
        hook.redeemParkedClaim(currency0, amountIn);

        // Claim is cleared
        assertEq(hook.parkedClaims(address(swapRouter), currencyId), 0, "parkedClaims should be 0");

        // Tokens arrived in the swapRouter's ERC-20 balance
        uint256 postBal = MockERC20(Currency.unwrap(currency0)).balanceOf(address(swapRouter));
        assertEq(postBal - preBal, amountIn, "tokens returned to user");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Toxic flag expires — swap passes through after TOXIC_WINDOW
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice After TOXIC_WINDOW elapses, the flagged address swaps normally.
    function test_toxicFlag_expiry() public {
        uint256 amountIn = 1e18;
        uint256 currencyId = currency0.toId();

        vm.prank(sensor);
        hook.flagToxicAddress(address(swapRouter));
        assertGt(hook.toxicExpiry(address(swapRouter)), block.timestamp);

        // Warp past the toxic window
        vm.warp(block.timestamp + hook.TOXIC_WINDOW() + 1);

        // Flag should have expired
        assertLe(hook.toxicExpiry(address(swapRouter)), block.timestamp, "flag expired");

        // Perform swap — should execute normally (no parking)
        BalanceDelta delta = _swapExactInput(amountIn);

        // Normal swap: negative amount0 in, positive amount1 out
        assertEq(int256(delta.amount0()), -int256(amountIn));
        assertGt(int256(delta.amount1()), 0, "should receive output after flag expires");

        // No parking occurred
        assertEq(hook.parkedClaims(address(swapRouter), currencyId), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Penalty fee applied in PENALIZE mode
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice In PENALIZE mode, a toxic swap is allowed but ToxicSwapPenalized is emitted.
    /// @dev    Uses a separate pool with parkingEnabled = false (PENALIZE mode).
    ///         Dynamic fee override only takes effect on LPFeeLibrary.DYNAMIC_FEE_FLAG pools;
    ///         for this test we verify the event emission (hook logic correctness).
    function test_penaltyFee_applied() public {
        // Deploy a second pool without parking enabled (default = PENALIZE mode)
        Currency c0;
        Currency c1;
        (c0, c1) = deployCurrencyPair();

        address penalizeFlags = address(FLAGS ^ (0x6666 << 144));
        bytes memory args = abi.encode(poolManager, sensor, address(this));
        deployCodeTo("ArgosLTSHook.sol:ArgosLTSHook", args, penalizeFlags);
        ArgosLTSHook penalizeHook = ArgosLTSHook(penalizeFlags);
        // parkingEnabled defaults to false → PENALIZE mode

        PoolKey memory penalizeKey = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(penalizeHook));
        poolManager.initialize(penalizeKey, Constants.SQRT_PRICE_1_1);

        int24 tl = TickMath.minUsableTick(penalizeKey.tickSpacing);
        int24 tu = TickMath.maxUsableTick(penalizeKey.tickSpacing);
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), 100e18
        );
        positionManager.mint(penalizeKey, tl, tu, 100e18, a0 + 1, a1 + 1, address(this), block.timestamp, "");

        // Flag the router via the new hook's sensor
        vm.prank(sensor);
        penalizeHook.flagToxicAddress(address(swapRouter));

        // Expect ToxicSwapPenalized event with a fee between BASE_FEE and TOXIC_FEE
        vm.expectEmit(true, false, false, false, address(penalizeHook));
        emit ArgosLTSHook.ToxicSwapPenalized(address(swapRouter), 0); // fee value checked below

        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: penalizeKey,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Find and verify ToxicSwapPenalized event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ToxicSwapPenalized(address,uint24)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig && logs[i].emitter == address(penalizeHook)) {
                uint24 fee = abi.decode(logs[i].data, (uint24));
                assertGe(fee, penalizeHook.BASE_FEE(), "penalty fee >= BASE_FEE");
                assertLe(fee, penalizeHook.TOXIC_FEE(), "penalty fee <= TOXIC_FEE");
                found = true;
                break;
            }
        }
        assertTrue(found, "ToxicSwapPenalized event not found");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6. Unauthorized sensor call reverts
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Calling flagToxicAddress from a non-sensor address must revert.
    function test_sensor_unauthorized() public {
        address impostor = makeAddr("impostor");
        vm.prank(impostor);
        vm.expectRevert(ArgosLTSHook.Unauthorized.selector);
        hook.flagToxicAddress(address(swapRouter));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 7. Fuzz — park and redeem roundtrip
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Fuzz test: any valid amountIn can be parked and fully redeemed.
    function test_fuzz_parkAndRedeem(uint128 amount) public {
        vm.assume(amount > 0 && amount <= 10e18);

        uint256 currencyId = currency0.toId();

        // Flag the router
        vm.prank(sensor);
        hook.flagToxicAddress(address(swapRouter));

        // Park
        _swapExactInput(amount);
        assertEq(hook.parkedClaims(address(swapRouter), currencyId), amount, "park amount tracked");

        // Redeem
        uint256 preBal = MockERC20(Currency.unwrap(currency0)).balanceOf(address(swapRouter));
        vm.prank(address(swapRouter));
        hook.redeemParkedClaim(currency0, amount);

        assertEq(hook.parkedClaims(address(swapRouter), currencyId), 0, "claim cleared");
        assertEq(
            MockERC20(Currency.unwrap(currency0)).balanceOf(address(swapRouter)) - preBal,
            amount,
            "full amount returned"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _swapExactInput(uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }
}
