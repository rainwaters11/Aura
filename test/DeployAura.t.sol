// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {DeployAura} from "../script/DeployAura.s.sol";
import {AuraDeploymentConfig} from "../script/config/AuraDeploymentConfig.sol";
import {AuraHook} from "../src/AuraHook.sol";
import {AuraRouter} from "../src/AuraRouter.sol";
import {AuraSettlementVerifier} from "../src/AuraSettlementVerifier.sol";

contract PoolManagerSlot0Mock {
    using PoolIdLibrary for PoolKey;

    mapping(bytes32 slot => bytes32 value) internal words;
    uint256 public initializeCalls;
    PoolId public lastInitializedPoolId;
    uint160 public lastInitializedSqrtPriceX96;

    function extsload(bytes32 slot) external view returns (bytes32) {
        return words[slot];
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24) {
        PoolId poolId = key.toId();
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(poolId), uint256(6)));
        if (address(key.hooks).code.length == 0) revert("missing hook");
        bytes4 hookResponse = IHooks(address(key.hooks)).beforeInitialize(msg.sender, key, sqrtPriceX96);
        if (hookResponse != IHooks.beforeInitialize.selector) revert("invalid hook response");
        if (uint160(uint256(words[slot])) != 0) revert("already initialized");
        words[slot] = bytes32(uint256(sqrtPriceX96));
        initializeCalls++;
        lastInitializedPoolId = poolId;
        lastInitializedSqrtPriceX96 = sqrtPriceX96;
        return 0;
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
    uint160 internal constant INITIAL_SQRT_PRICE_X96 = 79228162514264337593543950336;

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
            initialSqrtPriceX96: INITIAL_SQRT_PRICE_X96,
            deployer: DEPLOYER,
            deployerStartingNonce: STARTING_NONCE,
            create2Factory: script.DETERMINISTIC_DEPLOYMENT_PROXY(),
            verifier: vm.computeCreateAddress(DEPLOYER, STARTING_NONCE),
            predictedRouter: vm.computeCreateAddress(DEPLOYER, STARTING_NONCE + 1),
            minedHook: address(0),
            hookSalt: bytes32(0),
            initializationAuthority: DEPLOYER,
            callbackProxy: CALLBACK_PROXY,
            callbackProxyCodeHash: CALLBACK_PROXY.codehash,
            expectedRvmId: RVM_ID,
            verifierCreationCodeHash: keccak256(type(AuraSettlementVerifier).creationCode),
            routerCreationCodeHash: keccak256(type(AuraRouter).creationCode),
            hookCreationCodeHash: keccak256(type(AuraHook).creationCode),
            verifierRuntimeCodeHash: keccak256(type(AuraSettlementVerifier).runtimeCode),
            routerRuntimeCodeHash: bytes32(uint256(1)),
            hookRuntimeCodeHash: bytes32(uint256(1)),
            compilerVersion: "0.8.30",
            optimizer: true,
            optimizerRuns: 200,
            viaIr: false
        });
        (config.hookSalt, config.minedHook) = script.findHookSalt(config, 200_000);
        (config.routerRuntimeCodeHash, config.hookRuntimeCodeHash) = _deriveRuntimeCodeHashes(config);
    }

    function test_deploysExactConstructorsPredictionsFactorySaltFlagsAndInitializesPool() public {
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
        assertEq(hook.initializationAuthority(), config.initializationAuthority);
        assertEq(hook.reactiveCallbackProxy(), CALLBACK_PROXY);
        assertEq(hook.expectedRvmId(), RVM_ID);
        assertEq(hook.approvedInitialSqrtPriceX96(), config.initialSqrtPriceX96);
        assertEq(PoolId.unwrap(hook.auraPoolId()), PoolId.unwrap(router.auraPoolId()));
        assertEq(script.UNICHAIN_SEPOLIA_POOL_MANAGER().codehash, poolManagerCodeHashBefore);
        assertTrue(hook.auraPoolInitialized());
        assertEq(PoolManagerSlot0Mock(config.poolManager).initializeCalls(), 1);
        assertEq(
            PoolId.unwrap(PoolManagerSlot0Mock(config.poolManager).lastInitializedPoolId()),
            PoolId.unwrap(hook.auraPoolId())
        );
        assertEq(PoolManagerSlot0Mock(config.poolManager).lastInitializedSqrtPriceX96(), config.initialSqrtPriceX96);
    }

    function test_uninitializedPredictedPoolIdPassesPreflight() public view {
        (PoolKey memory key,,,) = script.validatePreflight(config);
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

    function test_initializationBeforeHookDeploymentFails() public {
        PoolKey memory key = script.auraPoolKey(config);
        vm.expectRevert("missing hook");
        vm.prank(config.initializationAuthority);
        PoolManagerSlot0Mock(config.poolManager).initialize(key, config.initialSqrtPriceX96);
    }

    function test_unauthorizedAccountCannotInitializeAfterHookDeployment() public {
        (AuraHook hook, PoolKey memory key) = _deployCoreWithoutInitialization();
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(AuraHook.UnauthorizedInitializationSender.selector);
        PoolManagerSlot0Mock(config.poolManager).initialize(key, config.initialSqrtPriceX96);
        assertFalse(hook.auraPoolInitialized());
    }

    function test_authorityCanInitializeOnceAtApprovedPrice() public {
        (AuraHook hook, PoolKey memory key) = _deployCoreWithoutInitialization();

        vm.prank(config.initializationAuthority);
        PoolManagerSlot0Mock(config.poolManager).initialize(key, config.initialSqrtPriceX96);
        assertTrue(hook.auraPoolInitialized());
        assertEq(PoolManagerSlot0Mock(config.poolManager).initializeCalls(), 1);

        PoolId poolId = hook.auraPoolId();
        vm.expectRevert(abi.encodeWithSelector(AuraHook.AuraPoolAlreadyInitialized.selector, poolId));
        vm.prank(config.initializationAuthority);
        PoolManagerSlot0Mock(config.poolManager).initialize(key, config.initialSqrtPriceX96);
    }

    function test_wrongPriceAndWrongPoolKeyFailInitialization() public {
        (AuraHook hook, PoolKey memory key) = _deployCoreWithoutInitialization();

        vm.prank(config.initializationAuthority);
        vm.expectRevert(abi.encodeWithSelector(AuraHook.InvalidInitializationPrice.selector, uint160(1)));
        PoolManagerSlot0Mock(config.poolManager).initialize(key, 1);

        PoolKey memory wrongKey = key;
        wrongKey.tickSpacing = wrongKey.tickSpacing + 1;
        vm.prank(config.initializationAuthority);
        vm.expectRevert(AuraHook.InvalidInitializationPoolKey.selector);
        PoolManagerSlot0Mock(config.poolManager).initialize(wrongKey, config.initialSqrtPriceX96);

        assertFalse(hook.auraPoolInitialized());
    }

    function test_identicalPredeployedCoreIsAcceptedAndInitialized() public {
        _deployCoreWithoutInitialization();
        runner.setConfig(config);

        (AuraSettlementVerifier verifier, AuraRouter router, AuraHook hook) = runner.run();
        assertEq(address(verifier), config.verifier);
        assertEq(address(router), config.predictedRouter);
        assertEq(address(hook), config.minedHook);
        assertEq(PoolManagerSlot0Mock(config.poolManager).initializeCalls(), 1);
        assertTrue(hook.auraPoolInitialized());
    }

    function test_identicalFactoryFrontRunRecoveryAllowsOneConsumedNonceAndInitializes() public {
        PoolKey memory key = script.auraPoolKey(config);
        vm.startPrank(DEPLOYER);
        new AuraSettlementVerifier();
        new AuraRouter(IPoolManager(config.poolManager), key);
        vm.stopPrank();

        address frontRunner = makeAddr("frontRunner");
        vm.prank(frontRunner);
        (bool success,) = config.create2Factory.call(abi.encodePacked(config.hookSalt, script.hookInitcode(config)));
        assertTrue(success);
        AuraHook frontRunHook = AuraHook(config.minedHook);
        assertEq(address(frontRunHook).codehash, config.hookRuntimeCodeHash);
        assertFalse(frontRunHook.auraPoolInitialized());

        // The deployer's subsequently reverted factory transaction consumed its
        // nonce before `--slow` stopped the original broadcast.
        vm.setNonce(DEPLOYER, STARTING_NONCE + 3);
        runner.setConfig(config);

        (AuraSettlementVerifier verifier, AuraRouter router, AuraHook hook) = runner.run();

        assertEq(address(verifier), config.verifier);
        assertEq(address(router), config.predictedRouter);
        assertEq(address(hook), config.minedHook);
        assertTrue(hook.auraPoolInitialized());
        assertEq(PoolManagerSlot0Mock(config.poolManager).initializeCalls(), 1);
    }

    function test_consumedFactoryNonceRequiresExactPredeployedHook() public {
        PoolKey memory key = script.auraPoolKey(config);
        vm.startPrank(DEPLOYER);
        new AuraSettlementVerifier();
        new AuraRouter(IPoolManager(config.poolManager), key);
        vm.stopPrank();
        vm.setNonce(DEPLOYER, STARTING_NONCE + 3);
        runner.setConfig(config);

        vm.expectRevert(abi.encodeWithSelector(DeployAura.NonceDrift.selector, STARTING_NONCE + 2, STARTING_NONCE + 3));
        runner.run();
    }

    function test_identicalFactoryFrontRunRecoveryRejectsAdditionalNonceDrift() public {
        _deployCoreWithoutInitialization();
        vm.setNonce(DEPLOYER, STARTING_NONCE + 4);
        runner.setConfig(config);

        vm.expectRevert(abi.encodeWithSelector(DeployAura.NonceDrift.selector, STARTING_NONCE + 2, STARTING_NONCE + 4));
        runner.run();
    }

    function test_mismatchedExistingHookImmutablesAreRejected() public {
        _deployCoreWithoutInitialization();
        config.initialSqrtPriceX96 = config.initialSqrtPriceX96 + 1;
        address changedHookPrediction = script.computeCreate2Address(
            config.create2Factory, config.hookSalt, keccak256(script.hookInitcode(config))
        );
        runner.setConfig(config);
        vm.expectRevert(
            abi.encodeWithSelector(DeployAura.AddressMismatch.selector, config.minedHook, changedHookPrediction)
        );
        runner.run();
    }

    function test_initializedPoolWithWrongPriceIsRejectedWhenHookAlreadyExists() public {
        (AuraHook hook, PoolKey memory key) = _deployCoreWithoutInitialization();
        PoolManagerSlot0Mock(config.poolManager).setSlot0(key.toId(), config.initialSqrtPriceX96 + 1);
        runner.setConfig(config);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAura.AuraPoolInitializationMismatch.selector,
                hook.auraPoolId(),
                config.initialSqrtPriceX96,
                config.initialSqrtPriceX96 + 1
            )
        );
        runner.run();
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

    function test_rejectsOccupiedDeploymentAddressWithMismatchedCodeHash() public {
        vm.etch(config.verifier, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAura.CodeHashMismatch.selector,
                config.verifier,
                config.verifierRuntimeCodeHash,
                config.verifier.codehash
            )
        );
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

    /// @dev `vm.setEnv` mutates process-wide state, so all environment parsing
    ///      regressions stay in one test and run in a deterministic sequence.
    function test_loadConfigRejectsInvalidFullWidthValues() public {
        _setEnvironment(config);
        vm.setEnv("AURA_FEE", vm.toString((uint256(1) << 24) + script.AURA_FEE()));
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.loadConfig();

        _setEnvironment(config);
        vm.setEnv("AURA_TICK_SPACING", vm.toString((uint256(1) << 24) + uint24(script.AURA_TICK_SPACING())));
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.loadConfig();

        _setEnvironment(config);
        vm.setEnv("AURA_DEPLOYER_STARTING_NONCE", vm.toString((uint256(1) << 64) + config.deployerStartingNonce));
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.loadConfig();

        _setEnvironment(config);
        vm.setEnv("AURA_DEPLOYER_STARTING_NONCE", vm.toString(type(uint64).max - 1));
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.loadConfig();

        _setEnvironment(config);
        vm.setEnv("AURA_OPTIMIZER_RUNS", vm.toString((uint256(1) << 32) + 200));
        vm.expectRevert(DeployAura.InvalidConfiguration.selector);
        script.loadConfig();

        _setEnvironment(config);
        vm.setEnv("AURA_INITIAL_SQRT_PRICE_X96", "0");
        vm.expectRevert(abi.encodeWithSelector(DeployAura.InvalidInitialSqrtPrice.selector, 0));
        script.loadConfig();

        _setEnvironment(config);
        vm.setEnv("AURA_INITIAL_SQRT_PRICE_X96", vm.toString((uint256(1) << 160) + uint256(config.initialSqrtPriceX96)));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAura.InvalidInitialSqrtPrice.selector, (uint256(1) << 160) + uint256(config.initialSqrtPriceX96)
            )
        );
        script.loadConfig();

        _setEnvironment(config);
        vm.setEnv("AURA_INITIAL_SQRT_PRICE_X96", vm.toString(uint256(TickMath.MIN_SQRT_PRICE)));
        vm.expectRevert(
            abi.encodeWithSelector(DeployAura.InitialSqrtPriceOutOfRange.selector, uint256(TickMath.MIN_SQRT_PRICE))
        );
        script.loadConfig();

        _setEnvironment(config);
        vm.setEnv("AURA_INITIAL_SQRT_PRICE_X96", vm.toString(uint256(TickMath.MAX_SQRT_PRICE)));
        vm.expectRevert(
            abi.encodeWithSelector(DeployAura.InitialSqrtPriceOutOfRange.selector, uint256(TickMath.MAX_SQRT_PRICE))
        );
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

    function test_rejectsOutOfRangeInitialSqrtPriceInTypedConfig() public {
        config.initialSqrtPriceX96 = 1;
        vm.expectRevert(abi.encodeWithSelector(DeployAura.InitialSqrtPriceOutOfRange.selector, uint256(1)));
        script.validatePreflight(config);
    }

    function test_initialSqrtPriceAffectsHookInitcodeHashSaltAndPredictedAddress() public {
        bytes32 initcodeHash = keccak256(script.hookInitcode(config));
        bytes32 salt = config.hookSalt;
        address predicted = script.computeCreate2Address(config.create2Factory, salt, initcodeHash);

        AuraDeploymentConfig memory changed = config;
        changed.initialSqrtPriceX96 = config.initialSqrtPriceX96 + 1;
        bytes32 changedInitcodeHash = keccak256(script.hookInitcode(changed));
        (bytes32 changedSalt, address changedHook) = script.findHookSalt(changed, 200_000);

        assertNotEq(changedInitcodeHash, initcodeHash);
        assertNotEq(changedSalt, salt);
        assertEq(predicted, config.minedHook);
        assertEq(changedHook, script.computeCreate2Address(changed.create2Factory, changedSalt, changedInitcodeHash));
        assertNotEq(changedHook, predicted);
    }

    function _deployCoreWithoutInitialization() internal returns (AuraHook hook, PoolKey memory key) {
        key = script.auraPoolKey(config);
        vm.startPrank(DEPLOYER);
        new AuraSettlementVerifier();
        new AuraRouter(IPoolManager(config.poolManager), key);
        (bool success,) = config.create2Factory.call(abi.encodePacked(config.hookSalt, script.hookInitcode(config)));
        vm.stopPrank();

        assertTrue(success);
        hook = AuraHook(config.minedHook);
        assertEq(address(hook).codehash, config.hookRuntimeCodeHash);
        assertEq(PoolManagerSlot0Mock(config.poolManager).initializeCalls(), 0);
        assertFalse(hook.auraPoolInitialized());
    }

    function _deriveRuntimeCodeHashes(AuraDeploymentConfig memory cfg)
        internal
        returns (bytes32 routerRuntimeCodeHash, bytes32 hookRuntimeCodeHash)
    {
        uint256 snapshotId = vm.snapshotState();
        PoolKey memory key = script.auraPoolKey(cfg);

        vm.startPrank(cfg.deployer);
        new AuraSettlementVerifier();
        new AuraRouter(IPoolManager(cfg.poolManager), key);
        (bool success,) = cfg.create2Factory.call(abi.encodePacked(cfg.hookSalt, script.hookInitcode(cfg)));
        vm.stopPrank();

        assertTrue(success);
        routerRuntimeCodeHash = cfg.predictedRouter.codehash;
        hookRuntimeCodeHash = cfg.minedHook.codehash;

        bool reverted = vm.revertToState(snapshotId);
        assertTrue(reverted);
    }

    function _setEnvironment(AuraDeploymentConfig memory c) internal {
        vm.setEnv("AURA_CHAIN_ID", vm.toString(c.chainId));
        vm.setEnv("AURA_POOL_MANAGER", vm.toString(c.poolManager));
        vm.setEnv("AURA_CURRENCY0", vm.toString(c.currency0));
        vm.setEnv("AURA_CURRENCY1", vm.toString(c.currency1));
        vm.setEnv("AURA_FEE", vm.toString(c.fee));
        vm.setEnv("AURA_TICK_SPACING", vm.toString(c.tickSpacing));
        vm.setEnv("AURA_INITIAL_SQRT_PRICE_X96", vm.toString(c.initialSqrtPriceX96));
        vm.setEnv("AURA_DEPLOYER", vm.toString(c.deployer));
        vm.setEnv("AURA_DEPLOYER_STARTING_NONCE", vm.toString(c.deployerStartingNonce));
        vm.setEnv("AURA_CREATE2_FACTORY", vm.toString(c.create2Factory));
        vm.setEnv("AURA_VERIFIER", vm.toString(c.verifier));
        vm.setEnv("AURA_PREDICTED_ROUTER", vm.toString(c.predictedRouter));
        vm.setEnv("AURA_MINED_HOOK", vm.toString(c.minedHook));
        vm.setEnv("AURA_HOOK_SALT", vm.toString(c.hookSalt));
        vm.setEnv("AURA_INITIALIZATION_AUTHORITY", vm.toString(c.initializationAuthority));
        vm.setEnv("AURA_CALLBACK_PROXY", vm.toString(c.callbackProxy));
        vm.setEnv("AURA_CALLBACK_PROXY_CODEHASH", vm.toString(c.callbackProxyCodeHash));
        vm.setEnv("AURA_EXPECTED_RVM_ID", vm.toString(c.expectedRvmId));
        vm.setEnv("AURA_VERIFIER_CREATION_CODEHASH", vm.toString(c.verifierCreationCodeHash));
        vm.setEnv("AURA_ROUTER_CREATION_CODEHASH", vm.toString(c.routerCreationCodeHash));
        vm.setEnv("AURA_HOOK_CREATION_CODEHASH", vm.toString(c.hookCreationCodeHash));
        vm.setEnv("AURA_VERIFIER_RUNTIME_CODEHASH", vm.toString(c.verifierRuntimeCodeHash));
        vm.setEnv("AURA_ROUTER_RUNTIME_CODEHASH", vm.toString(c.routerRuntimeCodeHash));
        vm.setEnv("AURA_HOOK_RUNTIME_CODEHASH", vm.toString(c.hookRuntimeCodeHash));
        vm.setEnv("AURA_COMPILER_VERSION", c.compilerVersion);
        vm.setEnv("AURA_OPTIMIZER", c.optimizer ? "true" : "false");
        vm.setEnv("AURA_OPTIMIZER_RUNS", vm.toString(c.optimizerRuns));
        vm.setEnv("AURA_VIA_IR", c.viaIr ? "true" : "false");
    }
}
