// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IAuraRouter
/// @notice The sole user-facing entrypoint for authenticated Aura exact-input orders.
interface IAuraRouter {
    function poolManager() external view returns (IPoolManager);

    function auraPoolId() external view returns (PoolId);

    function nextNonce(address owner) external view returns (uint64);

    /// @notice Places an exact-input order in the router's immutable Aura pool.
    /// @param zeroForOne True for currency0 to currency1; false for currency1 to currency0.
    /// @param amountIn Exact input amount.
    /// @param minAmountOut Minimum output accepted by the Aura auction.
    /// @param recipient Output-claim recipient; address(0) defaults to the caller.
    /// @param deadline Unix timestamp through which the order remains valid.
    /// @return swapDelta The PoolManager balance delta from the asynchronous parking swap.
    function placeOrder(bool zeroForOne, uint128 amountIn, uint128 minAmountOut, address recipient, uint64 deadline)
        external
        payable
        returns (BalanceDelta swapDelta);
}
