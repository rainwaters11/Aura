// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {AuraHook} from "../src/AuraHook.sol";
import {AuraClearingMath} from "../src/libraries/AuraClearingMath.sol";
import {IAuraSettlementSource} from "../src/interfaces/IAuraSettlementSource.sol";
import {BatchSolution, ParkedOrder, OrderStatus, BatchStatus} from "../src/types/AuraTypes.sol";
import {AuraParkingBase} from "./AuraParking.t.sol";

contract AuraSettlementTest is AuraParkingBase {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function test_perfectCowSettlesWithoutMovingPoolAndBacksClaims() public {
        BatchSolution memory solution = _closedSolution(10 ether, 10 ether, 10 ether, 10 ether);
        (uint160 sqrtBefore, int24 tickBefore,,) = poolManager.getSlot0(poolId);
        uint128 liquidityBefore = poolManager.getLiquidity(poolId);

        hook.settleBatch(address(this), solution);

        (uint160 sqrtAfter, int24 tickAfter,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtAfter, sqrtBefore);
        assertEq(tickAfter, tickBefore);
        assertEq(poolManager.getLiquidity(poolId), liquidityBefore);
        assertEq(uint8(hook.batchStatus(1)), uint8(BatchStatus.SETTLED));
        assertEq(hook.claimableBalances(poolId, owner, currency0), 10 ether);
        assertEq(hook.claimableBalances(poolId, owner, currency1), 10 ether);
        assertEq(poolManager.balanceOf(address(hook), currency0.toId()), 10 ether);
        assertEq(poolManager.balanceOf(address(hook), currency1.toId()), 10 ether);
        assertEq(poolManager.currencyDelta(address(hook), currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), currency1), 0);
    }

    function test_token0ResidualUsesActualOutputAndRecordsDust() public {
        BatchSolution memory solution = _closedSolution(12 ether, 6 ether, 3 ether, 6 ether);
        assertTrue(solution.residualZeroForOne);
        assertGt(solution.residualAmountIn, 0);
        hook.settleBatch(address(this), solution);
        _assertSettledAndBacked(solution);
        assertGt(hook.protocolDust(poolId, currency1), 0);
    }

    function test_token1ResidualUsesActualOutputAndRecordsDust() public {
        BatchSolution memory solution = _closedSolution(3 ether, 6 ether, 12 ether, 6 ether);
        assertFalse(solution.residualZeroForOne);
        assertGt(solution.residualAmountIn, 0);
        hook.settleBatch(address(this), solution);
        _assertSettledAndBacked(solution);
        assertGt(hook.protocolDust(poolId, currency0), 0);
    }

    function test_rejectsWrongCallerStatusReplayAndDirectCallback() public {
        BatchSolution memory solution = _closedSolution(10 ether, 10 ether, 10 ether, 10 ether);
        vm.prank(makeAddr("not-authority"));
        vm.expectRevert(AuraHook.UnauthorizedSettlement.selector);
        hook.settleBatch(address(this), solution);

        vm.expectRevert(AuraHook.InvalidRvmIdentity.selector);
        hook.settleBatch(makeAddr("wrong-rvm"), solution);

        vm.prank(address(poolManager));
        vm.expectRevert(AuraHook.InvalidUnlockContext.selector);
        hook.unlockCallback(abi.encode(uint8(2), solution));

        hook.settleBatch(address(this), solution);
        vm.expectRevert(AuraHook.BatchNotClosed.selector);
        hook.settleBatch(address(this), solution);
    }

    function test_recipientCanRedeemSettledOutputAndCannotReplay() public {
        BatchSolution memory solution = _closedSolution(10 ether, 10 ether, 10 ether, 10 ether);
        hook.settleBatch(address(this), solution);
        uint256 beforeBalance = MockERC20(Currency.unwrap(currency0)).balanceOf(owner);

        vm.prank(owner);
        hook.claimTokens(poolId, currency0, owner, 10 ether);

        assertEq(hook.claimableBalances(poolId, owner, currency0), 0);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(owner), beforeBalance + 10 ether);
        assertEq(poolManager.balanceOf(address(hook), currency0.toId()), 0);
        vm.prank(owner);
        vm.expectRevert(AuraHook.InsufficientClaimBalance.selector);
        hook.claimTokens(poolId, currency0, owner, 1);
    }

    function test_claimRejectsWrongPoolRecipientRangeAndDirectCallback() public {
        vm.expectRevert(AuraHook.InvalidClaim.selector);
        hook.claimTokens(PoolId.wrap(bytes32(uint256(1))), currency0, owner, 1);
        vm.expectRevert(AuraHook.InvalidClaim.selector);
        hook.claimTokens(poolId, currency0, address(0), 1);
        vm.expectRevert(AuraHook.InvalidClaim.selector);
        hook.claimTokens(poolId, currency0, owner, uint256(uint128(type(int128).max)) + 1);
        vm.prank(address(poolManager));
        vm.expectRevert(AuraHook.InvalidUnlockContext.selector);
        hook.unlockCallback(abi.encode(uint8(3), bytes32(0)));
    }

    function test_malformedExecutionPlanRevertsAtomically() public {
        BatchSolution memory solution = _closedSolution(10 ether, 10 ether, 10 ether, 10 ether);
        bytes32[] memory ids = hook.batchOrderIds(1);
        solution.payouts[0] += 1;
        solution.solutionHash = AuraClearingMath.computeSolutionHash(solution, _domain());
        uint256 claim0 = poolManager.balanceOf(address(hook), currency0.toId());

        vm.expectRevert(abi.encodeWithSelector(AuraClearingMath.PayoutMismatch.selector, 0));
        hook.settleBatch(address(this), solution);

        assertEq(uint8(hook.batchStatus(1)), uint8(BatchStatus.CLOSED));
        assertFalse(hook.usedSolutions(solution.solutionHash));
        assertEq(poolManager.balanceOf(address(hook), currency0.toId()), claim0);
        for (uint256 i; i < ids.length; ++i) {
            (,,,,,,,, OrderStatus status) = hook.orders(ids[i]);
            assertEq(uint8(status), uint8(OrderStatus.PARKED));
        }
    }

    function test_rejectsWrongResidualDirectionAmountAndPriceLimit() public {
        BatchSolution memory canonical = _closedSolution(12 ether, 6 ether, 3 ether, 6 ether);
        uint128 canonicalAmount = canonical.residualAmountIn;
        BatchSolution memory altered = canonical;
        altered.residualZeroForOne = false;
        altered.solutionHash = AuraClearingMath.computeSolutionHash(altered, _domain());
        vm.expectRevert(AuraClearingMath.ResidualMismatch.selector);
        hook.settleBatch(address(this), altered);

        altered.residualZeroForOne = true;
        altered.residualAmountIn = canonicalAmount;
        altered.residualAmountIn += 1;
        altered.solutionHash = AuraClearingMath.computeSolutionHash(altered, _domain());
        vm.expectRevert(AuraClearingMath.ResidualMismatch.selector);
        hook.settleBatch(address(this), altered);

        altered.residualAmountIn = canonicalAmount;
        altered.solutionHash = AuraClearingMath.computeSolutionHash(altered, _domain());
        altered.sqrtPriceLimitX96 += 1;
        vm.expectRevert(AuraClearingMath.InvalidSolutionHash.selector);
        hook.settleBatch(address(this), altered);
        assertEq(uint8(hook.batchStatus(1)), uint8(BatchStatus.CLOSED));
    }

    function test_insufficientResidualOutputRollsBackAllState() public {
        BatchSolution memory solution = _closedSolution(12 ether, 12 ether, 6 ether, 6 ether);
        bytes32[] memory ids = hook.batchOrderIds(1);
        uint256 inputClaim0 = poolManager.balanceOf(address(hook), currency0.toId());
        uint256 inputClaim1 = poolManager.balanceOf(address(hook), currency1.toId());

        vm.expectRevert(AuraHook.UnderfundedSettlement.selector);
        hook.settleBatch(address(this), solution);

        assertEq(uint8(hook.batchStatus(1)), uint8(BatchStatus.CLOSED));
        assertFalse(hook.usedSolutions(solution.solutionHash));
        assertEq(poolManager.balanceOf(address(hook), currency0.toId()), inputClaim0);
        assertEq(poolManager.balanceOf(address(hook), currency1.toId()), inputClaim1);
        assertEq(hook.claimableBalances(poolId, owner, currency0), 0);
        assertEq(hook.claimableBalances(poolId, owner, currency1), 0);
        for (uint256 i; i < ids.length; ++i) {
            assertEq(uint8(_stored(ids[i]).status), uint8(OrderStatus.PARKED));
        }
    }

    function _assertSettledAndBacked(BatchSolution memory solution) private view {
        assertEq(uint8(hook.batchStatus(1)), uint8(BatchStatus.SETTLED));
        uint256 liability0 = hook.claimableBalances(poolId, owner, currency0);
        uint256 liability1 = hook.claimableBalances(poolId, owner, currency1);
        assertEq(liability0, solution.payouts[1]);
        assertEq(liability1, solution.payouts[0]);
        assertGe(poolManager.balanceOf(address(hook), currency0.toId()), liability0);
        assertGe(poolManager.balanceOf(address(hook), currency1.toId()), liability1);
        assertEq(poolManager.currencyDelta(address(hook), currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), currency1), 0);
    }

    function _closedSolution(uint128 amount0, uint128 minimum1, uint128 amount1, uint128 minimum0)
        private
        returns (BatchSolution memory solution)
    {
        _place(true, amount0, minimum1);
        _place(false, amount1, minimum0);
        vm.roll(uint256(hook.openedAtBlock(1)) + hook.MAX_BATCH_WINDOW() + 1);
        hook.closeBatch(1);
        assertEq(uint8(hook.batchStatus(1)), uint8(BatchStatus.CLOSED));

        bytes32[] memory ids = hook.batchOrderIds(1);
        ParkedOrder[] memory parked = new ParkedOrder[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            parked[i] = _stored(ids[i]);
        }
        AuraClearingMath.Computation memory computed = AuraClearingMath.compute(parked);
        solution = BatchSolution({
            batchId: 1,
            deadline: parked[0].deadline,
            priceNumerator: computed.priceNumerator,
            priceDenominator: computed.priceDenominator,
            residualZeroForOne: computed.residualZeroForOne,
            residualAmountIn: computed.residualAmountIn,
            sqrtPriceLimitX96: computed.residualAmountIn == 0
                ? 0
                : computed.residualZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            solutionHash: bytes32(0),
            orderIds: ids,
            payouts: computed.payouts
        });
        solution.solutionHash = AuraClearingMath.computeSolutionHash(solution, _domain());
    }

    function _stored(bytes32 id) private view returns (ParkedOrder memory order) {
        return IAuraSettlementSource(address(hook)).orders(id);
    }

    function _domain() private view returns (AuraClearingMath.Domain memory) {
        return AuraClearingMath.Domain(block.chainid, address(hook), PoolId.unwrap(poolId));
    }
}

contract AuraSettlementInvariant is AuraSettlementTest {
    function invariant_liabilitiesAndDustNeverExceedClaims() public view {
        uint256 liability0 = hook.claimableBalances(poolId, owner, currency0) + hook.protocolDust(poolId, currency0);
        uint256 liability1 = hook.claimableBalances(poolId, owner, currency1) + hook.protocolDust(poolId, currency1);
        assertLe(liability0, poolManager.balanceOf(address(hook), currency0.toId()));
        assertLe(liability1, poolManager.balanceOf(address(hook), currency1.toId()));
    }
}
