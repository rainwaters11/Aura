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

/// @notice Lifecycle of an order admitted into Aura custody.
enum OrderStatus {
    NONE,
    PARKED,
    SETTLED,
    CANCELLED,
    CLAIMED
}

/// @notice Lifecycle of a bounded Aura batch.
enum BatchStatus {
    NONE,
    OPEN,
    READY,
    CLOSED,
    SETTLING,
    SETTLED,
    FAILED,
    REFUNDABLE
}

/// @notice Immutable facts recorded when an order is parked.
struct ParkedOrder {
    address owner;
    address recipient;
    uint64 batchId;
    uint64 deadline;
    uint64 nonce;
    bool zeroForOne;
    uint128 amountIn;
    uint128 minAmountOut;
    OrderStatus status;
}

/// @notice Canonical bounded settlement proposal for one frozen Aura batch.
/// @dev `solutionHash` commits to every other field and the ordered array hashes,
///      but is deliberately excluded from its own preimage.
struct BatchSolution {
    uint64 batchId;
    uint64 deadline;
    uint128 priceNumerator;
    uint128 priceDenominator;
    bool residualZeroForOne;
    uint128 residualAmountIn;
    uint160 sqrtPriceLimitX96;
    bytes32 solutionHash;
    bytes32[] orderIds;
    uint128[] payouts;
}

/// @notice Canonical account-scoped redemption request for settled output claims.
struct ClaimData {
    bytes32 poolId;
    address account;
    address recipient;
    address currency;
    uint128 amount;
}
