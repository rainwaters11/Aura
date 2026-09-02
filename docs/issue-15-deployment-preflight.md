# Issue 15: narrowed Aura Core deployment preflight

Date: 2026-08-30 (UTC)

Target: Unichain Sepolia (`chainId = 1301`)

Base commit: `609fab601316b9804e6821bab1cbddd1ca9bac14`

Branch: `codex/issue-15-aura-core-deployer`

## Decision

**STOP — NOT APPROVED FOR BROADCAST.** No transaction was signed, broadcast, or
simulated with a signing key, no pool was initialized, and no funds were spent.
The local Core is test-clean and below the EIP-170/EIP-3860 size limits, but a
production deployment cannot yet be reproduced safely because the required
public configuration and deployment tooling are incomplete.

In particular:

- no `UNICHAIN_SEPOLIA_RPC` or deployer configuration was present in the
  preflight environment, so the configured endpoint, deployer address, balance,
  nonce, and required wallet balance could not be validated;
- currencies, fee, tick spacing, callback proxy and its runtime code hash,
  expected RVM ID, the verifier/router/hook creation-code hashes, solution
  publisher, and state-view addresses have not been committed as an approved
  deployment manifest;
- the Aura Core deployment package exists on this branch, but its approved
  production manifest and chain-1301 contract simulation remain incomplete;
- the normative `AuraSolutionInbox` and `ReactiveBatchDispatcher` contracts and
  the production solution builder are not implemented in this commit;
- consequently there is no final Aura constructor tuple, CREATE2 salt, predicted
  hook address, complete finalized-state read, gas estimate, or verification
  argument set to approve.

These are stop conditions rather than values that may be guessed during a
financial deployment.

## Repository and build evidence

The worktree was empty before branching. `origin/main` was fetched immediately
before the branch was created; both `origin/main` and `HEAD` resolved to the base
commit above.

| Gate | Result |
| --- | --- |
| `forge fmt --check` | Pass |
| `forge build --sizes` | Pass with dependency/test warnings; optimized `AuraHook` runtime 21,716 bytes, margin 2,860 bytes; initcode 23,665 bytes, margin 25,487 bytes |
| `forge test -vvv` | Exact-head CI `#80` passed: 204 tests passed, 0 failed, 8 explicitly skipped Reactive fork tests, 212 total; all 21 deployer tests passed |
| Settlement/accounting invariants | Pass as part of the full suite |

Compiler/build identity is Solidity 0.8.30, Cancun, optimizer enabled with 200
runs, `via_ir = false`, metadata bytecode hash disabled. Foundry used for this
preflight was Forge 1.8.1.

Those human-readable build fields are defense in depth, not authoritative proof
of the artifacts used by `forge script`. The typed manifest separately requires
approved creation-code hashes for `AuraSettlementVerifier`, `AuraRouter`, and
`AuraHook`. Preflight compares them to the current `type(...).creationCode`
hashes before dependency checks, address prediction, salt mining, simulation, or
broadcast. Any compiler, optimizer, or CLI override that changes a deployable
artifact is rejected.

## Read-only network evidence

Because the required environment variable was absent, the repository's named
RPC configuration could not be exercised. As a non-authoritative connectivity
check only, `https://sepolia.unichain.org` returned chain ID 1301. It returned
24,009 bytes of code at the repository's candidate PoolManager
`0x00B036B58a818B1BC34d502D3fE730Db729e62AC` and 1,798 bytes at the normative
Circle testnet USDC `0x31d0220469e10c4E71834a79b1f276d740d3768F`.

The configured Blockscout API URL was reachable and returned HTTP 400 for a bare
request, which establishes reachability but **not** successful source
verification. `foundry.toml` declares Blockscout, chain 1301, and the correct API
base URL. The optional `BLOCKSCOUT_API_KEY` variable was absent; no secret value
was requested or printed.

## Deployable inventory and dependencies

### Existing narrowed Core

| Order | Contract | Network | Constructor dependencies | Verification constructor ABI |
| --- | --- | --- | --- | --- |
| 1 | `AuraSettlementVerifier` | Unichain Sepolia | None | `0x` |
| 2 | `AuraRouter` | Unichain Sepolia | canonical PoolManager; immutable PoolKey containing the **predicted** AuraHook, sorted currencies, fee, and tick spacing | `(address,(address,address,uint24,int24,address))` |
| 3 | `AuraHook` | Unichain Sepolia, CREATE2 | PoolManager, deployed router, currencies, fee, tick spacing, deployed verifier, callback proxy, expected RVM ID | `(address,address,address,address,uint24,int24,address,address,address)` |

`AuraClearingMath` is internally linked into creation bytecode and is not a
separate deployment. The canonical PoolManager, currencies, callback proxy, and
RVM identity are dependencies, not Aura-owned deployments.

The router/hook cycle is resolved deterministically, not by placeholder state.
Before that work begins, preflight requires deployed code at the approved
callback proxy and an exact match to its separately approved runtime code hash;
EOAs, mistyped addresses, missing deployments, and bytecode drift are rejected.

The address cycle is resolved as follows:

1. read and freeze the deployer nonce at the finalized preflight block;
2. calculate the verifier CREATE address and router CREATE address from that
   nonce and the exact transaction order;
3. build the router PoolKey with a candidate hook address;
4. build AuraHook initcode with the predicted router and verifier addresses and
   mine the CREATE2 salt;
5. rebuild the router constructor with the mined hook address and assert the
   predicted router address is unchanged (CREATE addresses depend on sender and
   nonce, not initcode);
6. deploy verifier, router, then hook through the canonical CREATE2 deployer;
7. compare every deployed immutable and runtime code hash before considering
   pool initialization.

### Normative production components absent at this commit

`AuraSolutionInbox` on Unichain Sepolia, `ReactiveBatchDispatcher` on Reactive
Network, and the read-only production solution builder are required by the
frozen specification but have no implementation to inventory or deploy. Their
absence prevents a complete production preflight and callback-path gas budget.
They must be implemented and reviewed under their own named issues; they must
not be improvised in Issue 15.

## Hook permission gate

OpenZeppelin `BaseAsyncSwap` requires only:

- `BEFORE_SWAP_FLAG = 0x0080`;
- `BEFORE_SWAP_RETURNS_DELTA_FLAG = 0x0008`.

Thus `REQUIRED_FLAGS = 0x0088` and `ALL_HOOK_MASK = 0x3fff`. The mandatory
pre-deployment assertion is:

```bash
test "$((PREDICTED_AURA_HOOK & 0x3fff))" -eq "$((0x0088))"
```

The local permission/mined-address test passed. A production address was **not**
mined because its constructor tuple is incomplete. Therefore the production
low-bit confirmation is pending, not passed. After configuration is approved,
record the salt and require both:

```text
uint160(predictedHook) & 0x3fff == 0x0088
extcodesize(predictedHook) == 0
```

immediately before broadcast. Any mismatch or occupied address aborts the run.

## Deterministic command templates (do not run without approval)

All values below are public addresses or configuration names. A key must be
provided through a wallet/keystore integration and must never appear in shell
history, command arguments, logs, or this repository.

### Second read-only preflight

```bash
test "$(cast chain-id --rpc-url "$UNICHAIN_SEPOLIA_RPC")" = 1301
cast code "$AURA_POOL_MANAGER" --rpc-url "$UNICHAIN_SEPOLIA_RPC" | test "$(cat)" != 0x
cast balance "$AURA_DEPLOYER" --rpc-url "$UNICHAIN_SEPOLIA_RPC"
cast nonce "$AURA_DEPLOYER" --block finalized --rpc-url "$UNICHAIN_SEPOLIA_RPC"
forge fmt --check
forge build --sizes
forge test -vv
forge script script/DeployAura.s.sol:DeployAura \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC" -vvvv
```

The `DeployAura` dry run must reject any chain other than 1301, print only
public configuration, assert code at all external dependencies, assert currency
ordering and the exact USDC address, require the immutable fee `3000` and tick
spacing `60`, mine and recheck `0x0088`, and emit a reviewable deployment plan.
Environment integers must be range-checked at full width before narrowing, and
the starting nonce must leave room for both predicted CREATE deployments.
Omitting `--broadcast` is mandatory. The dry run is not deployment approval and
does not replace the production solution-builder preflight below.

### Mandatory production solution-builder safety preflight

Deployment approval is impossible until the future production solution builder
is implemented and completes the repository-mandated read-only safety preflight.
The builder remains deferred and unimplemented at this exact head, and the
repository does not currently provide a `solver:preflight` command. Both are
explicit blockers; no solver output or passing result is claimed here.

Against the exact proposed deployment commit and approved chain-1301
configuration, this gate must prove:

- finalized-state access for all state required to quote the bounded residual;
- canonical clearing-price parity with the destination contracts;
- every individual payout is safe for the solution encoding and signed
  PoolManager operation bounds;
- the residual direction and amount are correct for the frozen canonical vector;
- quote parity with execution on a fork of the same pinned chain state; and
- no transaction is published and no public or fork state is mutated by the
  preflight workflow.

Once the production builder and its package scripts actually exist, the required
repository command sequence is:

```text
bun test solver
bun run solver:preflight -- <approved chain-1301 configuration> --no-publish
```

`<approved chain-1301 configuration>` is intentionally a placeholder for the
arguments supported by that future repository script. This document does not
invent concrete flags. `--no-publish` is mandatory: removing it, loading a
publisher credential, or publishing a proposal is outside read-only preflight
and requires separate approval. Successful Foundry tests and contract simulation
alone are insufficient for deployment approval.

Rerun both builder commands after every relevant contract, ABI, deployment
manifest, canonical-pricing, or payout change. Evidence from a different commit
or configuration cannot approve the proposed deployment.

### Approved deployment

Broadcast approval may be considered only after every item below exists for the
same exact head and approved manifest:

1. production deployment tooling is complete;
2. the chain-1301 contract simulation is complete;
3. the production solution builder is implemented;
4. `bun test solver` passes;
5. chain-1301 `solver:preflight` passes with mandatory `--no-publish`;
6. exact-head Remix compilation evidence is recorded;
7. exact-head Slither evidence is recorded with findings dispositioned;
8. full Foundry verification and the optimized contract-size gate pass;
9. CI is green;
10. an exact-head Codex review is clean; and
11. Misty approves the exact manifest and transaction list.

None of the builder, Remix, Slither, CI, or clean exact-head review evidence is
available in this preflight, so the gate remains closed. After all items pass,
Misty's approval must additionally name the commit, chain, deployer, expected
hook, exact transaction list, and maximum test ETH spend:

```bash
forge script script/DeployAura.s.sol:DeployAura \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC" \
  --broadcast --verify --slow \
  --verifier blockscout \
  --verifier-url https://unichain-sepolia.blockscout.com/api/ \
  -vvvv
```

If verification is separated from deployment, reproduce the exact build profile
and use constructor arguments generated by `cast abi-encode`, for example:

```bash
forge verify-contract --chain 1301 --compiler-version 0.8.30 \
  --num-of-optimizations 200 --verifier blockscout \
  --verifier-url https://unichain-sepolia.blockscout.com/api/ \
  --constructor-args "$CONSTRUCTOR_ARGS" \
  "$DEPLOYED_ADDRESS" src/AuraHook.sol:AuraHook
```

Repeat with `src/AuraRouter.sol:AuraRouter` and
`src/AuraSettlementVerifier.sol:AuraSettlementVerifier`; the verifier has no
constructor arguments.

## Wallet balance, transactions, rollback, and recovery

The required wallet balance is **not yet known** and must not be guessed. It is:

```text
maximum deployment gas from the successful 1301 dry run
× an approved max fee per gas
+ explicitly approved pool-initialization/liquidity budget
+ a separately approved callback-funding budget
+ an operator reserve
```

The current Core alone would require three deployment transactions (verifier,
router, CREATE2 hook). The complete frozen production system requires additional
inbox and Reactive dispatcher deployments and configuration/funding
transactions, so an exact total cannot be stated at this commit. Pool
initialization and liquidity are separate transactions and explicitly excluded
from preflight and deployment approval unless named.

The script rejects an initialized final PoolId during preflight. AuraHook also
reads that PoolId's PoolManager `slot0` in its constructor and rejects a nonzero
`sqrtPriceX96`, making the decisive guard atomic with CREATE2 hook deployment if
pool state changes after simulation but before broadcast.

Immediately before any separately approved future pool-initialization
transaction, read the final PoolId's PoolManager `slot0` again and stop if its
`sqrtPriceX96` is nonzero. Local tests alone never constitute deployment
approval; new exact-head CI must pass as part of the approval evidence.

There is no on-chain rollback for immutable deployments. Failure recovery is:

1. stop after the first failed or mismatched receipt; do not continue the
   sequence and do not initialize a pool;
2. preserve receipts, nonce, salt, bytecode hashes, and public logs;
3. if verifier deployment alone succeeds, it is harmless and reusable only if
   its verified runtime hash matches;
4. if the router succeeds but the hook fails, abandon that PoolKey/router pair;
   never point production users at it;
5. if the hook deploys but any immutable/code/flag check fails, quarantine every
   address and prepare a new reviewed manifest and salt;
6. revert repository changes to this base commit for the code rollback. Never
   attempt destructive on-chain recovery or send funds to an unvalidated
   address.

## Remaining risks and exact next approval

Remaining blockers include the production solution builder and its absent
`solver:preflight` command, passing builder tests, chain-1301 contract and builder
simulations, the final approved manifest and CREATE2 result, wallet/nonce/balance
and gas evidence, exact-head Remix and Slither evidence, green CI, a clean
exact-head Codex review, and Misty's approval of the exact manifest and
transaction list. No unavailable artifact is treated as passed. The eight
skipped fork tests also mean this run is not evidence for a live callback
deployment.

**No broadcast approval should be granted now.** Implement and review the
production builder under its separately scoped work, then rerun all gates above
from the exact proposed deployment head. Only after every mandatory artifact is
available may Misty provide the explicit written approval in the following form:

```text
Approve DeployAura from <commit> to Unichain Sepolia chain 1301,
using deployer <public address>, expected AuraHook <public address>,
for <exact transaction count> transactions and at most <exact test ETH>.
Do not initialize or fund the pool.
```

Any approval lacking one of those fields, or naming a different commit/address,
does not authorize signing or broadcast.
