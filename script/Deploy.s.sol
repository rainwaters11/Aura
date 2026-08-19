// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ArgosLTSHook} from "../src/ArgosLTSHook.sol";
import {ReactiveArbitrageSensor} from "../src/ReactiveArbitrageSensor.sol";

/// @title Deploy
/// @notice Foundry deployment script for ArgosLTSHook and ReactiveArbitrageSensor.
///
///         HOOK ADDRESS MINING:
///         Uniswap V4 validates that a hook's address encodes its permissions in the
///         trailing bits. This script uses CREATE2 with an iterated salt to find an
///         address satisfying the required flag mask before deploying.
///
///         Required flags:
///           Hooks.BEFORE_SWAP_FLAG (bit 7)
///           Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG (bit 3)
///
///         USAGE:
///           # Local Anvil
///           forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --private-key $PK --broadcast
///
///           # Unichain Sepolia
///           forge script script/DeployUnichain.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --private-key $PK --broadcast --verify
///
///         ENVIRONMENT VARIABLES:
///           POOL_MANAGER    — Uniswap V4 PoolManager address on target chain
///           REACTIVE_SENSOR — Address of the Reactive Network sensor (or mock)
///           OWNER           — Hook owner who can call setParkingMode()
///           CURRENCY0       — Token address (or address(0) for native ETH)
///           CURRENCY1       — Token address
///           SENSOR_HOOK     — ArgosLTSHook address for ReactiveArbitrageSensor (set after hook deploy)
///           DEST_CHAIN_ID   — Destination Unichain chain ID for sensor callbacks (1301 testnet)
contract Deploy is Script {
    using CurrencyLibrary for Currency;

    // ─────────────────────────────────────────────────────────────────────────
    // Flag mask for hook address requirement
    // ─────────────────────────────────────────────────────────────────────────

    uint160 public constant REQUIRED_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    // Mask for the lower 14 bits (all V4 hook permission bits)
    uint160 public constant ALL_HOOK_MASK = (1 << 14) - 1;

    // ─────────────────────────────────────────────────────────────────────────
    // Run
    // ─────────────────────────────────────────────────────────────────────────

    function run() external {
        // ── Read env vars ────────────────────────────────────────────────────
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address sensorAddr = vm.envOr("REACTIVE_SENSOR", vm.addr(1)); // default to test addr
        address ownerAddr = vm.envOr("OWNER", msg.sender);

        IPoolManager poolManager = IPoolManager(poolManagerAddr);

        console2.log("=== Argos LTS v2 Deployment ===");
        console2.log("PoolManager:     ", poolManagerAddr);
        console2.log("ReactiveSensor:  ", sensorAddr);
        console2.log("Owner:           ", ownerAddr);

        vm.startBroadcast();

        // ── Mine CREATE2 salt ────────────────────────────────────────────────
        // Find a salt such that the deployed address ends with the required hook flags.
        bytes memory constructorArgs = abi.encode(poolManager, sensorAddr, ownerAddr);
        bytes memory creationCode = abi.encodePacked(type(ArgosLTSHook).creationCode, constructorArgs);
        bytes32 initcodeHash = keccak256(creationCode);

        // CREATE2 factory (Arachnid deterministic deployment proxy)
        address create2Factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        bytes32 salt = bytes32(0);
        address predicted;
        uint256 attempts;
        while (true) {
            predicted = _computeCreate2Address(create2Factory, salt, initcodeHash);
            if (uint160(predicted) & ALL_HOOK_MASK == REQUIRED_FLAGS) break;
            unchecked {
                salt = bytes32(uint256(salt) + 1);
                attempts++;
            }
            require(attempts < 50_000, "Deploy: salt mining failed - too many iterations");
        }

        console2.log("Salt mined after", attempts, "iterations");
        console2.log("Predicted hook address:", predicted);

        // ── Deploy ArgosLTSHook ───────────────────────────────────────────────
        // Direct CREATE2 deployment via the Arachnid factory
        // Format: abi.encodePacked(salt, creationCode) sent to factory
        (bool ok,) = create2Factory.call(abi.encodePacked(salt, creationCode));
        require(ok, "Deploy: hook deployment failed");

        ArgosLTSHook hookDeployed = ArgosLTSHook(predicted);
        console2.log("ArgosLTSHook deployed at:", address(hookDeployed));

        // ── Configure default pool parking mode ───────────────────────────────
        address currency0Addr = vm.envOr("CURRENCY0", address(0));
        address currency1Addr = vm.envOr("CURRENCY1", address(0));
        bool deployPool = currency0Addr != address(0) && currency1Addr != address(0);

        if (deployPool) {
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(currency0Addr),
                currency1: Currency.wrap(currency1Addr),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(hookDeployed))
            });

            // Enable PARK mode on default pool
            hookDeployed.setParkingMode(key, true);
            console2.log("PARK mode enabled for pool");
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("ArgosLTSHook:              ", address(hookDeployed));
        console2.log("");
        console2.log("Next: deploy ReactiveArbitrageSensor to Reactive Network");
        console2.log("  SENSOR_HOOK=", address(hookDeployed));
        console2.log("  forge script script/DeployUnichain.s.sol --rpc-url $REACTIVE_RPC ...");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CREATE2 address prediction
    // ─────────────────────────────────────────────────────────────────────────

    function _computeCreate2Address(address factory, bytes32 salt, bytes32 initcodeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initcodeHash)))));
    }
}
