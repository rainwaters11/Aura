// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {BaseAsyncSwap} from "@openzeppelin/uniswap-hooks/src/base/BaseAsyncSwap.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {AuraRouter} from "../src/AuraRouter.sol";
import {AuraOrderData} from "../src/types/AuraTypes.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

contract AuraRouterAsyncHookHarness is BaseAsyncSwap {
    using PoolIdLibrary for PoolKey;

    error AlreadyConfigured();
    error UnauthorizedRouter();
    error InvalidPool();
    error InvalidOrder();
    error UnsupportedSwapMode();

    address public authorizedRouter;
    PoolId public expectedPoolId;

    address public lastSender;
    bool public lastZeroForOne;
    int256 public lastAmountSpecified;
    uint256 public lastAmountIn;
    AuraOrderData public lastOrderData;

    constructor(IPoolManager manager) BaseHook(manager) {}

    function configure(address authorizedRouter_, PoolId expectedPoolId_) external {
        if (authorizedRouter != address(0)) revert AlreadyConfigured();
        authorizedRouter = authorizedRouter_;
        expectedPoolId = expectedPoolId_;
    }

    function getLastOrderData() external view returns (AuraOrderData memory) {
        return lastOrderData;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender != authorizedRouter) revert UnauthorizedRouter();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(expectedPoolId)) revert InvalidPool();

        AuraOrderData memory order = abi.decode(hookData, (AuraOrderData));
        if (order.owner == address(0) || order.recipient == address(0) || order.minAmountOut == 0) {
            revert InvalidOrder();
        }

        lastSender = sender;
        lastZeroForOne = params.zeroForOne;
        lastAmountSpecified = params.amountSpecified;
        if (params.amountSpecified >= 0) revert UnsupportedSwapMode();
        lastAmountIn = uint256(-params.amountSpecified);
        lastOrderData = order;

        return super._beforeSwap(sender, key, params, hookData);
    }
}

contract AuraRouterIntegrationTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
    uint128 internal constant SEED_LIQUIDITY = 100e18;
    uint128 internal constant AMOUNT_IN = 1 ether;
    uint128 internal constant MIN_AMOUNT_OUT = 0.9 ether;

    AuraRouter internal router;
    AuraRouterAsyncHookHarness internal hook;

    Currency internal currency0;
    Currency internal currency1;

    PoolKey internal poolKey;
    PoolId internal poolId;

    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal spoofedOwner = makeAddr("spoofedOwner");

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        bytes memory constructorArgs = abi.encode(poolManager);
        (address minedHookAddress, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(AuraRouterAsyncHookHarness).creationCode, constructorArgs);
        hook = new AuraRouterAsyncHookHarness{salt: salt}(poolManager);
        assertEq(address(hook), minedHookAddress);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();
        router = new AuraRouter(poolManager, poolKey);
        hook.configure(address(router), poolId);

        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            SEED_LIQUIDITY
        );

        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            SEED_LIQUIDITY,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp + 1,
            ""
        );

        MockERC20(Currency.unwrap(currency0)).mint(owner, type(uint128).max);
        MockERC20(Currency.unwrap(currency1)).mint(owner, type(uint128).max);
        vm.prank(owner);
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        vm.prank(owner);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    function test_placeOrder_Integration_ParksAndPreservesPoolState() public {
        uint64 deadline = uint64(block.timestamp + router.MIN_ORDER_LIFETIME_SECONDS());
        uint256 preHookClaim = poolManager.balanceOf(address(hook), currency0.toId());
        uint256 prePoolCustody = MockERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        (uint160 preSqrtPriceX96, int24 preTick,,) = poolManager.getSlot0(poolId);
        uint128 preLiquidity = poolManager.getLiquidity(poolId);

        vm.prank(owner);
        router.placeOrder(true, AMOUNT_IN, MIN_AMOUNT_OUT, recipient, deadline);

        assertEq(hook.lastSender(), address(router));
        assertEq(hook.lastZeroForOne(), true);
        assertEq(hook.lastAmountSpecified(), -int256(uint256(AMOUNT_IN)));
        assertEq(hook.lastAmountIn(), AMOUNT_IN);
        {
            AuraOrderData memory observed = hook.getLastOrderData();
            assertEq(observed.version, router.ORDER_DATA_VERSION());
            assertEq(observed.owner, owner);
            assertEq(observed.recipient, recipient);
            assertEq(observed.nonce, 0);
            assertEq(observed.deadline, deadline);
            assertEq(observed.minAmountOut, MIN_AMOUNT_OUT);
        }

        assertEq(poolManager.balanceOf(address(hook), currency0.toId()) - preHookClaim, AMOUNT_IN);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager)) - prePoolCustody, AMOUNT_IN);

        (uint160 postSqrtPriceX96, int24 postTick,,) = poolManager.getSlot0(poolId);
        uint128 postLiquidity = poolManager.getLiquidity(poolId);
        assertEq(postSqrtPriceX96, preSqrtPriceX96);
        assertEq(postTick, preTick);
        assertEq(postLiquidity, preLiquidity);
    }

    function test_placeOrder_Integration_ScopesBackingToSpecifiedCurrency() public {
        uint64 deadline = uint64(block.timestamp + router.MIN_ORDER_LIFETIME_SECONDS());
        uint256 preCurrency0Claim = poolManager.balanceOf(address(hook), currency0.toId());
        uint256 preCurrency1Claim = poolManager.balanceOf(address(hook), currency1.toId());
        uint256 preCurrency1Custody = MockERC20(Currency.unwrap(currency1)).balanceOf(address(poolManager));

        vm.prank(owner);
        router.placeOrder(false, AMOUNT_IN, MIN_AMOUNT_OUT, recipient, deadline);

        assertEq(poolManager.balanceOf(address(hook), currency0.toId()), preCurrency0Claim);
        assertEq(poolManager.balanceOf(address(hook), currency1.toId()) - preCurrency1Claim, AMOUNT_IN);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(poolManager)) - preCurrency1Custody, AMOUNT_IN);
    }

    function test_placeOrder_Integration_RejectsUnauthorizedRouter() public {
        AuraOrderData memory order = AuraOrderData({
            version: router.ORDER_DATA_VERSION(),
            owner: address(this),
            recipient: recipient,
            nonce: 0,
            deadline: uint64(block.timestamp + router.MIN_ORDER_LIFETIME_SECONDS()),
            minAmountOut: MIN_AMOUNT_OUT
        });

        _expectUnauthorizedRouterWrappedRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: AMOUNT_IN,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(order),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function test_placeOrder_Integration_RejectsSpoofedOwner() public {
        AuraOrderData memory spoofedOrder = AuraOrderData({
            version: router.ORDER_DATA_VERSION(),
            owner: spoofedOwner,
            recipient: recipient,
            nonce: 777,
            deadline: uint64(block.timestamp + router.MIN_ORDER_LIFETIME_SECONDS()),
            minAmountOut: MIN_AMOUNT_OUT
        });

        _expectUnauthorizedRouterWrappedRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: AMOUNT_IN,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: abi.encode(spoofedOrder),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function test_placeOrder_Integration_PreventsOwnerSpoofingThroughRecipient() public {
        uint64 deadline = uint64(block.timestamp + router.MIN_ORDER_LIFETIME_SECONDS());

        vm.prank(owner);
        router.placeOrder(true, AMOUNT_IN, MIN_AMOUNT_OUT, spoofedOwner, deadline);

        AuraOrderData memory observed = hook.getLastOrderData();
        assertEq(observed.owner, owner);
        assertEq(observed.recipient, spoofedOwner);
    }

    function _expectUnauthorizedRouterWrappedRevert() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(AuraRouterAsyncHookHarness.UnauthorizedRouter.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }
}
