// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ToxicFlowLib
/// @notice Pure/view library for detecting toxic flow patterns and computing dynamic penalty fees.
/// @dev Used by ArgosLTSHook to separate detection logic from hook execution.
library ToxicFlowLib {
    // ─────────────────────────────────────────────────────────────────────────
    // Detection
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns true if `swapper` is currently flagged as toxic.
    /// @dev Checks that toxicExpiry[swapper] is set AND has not yet elapsed.
    /// @param toxicExpiry  Storage mapping of swapper → flag expiry timestamp.
    /// @param swapper      The address to check.
    function isToxic(mapping(address => uint256) storage toxicExpiry, address swapper) internal view returns (bool) {
        return toxicExpiry[swapper] > block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Penalty Fee
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Computes a linearly-decaying penalty fee for a toxic swapper.
    /// @dev    A fresher flag (more time remaining) maps to a fee closer to `maxFee`.
    ///         As the flag approaches expiry the fee decays back toward `baseFee`.
    ///
    ///         Formula:  fee = baseFee + (maxFee - baseFee) × remaining / window
    ///
    ///         NOTE: `flaggedAt` in this context is the *expiry* timestamp stored in
    ///         `toxicExpiry[swapper]` (i.e. block.timestamp + TOXIC_WINDOW at flag time).
    ///         The name follows the external spec; callers should pass `toxicExpiry[swapper]`.
    ///
    /// @param flaggedAt  Expiry timestamp of the toxic flag (toxicExpiry[swapper]).
    /// @param baseFee    Normal swap fee (e.g. 3000 = 0.30%).
    /// @param maxFee     Maximum penalty fee (e.g. 100_000 = 10.00%).
    /// @param window     Total toxic window duration in seconds (e.g. 5 minutes = 300).
    /// @return           Fee in bips (fits in uint24, max 100_000 < 2^24).
    function computePenaltyFee(uint256 flaggedAt, uint256 baseFee, uint256 maxFee, uint256 window)
        internal
        view
        returns (uint24)
    {
        // Flag already expired — return base fee
        if (block.timestamp >= flaggedAt) return uint24(baseFee);

        uint256 remaining = flaggedAt - block.timestamp;
        // Clamp remaining to window in case of clock skew
        if (remaining > window) remaining = window;

        uint256 fee = baseFee + ((maxFee - baseFee) * remaining) / window;
        return uint24(fee);
    }
}
