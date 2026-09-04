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
- currencies, fee, tick spacing, initialization authority, callback proxy and
  its runtime code hash, expected RVM ID, the verifier/router/hook
  creation+runtime hashes, solution
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

| Gate | Historical result | Provenance |
| --- | --- | --- |
| `forge fmt --check` | Pass | Local handoff snapshot `5d91ef0`; not CI and not the current PR head |
| `forge build --sizes` | Pass with dependency/test warnings; optimized `AuraHook` runtime 21,716 bytes, margin 2,860 bytes; initcode 23,665 bytes, margin 25,487 bytes | Local handoff snapshot `5d91ef0`; predates the initialization-authority callback guard |
| `forge test -vvv` | 204 tests passed, 0 failed, 8 explicitly skipped Reactive fork tests, 212 total; all 21 deployer tests passed | Historical CI run `#80` at `74768bafe67a73bd8a4a3bb2e650ca182869bb30` |
| Focused and full local reruns | 27 deployer tests passed; 210 full-suite tests passed, 0 failed, 8 intentionally skipped, 218 total | Local handoff snapshot `5d91ef0`; separate from CI run `#80` and not current exact-head evidence |
| Settlement/accounting invariants | Pass as part of the historical full suites | CI run `#80` and local snapshot `5d91ef0`; neither covers the current initialization-authority callback guard |

Compiler/build identity is Solidity 0.8.30, Cancun, optimizer enabled with 200
runs, `via_ir = false`, metadata bytecode hash disabled. Foundry used for the
historical preflight was Forge 1.8.1. Every result above is explicitly
historical; exact-head CI for the initialization-authority callback guard and its deployment tests
remains pending.

Those human-readable build fields are defense in depth, not authoritative proof
of the artifacts used by `forge script`. Before dependency checks or mining, the
typed manifest binds the current `type(...).creationCode` for
`AuraSettlementVerifier`, `AuraRouter`, and `AuraHook`, and separately compares
the verifier's current `type(...).runtimeCode`. Because router and hook runtime
bytecode contains constructor immutables, preflight instead compares their
configured runtime hashes with deployed code during deployment or exact-hook
recovery, then verifies every relevant immutable. Any compiler, optimizer, or
CLI override that changes a bound artifact is rejected.

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
| 3 | `AuraHook` | Unichain Sepolia, CREATE2 | PoolManager, deployed router, currencies, fee, tick spacing, deployed verifier, initialization authority, callback proxy, expected RVM ID, approved initial sqrt price | `(address,address,address,address,uint24,int24,address,address,address,address,uint160)` |

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
4. build AuraHook initcode with the predicted router/verifier addresses plus the
   approved initial sqrt price, then mine the CREATE2 salt;
5. rebuild the router constructor with the mined hook address and assert the
   predicted router address is unchanged (CREATE addresses depend on sender and
   nonce, not initcode);
6. deploy verifier, router, then hook through the canonical CREATE2 deployer;
7. after CREATE2 deployment, verify runtime+immutables and call
   `PoolManager.initialize` from the approved initialization authority at the
   approved `sqrtPriceX96` through the hook-gated `beforeInitialize` path;
8. compare every deployed immutable and runtime code hash.

### Normative production components absent at this commit

`AuraSolutionInbox` on Unichain Sepolia, `ReactiveBatchDispatcher` on Reactive
Network, and the read-only production solution builder are required by the
frozen specification but have no implementation to inventory or deploy. Their
absence prevents a complete production preflight and callback-path gas budget.
They must be implemented and reviewed under their own named issues; they must
not be improvised in Issue 15.

## Hook permission gate

AuraHook requires:

- `BEFORE_INITIALIZE_FLAG = 0x2000`;
- `BEFORE_SWAP_FLAG = 0x0080`;
- `BEFORE_SWAP_RETURNS_DELTA_FLAG = 0x0008`.

Thus `REQUIRED_FLAGS = 0x2088` and `ALL_HOOK_MASK = 0x3fff`. The mandatory
pre-deployment assertion is:

```bash
test "$((PREDICTED_AURA_HOOK & 0x3fff))" -eq "$((0x2088))"
```

The local permission/mined-address test passed. A production address was **not**
mined because its constructor tuple is incomplete. Therefore the production
low-bit confirmation is pending, not passed. After configuration is approved,
record the salt. For the normal vacant-address path, require both:

```text
uint160(predictedHook) & 0x3fff == 0x2088
extcodesize(predictedHook) == 0
```

immediately before broadcast, and keep

```text
AURA_REVIEWED_CREATE2_RECOVERY_TX_HASH=0x0000000000000000000000000000000000000000000000000000000000000000
```

An occupied predicted hook is never accepted based on address occupancy alone.
If the Aura deployer's nonce is still the exact expected post-verifier/router
value (`AURA_DEPLOYER_STARTING_NONCE + 2`), the preflight may reuse the hook only
after its runtime code, address, hook flags, PoolId, approved price, and every
immutable binding match the manifest. This is the verified
permissionless-predeployment case: the recovery hash stays zero because no
Aura-deployer factory transaction exists. If the deployer's nonce has advanced
exactly once beyond that expected value, the separate transaction-evidence
recovery preflight below applies. Any mismatch or other nonce drift is a hard
stop.

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
ordering and the exact USDC address, require the immutable fee `3000`, tick
spacing `60`, and approved initial sqrt price, mine and recheck `0x2088`, and
emit a reviewable deployment plan. Environment integers must be range-checked at
full width before narrowing, including nonzero/width/TickMath bounds for
`AURA_INITIAL_SQRT_PRICE_X96`, and the starting nonce must leave room for both
predicted CREATE deployments.
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

The current Core alone would require four deployment transactions (verifier,
router, CREATE2 hook, then authorized pool initialization). The complete frozen
production system requires additional
inbox and Reactive dispatcher deployments and configuration/funding
transactions, so an exact total cannot be stated at this commit. Liquidity
funding remains a separate transaction and is explicitly excluded from
preflight and deployment approval unless named.

The script rejects an initialized final PoolId before a fresh deployment and
verifies immutable+runtime bindings before reusing a preexisting hook. Pool
initialization is accepted only through hook-gated `beforeInitialize` checks for
authority, PoolKey, PoolId, approved price, and one-time execution.

There are two distinct occupied-hook paths. If a third party submits the exact
permissionless CREATE2 call before the Aura deployer sends its factory
transaction, the deployer nonce remains at the exact expected
post-verifier/router value (`AURA_DEPLOYER_STARTING_NONCE + 2`). The script
accepts that state only after the existing hook passes every code, address,
flag, PoolId, price, and immutable check; the manifest must keep
`AURA_REVIEWED_CREATE2_RECOVERY_TX_HASH` at zero because there is no deployer
factory transaction to review. This is verified exact-hook reuse, not
transaction recovery.

Exactly one additional deployment nonce may exist before initialization in two
audited `--slow` interruption states. First, an observer may submit the identical
permissionless CREATE2 factory call after the router receipt but before the
deployer's factory transaction, causing the deployer's transaction to revert.
Second, the deployer's own factory transaction may succeed before broadcasting
is interrupted and before the initialization transaction is sent. A fresh
script run accepts either state only when the verifier, router, and hook already
exist, the hook has passed the approved runtime, address, flag, PoolId, and
immutable checks, and the typed manifest contains the exact factory transaction
hash in `AURA_REVIEWED_CREATE2_RECOVERY_TX_HASH`.

Before accepting recovery, the script uses `cast rpc` through Foundry FFI and
the repository's `unichain_sepolia` alias to retrieve the public transaction and
receipt from chain 1301. It requires the configured transaction hash, matching
mined block identity, canonical receipt status `0` or `1`, approved deployer,
nonce starting plus two, approved CREATE2 factory, and exact approved salt
concatenated with the approved hook initcode. Status `0` proves the deployer's
copied factory call failed after the identical hook was deployed; status `1`
proves the deployer's factory call deployed that hook successfully. In both
cases, the executable transaction binding proves the nonce was consumed by the
approved factory call rather than unrelated wallet activity; operator review is
additional evidence only. The recovery run then records only the
authority-gated initialization transaction. Missing/stale evidence, RPC or JSON
failure, any transaction/receipt field mismatch, a noncanonical receipt status,
mismatched hook code, or additional nonce drift remains a hard stop. A
normal/fresh run must keep the recovery hash zero so stale recovery approval
cannot be reused.

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
4. if the exact approved hook was permissionlessly predeployed before the Aura
   deployer sent its factory transaction, rerun the read-only preflight;
   continue only when every hook binding validates, the deployer nonce remains
   at the expected post-verifier/router value (`starting + 2`), and the recovery
   hash remains zero;
5. if the router succeeds and the deployer factory nonce is consumed but
   initialization is not confirmed, rerun the read-only preflight; continue
   only when the exact approved hook exists, the nonce is exactly one above the
   verifier/router deployment nonce, and the manifest names the factory
   transaction that the script retrieves and validates against the approved
   chain, sender, nonce, target, canonical failed-or-successful status, mined
   block, salt, and hook initcode;
6. if no exact hook exists, the nonce differs by any other amount, or any
   immutable/code/flag check fails, quarantine every
   address and prepare a new reviewed manifest and salt;
7. revert repository changes to this base commit for the code rollback. Never
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
Do not fund the pool with liquidity.
```

Any approval lacking one of those fields, or naming a different commit/address,
does not authorize signing or broadcast.
