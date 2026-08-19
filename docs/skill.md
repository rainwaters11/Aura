# Aura Repository Skills and Execution Policy

Status: normative tooling runbook  
Version: 1.4  
Applies to: Codex, RemixAI, Cursor, GitHub agents, and local CLI operators

## 1. Purpose

This document defines the named capabilities an agent may use in the Aura repository, their exact commands, prerequisites, evidence, and permission boundaries. It does not grant broader authority than the user's current request.

Before editing, an agent must read:

1. `AGENTS.md`
2. `BASELINE.md`
3. `docs/design.md`
4. `docs/agent.md` when Reactive or solver code is in scope
5. `docs/security.md`
6. this file
7. the relevant installed dependency source

## 2. Global execution policy

### Allowed without additional approval

- Read repository files and dependency source.
- Create a feature branch when repository access is already authorized.
- Edit only files inside the requested scope.
- Run formatting, compilation, tests, static analysis, local Anvil, simulations, and read-only network calls.
- Prepare commits and a draft pull request when the user asked for publication.

### Requires explicit approval at the time of action

- Broadcasting any transaction to Unichain Sepolia or another public network.
- Deploying or verifying a contract.
- Spending testnet or mainnet assets.
- Changing repository secrets, branch protection, GitHub App permissions, or CI credentials.
- Marking a pull request ready, merging, closing issues, creating a release, or deleting branches.
- Changing locked protocol scope or a normative invariant.

### Prohibited

- Direct work on Argos `main`.
- Committing private keys, API keys, entity secrets, mnemonics, RPC credentials, or wallet recovery material.
- Disabling tests, weakening assertions, or changing protocol rules only to make CI pass.
- Installing duplicate v4 dependency trees without a reviewed dependency decision.
- Copying large external contracts without license review and attribution.
- Deploying from an uncommitted or CI-failing worktree.

## 3. Skill catalog

| Skill identifier | Trigger or command | Purpose | Permission tier |
| --- | --- | --- | --- |
| `foundry-build-test` | `forge build`, `forge test -vvv` | Compile and test the Cancun Solidity system. | Local safe |
| `foundry-narrow-test` | `forge test --match-path ...` | Run the smallest relevant regression gate first. | Local safe |
| `foundry-invariants` | `forge test --match-contract AuraInvariants -vvv` | Verify backing, conservation, replay, and terminal-state properties. | Local safe |
| `hook-miner` | `forge script script/HookMiner.s.sol` or Aura deployment miner | Find a CREATE2 salt for required v4 hook flags. | Local safe until broadcast |
| `batch-solver-sim` | `node scripts/simulate-solver.js` | Reproduce integer clearing math against fixtures. | Local safe |
| `solution-builder-readonly` | `bun run solver:preflight -- --no-publish` | Read finalized complete pool state and verify a production-format residual quote without signing or publishing. | Network read-only |
| `anvil-aura-debug` | `anvil` plus local deployment script | Reproduce complete parking, settlement, claim, and refund flows. | Local safe |
| `remix-desktop-sync` | Open the same Foundry folder in Remix Desktop | Compile, inspect storage, audit, and debug without duplicate files. | Local safe |
| `slither-audit` | `slither .` or RemixAI `/audit` | Static analysis against the exact commit. | Local safe |
| `unichain-readonly-preflight` | RPC and explorer reads only | Confirm chain, code, balances, addresses, and verification parameters. | Network read-only |
| `unichain-broadcast` | `forge script ... --broadcast` | Deploy or execute the live demo. | Approval required |
| `unichain-verify` | `forge verify-contract ...` | Publish source and metadata to Blockscout. | Approval required |
| `github-draft-pr` | branch, commit, push, draft PR | Publish bounded changes for review. | User-requested write |

## 4. `foundry-build-test`

### Configuration

The authoritative Foundry settings are:

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.30"
evm_version = "cancun"
via_ir = false
bytecode_hash = "none"
```

### Commands

```bash
forge fmt --check
forge build --sizes
forge test -vvv
```

### Pass criteria

- Formatting exits 0.
- Build exits 0 with no unexpected contract-size regression.
- Full tests exit 0.
- The agent records exact command, exit result, and test count in the PR description.

Warnings are not silently ignored. Classify each as fixed, accepted with rationale, or separately tracked.

## 5. `foundry-narrow-test`

Run the narrowest affected suite before the full suite:

```bash
forge test --match-path test/AuraParking.t.sol -vvv
forge test --match-path test/AuraSettlement.t.sol -vvv
forge test --match-path test/AuraClaim.t.sol -vvv
forge test --match-path test/AuraSecurity.t.sol -vvv
forge test --match-contract ReactiveBatchDispatcherTest -vvv
```

Choose only the relevant commands first, then run `foundry-build-test` before requesting review.

## 6. `foundry-invariants`

```bash
forge test --match-contract AuraInvariants -vvv
```

Minimum invariant set:

- hook ERC-6909 holdings cover claimable balances plus protocol dust per currency;
- every order leaves `PARKED` at most once;
- each batch settles at most once;
- each solution hash executes at most once;
- a successful unlock leaves zero unresolved deltas;
- timeout never removes a valid claim or permits double refund;
- a one-sided batch always reserves its final slot for the missing direction;
- no admitted order has less than `MIN_ORDER_LIFETIME_SECONDS` remaining and no closed batch contains a deadline shorter than the finality-plus-grace horizon;
- every prospective and frozen two-sided batch has a nonempty feasible price interval;
- no batch emits `BatchClosed` with an individually unencodable canonical payout;
- bounded arrays never exceed `MAX_BATCH_ORDERS`.

If an invariant fails, preserve the seed and counterexample in the issue or PR evidence.

## 7. `hook-miner`

The required permissions are `BEFORE_SWAP_FLAG` and `BEFORE_SWAP_RETURNS_DELTA_FLAG`.

Local mining example:

```bash
forge script script/DeployAura.s.sol:DeployAura --sig "mineOnly()" -vvv
```

If a dedicated script exists:

```bash
forge script script/HookMiner.s.sol:HookMiner -vvv
```

Pass criteria:

- expected CREATE2 address is deterministic;
- low-bit flags match the hook permissions exactly;
- constructor arguments and salt are recorded;
- a Foundry test validates permissions;
- no broadcast flag is present during mining or simulation.

## 8. `batch-solver-sim`

```bash
node scripts/simulate-solver.js --fixtures test/fixtures/solver
```

Requirements:

- use `bigint`, never JavaScript floating point;
- consume integer strings from fixtures;
- preserve the frozen stored order committed by `BatchClosed` and verify its membership hash;
- reject short-horizon deadlines and any incoming order that would make the prospective two-sided feasible interval empty;
- derive the sole canonical rational from the exact midpoint of frozen feasible bounds, treat `BatchClosed.referenceSqrtPriceX96` as telemetry only, reject alternate feasible prices, and output deadline-horizon validation, individual-encoding preflight, payouts, full-width totals, signed-range chunks, matched amounts, residual, and hash inputs;
- compare results with Solidity test vectors;
- exit nonzero on an invalid fixture marked as expected-valid or a mismatch.

The command must not contact a wallet, sign, or broadcast.

## 9. `solution-builder-readonly`

Run only after the production builder exists:

```bash
bun test solver
bun run solver:preflight -- \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC" \
  --no-publish
```

Requirements:

- verify chain ID 1301 and the immutable AuraHook, PoolManager, AuraSolutionInbox, and PoolKey addresses;
- read a finalized block and record only its public number and hash;
- obtain slot0, active liquidity, LP and protocol fees, tick bitmap, and every initialized tick crossed by the candidate through pinned v4 state-view interfaces;
- derive the sole destination-verifiable canonical price from the frozen feasible-interval midpoint, confirm every individual payout passed closure encoding bounds, run integer-identical quote math for only that candidate, and compare it with a forked pinned-v4 execution;
- fail closed when any state field, tick, block hash, or conservation check is missing or changes;
- load no publisher key, send no transaction, and emit no `SolutionProposed` event.

Removing `--no-publish`, loading a publisher credential, or submitting to AuraSolutionInbox is a public-network broadcast and requires explicit approval under `unichain-broadcast`.

## 10. `anvil-aura-debug`

Start a local node:

```bash
anvil
```

In a separate terminal, use the project deployment script without public RPC credentials:

```bash
forge script script/DeployAura.s.sol:DeployAura \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  -vvv
```

The `--broadcast` flag is permitted here only because the target is local Anvil. Confirm the chain ID and RPC endpoint before running.

Required local sequence:

1. Deploy PoolManager test environment, AuraRouter, and mined AuraHook.
2. Initialize the bound pool and seed liquidity.
3. Park one order in each direction.
4. Confirm slot0, tick, and liquidity are unchanged by parking.
5. Settle a batch and inspect the residual.
6. Claim both outputs.
7. Run a separate timeout/refund case.

## 11. `remix-desktop-sync`

Remix Desktop opens the same repository folder. Do not copy Solidity files into a separate Remix workspace.

Checklist:

1. Open Aura as a Foundry project.
2. Confirm package-root remappings match `remappings.txt`.
3. Select Solidity 0.8.30, Cancun, and the Foundry optimizer settings.
4. Compile `src/AuraHook.sol`, `src/AuraRouter.sol`, `src/AuraSolutionInbox.sol`, and `src/ReactiveBatchDispatcher.sol`.
5. Connect the Foundry Provider to local Anvil.
6. Attach to the deployment created by Foundry scripts.
7. Reproduce the smallest failing transaction.
8. Inspect storage, calldata, logs, and PoolManager deltas.
9. Convert confirmed defects into Foundry regression tests.
10. Record findings and the exact commit SHA in `docs/remix-audit.md`.

Remix success does not replace Foundry or CI success.

## 12. `slither-audit`

Preferred local command:

```bash
slither . --filter-paths "lib|test|script"
```

When available, RemixAI's Slither-backed audit may supplement the local run.

Focus areas:

- callback, router, and PoolManager authorization;
- reentrancy and nested unlock state;
- unsafe casts and signed amount handling;
- solution and order replay;
- array length mismatch and duplicate order IDs;
- price arithmetic, rounding, and overflow;
- cross-currency and cross-user accounting;
- trapped-fund, directional-capacity reservation, minimum-lifetime and closure-deadline preflight, nonempty feasible-interval admission, closure-payout preflight, finality-buffer, event-kind-scoped deduplication, authenticated cron routing, callback retry, and timeout paths;
- denial of service within the bounded batch.

Save each finding as fixed, accepted, false positive, or deferred with evidence.

## 13. `unichain-readonly-preflight`

For the live Unichain Sepolia configuration, verify the Circle-issued testnet USDC address is exactly `0x31d0220469e10c4E71834a79b1f276d740d3768F` before pool initialization. Local Foundry suites continue to use mock tokens. Circle or Arc SDK setup is a separate frontend/operator task and is never required for `forge build` or contract tests. Chainalysis credentials or calls are out of scope for the MVP repository.

Read-only preflight is mandatory before requesting broadcast approval.

Confirm:

- RPC reports chain ID 1301;
- configured PoolManager address has code;
- router, solution inbox, public solution-publisher address, callback proxy, expected RVM ID, currencies, fee, tick spacing, state-view addresses, and PoolKey are correct;
- expected hook address has the required flag bits;
- deployer has sufficient test ETH and no unexpected production funds;
- contract verification endpoint is reachable;
- the exact Git commit is clean and CI is green;
- a `solution-builder-readonly` run proves complete finalized state access, frozen-midpoint canonical-price parity, individual-payout encoding safety, and fork-quote parity without loading a publisher credential;
- the deployed minimum order lifetime, finality buffer, post-finality grace, retry delay, retry-attempt cap, feasible-interval admission rule, and Unix-deadline comparisons equal the normative `BASELINE.md` values.

Do not request or print secret values. Report variable names and validation status only.

## 14. `unichain-broadcast`

This skill pauses for explicit approval after a successful read-only preflight.

Approved command pattern:

```bash
forge script script/DeployAura.s.sol:DeployAura \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC" \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url https://unichain-sepolia.blockscout.com/api/ \
  -vvv
```

Safety requirements:

- name the exact script, chain, deployer, expected CREATE2 hook address, and estimated test ETH before approval;
- never reuse a mainnet RPC or chain ID;
- never paste a private key in the command or chat;
- stop on address, chain, constructor, or simulation mismatch;
- record transaction hash, block, deployed addresses, and commit SHA after success.

## 15. `unichain-verify`

Verification may run as part of an approved deployment or as a separate approved action:

```bash
forge verify-contract \
  --chain 1301 \
  --verifier blockscout \
  --verifier-url https://unichain-sepolia.blockscout.com/api/ \
  <DEPLOYED_ADDRESS> \
  <FULLY_QUALIFIED_CONTRACT_NAME>
```

Constructor arguments, compiler version, optimizer settings, source commit, and dependency versions must match deployment exactly.

## 16. `github-draft-pr`

Default publication sequence:

```bash
git status -sb
git diff -- docs/design.md docs/agent.md docs/skill.md
git switch -c agent/aura-three-pillar-architecture
git add docs/design.md docs/agent.md docs/skill.md
git commit -m "docs: define Aura three-pillar architecture"
git push -u origin agent/aura-three-pillar-architecture
```

Open a draft PR against `main`. Never stage unrelated files with `git add -A` in a mixed worktree.

PR evidence must include:

- what changed and why;
- protocol or security impact;
- exact validation commands and results;
- any unresolved ambiguity;
- rollback note;
- confirmation that no deployment occurred.

Do not merge or mark ready without explicit approval.

## 17. Dependency and remapping policy

Use the pinned Argos-compatible graph first:

```text
forge-std               v1.15.0
OpenZeppelin hooks      v1.2.1
hookmate                v0.5.1
reactive-lib            v0.2.0
Solidity                0.8.30
EVM                     cancun
```

Package-root remappings must preserve imports such as `@uniswap/v4-core/src/...`:

```text
forge-std/=lib/forge-std/src/
@uniswap/v4-core/=lib/uniswap-hooks/lib/v4-core/
@uniswap/v4-periphery/=lib/uniswap-hooks/lib/v4-periphery/
v4-core/=lib/uniswap-hooks/lib/v4-core/
v4-periphery/=lib/uniswap-hooks/lib/v4-periphery/
@openzeppelin/uniswap-hooks/=lib/uniswap-hooks/
uniswap-hooks/=lib/uniswap-hooks/
@openzeppelin/contracts/=lib/uniswap-hooks/lib/v4-core/lib/openzeppelin-contracts/contracts/
hookmate/=lib/hookmate/src/
reactive-lib/=lib/reactive-lib/
permit2/=lib/uniswap-hooks/lib/v4-periphery/lib/permit2/
solmate/=lib/uniswap-hooks/lib/v4-core/lib/solmate/
```

Do not append `/src/` when the import itself already contains `/src/`.

## 18. Evidence and handoff format

Every agent handoff reports:

```text
Branch:
Commit:
Scope:
Changed files:
Commands run:
Exact results:
Security impact:
Unresolved risks:
Deployment performed: yes/no
Next approval required:
```

Claims such as "tested," "verified," "deployed," or "settled" require corresponding command output or on-chain evidence. A prepared command is not a completed action.

## 19. Stop conditions

Stop and ask Misty before continuing when:

- repository or branch target is ambiguous;
- GitHub write permission fails;
- the worktree contains overlapping user changes;
- a required secret or public address is missing;
- chain ID or deployed bytecode differs from expectation;
- any invariant must change;
- narrow tests or full CI fail for an unexplained reason;
- a command would broadcast, merge, delete, or change access controls;
- the requested task expands beyond the locked MVP.
