// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BatchSolution} from "../types/AuraTypes.sol";

interface IAuraSettlementVerifier {
    function validate(BatchSolution calldata solution) external view returns (bytes4);
}
