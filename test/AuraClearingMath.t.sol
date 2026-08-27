// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {AuraClearingMath} from "../src/libraries/AuraClearingMath.sol";
import {BatchSolution, OrderStatus, ParkedOrder} from "../src/types/AuraTypes.sol";

contract AuraClearingMathHarness {
    function compute(ParkedOrder[] calldata orders) external pure returns (AuraClearingMath.Computation memory) {
        return AuraClearingMath.compute(orders);
    }

    function validateSolution(
        ParkedOrder[] calldata orders,
        bytes32[] calldata frozenOrderIds,
        bytes32 expectedOrderIdsHash,
        BatchSolution calldata solution,
        AuraClearingMath.Domain calldata domain,
        uint64 currentTimestamp,
        bool solutionAlreadyUsed
    ) external pure returns (AuraClearingMath.Computation memory) {
        return AuraClearingMath.validateSolution(
            orders, frozenOrderIds, expectedOrderIdsHash, solution, domain, currentTimestamp, solutionAlreadyUsed
        );
    }
}

contract AuraClearingMathTest is Test {
    uint128 internal constant M = uint128(type(int128).max);
    uint64 internal constant BATCH_ID = 7;
    uint64 internal constant DEADLINE = 1_000;

    AuraClearingMath.Domain internal domain =
        AuraClearingMath.Domain({chainId: 1301, auraHook: address(0xA11CE), poolId: keccak256("AURA_POOL")});
    AuraClearingMathHarness internal harness;

    function setUp() public {
        harness = new AuraClearingMathHarness();
    }

    function test_perfectCowUsesOnePriceAndNoResidual() public pure {
        ParkedOrder[] memory orders = new ParkedOrder[](2);
        orders[0] = _order(true, 6, 3);
        orders[1] = _order(false, 6, 4);

        AuraClearingMath.Computation memory result = AuraClearingMath.compute(orders);

        assertEq(result.priceNumerator, 1);
        assertEq(result.priceDenominator, 1);
        assertEq(result.payouts[0], 6);
        assertEq(result.payouts[1], 6);
        assertEq(result.residualAmountIn, 0);
        assertEq(result.matchedToken0Input, 6);
        assertEq(result.matchedToken1Input, 6);
        assertEq(result.roundingDustToken0, 0);
        assertEq(result.roundingDustToken1, 0);
    }

    function test_derivesToken0Residual() public pure {
        ParkedOrder[] memory orders = new ParkedOrder[](2);
        orders[0] = _order(true, 12, 6);
        orders[1] = _order(false, 6, 4);

        AuraClearingMath.Computation memory result = AuraClearingMath.compute(orders);

        assertTrue(result.residualZeroForOne);
        assertEq(result.residualAmountIn, 6);
        assertEq(result.matchedToken0Input, 6);
        assertEq(result.matchedToken1Input, 6);
        assertEq(result.token0Payout, 6);
        assertEq(result.token1Payout, 12);
    }

    function test_derivesToken1Residual() public pure {
        ParkedOrder[] memory orders = new ParkedOrder[](2);
        orders[0] = _order(true, 6, 3);
        orders[1] = _order(false, 12, 8);

        AuraClearingMath.Computation memory result = AuraClearingMath.compute(orders);

        assertFalse(result.residualZeroForOne);
        assertEq(result.residualAmountIn, 6);
        assertEq(result.matchedToken0Input, 6);
        assertEq(result.matchedToken1Input, 6);
        assertEq(result.token0Payout, 12);
        assertEq(result.token1Payout, 6);
    }

    function test_tracksDeterministicDirectMatchRoundingDust() public pure {
        ParkedOrder[] memory orders = new ParkedOrder[](3);
        orders[0] = _order(true, 4, 1);
        orders[1] = _order(true, 4, 1);
        orders[2] = _order(false, 13, 12);

        AuraClearingMath.Computation memory result = AuraClearingMath.compute(orders);

        assertEq(result.priceNumerator, 2);
        assertEq(result.priceDenominator, 3);
        assertEq(result.payouts[0], 2);
        assertEq(result.payouts[1], 2);
        assertEq(result.payouts[2], 19);
        assertFalse(result.residualZeroForOne);
        assertEq(result.residualAmountIn, 8);
        assertEq(result.matchedToken1Input, 5);
        assertEq(result.roundingDustToken1, 1);
    }

    function test_aggregatePayoutMayExceedSignedLimitWhenIndividualsFit() public pure {
        uint128 half = M / 2;
        ParkedOrder[] memory orders = new ParkedOrder[](3);
        orders[0] = _order(true, half, half);
        orders[1] = _order(true, half, half);
        orders[2] = _order(false, M, half);

        AuraClearingMath.Computation memory result = AuraClearingMath.compute(orders);

        assertGt(result.token1Payout, uint256(M));
        assertLe(result.payouts[0], M);
        assertLe(result.payouts[1], M);
    }

    function test_canonicalPriceVectors() public pure {
        _assertCanonical(1, 2, 3, 2, 1, 1);

        uint128 half = uint128((uint256(M) - 1) / 2);
        _assertCanonical(M - 1, M, M, M - 1, 1, 1);
        _assertCanonical(1, M, M, 1, 1, 1);
        _assertCanonical(M - 2, half, M, half - 1, M - 2, half);
    }

    function test_acceptsEightOrdersAndRejectsNine() public {
        ParkedOrder[] memory eight = new ParkedOrder[](8);
        for (uint256 i; i < 4; ++i) {
            eight[i] = _order(true, 10, 5);
            eight[i + 4] = _order(false, 10, 5);
        }
        AuraClearingMath.compute(eight);

        ParkedOrder[] memory nine = new ParkedOrder[](9);
        for (uint256 i; i < 9; ++i) {
            nine[i] = _order(i % 2 == 0, 10, 5);
        }
        vm.expectRevert(AuraClearingMath.InvalidBatchSize.selector);
        harness.compute(nine);
    }

    function test_rejectsEmptyIntervalAndUnsafeAmount() public {
        ParkedOrder[] memory orders = new ParkedOrder[](2);
        orders[0] = _order(true, 10, 20);
        orders[1] = _order(false, 10, 9);
        vm.expectRevert(AuraClearingMath.EmptyFeasibleInterval.selector);
        harness.compute(orders);

        orders[0] = _order(true, M + 1, 1);
        orders[1] = _order(false, 10, 1);
        vm.expectRevert(abi.encodeWithSelector(AuraClearingMath.InvalidOrder.selector, 0));
        harness.compute(orders);
    }

    function test_rejectsPerDirectionAggregateOverflow() public {
        ParkedOrder[] memory orders = new ParkedOrder[](3);
        uint128 overHalf = M / 2 + 1;
        orders[0] = _order(true, overHalf, 1);
        orders[1] = _order(true, overHalf, 1);
        orders[2] = _order(false, 10, 1);

        vm.expectRevert(AuraClearingMath.AmountOverflow.selector);
        harness.compute(orders);
    }

    function test_rejectsCanonicalIndividualPayoutAboveSignedLimit() public {
        ParkedOrder[] memory orders = new ParkedOrder[](2);
        uint128 half = M / 2;
        uint128 quarter = M / 4;
        orders[0] = _order(true, half, half * 2);
        orders[1] = _order(false, quarter * 4, quarter);

        vm.expectRevert(abi.encodeWithSelector(AuraClearingMath.PayoutOverflow.selector, 0));
        harness.compute(orders);
    }

    function test_validatesCompleteTypedSolutionAtDeadlineEquality() public view {
        (ParkedOrder[] memory orders, bytes32[] memory ids, BatchSolution memory solution) = _validSolution();

        AuraClearingMath.Computation memory result = AuraClearingMath.validateSolution(
            orders, ids, keccak256(abi.encode(ids)), solution, domain, DEADLINE, false
        );

        assertEq(result.priceNumerator, solution.priceNumerator);
        assertEq(result.priceDenominator, solution.priceDenominator);
        assertEq(result.residualAmountIn, solution.residualAmountIn);
    }

    function test_solutionHashUsesExactTypedPreimageAndExcludesItself() public view {
        (,, BatchSolution memory solution) = _validSolution();
        bytes32 expected = 0x03261810bb86b953e7ca24871961cde49d2cfd7e161ee345aa0e934557db32a5;
        assertEq(AuraClearingMath.computeSolutionHash(solution, domain), expected);

        solution.solutionHash = bytes32(uint256(123));
        assertEq(AuraClearingMath.computeSolutionHash(solution, domain), expected);
    }

    function test_rejectsDuplicateMembershipAndLengthMismatch() public {
        (ParkedOrder[] memory orders, bytes32[] memory ids, BatchSolution memory solution) = _validSolution();
        ids[1] = ids[0];
        solution.orderIds[1] = ids[0];
        solution.solutionHash = AuraClearingMath.computeSolutionHash(solution, domain);
        vm.expectRevert(abi.encodeWithSelector(AuraClearingMath.DuplicateOrderId.selector, 1));
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, false);

        (orders, ids, solution) = _validSolution();
        solution.payouts = new uint128[](1);
        vm.expectRevert(AuraClearingMath.ArrayLengthMismatch.selector);
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, false);
    }

    function test_rejectsExpiredAndOverlongSolutionDeadline() public {
        (ParkedOrder[] memory orders, bytes32[] memory ids, BatchSolution memory solution) = _validSolution();
        vm.expectRevert(AuraClearingMath.ExpiredSolution.selector);
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, DEADLINE + 1, false);

        solution.deadline = DEADLINE + 1;
        solution.solutionHash = AuraClearingMath.computeSolutionHash(solution, domain);
        vm.expectRevert(abi.encodeWithSelector(AuraClearingMath.SolutionDeadlineExceedsOrder.selector, 0));
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, false);
    }

    function test_rejectsWrongMembershipBatchAndOrderState() public {
        (ParkedOrder[] memory orders, bytes32[] memory ids, BatchSolution memory solution) = _validSolution();

        vm.expectRevert(AuraClearingMath.MembershipMismatch.selector);
        harness.validateSolution(orders, ids, bytes32(uint256(1)), solution, domain, 1, false);

        ++solution.batchId;
        solution.solutionHash = AuraClearingMath.computeSolutionHash(solution, domain);
        vm.expectRevert(abi.encodeWithSelector(AuraClearingMath.BatchMismatch.selector, 0));
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, false);

        (orders, ids, solution) = _validSolution();
        orders[0].status = OrderStatus.SETTLED;
        vm.expectRevert(abi.encodeWithSelector(AuraClearingMath.InvalidOrderStatus.selector, 0));
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, false);
    }

    function test_rejectsZeroOrNoncanonicalEquivalentPriceTuple() public {
        (ParkedOrder[] memory orders, bytes32[] memory ids, BatchSolution memory solution) = _validSolution();

        solution.priceDenominator = 0;
        solution.solutionHash = AuraClearingMath.computeSolutionHash(solution, domain);
        vm.expectRevert(AuraClearingMath.NonCanonicalPrice.selector);
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, false);

        (orders, ids, solution) = _validSolution();
        solution.priceNumerator = 2;
        solution.priceDenominator = 2;
        solution.solutionHash = AuraClearingMath.computeSolutionHash(solution, domain);
        vm.expectRevert(AuraClearingMath.NonCanonicalPrice.selector);
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, false);
    }

    function test_solutionHashBindsPriceLimitAndDomain() public {
        (ParkedOrder[] memory orders, bytes32[] memory ids, BatchSolution memory solution) = _validSolution();

        ++solution.sqrtPriceLimitX96;
        vm.expectRevert(AuraClearingMath.InvalidSolutionHash.selector);
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, false);

        (orders, ids, solution) = _validSolution();
        AuraClearingMath.Domain memory wrongDomain = domain;
        ++wrongDomain.chainId;
        vm.expectRevert(AuraClearingMath.InvalidSolutionHash.selector);
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, wrongDomain, 1, false);
    }

    function test_rejectsNoncanonicalPricePayoutResidualReplayAndHash() public {
        (ParkedOrder[] memory orders, bytes32[] memory ids, BatchSolution memory solution) = _validSolution();

        solution.priceNumerator = 2;
        solution.solutionHash = AuraClearingMath.computeSolutionHash(solution, domain);
        vm.expectRevert(AuraClearingMath.NonCanonicalPrice.selector);
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, false);

        (orders, ids, solution) = _validSolution();
        ++solution.payouts[0];
        solution.solutionHash = AuraClearingMath.computeSolutionHash(solution, domain);
        vm.expectRevert(abi.encodeWithSelector(AuraClearingMath.PayoutMismatch.selector, 0));
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, false);

        (orders, ids, solution) = _validSolution();
        ++solution.residualAmountIn;
        solution.solutionHash = AuraClearingMath.computeSolutionHash(solution, domain);
        vm.expectRevert(AuraClearingMath.ResidualMismatch.selector);
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, false);

        (orders, ids, solution) = _validSolution();
        solution.sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE;
        solution.solutionHash = AuraClearingMath.computeSolutionHash(solution, domain);
        vm.expectRevert(AuraClearingMath.InvalidPriceLimit.selector);
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, false);

        (orders, ids, solution) = _validSolution();
        vm.expectRevert(AuraClearingMath.SolutionAlreadyUsed.selector);
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, true);

        solution.solutionHash = bytes32(uint256(1));
        vm.expectRevert(AuraClearingMath.InvalidSolutionHash.selector);
        harness.validateSolution(orders, ids, keccak256(abi.encode(ids)), solution, domain, 1, false);
    }

    function _validSolution()
        internal
        view
        returns (ParkedOrder[] memory orders, bytes32[] memory ids, BatchSolution memory solution)
    {
        orders = new ParkedOrder[](2);
        orders[0] = _order(true, 12, 6);
        orders[1] = _order(false, 6, 4);
        ids = new bytes32[](2);
        ids[0] = keccak256("ORDER_0");
        ids[1] = keccak256("ORDER_1");

        AuraClearingMath.Computation memory expected = AuraClearingMath.compute(orders);
        solution.batchId = BATCH_ID;
        solution.deadline = DEADLINE;
        solution.priceNumerator = expected.priceNumerator;
        solution.priceDenominator = expected.priceDenominator;
        solution.residualZeroForOne = expected.residualZeroForOne;
        solution.residualAmountIn = expected.residualAmountIn;
        solution.sqrtPriceLimitX96 = 4_295_128_740;
        solution.orderIds = ids;
        solution.payouts = expected.payouts;
        solution.solutionHash = AuraClearingMath.computeSolutionHash(solution, domain);
    }

    function _order(bool zeroForOne, uint128 amountIn, uint128 minimum) internal pure returns (ParkedOrder memory) {
        return ParkedOrder({
            owner: address(0xBEEF),
            recipient: address(0xCAFE),
            batchId: BATCH_ID,
            deadline: DEADLINE,
            nonce: 0,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            minAmountOut: minimum,
            status: OrderStatus.PARKED
        });
    }

    function _assertCanonical(
        uint128 lowerNumerator,
        uint128 lowerDenominator,
        uint128 upperNumerator,
        uint128 upperDenominator,
        uint128 expectedNumerator,
        uint128 expectedDenominator
    ) internal pure {
        AuraClearingMath.Bounds memory bounds = AuraClearingMath.Bounds({
            lowerNumerator: lowerNumerator,
            lowerDenominator: lowerDenominator,
            upperNumerator: upperNumerator,
            upperDenominator: upperDenominator
        });
        (uint128 numerator, uint128 denominator) = AuraClearingMath.canonicalPrice(bounds);
        assertEq(numerator, expectedNumerator);
        assertEq(denominator, expectedDenominator);
    }
}

contract AuraClearingMathFuzz is Test {
    uint256 internal constant M = uint256(uint128(type(int128).max));

    function testFuzz_floorPayoutMatchesReference(uint64 amount, uint64 numerator, uint64 denominator) public pure {
        amount = uint64(bound(amount, 1, type(uint64).max));
        numerator = uint64(bound(numerator, 1, type(uint64).max));
        denominator = uint64(bound(denominator, 1, type(uint64).max));

        uint256 expected = uint256(amount) * numerator / denominator;
        assertEq(AuraClearingMath.clearingPayout(amount, true, numerator, denominator), expected);
        assertEq(
            AuraClearingMath.clearingPayout(amount, false, numerator, denominator),
            uint256(amount) * denominator / numerator
        );
    }

    function testFuzz_residualAtUnitPriceIsAbsoluteDifference(uint128 token0Input, uint128 token1Input) public pure {
        token0Input = uint128(bound(token0Input, 1, M));
        token1Input = uint128(bound(token1Input, 1, M));

        (bool zeroForOne, uint128 residual) = AuraClearingMath.deriveResidual(token0Input, token1Input, 1, 1);
        uint256 expected =
            token0Input > token1Input ? uint256(token0Input) - token1Input : uint256(token1Input) - token0Input;
        assertEq(residual, expected);
        if (residual != 0) assertEq(zeroForOne, token0Input > token1Input);
    }

    function testFuzz_midpointReferenceModel(uint64 a, uint64 b, uint64 denominator) public pure {
        denominator = uint64(bound(denominator, 1, type(uint64).max));
        uint128 lower = uint128(a < b ? a : b) + 1;
        uint128 upper = uint128(a < b ? b : a) + 1;

        AuraClearingMath.Bounds memory bounds = AuraClearingMath.Bounds({
            lowerNumerator: lower, lowerDenominator: denominator, upperNumerator: upper, upperDenominator: denominator
        });
        (uint128 numerator, uint128 midpointDenominator) = AuraClearingMath.canonicalPrice(bounds);

        uint256 referenceNumerator = uint256(lower) + upper;
        uint256 referenceDenominator = 2 * uint256(denominator);
        uint256 divisor = _gcd(referenceNumerator, referenceDenominator);
        assertEq(numerator, referenceNumerator / divisor);
        assertEq(midpointDenominator, referenceDenominator / divisor);
        assertEq(_gcd(numerator, midpointDenominator), 1);
        assertGe(uint256(numerator) * denominator, uint256(lower) * midpointDenominator);
        assertLe(uint256(numerator) * denominator, uint256(upper) * midpointDenominator);
    }

    function testFuzz_fullPrecisionPayoutDoesNotUseTruncatedProduct(
        uint128 amount,
        uint128 numerator,
        uint128 denominator
    ) public pure {
        amount = uint128(bound(amount, 1, M));
        numerator = uint128(bound(numerator, 1, type(uint128).max));
        denominator = uint128(bound(denominator, 1, type(uint128).max));

        assertEq(
            AuraClearingMath.clearingPayout(amount, true, numerator, denominator),
            FullMath.mulDiv(amount, numerator, denominator)
        );
    }

    function _gcd(uint256 x, uint256 y) private pure returns (uint256) {
        while (y != 0) (x, y) = (y, x % y);
        return x;
    }
}
