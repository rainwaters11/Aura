// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IReactive} from "reactive-lib/src/interfaces/IReactive.sol";

import {ToxicFlowLib} from "../src/libraries/ToxicFlowLib.sol";
import {ReactiveArbitrageSensor} from "../src/ReactiveArbitrageSensor.sol";

/// @title ToxicFlowLibHarness
/// @dev   Exposes ToxicFlowLib internal functions for direct unit testing.
contract ToxicFlowLibHarness {
    mapping(address => uint256) public toxicExpiry;

    function setExpiry(address addr, uint256 expiry) external {
        toxicExpiry[addr] = expiry;
    }

    function isToxic(address addr) external view returns (bool) {
        return ToxicFlowLib.isToxic(toxicExpiry, addr);
    }

    function computePenaltyFee(uint256 flaggedAt, uint256 baseFee, uint256 maxFee, uint256 window)
        external
        view
        returns (uint24)
    {
        return ToxicFlowLib.computePenaltyFee(flaggedAt, baseFee, maxFee, window);
    }
}

/// @title ToxicFlowDetectionTest
/// @notice Unit tests for ToxicFlowLib pure functions and ReactiveArbitrageSensor.react().
contract ToxicFlowDetectionTest is Test {
    // ─────────────────────────────────────────────────────────────────────────
    // ToxicFlowLib - isToxic()
    // ─────────────────────────────────────────────────────────────────────────

    ToxicFlowLibHarness harness;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    uint256 constant BASE_FEE = 3000;
    uint256 constant MAX_FEE = 100_000;
    uint256 constant WINDOW = 5 minutes;

    function setUp() public {
        harness = new ToxicFlowLibHarness();
    }

    /// @notice An address with no expiry set is not toxic.
    function test_isToxic_notFlagged() public view {
        assertFalse(harness.isToxic(ALICE), "unflagged address should not be toxic");
    }

    /// @notice An address flagged in the future is toxic.
    function test_isToxic_flaggedAndActive() public {
        harness.setExpiry(ALICE, block.timestamp + WINDOW);
        assertTrue(harness.isToxic(ALICE), "active flag -> toxic");
    }

    /// @notice A flag expiring exactly at block.timestamp is NOT toxic (>  not >=).
    function test_isToxic_expiredAtExactTimestamp() public {
        harness.setExpiry(ALICE, block.timestamp);
        assertFalse(harness.isToxic(ALICE), "flag at exact timestamp -> expired");
    }

    /// @notice A flag set in the past is not toxic.
    function test_isToxic_expiredInPast() public {
        harness.setExpiry(ALICE, block.timestamp - 1);
        assertFalse(harness.isToxic(ALICE), "past expiry -> not toxic");
    }

    /// @notice Flags for different addresses are independent.
    function test_isToxic_independentAddresses() public {
        harness.setExpiry(ALICE, block.timestamp + WINDOW);
        harness.setExpiry(BOB, block.timestamp - 1); // expired

        assertTrue(harness.isToxic(ALICE));
        assertFalse(harness.isToxic(BOB));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ToxicFlowLib - computePenaltyFee()
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice An expired flag returns exactly baseFee.
    function test_computePenaltyFee_expired_returnsBaseFee() public {
        uint256 expiry = block.timestamp - 1; // already expired
        uint24 fee = harness.computePenaltyFee(expiry, BASE_FEE, MAX_FEE, WINDOW);
        assertEq(fee, BASE_FEE, "expired flag -> baseFee");
    }

    /// @notice A flag at exact expiry returns baseFee.
    function test_computePenaltyFee_exactExpiry_returnsBaseFee() public {
        uint24 fee = harness.computePenaltyFee(block.timestamp, BASE_FEE, MAX_FEE, WINDOW);
        assertEq(fee, BASE_FEE, "exact expiry -> baseFee");
    }

    /// @notice A freshly-set flag (full WINDOW remaining) returns maxFee.
    function test_computePenaltyFee_freshFlag_returnsMaxFee() public {
        uint256 expiry = block.timestamp + WINDOW; // full window remaining
        uint24 fee = harness.computePenaltyFee(expiry, BASE_FEE, MAX_FEE, WINDOW);
        assertEq(fee, MAX_FEE, "full window remaining -> maxFee");
    }

    /// @notice Halfway through the window returns a fee between baseFee and maxFee.
    function test_computePenaltyFee_halfway_interpolates() public {
        uint256 expiry = block.timestamp + WINDOW / 2;
        uint24 fee = harness.computePenaltyFee(expiry, BASE_FEE, MAX_FEE, WINDOW);

        uint256 expected = BASE_FEE + (MAX_FEE - BASE_FEE) / 2;
        assertEq(fee, uint24(expected), "halfway -> midpoint fee");
    }

    /// @notice Fee is always in [baseFee, maxFee] range.
    function test_fuzz_computePenaltyFee_inRange(uint256 remaining) public view {
        vm.assume(remaining <= WINDOW);
        uint256 expiry = block.timestamp + remaining;
        uint24 fee = harness.computePenaltyFee(expiry, BASE_FEE, MAX_FEE, WINDOW);
        assertGe(fee, BASE_FEE, "fee >= baseFee");
        assertLe(fee, MAX_FEE, "fee <= maxFee");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ReactiveArbitrageSensor - sandwich detection
    // ─────────────────────────────────────────────────────────────────────────

    ReactiveArbitrageSensor sensor;
    address constant ARGOS_HOOK = address(0xCAFE);
    uint256 constant UNICHAIN_CHAIN_ID = 1301;

    // V3 Swap event topic0
    bytes32 constant SWAP_TOPIC = keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)");

    // Reactive Callback event signature
    bytes32 constant CALLBACK_SIG = keccak256("Callback(uint256,address,uint64,bytes)");

    function _makeSwapLog(address swapSender, uint256 blockNum) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: 1, // Ethereum mainnet
            _contract: address(0xBEEF),
            topic_0: uint256(SWAP_TOPIC),
            topic_1: uint256(uint160(swapSender)),
            topic_2: uint256(uint160(address(0xDEAD))),
            topic_3: 0,
            data: "",
            block_number: blockNum,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function setUp_sensor() internal {
        // AbstractReactive uses vmOnly modifier which reads extcodesize(0xfffff...)
        // In forge local env this passes (no code at that address).
        sensor = new ReactiveArbitrageSensor(ARGOS_HOOK, UNICHAIN_CHAIN_ID);
    }

    /// @notice Constructor sets argosHook and destinationChainId correctly.
    function test_sensor_deployment() public {
        setUp_sensor();
        assertEq(sensor.argosHook(), ARGOS_HOOK);
        assertEq(sensor.destinationChainId(), UNICHAIN_CHAIN_ID);
        assertEq(sensor.SANDWICH_THRESHOLD(), 2);
    }

    /// @notice A single swap from a sender does NOT emit a Callback.
    function test_sensor_singleSwap_noCallback() public {
        setUp_sensor();
        address arb = makeAddr("arb");

        vm.recordLogs();
        sensor.react(_makeSwapLog(arb, 100));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], CALLBACK_SIG, "single swap should not trigger Callback");
        }
        assertEq(sensor.swapCountPerBlock(arb, 100), 1);
    }

    /// @notice A second swap from the same sender in the same block emits SandwichDetected + Callback.
    function test_sensor_twoSwaps_emitsCallback() public {
        setUp_sensor();
        address arb = makeAddr("arb");

        sensor.react(_makeSwapLog(arb, 100));

        // Record logs for the second call
        vm.recordLogs();
        sensor.react(_makeSwapLog(arb, 100));

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify SandwichDetected was emitted
        bytes32 sandwichSig = keccak256("SandwichDetected(address,uint256,uint8)");
        bool foundSandwich = false;
        bool foundCallback = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sandwichSig) {
                foundSandwich = true;
            }
            if (logs[i].topics[0] == CALLBACK_SIG) {
                foundCallback = true;
                // Callback(uint256 indexed chain_id, address indexed _contract, uint64 indexed gas_limit, bytes payload)
                // The first 3 params are indexed (in topics). Only `bytes payload` is in the log data.
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                bytes memory expectedPayload = abi.encodeWithSignature("flagToxicAddress(address)", arb);
                assertEq(payload, expectedPayload, "Callback payload should encode flagToxicAddress(arb)");
            }
        }

        assertTrue(foundSandwich, "SandwichDetected event not emitted");
        assertTrue(foundCallback, "Callback event not emitted on second swap");
        assertEq(sensor.swapCountPerBlock(arb, 100), 2);
    }

    /// @notice Non-Swap topic0 events are ignored.
    function test_sensor_nonSwapTopic_ignored() public {
        setUp_sensor();
        address arb = makeAddr("arb");

        IReactive.LogRecord memory log = _makeSwapLog(arb, 100);
        log.topic_0 = uint256(keccak256("Transfer(address,address,uint256)")); // wrong event

        vm.recordLogs();
        sensor.react(log);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], CALLBACK_SIG, "non-Swap event should not trigger Callback");
        }
        assertEq(sensor.swapCountPerBlock(arb, 100), 0, "count should not increment for non-Swap");
    }

    /// @notice Swaps in different blocks are tracked independently.
    function test_sensor_differentBlocks_independent() public {
        setUp_sensor();
        address arb = makeAddr("arb");

        // One swap in block 100 and one swap in block 101 - threshold NOT reached for either
        sensor.react(_makeSwapLog(arb, 100));

        vm.recordLogs();
        sensor.react(_makeSwapLog(arb, 101)); // different block -> separate counter

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], CALLBACK_SIG, "cross-block swaps should not trigger");
        }

        assertEq(sensor.swapCountPerBlock(arb, 100), 1);
        assertEq(sensor.swapCountPerBlock(arb, 101), 1);
    }

    /// @notice Zero address sender is ignored.
    function test_sensor_zeroSender_ignored() public {
        setUp_sensor();

        IReactive.LogRecord memory log = _makeSwapLog(address(0), 100);

        vm.recordLogs();
        sensor.react(log);
        sensor.react(log); // two calls, still shouldn't trigger for zero addr

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], CALLBACK_SIG, "zero sender should not emit Callback");
        }
    }
}
