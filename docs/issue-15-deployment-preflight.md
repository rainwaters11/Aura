# Issue 15: narrowed Aura Core deployment preflight

Date: 2026-08-30 (UTC)

Target: Unichain Sepolia (`chainId = 1301`)

Base commit: `609fab601316b9804e6821bab1cbddd1ca9bac14`

Branch: `codex/issue-15-deployment-preflight`

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
- currencies, fee, tick spacing, callback proxy, expected RVM ID, solution
  publisher, and state-view addresses have not been committed as an approved
  deployment manifest;
- there is no Aura Core deployment script. The existing Unichain script deploys
  the retired `ArgosLTSHook`, starts a broadcast internally, and is not suitable
  for Aura;
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
| `forge test -vv` | Pass: 182 passed, 0 failed, 8 explicitly skipped fork tests, 190 total |
| Settlement/accounting invariants | Pass as part of the full suite |

Compiler/build identity is Solidity 0.8.30, Cancun, optimizer enabled with 200
runs, `via_ir = false`, metadata bytecode hash disabled. Foundry used for this
preflight was Forge 1.8.1.

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

The router/hook cycle is resolved deterministically, not by placeholder state:

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
cast code "$POOL_MANAGER" --rpc-url "$UNICHAIN_SEPOLIA_RPC" | test "$(cat)" != 0x
cast balance "$DEPLOYER" --rpc-url "$UNICHAIN_SEPOLIA_RPC"
cast nonce "$DEPLOYER" --block finalized --rpc-url "$UNICHAIN_SEPOLIA_RPC"
forge fmt --check
forge build --sizes
forge test -vv
forge script script/DeployAura.s.sol:DeployAura \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC" -vvvv
```

The future `DeployAura` dry run must reject any chain other than 1301, perform no
internal `startBroadcast`, print only public configuration, assert code at all
external dependencies, assert currency ordering and the exact USDC address,
mine and recheck `0x0088`, and emit a machine-readable deployment plan. Merely
omitting `--broadcast` is not sufficient if a script calls `startBroadcast`.

### Approved deployment

Only after a clean dry run and an explicit approval naming commit, chain,
deployer, expected hook, transaction count, and maximum test ETH spend:

```bash
forge script script/DeployAura.s.sol:DeployAura \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC" \
  --broadcast --verify \
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

Remaining blockers are the missing production components, deployment manifest,
Aura deployment script/tests, final CREATE2 result, finalized-state builder
parity, wallet/nonce/balance check, gas estimate, and successful Blockscout
verification rehearsal. The eight skipped fork tests also mean this run is not
evidence for a live callback deployment.

**No broadcast approval should be granted now.** The next approval needed is to
open separately scoped implementation work for the missing production components
and Aura deployment tooling/configuration. After those changes merge, rerun this
preflight from that exact clean `main` commit. Only then may the operator provide
an explicit written approval in the following form:

```text
Approve DeployAura from <commit> to Unichain Sepolia chain 1301,
using deployer <public address>, expected AuraHook <public address>,
for <exact transaction count> transactions and at most <exact test ETH>.
Do not initialize or fund the pool.
```

Any approval lacking one of those fields, or naming a different commit/address,
does not authorize signing or broadcast.
