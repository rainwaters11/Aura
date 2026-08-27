// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ParkedOrder, BatchSolution, BatchStatus} from "./types/AuraTypes.sol";
import {AuraClearingMath} from "./libraries/AuraClearingMath.sol";
import {IAuraSettlementVerifier} from "./interfaces/IAuraSettlementVerifier.sol";
import {IAuraSettlementSource} from "./interfaces/IAuraSettlementSource.sol";

/// @title AuraSettlementVerifier
/// @notice Stateless validation boundary that pulls all trusted context from the calling hook.
contract AuraSettlementVerifier is IAuraSettlementVerifier {
    bytes4 public constant VALID_SOLUTION = IAuraSettlementVerifier.validate.selector;

    error BatchNotClosed();
    error MissingClosureTimestamp();

    function validate(BatchSolution calldata solution) external view returns (bytes4) {
        IAuraSettlementSource source = IAuraSettlementSource(msg.sender);
        if (source.batchStatus(solution.batchId) != BatchStatus.CLOSED) revert BatchNotClosed();
        if (source.closedAtTimestamp(solution.batchId) == 0) revert MissingClosureTimestamp();

        bytes32[] memory ids = source.batchOrderIds(solution.batchId);
        ParkedOrder[] memory parked = new ParkedOrder[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            parked[i] = source.orders(ids[i]);
        }

        PoolId poolId = source.auraPoolId();
        AuraClearingMath.validateSolution(
            parked,
            ids,
            keccak256(abi.encode(ids)),
            solution,
            AuraClearingMath.Domain(block.chainid, msg.sender, PoolId.unwrap(poolId)),
            uint64(block.timestamp),
            source.usedSolutions(solution.solutionHash)
        );
        return VALID_SOLUTION;
    }
}
