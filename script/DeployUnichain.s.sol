// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ArgosLTSHook} from "../src/ArgosLTSHook.sol";
import {ReactiveArbitrageSensor} from "../src/ReactiveArbitrageSensor.sol";

/// @title DeployUnichain
/// @notice Deploys ArgosLTS specifically to Unichain Sepolia (testnet).
///
///         This script derives deployment parameters from environment variables
///         using Unichain Sepolia defaults where available.
///
///         UNICHAIN SEPOLIA CONSTANTS (as of hackathon submission):
///           Chain ID:       1301
///           PoolManager:    0xC81462Fec8B23319F288047f8A03A57682a35C1A
///           Block time:     ~250ms
///
///         USAGE:
///           export UNICHAIN_SEPOLIA_RPC="..."
///           export PRIVATE_KEY="0x..."
///           export OWNER="0x..."
///           export REACTIVE_SENSOR="0x..."   # set after Reactive chain deploy
///           forge script script/DeployUnichain.s.sol \
///             --rpc-url $UNICHAIN_SEPOLIA_RPC   \
///             --private-key $PRIVATE_KEY        \
///             --broadcast                       \
///             --verify                          \
///             --etherscan-api-key $BLOCKSCOUT_KEY
///
///         NOTE ON SENSOR ADDRESS:
///         When deploying to testnet without a live Reactive Network integration,
///         use a controlled EOA as the REACTIVE_SENSOR for manual testing.
///         Replace with the actual Reactive callback proxy address for mainnet.
contract DeployUnichain is Script {
    // ─────────────────────────────────────────────────────────────────────────
    // Unichain Sepolia known addresses
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Uniswap V4 PoolManager on Unichain Sepolia (verified 2026-04 from docs.uniswap.org/contracts/v4/deployments)
    address public constant UNICHAIN_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    uint256 public constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    uint160 public constant REQUIRED_FLAGS = uint160(0x0080 | 0x0008); // BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG

    uint160 public constant ALL_HOOK_MASK = (1 << 14) - 1;

    address public constant ARGOS_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address owner = vm.envOr("OWNER", msg.sender);
        address sensor = vm.envOr("REACTIVE_SENSOR", msg.sender); // fallback to deployer for testing
        address poolManagerAddr = vm.envOr("UNICHAIN_POOL_MANAGER_OVERRIDE", UNICHAIN_POOL_MANAGER);

        console2.log("=== Argos LTS v2 - Unichain Sepolia Deployment ===");
        console2.log("Chain ID:         1301 (Unichain Sepolia)");
        console2.log("PoolManager:     ", poolManagerAddr);
        console2.log("ReactiveSensor:  ", sensor);
        console2.log("Owner:           ", owner);
        console2.log("Deployer:        ", msg.sender);

        vm.startBroadcast();

        // ── Mine CREATE2 salt ─────────────────────────────────────────────────
        bytes memory args = abi.encode(poolManagerAddr, sensor, owner);
        bytes memory creationCode = abi.encodePacked(type(ArgosLTSHook).creationCode, args);
        bytes32 initcodeHash = keccak256(creationCode);

        bytes32 salt;
        address predicted;
        uint256 attempts;
        while (true) {
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), ARGOS_CREATE2_FACTORY, salt, initcodeHash))))
            );
            if (uint160(predicted) & ALL_HOOK_MASK == REQUIRED_FLAGS) break;
            unchecked {
                salt = bytes32(uint256(salt) + 1);
                attempts++;
            }
            require(attempts < 100_000, "DeployUnichain: could not find valid salt");
        }

        console2.log("Salt mined (iterations):", attempts);
        console2.log("Predicted ArgosLTSHook address:", predicted);

        (bool ok,) = ARGOS_CREATE2_FACTORY.call(abi.encodePacked(salt, creationCode));
        require(ok, "DeployUnichain: ArgosLTSHook deployment failed");

        ArgosLTSHook hookDeployed = ArgosLTSHook(predicted);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Successful ===");
        console2.log("ArgosLTSHook:    ", address(hookDeployed));
        console2.log("");
        console2.log("Verify on Blockscout Unichain Sepolia:");
        console2.log("  https://unichain-sepolia.blockscout.com/address/", address(hookDeployed));
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Deploy ReactiveArbitrageSensor on Reactive Network");
        console2.log("     with SENSOR_HOOK =", address(hookDeployed));
        console2.log("  2. Call hook.setParkingMode(poolKey, true) for your USDC/WETH pool");
        console2.log("  3. Configure Lit Protocol action with hook address");
        console2.log("     See: integrations/lit-protocol/README.md");
    }
}
