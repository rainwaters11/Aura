// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ParkedOrder, BatchStatus} from "../types/AuraTypes.sol";

/// @notice Narrow read-only state surface consumed by the settlement verifier.
interface IAuraSettlementSource {
    function auraPoolId() external view returns (PoolId);
    function batchOrderIds(uint64 batchId) external view returns (bytes32[] memory);
    function batchStatus(uint64 batchId) external view returns (BatchStatus);
    function closedAtTimestamp(uint64 batchId) external view returns (uint64);
    function usedSolutions(bytes32 solutionHash) external view returns (bool);
    function orders(bytes32 orderId) external view returns (ParkedOrder memory);
}
