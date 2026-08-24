// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {IAuraRouter} from "./interfaces/IAuraRouter.sol";
import {AuraOrderData} from "./types/AuraTypes.sol";

/// @title AuraRouter
/// @notice The sole authenticated entrypoint for exact-input Aura orders.
/// @dev Owner identity is derived only from `msg.sender`. AuraHook must independently require that
///      its `sender` is this router and must validate all decoded order data.
contract AuraRouter is IAuraRouter, IUnlockCallback {
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    /// @notice The only supported Aura order-data format.
    uint8 public constant ORDER_DATA_VERSION = 1;

    /// @notice Minimum lifetime required by the Aura protocol for an admitted order.
    uint64 public constant MIN_ORDER_LIFETIME_SECONDS = 13 hours;

    /// @notice PoolManager used for all router unlocks.
    IPoolManager public immutable override poolManager;

    /// @notice Immutable identifier for the only pool this router can access.
    PoolId public immutable auraPoolId;

    Currency private immutable _currency0;
    Currency private immutable _currency1;
    uint24 private immutable _fee;
    int24 private immutable _tickSpacing;
    IHooks private immutable _hooks;

    /// @notice The next nonce to bind to an owner's order.
    mapping(address owner => uint64 nonce) public nextNonce;

    bool private _unlocking;

    error InvalidPoolManager();
    error InvalidHook();
    error InvalidAmount();
    error InvalidMinimumOutput();
    error InvalidDeadline();
    error InvalidNativeValue();
    error NonceOverflow();
    error UnauthorizedUnlockCallback();
    error UnexpectedUnlock();

    /// @notice Creates a router permanently bound to `auraPoolKey`.
    /// @param poolManager_ The Uniswap v4 PoolManager used by the configured Aura pool.
    /// @param auraPoolKey_ The only PoolKey this router will submit.
    constructor(IPoolManager poolManager_, PoolKey memory auraPoolKey_) {
        if (address(poolManager_) == address(0)) revert InvalidPoolManager();
        if (address(auraPoolKey_.hooks) == address(0)) revert InvalidHook();

        poolManager = poolManager_;
        auraPoolId = auraPoolKey_.toId();
        _currency0 = auraPoolKey_.currency0;
        _currency1 = auraPoolKey_.currency1;
        _fee = auraPoolKey_.fee;
        _tickSpacing = auraPoolKey_.tickSpacing;
        _hooks = auraPoolKey_.hooks;
    }

    /// @notice Returns the single immutable PoolKey accepted by this router.
    function auraPoolKey() public view returns (PoolKey memory) {
        return PoolKey(_currency0, _currency1, _fee, _tickSpacing, _hooks);
    }

    /// @inheritdoc IAuraRouter
    function placeOrder(bool zeroForOne, uint128 amountIn, uint128 minAmountOut, address recipient, uint64 deadline)
        external
        payable
        override
        returns (BalanceDelta swapDelta)
    {
        if (_unlocking) revert UnexpectedUnlock();
        if (amountIn == 0 || amountIn > uint128(type(int128).max)) revert InvalidAmount();
        if (minAmountOut == 0 || minAmountOut > uint128(type(int128).max)) revert InvalidMinimumOutput();
        if (uint256(deadline) < block.timestamp + MIN_ORDER_LIFETIME_SECONDS) {
            revert InvalidDeadline();
        }

        Currency inputCurrency = zeroForOne ? _currency0 : _currency1;
        if (Currency.unwrap(inputCurrency) == address(0)) {
            if (msg.value != amountIn) revert InvalidNativeValue();
        } else if (msg.value != 0) {
            revert InvalidNativeValue();
        }

        uint64 nonce = nextNonce[msg.sender];
        if (nonce == type(uint64).max) revert NonceOverflow();
        unchecked {
            nextNonce[msg.sender] = nonce + 1;
        }

        AuraOrderData memory order = AuraOrderData({
            version: ORDER_DATA_VERSION,
            owner: msg.sender,
            recipient: recipient == address(0) ? msg.sender : recipient,
            nonce: nonce,
            deadline: deadline,
            minAmountOut: minAmountOut
        });
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(uint256(amountIn)),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        _unlocking = true;
        bytes memory result = poolManager.unlock(abi.encode(msg.sender, inputCurrency, amountIn, params, order));
        _unlocking = false;
        swapDelta = abi.decode(result, (BalanceDelta));
    }

    /// @notice Executes one router-authenticated parking swap and settles its input delta.
    /// @dev Only PoolManager may call this callback. Its data is created internally by `placeOrder`;
    ///      users cannot choose a PoolKey, owner, nonce, or hook payload.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedUnlockCallback();
        if (!_unlocking) revert UnexpectedUnlock();

        (
            address owner,
            Currency inputCurrency,
            uint128 amountIn,
            SwapParams memory params,
            AuraOrderData memory order
        ) = abi.decode(data, (address, Currency, uint128, SwapParams, AuraOrderData));

        BalanceDelta swapDelta = poolManager.swap(auraPoolKey(), params, abi.encode(order));
        inputCurrency.settle(poolManager, owner, amountIn, false);

        return abi.encode(swapDelta);
    }
}
