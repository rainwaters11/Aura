// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {ArgosLTSHook} from "../src/ArgosLTSHook.sol";

/// @title ERC6909ParkingTest
/// @notice Edge-case tests for the ERC-6909 parking mechanic in ArgosLTSHook.
///         Tests are focused on parking lifecycle edge cases and boundary conditions.
contract ERC6909ParkingTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint160 internal constant FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    ArgosLTSHook hook;
    address sensor;

    function setUp() public {
        deployArtifactsAndLabel();
        sensor = makeAddr("sensor");
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(FLAGS ^ (0x7777 << 144));
        bytes memory args = abi.encode(poolManager, sensor, address(this));
        deployCodeTo("ArgosLTSHook.sol:ArgosLTSHook", args, flags);
        hook = ArgosLTSHook(flags);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tl = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tu = TickMath.maxUsableTick(poolKey.tickSpacing);
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), 100e18
        );
        positionManager.mint(poolKey, tl, tu, 100e18, a0 + 1, a1 + 1, address(this), block.timestamp, "");

        hook.setParkingMode(poolKey, true);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Edge case 1: zero-amount park reverts
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A swap with amountSpecified = 0 is not exact-input (>= 0) → UnsupportedParkMode.
    function test_parkZeroAmount_reverts() public {
        vm.prank(sensor);
        hook.flagToxicAddress(address(swapRouter));

        // amountSpecified = 0 is treated as exact-output (not exact-input)
        // _parkSwap reverts with UnsupportedParkMode when amountSpecified >= 0
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: 0,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Edge case 2: redeeming more than parked reverts
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Attempting to redeem more than the parked amount reverts with InsufficientParked.
    function test_redeemMoreThanParked_reverts() public {
        uint256 amountIn = 1e18;
        uint256 currencyId = currency0.toId();

        vm.prank(sensor);
        hook.flagToxicAddress(address(swapRouter));
        _swapExactInput(amountIn);

        assertEq(hook.parkedClaims(address(swapRouter), currencyId), amountIn);

        vm.prank(address(swapRouter));
        vm.expectRevert(ArgosLTSHook.InsufficientParked.selector);
        hook.redeemParkedClaim(currency0, amountIn + 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Edge case 3: multiple parks accumulate correctly
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Two parks for the same user/currency accumulate in parkedClaims.
    function test_multipleParks_accumulateCorrectly() public {
        uint256 amountA = 1e18;
        uint256 amountB = 2e18;
        uint256 currencyId = currency0.toId();

        vm.prank(sensor);
        hook.flagToxicAddress(address(swapRouter));

        _swapExactInput(amountA);
        assertEq(hook.parkedClaims(address(swapRouter), currencyId), amountA);

        _swapExactInput(amountB);
        assertEq(hook.parkedClaims(address(swapRouter), currencyId), amountA + amountB, "parks should accumulate");

        // Full redemption
        vm.prank(address(swapRouter));
        hook.redeemParkedClaim(currency0, amountA + amountB);
        assertEq(hook.parkedClaims(address(swapRouter), currencyId), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Edge case 4: different currencies tracked independently
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Parked amounts for different currencies are stored independently.
    function test_parkDifferentCurrencies_independent() public {
        uint256 amountIn = 1e18;

        vm.prank(sensor);
        hook.flagToxicAddress(address(swapRouter));

        uint256 currencyId0 = currency0.toId();
        uint256 currencyId1 = currency1.toId();

        // Park currency0 (zeroForOne = true → input = currency0)
        _swapExactInput(amountIn);
        assertEq(hook.parkedClaims(address(swapRouter), currencyId0), amountIn);
        assertEq(hook.parkedClaims(address(swapRouter), currencyId1), 0, "currency1 unaffected");

        // Park currency1 (zeroForOne = false → input = currency1)
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: false, // input is currency1
            poolKey: poolKey,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(hook.parkedClaims(address(swapRouter), currencyId1), amountIn, "currency1 tracked");
        // currency0 claim unchanged
        assertEq(hook.parkedClaims(address(swapRouter), currencyId0), amountIn, "currency0 unchanged");

        // Partial redemption of currency1 only
        vm.prank(address(swapRouter));
        hook.redeemParkedClaim(currency1, amountIn);
        assertEq(hook.parkedClaims(address(swapRouter), currencyId1), 0, "currency1 redeemed");
        assertEq(hook.parkedClaims(address(swapRouter), currencyId0), amountIn, "currency0 still parked");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper
    // ─────────────────────────────────────────────────────────────────────────

    function _swapExactInput(uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
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
