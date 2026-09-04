// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {AuraHook} from "../src/AuraHook.sol";
import {AuraRouter} from "../src/AuraRouter.sol";
import {AuraSettlementVerifier} from "../src/AuraSettlementVerifier.sol";
import {IAuraRouter} from "../src/interfaces/IAuraRouter.sol";
import {IAuraSettlementVerifier} from "../src/interfaces/IAuraSettlementVerifier.sol";
import {AuraDeploymentConfig} from "./config/AuraDeploymentConfig.sol";

struct Create2RecoveryTransaction {
    bytes32 transactionHash;
    bytes32 blockHash;
    uint256 blockNumber;
    uint256 chainId;
    address sender;
    uint256 nonce;
    address target;
    bytes input;
}

struct Create2RecoveryReceipt {
    bytes32 transactionHash;
    bytes32 blockHash;
    uint256 blockNumber;
    address sender;
    address target;
    uint256 status;
}

/// @notice Mines and deploys the three-contract Aura Core.
/// @dev The CREATE2 factory accepts calldata `salt || initcode`, as used by the
///      deterministic deployment proxy at 0x4e59...956C.
contract DeployAura is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    uint256 public constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint160 public constant REQUIRED_HOOK_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
    uint160 public constant ALL_HOOK_MASK = uint160(Hooks.ALL_HOOK_MASK);
    uint256 public constant MAX_SALT_ATTEMPTS = 200_000;
    uint24 public constant AURA_FEE = 3000;
    int24 public constant AURA_TICK_SPACING = 60;

    address public constant UNICHAIN_SEPOLIA_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address public constant UNICHAIN_SEPOLIA_USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F;
    address public constant UNICHAIN_SEPOLIA_WETH = 0x4200000000000000000000000000000000000006;
    address public constant DETERMINISTIC_DEPLOYMENT_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant DETERMINISTIC_DEPLOYMENT_PROXY_CODEHASH =
        0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;
    bytes32 public constant VERIFIER_ARTIFACT = keccak256("AuraSettlementVerifier");
    bytes32 public constant ROUTER_ARTIFACT = keccak256("AuraRouter");
    bytes32 public constant HOOK_ARTIFACT = keccak256("AuraHook");
    bytes32 public constant VERIFIER_RUNTIME_ARTIFACT = keccak256("AuraSettlementVerifierRuntime");
    bytes32 public constant ROUTER_RUNTIME_ARTIFACT = keccak256("AuraRouterRuntime");
    bytes32 public constant HOOK_RUNTIME_ARTIFACT = keccak256("AuraHookRuntime");

    error WrongChain(uint256 actual);
    error InvalidConfiguration();
    error MissingCode(address account);
    error UnexpectedCode(address account);
    error CodeHashMismatch(address account, bytes32 expected, bytes32 actual);
    error CreationCodeHashMismatch(bytes32 artifact, bytes32 expected, bytes32 actual);
    error RuntimeCodeHashMismatch(bytes32 artifact, bytes32 expected, bytes32 actual);
    error NonceDrift(uint64 expected, uint64 actual);
    error MissingCreate2RecoveryEvidence();
    error UnexpectedCreate2RecoveryEvidence(bytes32 transactionHash);
    error InvalidCreate2RecoveryTransaction(bytes32 transactionHash);
    error InvalidCreate2RecoveryReceipt(bytes32 transactionHash);
    error AddressMismatch(address expected, address actual);
    error HookPermissionMismatch(address hook);
    error Create2DeploymentFailed();
    error AuraPoolAlreadyInitialized(PoolId poolId);
    error AuraPoolInitializationMismatch(PoolId poolId, uint160 expected, uint160 actual);
    error InvalidInitialSqrtPrice(uint256 value);
    error InitialSqrtPriceOutOfRange(uint256 value);

    function run() external returns (AuraSettlementVerifier verifier, AuraRouter router, AuraHook hook) {
        AuraDeploymentConfig memory config = loadConfig();
        (PoolKey memory key, bool verifierAlreadyDeployed, bool routerAlreadyDeployed, bool hookAlreadyDeployed) =
            validatePreflight(config);

        vm.startBroadcast(config.deployer);
        if (verifierAlreadyDeployed) {
            verifier = AuraSettlementVerifier(config.verifier);
        } else {
            verifier = new AuraSettlementVerifier();
            if (address(verifier) != config.verifier) revert AddressMismatch(config.verifier, address(verifier));
            _requireNonce(config.deployer, config.deployerStartingNonce + 1);
        }
        _requireCodeHash(address(verifier), config.verifierRuntimeCodeHash);

        if (routerAlreadyDeployed) {
            router = AuraRouter(config.predictedRouter);
        } else {
            router = new AuraRouter(IPoolManager(config.poolManager), key);
            if (address(router) != config.predictedRouter) {
                revert AddressMismatch(config.predictedRouter, address(router));
            }
            _requireNonce(config.deployer, config.deployerStartingNonce + 2);
        }
        _requireCodeHash(address(router), config.routerRuntimeCodeHash);

        if (!hookAlreadyDeployed) {
            bytes memory initcode = hookInitcode(config);
            (bool success,) = config.create2Factory.call(abi.encodePacked(config.hookSalt, initcode));
            // A hook deployed after simulation but before this raw factory transaction
            // makes the broadcast transaction revert. `validatePreflight` permits one
            // consumed factory nonce on the audited recovery run only after the exact
            // hook deployment and immutable bindings have been verified.
            if (!success && config.minedHook.code.length == 0) revert Create2DeploymentFailed();
        }
        hook = AuraHook(config.minedHook);
        _requireHookDeployment(config, hook);

        PoolId poolId = hook.auraPoolId();
        (uint160 sqrtPriceX96,,,) = IPoolManager(config.poolManager).getSlot0(poolId);
        if (sqrtPriceX96 == 0) {
            IPoolManager(config.poolManager).initialize(key, config.initialSqrtPriceX96);
            (sqrtPriceX96,,,) = IPoolManager(config.poolManager).getSlot0(poolId);
        }
        if (sqrtPriceX96 != config.initialSqrtPriceX96) {
            revert AuraPoolInitializationMismatch(poolId, config.initialSqrtPriceX96, sqrtPriceX96);
        }
        vm.stopBroadcast();

        console2.log("AuraSettlementVerifier", address(verifier));
        console2.log("AuraRouter", address(router));
        console2.log("AuraHook", address(hook));
    }

    function loadConfig() public view virtual returns (AuraDeploymentConfig memory config) {
        uint256 feeValue = vm.envUint("AURA_FEE");
        int256 tickSpacingValue = vm.envInt("AURA_TICK_SPACING");
        uint256 initialSqrtPriceX96Value = vm.envUint("AURA_INITIAL_SQRT_PRICE_X96");
        uint256 startingNonceValue = vm.envUint("AURA_DEPLOYER_STARTING_NONCE");
        uint256 optimizerRunsValue = vm.envUint("AURA_OPTIMIZER_RUNS");

        if (feeValue > type(uint24).max || feeValue != AURA_FEE) revert InvalidConfiguration();
        if (
            tickSpacingValue < type(int24).min || tickSpacingValue > type(int24).max
                || tickSpacingValue != AURA_TICK_SPACING
        ) revert InvalidConfiguration();
        if (initialSqrtPriceX96Value == 0 || initialSqrtPriceX96Value > type(uint160).max) {
            revert InvalidInitialSqrtPrice(initialSqrtPriceX96Value);
        }
        if (initialSqrtPriceX96Value <= TickMath.MIN_SQRT_PRICE || initialSqrtPriceX96Value >= TickMath.MAX_SQRT_PRICE) revert InitialSqrtPriceOutOfRange(initialSqrtPriceX96Value);
        if (startingNonceValue > uint256(type(uint64).max) - 2) revert InvalidConfiguration();
        if (optimizerRunsValue > type(uint32).max || optimizerRunsValue != 200) revert InvalidConfiguration();

        config = AuraDeploymentConfig({
            chainId: vm.envUint("AURA_CHAIN_ID"),
            poolManager: vm.envAddress("AURA_POOL_MANAGER"),
            currency0: vm.envAddress("AURA_CURRENCY0"),
            currency1: vm.envAddress("AURA_CURRENCY1"),
            fee: uint24(feeValue),
            tickSpacing: int24(tickSpacingValue),
            initialSqrtPriceX96: uint160(initialSqrtPriceX96Value),
            deployer: vm.envAddress("AURA_DEPLOYER"),
            deployerStartingNonce: uint64(startingNonceValue),
            reviewedCreate2RecoveryTxHash: vm.envBytes32("AURA_REVIEWED_CREATE2_RECOVERY_TX_HASH"),
            create2Factory: vm.envAddress("AURA_CREATE2_FACTORY"),
            verifier: vm.envAddress("AURA_VERIFIER"),
            predictedRouter: vm.envAddress("AURA_PREDICTED_ROUTER"),
            minedHook: vm.envAddress("AURA_MINED_HOOK"),
            hookSalt: vm.envBytes32("AURA_HOOK_SALT"),
            initializationAuthority: vm.envAddress("AURA_INITIALIZATION_AUTHORITY"),
            callbackProxy: vm.envAddress("AURA_CALLBACK_PROXY"),
            callbackProxyCodeHash: vm.envBytes32("AURA_CALLBACK_PROXY_CODEHASH"),
            expectedRvmId: vm.envAddress("AURA_EXPECTED_RVM_ID"),
            verifierCreationCodeHash: vm.envBytes32("AURA_VERIFIER_CREATION_CODEHASH"),
            routerCreationCodeHash: vm.envBytes32("AURA_ROUTER_CREATION_CODEHASH"),
            hookCreationCodeHash: vm.envBytes32("AURA_HOOK_CREATION_CODEHASH"),
            verifierRuntimeCodeHash: vm.envBytes32("AURA_VERIFIER_RUNTIME_CODEHASH"),
            routerRuntimeCodeHash: vm.envBytes32("AURA_ROUTER_RUNTIME_CODEHASH"),
            hookRuntimeCodeHash: vm.envBytes32("AURA_HOOK_RUNTIME_CODEHASH"),
            compilerVersion: vm.envString("AURA_COMPILER_VERSION"),
            optimizer: vm.envBool("AURA_OPTIMIZER"),
            optimizerRuns: uint32(optimizerRunsValue),
            viaIr: vm.envBool("AURA_VIA_IR")
        });
    }

    function validatePreflight(AuraDeploymentConfig memory config)
        public
        returns (PoolKey memory key, bool verifierAlreadyDeployed, bool routerAlreadyDeployed, bool hookAlreadyDeployed)
    {
        if (block.chainid != UNICHAIN_SEPOLIA_CHAIN_ID || config.chainId != UNICHAIN_SEPOLIA_CHAIN_ID) {
            revert WrongChain(block.chainid);
        }
        if (
            config.poolManager != UNICHAIN_SEPOLIA_POOL_MANAGER || config.currency0 != UNICHAIN_SEPOLIA_USDC
                || config.currency1 != UNICHAIN_SEPOLIA_WETH || config.currency0 >= config.currency1
                || config.fee != AURA_FEE || config.tickSpacing != AURA_TICK_SPACING
                || config.deployerStartingNonce > type(uint64).max - 2 || config.deployer == address(0)
                || config.initializationAuthority == address(0) || config.initializationAuthority != config.deployer
                || config.callbackProxy == address(0) || config.callbackProxyCodeHash == bytes32(0)
                || config.expectedRvmId == address(0) || config.create2Factory != DETERMINISTIC_DEPLOYMENT_PROXY
                || config.verifierCreationCodeHash == bytes32(0) || config.routerCreationCodeHash == bytes32(0)
                || config.hookCreationCodeHash == bytes32(0) || config.verifierRuntimeCodeHash == bytes32(0)
                || config.routerRuntimeCodeHash == bytes32(0) || config.hookRuntimeCodeHash == bytes32(0)
                || keccak256(bytes(config.compilerVersion)) != keccak256("0.8.30") || !config.optimizer
                || config.optimizerRuns != 200 || config.viaIr
        ) revert InvalidConfiguration();
        if (config.initialSqrtPriceX96 == 0) revert InvalidInitialSqrtPrice(0);
        if (
            config.initialSqrtPriceX96 <= TickMath.MIN_SQRT_PRICE
                || config.initialSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE
        ) revert InitialSqrtPriceOutOfRange(config.initialSqrtPriceX96);

        _requireCreationCodeHash(
            VERIFIER_ARTIFACT, config.verifierCreationCodeHash, keccak256(type(AuraSettlementVerifier).creationCode)
        );
        _requireCreationCodeHash(
            ROUTER_ARTIFACT, config.routerCreationCodeHash, keccak256(type(AuraRouter).creationCode)
        );
        _requireCreationCodeHash(HOOK_ARTIFACT, config.hookCreationCodeHash, keccak256(type(AuraHook).creationCode));
        _requireRuntimeCodeHash(
            VERIFIER_RUNTIME_ARTIFACT,
            config.verifierRuntimeCodeHash,
            keccak256(type(AuraSettlementVerifier).runtimeCode)
        );

        _requireCode(config.poolManager);
        _requireCode(config.currency0);
        _requireCode(config.currency1);
        _requireCode(config.create2Factory);
        _requireCode(config.callbackProxy);
        if (config.create2Factory.codehash != DETERMINISTIC_DEPLOYMENT_PROXY_CODEHASH) {
            revert CodeHashMismatch(
                config.create2Factory, DETERMINISTIC_DEPLOYMENT_PROXY_CODEHASH, config.create2Factory.codehash
            );
        }
        if (config.callbackProxy.codehash != config.callbackProxyCodeHash) {
            revert CodeHashMismatch(config.callbackProxy, config.callbackProxyCodeHash, config.callbackProxy.codehash);
        }
        verifierAlreadyDeployed = config.verifier.code.length != 0;
        routerAlreadyDeployed = config.predictedRouter.code.length != 0;
        hookAlreadyDeployed = config.minedHook.code.length != 0;
        if (hookAlreadyDeployed && (!verifierAlreadyDeployed || !routerAlreadyDeployed)) revert InvalidConfiguration();
        if (routerAlreadyDeployed && !verifierAlreadyDeployed) revert InvalidConfiguration();
        if (verifierAlreadyDeployed) {
            _requireCodeHash(config.verifier, config.verifierRuntimeCodeHash);
        }
        if (routerAlreadyDeployed) {
            _requireCodeHash(config.predictedRouter, config.routerRuntimeCodeHash);
        }
        uint64 expectedNonce = config.deployerStartingNonce;
        if (verifierAlreadyDeployed) ++expectedNonce;
        if (routerAlreadyDeployed) ++expectedNonce;

        address verifierPrediction = vm.computeCreateAddress(config.deployer, config.deployerStartingNonce);
        if (verifierPrediction != config.verifier) revert AddressMismatch(config.verifier, verifierPrediction);
        address routerPrediction = vm.computeCreateAddress(config.deployer, config.deployerStartingNonce + 1);
        if (routerPrediction != config.predictedRouter) {
            revert AddressMismatch(config.predictedRouter, routerPrediction);
        }

        bytes32 initcodeHash = keccak256(hookInitcode(config));
        address hookPrediction = computeCreate2Address(config.create2Factory, config.hookSalt, initcodeHash);
        if (hookPrediction != config.minedHook) revert AddressMismatch(config.minedHook, hookPrediction);
        (bytes32 minedSalt, address minedHook) = findHookSalt(config, MAX_SALT_ATTEMPTS);
        if (minedSalt != config.hookSalt) revert InvalidConfiguration();
        if (minedHook != config.minedHook) revert AddressMismatch(config.minedHook, minedHook);
        requireHookFlags(hookPrediction);

        key = auraPoolKey(config);
        PoolId poolId = key.toId();
        if (routerAlreadyDeployed) {
            AuraRouter existingRouter = AuraRouter(config.predictedRouter);
            if (address(existingRouter.poolManager()) != config.poolManager) {
                revert AddressMismatch(config.poolManager, address(existingRouter.poolManager()));
            }
            if (PoolId.unwrap(existingRouter.auraPoolId()) != PoolId.unwrap(poolId)) revert InvalidConfiguration();
        }
        if (hookAlreadyDeployed) {
            _requireHookDeployment(config, AuraHook(config.minedHook));
            (uint160 sqrtPriceX96,,,) = IPoolManager(config.poolManager).getSlot0(poolId);
            if (sqrtPriceX96 != 0 && sqrtPriceX96 != config.initialSqrtPriceX96) {
                revert AuraPoolInitializationMismatch(poolId, config.initialSqrtPriceX96, sqrtPriceX96);
            }
        } else {
            (uint160 sqrtPriceX96,,,) = IPoolManager(config.poolManager).getSlot0(poolId);
            if (sqrtPriceX96 != 0) revert AuraPoolAlreadyInitialized(poolId);
        }
        _requireDeploymentNonce(config, expectedNonce, hookAlreadyDeployed);
    }

    function auraPoolKey(AuraDeploymentConfig memory config) public pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(config.currency0),
            currency1: Currency.wrap(config.currency1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(config.minedHook)
        });
    }

    function hookInitcode(AuraDeploymentConfig memory config) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(AuraHook).creationCode,
            abi.encode(
                IPoolManager(config.poolManager),
                IAuraRouter(config.predictedRouter),
                Currency.wrap(config.currency0),
                Currency.wrap(config.currency1),
                config.fee,
                config.tickSpacing,
                IAuraSettlementVerifier(config.verifier),
                config.initializationAuthority,
                config.callbackProxy,
                config.expectedRvmId,
                config.initialSqrtPriceX96
            )
        );
    }

    function findHookSalt(AuraDeploymentConfig memory config, uint256 maxAttempts)
        public
        pure
        returns (bytes32 salt, address hook)
    {
        bytes32 initcodeHash = keccak256(hookInitcode(config));
        for (uint256 i; i < maxAttempts; ++i) {
            salt = bytes32(i);
            hook = computeCreate2Address(config.create2Factory, salt, initcodeHash);
            if (uint160(hook) & ALL_HOOK_MASK == REQUIRED_HOOK_FLAGS) return (salt, hook);
        }
        revert InvalidConfiguration();
    }

    function computeCreate2Address(address factory, bytes32 salt, bytes32 initcodeHash) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initcodeHash)))));
    }

    function _requireHookDeployment(AuraDeploymentConfig memory config, AuraHook hook) internal view {
        if (address(hook).code.length == 0) revert MissingCode(address(hook));
        _requireCodeHash(address(hook), config.hookRuntimeCodeHash);
        bytes memory initcode = hookInitcode(config);
        if (address(hook) != computeCreate2Address(config.create2Factory, config.hookSalt, keccak256(initcode))) {
            revert AddressMismatch(config.minedHook, address(hook));
        }
        requireHookFlags(address(hook));
        if (address(hook.auraRouter()) != config.predictedRouter) {
            revert AddressMismatch(config.predictedRouter, address(hook.auraRouter()));
        }
        if (address(hook.settlementVerifier()) != config.verifier) {
            revert AddressMismatch(config.verifier, address(hook.settlementVerifier()));
        }
        if (address(hook.poolManager()) != config.poolManager) {
            revert AddressMismatch(config.poolManager, address(hook.poolManager()));
        }
        if (PoolId.unwrap(hook.auraPoolId()) != PoolId.unwrap(auraPoolKey(config).toId())) {
            revert InvalidConfiguration();
        }
        if (hook.initializationAuthority() != config.initializationAuthority) {
            revert AddressMismatch(config.initializationAuthority, hook.initializationAuthority());
        }
        if (hook.reactiveCallbackProxy() != config.callbackProxy) {
            revert AddressMismatch(config.callbackProxy, hook.reactiveCallbackProxy());
        }
        if (hook.expectedRvmId() != config.expectedRvmId) {
            revert AddressMismatch(config.expectedRvmId, hook.expectedRvmId());
        }
        if (hook.approvedInitialSqrtPriceX96() != config.initialSqrtPriceX96) {
            revert InvalidInitialSqrtPrice(hook.approvedInitialSqrtPriceX96());
        }
    }

    function _requireCode(address account) internal view {
        if (account.code.length == 0) revert MissingCode(account);
    }

    function _requireNoCode(address account) internal view {
        if (account == address(0) || account.code.length != 0) revert UnexpectedCode(account);
    }

    function _requireCodeHash(address account, bytes32 expected) internal view {
        bytes32 actual = account.codehash;
        if (actual != expected) revert CodeHashMismatch(account, expected, actual);
    }

    function _requireNonce(address deployer, uint64 expected) internal view {
        uint64 actual = vm.getNonce(deployer);
        if (actual != expected) revert NonceDrift(expected, actual);
    }

    function _requireDeploymentNonce(AuraDeploymentConfig memory config, uint64 expected, bool exactHookAlreadyDeployed)
        internal
    {
        uint64 actual = vm.getNonce(config.deployer);
        if (actual == expected) {
            if (config.reviewedCreate2RecoveryTxHash != bytes32(0)) {
                revert UnexpectedCreate2RecoveryEvidence(config.reviewedCreate2RecoveryTxHash);
            }
            return;
        }

        // During a `--slow` broadcast, exactly one factory nonce can be consumed
        // before initialization in either of two audited states: an identical
        // permissionless CREATE2 call front-ran the deployer's failed factory
        // transaction, or the deployer's factory transaction succeeded before
        // the broadcast was interrupted. A rerun may continue to guarded
        // initialization only after the existing hook passed every code, address,
        // flag, and immutable check above and the manifest names that exact factory
        // transaction. The transaction and receipt are fetched from the configured
        // chain and bound to the sender, nonce, factory, calldata, mined block, and
        // a canonical failed-or-successful receipt status. No unrelated wallet
        // activity or other nonce drift is accepted as implicit recovery evidence.
        if (exactHookAlreadyDeployed && expected != type(uint64).max && actual == expected + 1) {
            if (config.reviewedCreate2RecoveryTxHash == bytes32(0)) revert MissingCreate2RecoveryEvidence();
            _requireCreate2RecoveryEvidence(config, expected);
            return;
        }

        revert NonceDrift(expected, actual);
    }

    function _requireCreate2RecoveryEvidence(AuraDeploymentConfig memory config, uint64 expectedNonce) internal {
        bytes32 reviewedHash = config.reviewedCreate2RecoveryTxHash;
        (Create2RecoveryTransaction memory transaction, Create2RecoveryReceipt memory receipt) =
            _loadCreate2RecoveryEvidence(reviewedHash);

        bytes32 expectedInputHash = keccak256(abi.encodePacked(config.hookSalt, hookInitcode(config)));
        if (
            transaction.transactionHash != reviewedHash || transaction.blockHash == bytes32(0)
                || transaction.blockNumber == 0 || transaction.chainId != config.chainId
                || transaction.sender != config.deployer || transaction.nonce != expectedNonce
                || transaction.target != config.create2Factory || keccak256(transaction.input) != expectedInputHash
        ) revert InvalidCreate2RecoveryTransaction(reviewedHash);

        if (
            receipt.transactionHash != reviewedHash || receipt.blockHash == bytes32(0)
                || receipt.blockHash != transaction.blockHash || receipt.blockNumber == 0
                || receipt.blockNumber != transaction.blockNumber || receipt.sender != config.deployer
                || receipt.target != config.create2Factory || receipt.status > 1
        ) revert InvalidCreate2RecoveryReceipt(reviewedHash);
    }

    function _loadCreate2RecoveryEvidence(bytes32 transactionHash)
        internal
        virtual
        returns (Create2RecoveryTransaction memory transaction, Create2RecoveryReceipt memory receipt)
    {
        string memory transactionJson = _castRpc("eth_getTransactionByHash", transactionHash);
        string memory receiptJson = _castRpc("eth_getTransactionReceipt", transactionHash);

        transaction = Create2RecoveryTransaction({
            transactionHash: vm.parseJsonBytes32(transactionJson, ".hash"),
            blockHash: vm.parseJsonBytes32(transactionJson, ".blockHash"),
            blockNumber: vm.parseJsonUint(transactionJson, ".blockNumber"),
            chainId: vm.parseJsonUint(transactionJson, ".chainId"),
            sender: vm.parseJsonAddress(transactionJson, ".from"),
            nonce: vm.parseJsonUint(transactionJson, ".nonce"),
            target: vm.parseJsonAddress(transactionJson, ".to"),
            input: vm.parseJsonBytes(transactionJson, ".input")
        });
        receipt = Create2RecoveryReceipt({
            transactionHash: vm.parseJsonBytes32(receiptJson, ".transactionHash"),
            blockHash: vm.parseJsonBytes32(receiptJson, ".blockHash"),
            blockNumber: vm.parseJsonUint(receiptJson, ".blockNumber"),
            sender: vm.parseJsonAddress(receiptJson, ".from"),
            target: vm.parseJsonAddress(receiptJson, ".to"),
            status: vm.parseJsonUint(receiptJson, ".status")
        });
    }

    function _castRpc(string memory method, bytes32 transactionHash) internal virtual returns (string memory) {
        string[] memory command = new string[](6);
        command[0] = "cast";
        command[1] = "rpc";
        command[2] = "--rpc-url";
        command[3] = "unichain_sepolia";
        command[4] = method;
        command[5] = vm.toString(transactionHash);
        return string(vm.ffi(command));
    }

    function _requireCreationCodeHash(bytes32 artifact, bytes32 expected, bytes32 actual) internal pure {
        if (actual != expected) revert CreationCodeHashMismatch(artifact, expected, actual);
    }

    function _requireRuntimeCodeHash(bytes32 artifact, bytes32 expected, bytes32 actual) internal pure {
        if (actual != expected) revert RuntimeCodeHashMismatch(artifact, expected, actual);
    }

    function requireHookFlags(address hook) public pure {
        if (uint160(hook) & ALL_HOOK_MASK != REQUIRED_HOOK_FLAGS) revert HookPermissionMismatch(hook);
    }
}
