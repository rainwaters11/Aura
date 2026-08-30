# Issue 15 Aura Core deployer handoff

Base: `609fab601316b9804e6821bab1cbddd1ca9bac14` (PR #30 merge)

Branch: `codex/issue-15-aura-core-deployer`

Target: Unichain Sepolia, chain ID 1301

## Scope and stop decision

This package prepares deployment of only `AuraSettlementVerifier`, `AuraRouter`,
and `AuraHook`. It does not initialize a pool and contains no liquidity, token
transfer, verification, signing, or public broadcast action. Solution inbox,
Reactive dispatcher/automation, solver infrastructure or competition, frontend,
Circle/Arc integration, and multi-pool behavior are deferred non-goals.

**The chain-1301 deployment simulation is blocked pending approval of the public
deployer address, callback proxy, and expected RVM identity.** Those values
determine nonce-derived and CREATE2 addresses. They were not present in the
environment and have not been invented. No simulated production address, gas
estimate, or wallet requirement is claimed until that exact tuple is approved.

The callback proxy is the only caller authorized to invoke settlement, and the
RVM identity is independently checked inside that call. A wrong or unavailable
proxy/RVM pair prevents settlement callbacks; users retain the fixed timeout
refund path. Neither value can be a zero address. The operator must approve the
proxy address and its nonzero runtime code hash as one manifest entry. Preflight
rejects an EOA, missing proxy deployment, or code-hash mismatch before address
prediction, hook mining, or deployment simulation.

## Typed manifest

`AuraDeploymentConfig` is the authoritative typed manifest. The checked-in
`.env.example` enumerates every field but deliberately uses `REQUIRED_*` markers
for undecided values, so it cannot be accidentally consumed as a valid manifest.
The deployer script rejects the wrong chain, canonical-address mismatch, missing
dependency code, zero authorities, nonce drift, occupied output address,
noncanonical salt, address mismatch, hook-bit mismatch, callback-proxy bytecode
drift, or build-setting drift.
The pool configuration is immutable and pinned to fee `3000` with tick spacing
`60`; other nonzero values and incompatible fee/tick-spacing combinations fail
before hook-address mining or deployment simulation.

Environment integers are read at full width and checked before narrowing. In
particular, fee, tick spacing, deployer starting nonce, and optimizer runs reject
out-of-range values rather than truncating them. The nonce must also leave two
slots for the verifier and router CREATE address predictions.

Approved fixed values are:

| Field | Value |
| --- | --- |
| chain ID | `1301` |
| PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| currency0 | Circle testnet USDC `0x31d0220469e10c4E71834a79b1f276d740d3768F` |
| currency1 | OP Stack WETH9 predeploy `0x4200000000000000000000000000000000000006` |
| fee / tick spacing | `3000` / `60` |
| CREATE2 factory | deterministic deployment proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C` |
| compiler | Solidity `0.8.30`, optimizer enabled, 200 runs, `via_ir = false` |

The WETH address is not inferred from an arbitrary token list: it is the WETH9
predeploy specified for OP Stack networks, and the read-only Unichain Sepolia
probe returned `name = Wrapped Ether`, `symbol = WETH`, and 2,865 bytes of code.
The same probe confirmed code at PoolManager, USDC, WETH, and the CREATE2 factory.

Read-only bytecode evidence at the preflight checkpoint:

| Address | Bytes | Runtime code hash |
| --- | ---: | --- |
| PoolManager | 24,009 | `0x7c5e10e0bd8580e13b48751e4cd7db6315577488d0f76b20bc6c8bcbe2646dc0` |
| USDC | 1,798 | `0xc2059a483ceeca165dfcc9727922e7c8c7b99710e84eca06cf765c235b133893` |
| WETH9 | 2,865 | `0xd0f1614c5dacfbd34f1c6f500f397009e4c9a8bfd4e02db353edb2253d9a8012` |
| CREATE2 factory | 69 | `0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989` |

The script pins the factory code hash because its `salt || initcode` behavior is
part of address mining. PoolManager and token deployments are required to have
code; their proxy/implementation governance remains an external dependency.

Values still requiring explicit operator approval are deployer, finalized
starting nonce, callback proxy address and runtime code hash, and expected RVM
ID. After those are fixed:

1. verifier is predicted at `CREATE(deployer, startingNonce)`;
2. router is predicted at `CREATE(deployer, startingNonce + 1)`;
3. hook initcode is built with those predictions and the complete immutable
   constructor tuple;
4. the first salt within the bounded search whose address has low bits `0x0088`
   is recorded;
5. verifier and router are created in that order and nonce/address checked after
   each transaction;
6. the hook is deployed by calling the same factory with `salt || initcode`, then
   its address, code, and permission bits are checked.

This is specifically Uniswap v4 hook-address mining plus router-address
prediction. It is not a generic deterministic-deployment policy.

## Verification evidence

- `forge fmt` and `forge fmt --check`: passed.
- `git diff --check`: passed.
- `forge build --sizes --optimize --optimizer-runs 200`: passed. Optimized
  `AuraHook` runtime is 21,716 bytes, 1,284 bytes below the 23,000-byte
  operational ceiling (and 2,860 bytes below EIP-170).
- Exact-head CI `#79` passed `forge fmt --check`, `forge build --sizes`, and
  `forge test -vvv`: 204 tests passed, 0 failed, and 8 intentional Reactive fork
  tests skipped (212 total). All 21 deployer tests passed, including focused
  regressions for missing callback-proxy code, code-hash drift, and a zero
  approved code hash.
- The required non-broadcast `forge script` command reached configuration load
  and stopped on missing `AURA_CHAIN_ID`, as intended. It did not simulate or
  publish transactions. This is a blocker, not a successful fork simulation.

The test-only deployment uses fictional authorities and a local EVM solely to
prove transaction order and assertions. Its addresses and aggregate test gas are
not production simulation results and must not be copied into the manifest.

## Read-only simulation command

Only after replacing every `REQUIRED_*` marker with an approved public value:

```bash
set -a
. deployments/unichain-sepolia-aura-core.env
set +a
forge script script/DeployAura.s.sol:DeployAura \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC" -vvv
```

The absence of `--broadcast` is mandatory. The script uses `startBroadcast` only
to make Foundry construct the correct unsigned transaction sequence during
simulation; it cannot publish without the CLI broadcast flag. Expected ordering
is verifier CREATE, router CREATE, then CREATE2-factory call. Pool initialization
is not present in the script.

For verification rehearsal, constructor arguments are exactly:

```text
AuraSettlementVerifier: 0x
AuraRouter: abi.encode(poolManager, (currency0,currency1,fee,tickSpacing,minedHook))
AuraHook: abi.encode(poolManager,predictedRouter,currency0,currency1,fee,
                     tickSpacing,verifier,callbackProxy,expectedRvmId)
```

## Required balance and recovery

Required balance remains pending the blocked fork simulation. After it runs,
record each transaction gas estimate, sum them, apply a documented conservative
gas multiplier, and multiply by an approved maximum fee per gas. The recommended
balance is that deployment maximum plus an operator reserve; pool funding is
separate and is not authorized by this package.

On any mismatch, stop before the next transaction and never initialize a pool.
A verifier with matching verified bytecode may be reused only under a newly
reviewed manifest. A router whose hook deployment failed is abandoned with its
PoolKey. Any hook address/code/immutable mismatch quarantines the entire tuple.
Repository rollback is a revert of this deployment-package commit; immutable
on-chain contracts have no destructive rollback.

## Approval required for the simulation checkpoint

Provide and approve exactly:

```text
Use deployer <public address> at finalized nonce <nonce>, callback proxy
<public address> with runtime code hash <bytes32>, and expected RVM identity
<public address> to mine the Issue 15 AuraHook address and run an unsigned,
non-broadcast Unichain Sepolia fork simulation from <exact commit>.
```

That approval authorizes only read-only RPC access and unsigned simulation. It
does not authorize signing, broadcasting, public verification, pool
initialization, funding, token transfers, or Reactive deployment.
