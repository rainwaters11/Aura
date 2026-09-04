# Issue 15 Aura Core deployer handoff

Base: `609fab601316b9804e6821bab1cbddd1ca9bac14` (PR #30 merge)

Branch: `codex/issue-15-aura-core-deployer`

Target: Unichain Sepolia, chain ID 1301

## Scope and stop decision

This package prepares deployment of only `AuraSettlementVerifier`, `AuraRouter`,
and `AuraHook`. The hook enforces one-time initialization through
`beforeInitialize` for the operator-approved initialization authority and
`AURA_INITIAL_SQRT_PRICE_X96`, while the script performs that initialize call only
after verified hook code exists. The package contains no liquidity, token
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
drift, creation-code drift, or build-setting drift.
The pool configuration is immutable and pinned to fee `3000` with tick spacing
`60`; other nonzero values and incompatible fee/tick-spacing combinations fail
before hook-address mining or deployment simulation.

Environment integers are read at full width and checked before narrowing. In
particular, fee, tick spacing, initial sqrt price, deployer starting nonce, and
optimizer runs reject out-of-range values rather than truncating them. The
initial price must be nonzero, fit `uint160`, and lie strictly inside TickMath
bounds; the nonce must also leave two slots for the verifier and router CREATE
address predictions.

The compiler fields document the intended build profile, but are not trusted as
proof of the bytecode that Foundry actually compiled. The manifest must also
contain separately approved creation and runtime code hashes for
`AuraSettlementVerifier`, `AuraRouter`, and `AuraHook`. Preflight hashes each
current `type(...).creationCode` and `type(...).runtimeCode` value and compares
it with the approved value before dependency checks, address prediction, salt
mining, simulation, or broadcast. Compiler and CLI overrides therefore fail
unless they produce byte-for-byte identical deployable artifacts.

Approved fixed values are:

| Field | Value |
| --- | --- |
| chain ID | `1301` |
| PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| currency0 | Circle testnet USDC `0x31d0220469e10c4E71834a79b1f276d740d3768F` |
| currency1 | OP Stack WETH9 predeploy `0x4200000000000000000000000000000000000006` |
| fee / tick spacing | `3000` / `60` |
| initial sqrt price (`AURA_INITIAL_SQRT_PRICE_X96`) | required approved nonzero `uint160` strictly inside TickMath bounds |
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
starting nonce, initialization authority, callback proxy address and runtime code
hash, expected RVM ID, and the verifier/router/hook creation+runtime code
hashes produced by the reviewed locked build. After those are fixed:

1. verifier is predicted at `CREATE(deployer, startingNonce)`;
2. router is predicted at `CREATE(deployer, startingNonce + 1)`;
3. hook initcode is built with those predictions, the approved initial sqrt
   price, and the complete immutable constructor tuple;
4. the first salt within the bounded search whose address has low bits `0x2088`
   is recorded;
5. verifier and router are created in that order and nonce/address checked after
   each transaction;
6. the hook is deployed by calling the same factory with `salt || initcode`; the
   constructor pins the immutable pool tuple, initialization authority, and
   approved initial price;
7. the hook address, code, and immutable values are checked;
8. only after the hook code exists, the approved authority initializes the pool
   once at the approved sqrt price through the hook-gated `beforeInitialize`
   callback.

This is specifically Uniswap v4 hook-address mining plus router-address
prediction. It is not a generic deterministic-deployment policy.

## Verification evidence

### Historical CI evidence

- CI run `#80` passed against historical commit
  `74768bafe67a73bd8a4a3bb2e650ca182869bb30`. It ran `forge fmt --check`,
  `forge build --sizes`, and `forge test -vvv`: 204 tests passed, 0 failed, and
  8 intentional Reactive fork tests skipped (212 total). All 21 deployer tests
  passed, including focused regressions for missing callback-proxy code,
  code-hash drift, and a zero approved code hash.
- CI run `#82` belongs only to PR #31 commit
  `df487f01c7e39df68970d2fcab7959f4d50c7a0d`. It is historical evidence only.
- CI run `#83` is predecessor evidence and does not test this completed patch.

### Historical local verification evidence

The handoff records local snapshot `5d91ef0` separately from CI run `#80`.
That snapshot is not a GitHub Actions run, is not the current PR head, and
predates the initialization-authority callback guard and its deployment tests.

- `forge fmt` and `forge fmt --check`: passed.
- `git diff --check`: passed.
- `forge build --sizes --optimize --optimizer-runs 200`: passed. Optimized
  `AuraHook` runtime is 21,716 bytes, 1,284 bytes below the 23,000-byte
  operational ceiling (and 2,860 bytes below EIP-170).
- `forge test --match-contract DeployAuraTest -vv`: 27 passed, 0 failed, 0
  skipped.
- `forge test -vv`: 210 passed, 0 failed, 8 intentionally skipped Reactive
  fork tests, 218 total.
- The required non-broadcast `forge script` command reached configuration load
  and stopped on missing `AURA_CHAIN_ID`, as intended. It did not simulate or
  publish transactions. This is a blocker, not a successful fork simulation.

These results were produced locally during the earlier implementation and do
not substitute for CI on the current PR head.

### Current exact-head CI evidence

Current exact-head CI evidence belongs in the PR checks and PR handoff after the
focused correction commit is pushed. A run for any earlier commit must not be
described as current exact-head evidence. New exact-head CI remains pending, and
no deployment approval may rely on local tests alone.

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
is verifier CREATE, router CREATE, then CREATE2-factory call, then one
`PoolManager.initialize` call from the approved initialization authority at the
approved initial price.

For verification rehearsal, constructor arguments are exactly:

```text
AuraSettlementVerifier: 0x
AuraRouter: abi.encode(poolManager, (currency0,currency1,fee,tickSpacing,minedHook))
AuraHook: abi.encode(poolManager,predictedRouter,currency0,currency1,fee,
                     tickSpacing,verifier,initializationAuthority,
                     callbackProxy,expectedRvmId,initialSqrtPriceX96)
```

## Required balance and recovery

Required balance remains pending the blocked fork simulation. After it runs,
record each transaction gas estimate, sum them, apply a documented conservative
gas multiplier, and multiply by an approved maximum fee per gas. The recommended
balance is that deployment maximum plus an operator reserve; pool funding is
separate and is not authorized by this package.

On any mismatch, stop before the next transaction. The script rejects an
already-initialized final PoolId before a fresh deployment, validates any
preexisting hook code and immutables before reuse, and initializes only through
the hook-gated authority+price checks after deployment. If the pool is already
initialized, execution is accepted only when the observed starting price equals
the approved manifest value.
A verifier with matching verified bytecode may be reused only under a newly
reviewed manifest. A router whose hook deployment failed is abandoned with its
PoolKey. Any hook address/code/immutable mismatch quarantines the entire tuple.
Repository rollback is a revert of this deployment-package commit; immutable
on-chain contracts have no destructive rollback.

## Approval required for the simulation checkpoint

Provide and approve exactly:

```text
Use deployer <public address> at finalized nonce <nonce>, initialization
authority <public address>, callback proxy <public address> with runtime code
hash <bytes32>, and expected RVM identity <public address>, with approved
verifier/router/hook creation+runtime hashes
<bytes32>/<bytes32>/<bytes32>/<bytes32>/<bytes32>/<bytes32>, and approved initial
sqrt price <uint160>, to mine the Issue 15 AuraHook address and run an unsigned,
non-broadcast Unichain Sepolia fork simulation from <exact commit>.
```

That approval authorizes only read-only RPC access and unsigned simulation. It
does not authorize signing, broadcasting, public verification, pool
initialization, funding, token transfers, or Reactive deployment.
