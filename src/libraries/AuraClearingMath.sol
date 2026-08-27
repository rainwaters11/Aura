// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BatchSolution, OrderStatus, ParkedOrder} from "../types/AuraTypes.sol";

/// @notice Pure canonical price, payout, residual, and typed-solution validation for Aura.
/// @dev The price convention is token1 per token0. All user payouts round down.
library AuraClearingMath {
    uint256 internal constant MAX_SIGNED_AMOUNT = uint256(uint128(type(int128).max));
    uint256 internal constant MAX_BATCH_ORDERS = 8;

    bytes32 internal constant SOLUTION_TYPEHASH = keccak256(
        "AuraBatchSolution(uint256 chainId,address auraHook,bytes32 poolId,uint64 batchId,uint64 deadline,uint128 priceNumerator,uint128 priceDenominator,bool residualZeroForOne,uint128 residualAmountIn,uint160 sqrtPriceLimitX96,bytes32 orderIdsHash,bytes32 payoutsHash)"
    );

    struct Domain {
        uint256 chainId;
        address auraHook;
        bytes32 poolId;
    }

    struct Bounds {
        uint128 lowerNumerator;
        uint128 lowerDenominator;
        uint128 upperNumerator;
        uint128 upperDenominator;
    }

    struct Computation {
        uint128 priceNumerator;
        uint128 priceDenominator;
        bool residualZeroForOne;
        uint128 residualAmountIn;
        uint128[] payouts;
        uint256 token0Input;
        uint256 token1Input;
        uint256 token0Payout;
        uint256 token1Payout;
        uint256 matchedToken0Input;
        uint256 matchedToken1Input;
        uint256 roundingDustToken0;
        uint256 roundingDustToken1;
    }

    /// @dev Static tuple matching the normative outer `abi.encode` preimage exactly.
    struct SolutionHashData {
        bytes32 typeHash;
        uint256 chainId;
        address auraHook;
        bytes32 poolId;
        uint64 batchId;
        uint64 deadline;
        uint128 priceNumerator;
        uint128 priceDenominator;
        bool residualZeroForOne;
        uint128 residualAmountIn;
        uint160 sqrtPriceLimitX96;
        bytes32 orderIdsHash;
        bytes32 payoutsHash;
    }

    error InvalidBatchSize();
    error InvalidOrder(uint256 index);
    error InvalidOrderStatus(uint256 index);
    error BatchMismatch(uint256 index);
    error DirectionMissing();
    error EmptyFeasibleInterval();
    error AmountOverflow();
    error InvalidPrice();
    error PayoutBelowMinimum(uint256 index);
    error PayoutOverflow(uint256 index);
    error ArrayLengthMismatch();
    error InvalidOrderId(uint256 index);
    error DuplicateOrderId(uint256 index);
    error MembershipMismatch();
    error SolutionAlreadyUsed();
    error ExpiredSolution();
    error ExpiredOrder(uint256 index);
    error SolutionDeadlineExceedsOrder(uint256 index);
    error NonCanonicalPrice();
    error PayoutMismatch(uint256 index);
    error ResidualMismatch();
    error InvalidPriceLimit();
    error InvalidSolutionHash();

    /// @notice Computes the sole canonical price, payouts, residual, and direct-match dust.
    function compute(ParkedOrder[] memory orders) internal pure returns (Computation memory result) {
        Bounds memory bounds;
        (bounds, result.token0Input, result.token1Input) = _scanOrders(orders);
        (result.priceNumerator, result.priceDenominator) = canonicalPrice(bounds);

        result.payouts = new uint128[](orders.length);
        for (uint256 i; i < orders.length; ++i) {
            ParkedOrder memory order = orders[i];
            uint256 payout =
                clearingPayout(order.amountIn, order.zeroForOne, result.priceNumerator, result.priceDenominator);
            if (payout < order.minAmountOut) revert PayoutBelowMinimum(i);
            if (payout > MAX_SIGNED_AMOUNT) revert PayoutOverflow(i);

            result.payouts[i] = uint128(payout);
            if (order.zeroForOne) result.token1Payout += payout;
            else result.token0Payout += payout;
        }

        (result.residualZeroForOne, result.residualAmountIn) =
            deriveResidual(result.token0Input, result.token1Input, result.priceNumerator, result.priceDenominator);
        _recordDirectMatch(result);
    }

    /// @notice Validates a complete untrusted solution against frozen ordered batch evidence.
    function validateSolution(
        ParkedOrder[] memory orders,
        bytes32[] memory frozenOrderIds,
        bytes32 expectedOrderIdsHash,
        BatchSolution memory solution,
        Domain memory domain,
        uint64 currentTimestamp,
        bool solutionAlreadyUsed
    ) internal pure returns (Computation memory expected) {
        if (solutionAlreadyUsed) revert SolutionAlreadyUsed();
        if (solution.deadline == 0 || currentTimestamp > solution.deadline) revert ExpiredSolution();
        if (
            orders.length != frozenOrderIds.length || solution.orderIds.length != frozenOrderIds.length
                || solution.payouts.length != frozenOrderIds.length
        ) revert ArrayLengthMismatch();
        if (keccak256(abi.encode(frozenOrderIds)) != expectedOrderIdsHash) revert MembershipMismatch();

        for (uint256 i; i < frozenOrderIds.length; ++i) {
            bytes32 orderId = frozenOrderIds[i];
            if (orderId == bytes32(0)) revert InvalidOrderId(i);
            if (solution.orderIds[i] != orderId) revert MembershipMismatch();
            if (orders[i].batchId != solution.batchId) revert BatchMismatch(i);
            if (currentTimestamp > orders[i].deadline) revert ExpiredOrder(i);
            if (solution.deadline > orders[i].deadline) revert SolutionDeadlineExceedsOrder(i);
            for (uint256 j; j < i; ++j) {
                if (frozenOrderIds[j] == orderId) revert DuplicateOrderId(i);
            }
        }

        expected = compute(orders);
        if (
            solution.priceNumerator != expected.priceNumerator || solution.priceDenominator != expected.priceDenominator
        ) revert NonCanonicalPrice();
        for (uint256 i; i < expected.payouts.length; ++i) {
            if (solution.payouts[i] != expected.payouts[i]) revert PayoutMismatch(i);
        }
        if (
            solution.residualZeroForOne != expected.residualZeroForOne
                || solution.residualAmountIn != expected.residualAmountIn
        ) revert ResidualMismatch();
        if (
            expected.residualAmountIn != 0
                && (solution.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE
                    || solution.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE)
        ) revert InvalidPriceLimit();
        if (solution.solutionHash != computeSolutionHash(solution, domain)) revert InvalidSolutionHash();
    }

    /// @notice Derives the canonical reduced midpoint or the normative bounded fallback.
    function canonicalPrice(Bounds memory bounds) internal pure returns (uint128 numerator, uint128 denominator) {
        if (
            bounds.lowerNumerator == 0 || bounds.lowerDenominator == 0 || bounds.upperNumerator == 0
                || bounds.upperDenominator == 0
        ) revert InvalidPrice();
        if (
            uint256(bounds.lowerNumerator) * bounds.upperDenominator
                > uint256(bounds.upperNumerator) * bounds.lowerDenominator
        ) revert EmptyFeasibleInterval();

        uint256 midpointNumerator = uint256(bounds.lowerNumerator) * bounds.upperDenominator
            + uint256(bounds.upperNumerator) * bounds.lowerDenominator;
        uint256 midpointDenominator = 2 * uint256(bounds.lowerDenominator) * bounds.upperDenominator;
        uint256 divisor = gcd(midpointNumerator, midpointDenominator);
        midpointNumerator /= divisor;
        midpointDenominator /= divisor;

        if (midpointNumerator <= type(uint128).max && midpointDenominator <= type(uint128).max) {
            return (uint128(midpointNumerator), uint128(midpointDenominator));
        }
        if (_withinInterval(1, 1, bounds)) return (1, 1);
        return (bounds.lowerNumerator, bounds.lowerDenominator);
    }

    /// @notice Calculates one floor-rounded payout at the directed uniform price.
    function clearingPayout(uint128 amountIn, bool zeroForOne, uint128 priceNumerator, uint128 priceDenominator)
        internal
        pure
        returns (uint256)
    {
        if (amountIn == 0 || priceNumerator == 0 || priceDenominator == 0) revert InvalidPrice();
        return zeroForOne
            ? FullMath.mulDiv(amountIn, priceNumerator, priceDenominator)
            : FullMath.mulDiv(amountIn, priceDenominator, priceNumerator);
    }

    /// @notice Derives the exact residual direction and amount from full-width aggregate inputs.
    function deriveResidual(uint256 token0Input, uint256 token1Input, uint128 priceNumerator, uint128 priceDenominator)
        internal
        pure
        returns (bool residualZeroForOne, uint128 residualAmountIn)
    {
        if (
            token0Input == 0 || token1Input == 0 || token0Input > MAX_SIGNED_AMOUNT || token1Input > MAX_SIGNED_AMOUNT
                || priceNumerator == 0 || priceDenominator == 0
        ) revert InvalidPrice();

        uint256 token0Value = token0Input * priceNumerator;
        uint256 token1Value = token1Input * priceDenominator;
        uint256 residual;
        if (token0Value > token1Value) {
            residualZeroForOne = true;
            residual = token0Input - FullMath.mulDiv(token1Input, priceDenominator, priceNumerator);
        } else if (token0Value < token1Value) {
            residual = token1Input - FullMath.mulDiv(token0Input, priceNumerator, priceDenominator);
        }
        if (residual > MAX_SIGNED_AMOUNT) revert AmountOverflow();
        residualAmountIn = uint128(residual);
    }

    /// @notice Reproduces the exact normative typed solution hash.
    function computeSolutionHash(BatchSolution memory solution, Domain memory domain) internal pure returns (bytes32) {
        SolutionHashData memory data;
        data.typeHash = SOLUTION_TYPEHASH;
        data.chainId = domain.chainId;
        data.auraHook = domain.auraHook;
        data.poolId = domain.poolId;
        data.batchId = solution.batchId;
        data.deadline = solution.deadline;
        data.priceNumerator = solution.priceNumerator;
        data.priceDenominator = solution.priceDenominator;
        data.residualZeroForOne = solution.residualZeroForOne;
        data.residualAmountIn = solution.residualAmountIn;
        data.sqrtPriceLimitX96 = solution.sqrtPriceLimitX96;
        data.orderIdsHash = keccak256(abi.encode(solution.orderIds));
        data.payoutsHash = keccak256(abi.encode(solution.payouts));
        return keccak256(abi.encode(data));
    }

    function gcd(uint256 a, uint256 b) internal pure returns (uint256) {
        while (b != 0) {
            (a, b) = (b, a % b);
        }
        return a;
    }

    function _scanOrders(ParkedOrder[] memory orders)
        private
        pure
        returns (Bounds memory bounds, uint256 token0Input, uint256 token1Input)
    {
        if (orders.length < 2 || orders.length > MAX_BATCH_ORDERS) revert InvalidBatchSize();
        uint64 batchId = orders[0].batchId;
        uint256 lowerNumerator;
        uint256 lowerDenominator = 1;
        uint256 upperNumerator;
        uint256 upperDenominator;

        for (uint256 i; i < orders.length; ++i) {
            ParkedOrder memory order = orders[i];
            if (
                order.amountIn == 0 || order.minAmountOut == 0 || order.deadline == 0
                    || order.amountIn > MAX_SIGNED_AMOUNT || order.minAmountOut > MAX_SIGNED_AMOUNT
            ) revert InvalidOrder(i);
            if (order.status != OrderStatus.PARKED) revert InvalidOrderStatus(i);
            if (order.batchId != batchId) revert BatchMismatch(i);

            if (order.zeroForOne) {
                token0Input += order.amountIn;
                if (token0Input > MAX_SIGNED_AMOUNT) revert AmountOverflow();
                if (lowerNumerator * order.amountIn < uint256(order.minAmountOut) * lowerDenominator) {
                    (lowerNumerator, lowerDenominator) = (order.minAmountOut, order.amountIn);
                }
            } else {
                token1Input += order.amountIn;
                if (token1Input > MAX_SIGNED_AMOUNT) revert AmountOverflow();
                if (
                    upperDenominator == 0
                        || upperNumerator * order.minAmountOut > uint256(order.amountIn) * upperDenominator
                ) {
                    (upperNumerator, upperDenominator) = (order.amountIn, order.minAmountOut);
                }
            }
        }
        if (lowerNumerator == 0 || upperDenominator == 0) revert DirectionMissing();
        if (lowerNumerator * upperDenominator > upperNumerator * lowerDenominator) {
            revert EmptyFeasibleInterval();
        }

        uint256 lowerDivisor = gcd(lowerNumerator, lowerDenominator);
        uint256 upperDivisor = gcd(upperNumerator, upperDenominator);
        bounds = Bounds({
            lowerNumerator: uint128(lowerNumerator / lowerDivisor),
            lowerDenominator: uint128(lowerDenominator / lowerDivisor),
            upperNumerator: uint128(upperNumerator / upperDivisor),
            upperDenominator: uint128(upperDenominator / upperDivisor)
        });
    }

    function _recordDirectMatch(Computation memory result) private pure {
        if (result.residualAmountIn == 0) {
            result.matchedToken0Input = result.token0Input;
            result.matchedToken1Input = result.token1Input;
            result.roundingDustToken0 = result.matchedToken0Input - result.token0Payout;
            result.roundingDustToken1 = result.matchedToken1Input - result.token1Payout;
        } else if (result.residualZeroForOne) {
            result.matchedToken0Input = result.token0Input - result.residualAmountIn;
            result.matchedToken1Input = result.token1Input;
            result.roundingDustToken0 = result.matchedToken0Input - result.token0Payout;
        } else {
            result.matchedToken0Input = result.token0Input;
            result.matchedToken1Input = result.token1Input - result.residualAmountIn;
            result.roundingDustToken1 = result.matchedToken1Input - result.token1Payout;
        }
    }

    function _withinInterval(uint256 numerator, uint256 denominator, Bounds memory bounds) private pure returns (bool) {
        return numerator * bounds.lowerDenominator >= uint256(bounds.lowerNumerator) * denominator
            && numerator * bounds.upperDenominator <= uint256(bounds.upperNumerator) * denominator;
    }
}
