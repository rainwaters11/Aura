// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Typed, public configuration for one Aura Core deployment.
struct AuraDeploymentConfig {
    uint256 chainId;
    address poolManager;
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    uint160 initialSqrtPriceX96;
    address deployer;
    uint64 deployerStartingNonce;
    bytes32 reviewedCreate2FailureTxHash;
    address create2Factory;
    address verifier;
    address predictedRouter;
    address minedHook;
    bytes32 hookSalt;
    address initializationAuthority;
    address callbackProxy;
    bytes32 callbackProxyCodeHash;
    address expectedRvmId;
    bytes32 verifierCreationCodeHash;
    bytes32 routerCreationCodeHash;
    bytes32 hookCreationCodeHash;
    bytes32 verifierRuntimeCodeHash;
    bytes32 routerRuntimeCodeHash;
    bytes32 hookRuntimeCodeHash;
    string compilerVersion;
    bool optimizer;
    uint32 optimizerRuns;
    bool viaIr;
}
