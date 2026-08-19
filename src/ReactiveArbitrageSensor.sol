// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/src/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/src/interfaces/IReactive.sol";

/// @title ReactiveArbitrageSensor
/// @notice RSC (Reactive Smart Contract) that detects toxic L1 arbitrage patterns
///         BEFORE they reach Unichain via the Reactive Network's event subscription model.
///
/// @dev    DETECTION MECHANISM — SANDWICH PATTERN:
///         This sensor subscribes to Uniswap V3 Pool Swap events on Ethereum mainnet.
///         It tracks how many times each address appears as the swap sender within
///         a single L1 block. When the count reaches SANDWICH_THRESHOLD (≥2), the
///         address is flagged as a suspect sandwich attacker.
///
///         WHY THIS WORKS (timing advantage):
///         ┌─────────────────────────────────────────────────────────────────┐
///         │  Ethereum L1 block time  ~12 seconds                            │
///         │  Unichain block time     ~250ms (Flashblock preconfirmations)   │
///         │                                                                  │
///         │  Reactive Network observes the L1 event at block N, dispatches  │
///         │  a cross-chain callback to ArgosLTSHook on Unichain, which      │
///         │  flags the address BEFORE the arb wallet can bridge and execute  │
///         │  its Unichain leg during the same L1 block window.              │
///         └─────────────────────────────────────────────────────────────────┘
///
///         DEPLOYMENT:
///         Deploy this contract to the Reactive Network. It will automatically
///         subscribe to the V3 Swap event topic on all monitored L1 contracts.
///         In the Reactive Network paradigm, this is a "Reactive Smart Contract"
///         (RSC) that lives on-chain on the Reactive chain and reacts to L1 events.
///
///         The Callback event triggers ArgosLTSHook.flagToxicAddress() on Unichain
///         via the Reactive Network's cross-chain callback delivery mechanism.
contract ReactiveArbitrageSensor is AbstractReactive {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Uniswap V3 Pool Swap event topic0.
    ///         keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)")
    ///         topic1 = sender (indexed), topic2 = recipient (indexed)
    bytes32 public constant SWAP_TOPIC = keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)");

    /// @notice Minimum swaps from the same sender in one L1 block to trigger detection.
    uint8 public constant SANDWICH_THRESHOLD = 2;

    /// @notice Gas limit for the Reactive Network cross-chain callback to Unichain.
    uint64 public constant CALLBACK_GAS_LIMIT = 600_000;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice ArgosLTSHook address on Unichain — the callback target.
    address public immutable argosHook;

    /// @notice Unichain chain ID (testnet = 1301, mainnet = 130).
    uint256 public immutable destinationChainId;

    /// @notice Counts swaps per sender per L1 block number.
    ///         swapCountPerBlock[sender][l1BlockNumber] = count
    mapping(address => mapping(uint256 => uint8)) public swapCountPerBlock;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event SandwichDetected(address indexed sender, uint256 blockNumber, uint8 swapCount);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @param _argosHook          ArgosLTSHook address on Unichain.
    /// @param _destinationChainId Unichain chain ID (1301 for testnet).
    constructor(address _argosHook, uint256 _destinationChainId) {
        require(_argosHook != address(0), "Sensor: zero hook");
        argosHook = _argosHook;
        destinationChainId = _destinationChainId;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core — Reactive Network Entry Point
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Called by the Reactive Network VM when a subscribed L1 event fires.
    /// @dev    The Reactive Network calls react() on this RSC each time a watched
    ///         event is observed on L1. The LogRecord struct carries the full event
    ///         context (chain_id, contract address, topics, data, block number, etc.)
    ///
    ///         SANDWICH DETECTION ALGORITHM:
    ///         1. Ignore events that are not Uniswap V3 Swap events.
    ///         2. Decode the sender from topic_1 (first indexed param of Swap).
    ///         3. Increment swapCountPerBlock[sender][block_number].
    ///         4. If count >= SANDWICH_THRESHOLD:
    ///            a. Emit SandwichDetected for audit trail.
    ///            b. Emit Callback — the Reactive Network delivers this as a
    ///               cross-chain call to ArgosLTSHook.flagToxicAddress(sender)
    ///               on Unichain, arriving BEFORE L1 block finalises.
    ///
    /// @param log  Reactive Network log record containing the L1 event data.
    function react(IReactive.LogRecord calldata log) external override vmOnly {
        // Gate 1: Only process Uniswap V3 Swap events
        if (log.topic_0 != uint256(SWAP_TOPIC)) return;

        // Gate 2: Decode sender from topic_1 (indexed sender address)
        address sender = address(uint160(log.topic_1));

        // Gate 3: Zero address is not a real sender
        if (sender == address(0)) return;

        // Increment swap count for this sender in this L1 block
        uint8 newCount;
        unchecked {
            // Safe: overflow at 255 is gracefully handled (threshold is 2)
            newCount = swapCountPerBlock[sender][log.block_number] + 1;
        }
        swapCountPerBlock[sender][log.block_number] = newCount;

        // Check for sandwich pattern
        if (newCount < SANDWICH_THRESHOLD) return;

        emit SandwichDetected(sender, log.block_number, newCount);

        // Dispatch cross-chain callback to ArgosLTSHook.flagToxicAddress() on Unichain.
        // The Reactive Network observes this Callback event and delivers the payload
        // as an on-chain transaction to the destination contract on the destination chain.
        bytes memory payload = abi.encodeWithSignature("flagToxicAddress(address)", sender);
        emit Callback(destinationChainId, argosHook, CALLBACK_GAS_LIMIT, payload);
    }
}
