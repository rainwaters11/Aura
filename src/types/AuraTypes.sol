// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Authenticated metadata supplied by AuraRouter to AuraHook for one exact-input order.
/// @dev `amountIn` and direction are deliberately absent: AuraHook derives both from `SwapParams`.
struct AuraOrderData {
    uint8 version;
    address owner;
    address recipient;
    uint64 nonce;
    uint64 deadline;
    uint128 minAmountOut;
}
