// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {DeployAura} from "../script/DeployAura.s.sol";
import {AuraDeploymentConfig} from "../script/config/AuraDeploymentConfig.sol";
import {AuraHook} from "../src/AuraHook.sol";
import {AuraRouter} from "../src/AuraRouter.sol";
import {AuraSettlementVerifier} from "../src/AuraSettlementVerifier.sol";

contract PoolManagerSlot0Mock {
    mapping(bytes32 slot => bytes32 value) internal words;
    uint256 public initializeCalls;

    function extsload(bytes32 slot) external view returns (bytes32) {
        return words[slot];
    }

    function setSlot0(PoolId poolId, uint160 sqrtPriceX96) external {
        words[keccak256(abi.encode(PoolId.unwrap(poolId), uint256(6)))] = bytes32(uint256(sqrtPriceX96));
    }
}

contract DeployAuraHarness is DeployAura {
    AuraDeploymentConfig private configOverride;

    function setConfig(AuraDeploymentConfig memory config_) external {
        configOverride = config_;
    }

    function loadConfig() public view override returns (AuraDeploymentConfig memory) {
        return configOverride;
    }
}

contract DeployAuraTest is Test {
    using PoolIdLibrary for PoolKey;

    DeployAura internal script;
    DeployAuraHarness internal runner;
    AuraDeploymentConfig internal config;

    address internal constant DEPLOYER = address(0xA11CE);
    address internal constant CALLBACK_PROXY = address(0xCA11BAC);
    address internal constant RVM_ID = address(0xB0B);
    uint64 internal constant STARTING_NONCE = 7;

    function setUp() public {
        vm.chainId(1301);
        script = new DeployAura();
        runner = new DeployAuraHarness();

        PoolManagerSlot0Mock poolManagerMock = new PoolManagerSlot0Mock();
        vm.etch(script.UNICHAIN_SEPOLIA_POOL_MANAGER(), address(poolManagerMock).code);
        vm.etch(script.UNICHAIN_SEPOLIA_USDC(), hex"00");
        vm.etch(script.UNICHAIN_SEPOLIA_WETH(), hex"00");
        vm.etch(CALLBACK_PROXY, hex"00");
        vm.etch(
            script.DETERMINISTIC_DEPLOYMENT_PROXY(),
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        vm.setNonce(DEPLOYER, STARTING_NONCE);

        config = AuraDeploymentConfig({
            chainId: 1301,
            poolManager: script.UNICHAIN_SEPOLIA_POOL_MANAGER(),
            currency0: script.UNICHAIN_SEPOLIA_USDC(),
            currency1: script.UNICHAIN_SEPOLIA_WETH(),
            fee: 3000,
            tickSpacing: 60,
            deployer: DEPLOYER,
            deployerStartingNonce: STARTING_NONCE,
            create2Factory: script.DETERMINISTIC_DEPLOYMENT_PROXY(),
            verifier: vm.computeCreateAddress(DEPLOYER, STARTING_NONCE),
            predictedRouter: vm.computeCreateAddress(DEPLOYER, STARTING_NONCE + 1),
            minedHook: address(0),
            hookSalt: bytes32(0),
            callbackProxy: CALLBACK_PROXY,
            callbackProxyCodeHash: CALLBACK_PROXY.codehash,
            expectedRvmId: RVM_ID,
            verifierCreationCodeHash: keccak256(type(AuraSettlementVerifier).creationCode),
            routerCreationCodeHash: keccak256(type(AuraRouter).creationCode),
            hookCreationCodeHash: keccak256(type(AuraHook).creationCode),
            compilerVersion: "0.8.30",
            optimizer: true,
            optimizerRuns: 200,
            viaIr: false
        });
        (config.hookSalt, config.minedHook) = script.findHookSalt(config, 200_000);
    }

    function test_deploysExactConstructorsPredictionsFactorySaltAndFlagsWithoutInitializingPool() public {
        runner.setConfig(config);
        bytes32 poolManagerCodeHashBefore = script.UNICHAIN_SEPOLIA_POOL_MANAGER().codehash;

        (AuraSettlementVerifier verifier, AuraRouter router, AuraHook hook) = runner.run();

        assertEq(address(verifier), config.verifier);
        assertEq(address(router), config.predictedRouter);
        assertEq(address(hook), config.minedHook);
        assertEq(uint160(address(hook)) & script.ALL_HOOK_MASK(), script.REQUIRED_HOOK_FLAGS());
        assertEq(address(router.poolManager()), config.poolManager);
        PoolKey memory key = router.auraPoolKey();
        assertEq(Currency.unwrap(key.currency0), config.currency0);
        assertEq(Currency.unwrap(key.currency1), config.currency1);
        assertEq(key.fee, config.fee);
        assertEq(key.tickSpacing, config.tickSpacing);
        assertEq(address(key.hooks), config.minedHook);
        assertEq(address(hook.auraRouter()), config.predictedRouter);
        assertEq(address(hook.settlementVerifier()), config.verifier);
        assertEq(hook.reactiveCallbackProxy(), CALLBACK_PROXY);
        assertEq(hook.expectedRvmId(), RVM_ID);
        assertEq(PoolId.unwrap(hook.auraPoolId()), PoolId.unwrap(router.auraPoolId()));
        assertEq(script.UNICHAIN_SEPOLIA_POOL_MANAGER().codehash, poolManagerCodeHashBefore);
        assertEq(PoolManagerSlot0Mock(config.poolManager).initializeCalls(), 0);
    }

    function test_uninitializedPredictedPoolIdPassesPreflight() public view {
        PoolKey memory key = script.validatePreflight(config);
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(script.auraPoolKey(config).toId()));
    }

    function test_preinitializedPredictedPoolRejectsBeforeAnyDeployment() public {
        PoolId poolId = script.auraPoolKey(config).toId();
        PoolManagerSlot0Mock(config.poolManager).setSlot0(poolId, 1);
        runner.setConfig(config);

        uint64 nonceBefore = vm.getNonce(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(DeployAura.AuraPoolAlreadyInitialized.selector, poolId));
        runner.run();

        assertEq(vm.getNonce(DEPLOYER), nonceBefore);
        assertEq(config.verifier.code.length, 0);
        assertEq(config.predictedRouter.code.length, 0);
        assertEq(config.minedHook.code.length, 0);
        assertEq(PoolManagerSlot0Mock(config.poolManager).initializeCalls(), 0);
    }

    function test_poolInitializedAfterPreflightRejectsHookDeploymentAtomically() public {
        PoolId poolId = script.auraPoolKey(config).toId();
        bytes32 poolStateSlot = keccak256(abi.encode(PoolId.unwrap(poolId), uint256(6)));
        bytes[] memory slot0Results = new bytes[](2);
        slot0Results[0] = abi.encode(bytes32(0));
        slot0Results[1] = abi.encode(bytes32(uint256(1)));
        vm.mockCalls(
            config.poolManager,
            abi.encodeWithSelector(PoolManagerSlot0Mock.extsload.selector, poolStateSlot),
            slot0Results
        );
        runner.setConfig(config);

        vm.expectRevert(DeployAura.Create2DeploymentFailed.selector);
        runner.run();

        // Broadcasts are separate public transactions, so nonce rollback is not a safety property here.
        // The constructor-level invariant is that CREATE2 cannot leave a hook deployed after slot0 initializes.
        assertEq(config.verifier.code.length, 0);
        assertEq(config.predictedRouter.code.length, 0);
        assertEq(config.minedHook.code.length, 0);
        assertEq(PoolManagerSlot0Mock(config.poolManager).initializeCalls(), 0);
    }

    function test_rejectsWrongChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployAura.WrongChain.selector, 1));
        script.validatePreflight(config);
    }

    function test_rejectsNonceDrift() public {
        vm.setNonce(DEPLOYER, STARTING_NONCE + 1);
        vm.expectRevert(abi.encodeWithSelector(DeployAura.NonceDrift.selector, STARTING_NONCE, STARTING_NONCE + 1));
        script.validatePreflight(config);
    }

    function test_rejectsWrongPredictedAddress() public {
        config.predictedRouter = address(0xBAD);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAura.AddressMismatch.selector,
                config.predictedRouter,
                vm.computeCreateAddress(DEPLOYER, STARTING_NONCE + 1)
            )
        );
        script.validatePreflight(config);
    }

    function test_rejectsMissingDependencyCode() public {
        vm.etch(config.currency1, "");
        vm.expectRevert(abi.encodeWithSelector(DeployAura.MissingCode.selector, config.currency1));
        script.validatePreflight(config);
    }

    function test_rejectsOccupiedDeploymentAddress() public {
        vm.etch(config.verifier, hex"00");
        vm.expectRevert(abi.encodeWithSelector(DeployAura.UnexpectedCode.selector, config.verifier));
        script.validatePreflight(config);
    }

    function test_rejectsCreate2FactoryBytecodeMismatch() public {
        vm.etch(config.create2Factory, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAura.CodeHashMismatch.selector,
                config.create2Factory,
                script.DETERMINISTIC_DEPLOYMENT_PROXY_CODEHASH(),
                config.create2Factory.codehash
            )
        );
        script.validatePreflight(config);
    }

    function test_rejectsCallbackProxyWithoutCode() public {
        vm.etch(CALLBACK_PROXY, "");
        vm.expectRevert(abi.encodeWithSelector(DeployAura.MissingCode.selector, CALLBACK_PROXY));
        script.validatePreflight(config);
    }

    function test_rejectsCallbackProxyCodeHashMismatch() public {
        bytes32 unexpectedCodeHash = keccak256("unexpected callback proxy");
        config.callbackProxyCodeHash = unexpectedCodeHash;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAura.CodeHashMismatch.selector, CALLBACK_PROXY, unexpectedCodeHash, CALLBACK_PROXY.codehash
            )
        );
        script.validatePreflight(config);
    }

    function test_rejectsZeroCallbackProxyCodeHash() public {
        config.callbackProxyCodeHash = bytes32(0);
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.validatePreflight(config);
    }

    function test_rejectsVerifierCreationCodeHashMismatch() public {
        bytes32 expected = keccak256("unapproved verifier creation code");
        config.verifierCreationCodeHash = expected;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAura.CreationCodeHashMismatch.selector,
                script.VERIFIER_ARTIFACT(),
                expected,
                keccak256(type(AuraSettlementVerifier).creationCode)
            )
        );
        script.validatePreflight(config);
    }

    function test_rejectsRouterCreationCodeHashMismatch() public {
        bytes32 expected = keccak256("unapproved router creation code");
        config.routerCreationCodeHash = expected;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAura.CreationCodeHashMismatch.selector,
                script.ROUTER_ARTIFACT(),
                expected,
                keccak256(type(AuraRouter).creationCode)
            )
        );
        script.validatePreflight(config);
    }

    function test_rejectsHookCreationCodeHashMismatch() public {
        bytes32 expected = keccak256("unapproved hook creation code");
        config.hookCreationCodeHash = expected;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAura.CreationCodeHashMismatch.selector,
                script.HOOK_ARTIFACT(),
                expected,
                keccak256(type(AuraHook).creationCode)
            )
        );
        script.validatePreflight(config);
    }

    function test_rejectsZeroApprovedCreationCodeHash() public {
        config.hookCreationCodeHash = bytes32(0);
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.validatePreflight(config);
    }

    function test_rejectsConfigurationMismatchAndZeroAuthorities() public {
        config.optimizerRuns = 201;
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.validatePreflight(config);

        config.optimizerRuns = 200;
        config.callbackProxy = address(0);
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.validatePreflight(config);
    }

    function test_rejectsUnapprovedFee() public {
        config.fee = script.AURA_FEE() + 1;
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.validatePreflight(config);
    }

    function test_rejectsUnapprovedTickSpacing() public {
        config.tickSpacing = script.AURA_TICK_SPACING() + 1;
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.validatePreflight(config);
    }

    function test_rejectsIncompatibleFeeAndTickSpacingCombination() public {
        config.fee = 500;
        config.tickSpacing = 10;
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.validatePreflight(config);
    }

    function test_loadConfigRejectsOversizedFeeThatAliasesApprovedValue() public {
        _setEnvironment(config);
        vm.setEnv("AURA_FEE", vm.toString((uint256(1) << 24) + script.AURA_FEE()));
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.loadConfig();
    }

    function test_loadConfigRejectsOversizedTickSpacingThatAliasesApprovedValue() public {
        _setEnvironment(config);
        vm.setEnv("AURA_TICK_SPACING", vm.toString((uint256(1) << 24) + uint24(script.AURA_TICK_SPACING())));
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.loadConfig();
    }

    function test_loadConfigRejectsOversizedNonceThatAliasesApprovedValue() public {
        _setEnvironment(config);
        vm.setEnv("AURA_DEPLOYER_STARTING_NONCE", vm.toString((uint256(1) << 64) + config.deployerStartingNonce));
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.loadConfig();
    }

    function test_loadConfigRejectsNonceWithoutTwoPredictionSlots() public {
        _setEnvironment(config);
        vm.setEnv("AURA_DEPLOYER_STARTING_NONCE", vm.toString(type(uint64).max - 1));
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.loadConfig();
    }

    function test_loadConfigRejectsOversizedOptimizerRunsThatAliasesApprovedValue() public {
        _setEnvironment(config);
        vm.setEnv("AURA_OPTIMIZER_RUNS", vm.toString((uint256(1) << 32) + 200));
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.loadConfig();
    }

    function test_rejectsWrongFactoryAndPermissionBits() public {
        config.create2Factory = address(0xFACADE);
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.validatePreflight(config);

        config.create2Factory = script.DETERMINISTIC_DEPLOYMENT_PROXY();
        config.hookSalt = bytes32(0);
        config.minedHook = script.computeCreate2Address(
            config.create2Factory, config.hookSalt, keccak256(script.hookInitcode(config))
        );
        assertNotEq(uint160(config.minedHook) & script.ALL_HOOK_MASK(), script.REQUIRED_HOOK_FLAGS());
        vm.expectRevert(abi.encodeWithSelector(DeployAura.HookPermissionMismatch.selector, config.minedHook));
        script.requireHookFlags(config.minedHook);
    }

    function test_rejectsSaltOtherThanMinedCanonicalSalt() public {
        config.hookSalt = bytes32(uint256(config.hookSalt) + 1);
        config.minedHook = script.computeCreate2Address(
            config.create2Factory, config.hookSalt, keccak256(script.hookInitcode(config))
        );
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.validatePreflight(config);
    }

    function _setEnvironment(AuraDeploymentConfig memory c) internal {
        vm.setEnv("AURA_CHAIN_ID", vm.toString(c.chainId));
        vm.setEnv("AURA_POOL_MANAGER", vm.toString(c.poolManager));
        vm.setEnv("AURA_CURRENCY0", vm.toString(c.currency0));
        vm.setEnv("AURA_CURRENCY1", vm.toString(c.currency1));
        vm.setEnv("AURA_FEE", vm.toString(c.fee));
        vm.setEnv("AURA_TICK_SPACING", vm.toString(c.tickSpacing));
        vm.setEnv("AURA_DEPLOYER", vm.toString(c.deployer));
        vm.setEnv("AURA_DEPLOYER_STARTING_NONCE", vm.toString(c.deployerStartingNonce));
        vm.setEnv("AURA_CREATE2_FACTORY", vm.toString(c.create2Factory));
        vm.setEnv("AURA_VERIFIER", vm.toString(c.verifier));
        vm.setEnv("AURA_PREDICTED_ROUTER", vm.toString(c.predictedRouter));
        vm.setEnv("AURA_MINED_HOOK", vm.toString(c.minedHook));
        vm.setEnv("AURA_HOOK_SALT", vm.toString(c.hookSalt));
        vm.setEnv("AURA_CALLBACK_PROXY", vm.toString(c.callbackProxy));
        vm.setEnv("AURA_CALLBACK_PROXY_CODEHASH", vm.toString(c.callbackProxyCodeHash));
        vm.setEnv("AURA_EXPECTED_RVM_ID", vm.toString(c.expectedRvmId));
        vm.setEnv("AURA_VERIFIER_CREATION_CODEHASH", vm.toString(c.verifierCreationCodeHash));
        vm.setEnv("AURA_ROUTER_CREATION_CODEHASH", vm.toString(c.routerCreationCodeHash));
        vm.setEnv("AURA_HOOK_CREATION_CODEHASH", vm.toString(c.hookCreationCodeHash));
        vm.setEnv("AURA_COMPILER_VERSION", c.compilerVersion);
        vm.setEnv("AURA_OPTIMIZER", c.optimizer ? "true" : "false");
        vm.setEnv("AURA_OPTIMIZER_RUNS", vm.toString(c.optimizerRuns));
        vm.setEnv("AURA_VIA_IR", c.viaIr ? "true" : "false");
    }
}
