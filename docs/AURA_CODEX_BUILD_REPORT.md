# Aura Codex Master Build Report v2.3

Prepared for Misty Waters on August 18, 2026.

Version 2.3 establishes the Three-Pillar Markdown Architecture and locks the external-integration boundary. Circle-issued testnet USDC is the preferred live-demo asset on Unichain Sepolia. Circle and Arc SDKs may support optional funding or bridging UX, but they do not enter Aura's settlement-critical contracts. Chainalysis is a post-MVP monitoring and compliance integration, not an on-chain order gate. Remix Desktop remains a shared-filesystem verification layer, while Foundry and GitHub Actions are the authoritative build gates.

## Three-Pillar architecture

Aura agents must read three normative documents before implementation:

1. `docs/design.md` defines on-chain lifecycle, schemas, rational price math, state transitions, PoolManager conservation, claims, refunds, and security invariants.
2. `docs/agent.md` defines canonical event topics, bounded batch ingestion, deterministic solution construction, RVM callback formatting, retry policy, and failure handling.
3. `docs/skill.md` defines allowed commands, validation evidence, deployment approval gates, GitHub publication rules, and stop conditions.

The precedence order is `design.md`, then `agent.md`, then `skill.md`, then implementation comments. Protocol changes require a dedicated documentation and test change. Agents must stop instead of guessing when the documents do not resolve an ambiguity.

Aura retains the Argos repository-root Foundry layout. The contracts remain under `src/`, `test/`, and `script/`. Introducing a nested `contracts/` directory would require an unnecessary build-path migration and is not part of the Aura baseline.

## Executive decision

Build Aura as a new repository seeded from `rainwaters11/Argos_LTS`, not as a rewrite on Argos' `main` branch.

Recommended repository: `rainwaters11/Aura`

Recommended baseline: Argos commit `4603269e8af7dbbff6e337546fd9d7be27deb34c`

Recommended first branch: `codex/aura-foundation`

Aura should reuse Argos' tested ERC-6909 custody and redemption pattern, Foundry configuration, hook-address mining, Unichain deployment scripts, and `BaseTest` utilities. It should replace Argos' toxic-address logic, old React/Vite frontend, and Reactive sensor with a focused, single-pool batch-auction system.

The MVP is one exact-input Uniswap v4 pool, one bounded batch, two-sided CoW matching, one residual AMM swap, one Reactive callback, and user claims. Multi-pool settlement, partial fills, multi-hop routing, solver competition, and generalized order types are post-hackathon work.

## VS Code, Codex, Foundry, and Remix Desktop workflow

Aura uses one local Git repository opened by two development surfaces:

- VS Code with Codex owns architecture-compliant edits, Foundry tests, scripts, Git operations, and pull-request preparation.
- Remix Desktop opens the same repository folder for independent compilation feedback, static analysis, transaction inspection, storage inspection, and visual debugging.
- Foundry is the source of truth for compilation, formatting, tests, fuzzing, invariants, gas reports, and CI.
- Remix is a verification aid. A successful Remix compilation or audit never replaces a green Foundry suite.

### Compiler consistency

Use Solidity 0.8.30 and Cancun EVM in both Foundry and Remix Desktop. OpenZeppelin `BaseAsyncSwap` has pragma `^0.8.26`, so it remains compatible with the pinned 0.8.30 project compiler. Do not compile the same commit with 0.8.26 in Remix and 0.8.30 in CI because optimizer and code-generation differences weaken reproducibility.

### Foundry project loading in Remix Desktop

1. Open the Aura repository folder directly in Remix Desktop.
2. Load it as a Foundry project.
3. Verify the generated Remix compiler configuration contains the project's exact remappings. Add missing remappings to that compiler configuration rather than changing correct Foundry imports.
4. Select Solidity 0.8.30, Cancun, and the same optimizer settings recorded in `foundry.toml`.
5. Compile `src/AuraHook.sol`, `src/AuraRouter.sol`, and their dependency graph.
6. Record any discrepancy between Remix and `forge build` in `docs/remix-audit.md` before changing source code.

### Local transaction debugging

1. Start Anvil from the repository using the same chain setup used by Foundry tests.
2. In Remix Deploy and Run, select Foundry Provider and connect to the Anvil JSON-RPC endpoint.
3. Deploy through the project scripts where possible, then attach Remix to the deployed addresses.
4. Reproduce the smallest failing parking, settlement, refund, or claim transaction.
5. Use the Remix Debugger and Storage Inspector to examine PoolManager deltas, batch status, order status, ERC-6909 custody, and claimable balances.
6. Convert every confirmed failure into a Foundry regression test before implementing the fix.

### Static analysis and audit evidence

- Run `forge fmt --check`, `forge build --sizes`, and the narrow Foundry tests first.
- Run Slither from the local toolchain or through RemixAI's Slither-backed `/audit` flow when available.
- Run Remix Contract Auditor or static analysis checks against `AuraHook`, `AuraRouter`, and the clearing library.
- Focus review on authorization, forged hook data, replayed batch solutions, cross-order accounting, reentrancy around unlock callbacks, unsafe casts, rounding, denial of service from bounded arrays, and trapped-fund paths.
- Save findings, false positives, dispositions, and the audited commit SHA in `docs/remix-audit.md`.

### Public-network safety

- Use Foundry Provider for local Anvil testing.
- Use a wallet-backed Injected Provider or an explicitly configured public-network provider for Unichain Sepolia only after the local gates pass.
- Confirm chain ID, PoolManager address, hook address flags, selected account, and test-token balances before signing.
- Never paste private keys into Remix, source files, shell history, screenshots, or the build report.
- Perform a read-only preflight before any broadcast and require Misty's explicit approval for deployment.

## Repository audit

The current Argos repository provides a strong technical base, but it is not ready to use unchanged.

### Reuse

- `src/ArgosLTSHook.sol`: ERC-6909 mint, burn, take, and CEI redemption flow.
- `test/utils/BaseTest.sol`: pool manager, routers, currencies, liquidity setup, and hook test scaffolding.
- `test/ERC6909Parking.t.sol`: accumulation, currency separation, and over-redemption test patterns.
- `script/Deploy.s.sol` and `script/DeployUnichain.s.sol`: CREATE2 flag mining and Unichain Sepolia deployment patterns.
- `foundry.toml`: Cancun EVM target, Solidity configuration, RPC aliases, and Blockscout verification.
- `lib/uniswap-hooks` at v1.2.1 and `lib/reactive-lib` at v0.2.0.

### Replace or repair

- `.github/workflows/ci.yml` uses `working-directory: ./Argos_LTS` even though the GitHub repository root is already `Argos_LTS`. This is the likely cause of the repeated Forge CI failures. Confirm through Actions logs when the Aura checkout exists, then remove the incorrect working directory.
- `AGENTS.md` mandates `docs/V4_SECURITY_SKILL.md`, but that file is missing. Aura must add a real security checklist or remove the broken reference before Codex starts implementation.
- Argos records the hook `sender`, which is typically the router, as the user. Aura needs a dedicated router that constructs authenticated hook data from `msg.sender`.
- The old Vite frontend should not be mixed with the requested Scaffold-ETH 2 frontend.
- Legacy Argos contracts and tests should remain in Git history and be removed from Aura's active `src/` and `test/` trees to avoid stale code, confusing coverage, and accidental deployment.

## Corrections to the original master report

| Original directive | Corrected directive |
| --- | --- |
| Install top-level `v4-core`, `v4-periphery`, `uniswap-hooks`, and OpenZeppelin Contracts independently. | Follow the official v4-template dependency graph. Pin `OpenZeppelin/uniswap-hooks` once and use its recursive submodules for v4-core, v4-periphery, and OpenZeppelin Contracts. This avoids duplicate Solidity source identities and remapping conflicts. |
| Inherit directly from `BaseHook` and reproduce async parking manually. | Prefer `BaseAsyncSwap`, which inherits `BaseHook` and already implements the audited exact-input ERC-6909 parking behavior. Override `_beforeSwap`, validate Aura order metadata, call `super._beforeSwap`, and then record the order. |
| Treat hook `sender` as the user. | Treat hook `sender` as a router. Accept orders only from `AuraRouter`, which writes the real owner and recipient into hook data from its own `msg.sender`. Reject arbitrary routers and spoofed hook data. |
| `blockBatches[block.number]` is the primary order store. | Store orders by `orderId` and index order IDs by bounded `batchId`. Do not expose or iterate an unbounded dynamic struct array in settlement paths. |
| `settleBatch(PoolKey, netImbalance, users, payouts)` is enough. | Use a typed `BatchSolution` containing batch ID, order IDs, clearing price, payouts, residual direction and amount, price limit, deadline, and solution hash. Validate every order and all conservation rules on-chain. |
| Solver authorization alone protects settlement. | The Reactive callback is authorized, but its solution remains untrusted. Aura validates batch status, order ownership, token direction, expiry, min-out, uniform price, totals, residual swap bounds, and replay protection. |
| CoW's settlement contract calculates the uniform clearing price. | CoW solvers compute prices off-chain or in solver logic. `GPv2Settlement` validates and executes solver-supplied prices. Aura should implement a small, transparent two-token clearing library and not port the full settlement contract. |
| `ReactiveCoWSolver` is an off-chain agent contract. | A Reactive Contract runs in ReactVM and dispatches authenticated callbacks. Name it `ReactiveBatchDispatcher`. For this MVP it aggregates a bounded number of event records and computes a deterministic two-token solution. |
| Copy the stop-order demo. | Adapt only the subscription, `react(LogRecord)`, callback payload, callback-proxy authorization, and RVM-ID pattern. The current demo includes correctness TODOs and should not be copied wholesale. |
| Watch events with raw Wagmi only. | In Scaffold-ETH 2, use `useScaffoldWatchContractEvent`, `useScaffoldEventHistory`, `useScaffoldReadContract`, and `useScaffoldWriteContract` where possible. |
| Compile with Solidity 0.8.26 in Remix while Foundry uses 0.8.30. | Pin Solidity 0.8.30 and Cancun in both environments so visual debugging corresponds to CI bytecode and compiler behavior. |
| Trust any address decoded from `hookData`. | Require `sender == AuraRouter` and make AuraRouter construct owner data from `msg.sender`. Decoding alone does not authenticate the wallet. |
| Refund by `blockNumber` and array index. | Refund by immutable `orderId`, verify ownership and status, update state before unlocking, and reject double refunds. |
| Use `v4-core/=lib/v4-core/src/` style remappings. | Map the import prefix to the package root. Appending `/src/` to a prefix already used as `v4-core/src/...` creates an invalid `src/src` path. |

## Locked MVP scope

### In scope

- Unichain Sepolia.
- One AuraHook deployment bound to one PoolKey.
- Exact-input, full-fill orders only.
- A dedicated `AuraRouter` as the only order-entry router.
- Two-sided orders for one token pair.
- A bounded batch of no more than 8 orders for tests and no more than 4 orders in the live demo.
- One uniform directed clearing price per batch.
- Direct Coincidence of Wants matching.
- One residual exact-input swap against the real Uniswap v4 pool curve.
- ERC-6909 custody for parked inputs and settled output claims.
- User-controlled `claimTokens` withdrawal.
- Reactive Network event subscription and authenticated callback.
- A live dashboard showing parked orders, batch totals, settlement status, residual curve use, and claimable output.

### Deferred

- Multiple pools per hook.
- Partial fills.
- Exact-output orders.
- Multi-hop routing.
- General CoW solver competition.
- Arbitrary solver interactions.
- Gas sponsorship.
- Production-grade economic optimization.
- Mainnet deployment.

## External integration boundary

### Circle and Arc

- Use Circle's official Unichain Sepolia USDC contract, `0x31d0220469e10c4E71834a79b1f276d740d3768F`, for the public testnet pool and demo.
- Continue to use deterministic local mock tokens in Foundry unit, fuzz, and invariant tests.
- Treat Circle App Kit, Bridge Kit, Wallets, Gateway, CCTP, and Paymaster features as optional frontend or operator tooling. They must not be imported into `AuraHook`, `AuraRouter`, `AuraClearingMath`, or settlement validation.
- Do not add a bridge flow unless the core park, settle, refund, and claim path is already green. A bridge failure must not strand an Aura order or claim.
- Keep Circle API keys, entity secrets, wallet secrets, and private keys outside the repository and browser bundle.

### Chainalysis

- Do not perform synchronous Chainalysis screening inside `_beforeSwap`, settlement, claims, or refunds. This would add availability, privacy, centralization, and denial-of-service risk to the protocol's safety path.
- Defer KYT, Address Screening, and Hexagate-style monitoring to a separate post-MVP adapter or operator dashboard.
- If later enabled, screening results are advisory or policy inputs at the router/operator boundary. They cannot weaken sovereign refunds or make already parked funds permanently unclaimable.

## Target architecture

### `src/AuraHook.sol`

Inherit from `BaseAsyncSwap` and `IUnlockCallback`.

Responsibilities:

- Require `sender == address(auraRouter)` for parked Aura orders.
- Decode versioned `AuraOrderData` from `hookData`.
- Validate owner, recipient, deadline, nonce, amount, direction, pool binding, and minimum output.
- Call `super._beforeSwap(...)` to perform exact-input parking and mint input ERC-6909 claims to the hook.
- Create `orderId = keccak256(owner, nonce, poolId, amountIn, direction, minAmountOut, deadline)`.
- Store a bounded `Order` record and append its ID to the active batch.
- Emit `OrderParked(batchId, orderId, owner, recipient, tokenIn, tokenOut, amountIn, minAmountOut)`.
- Mark the batch `READY` and emit `BatchReady` when the demo threshold of two orders is reached.
- Allow permissionless timeout closure after `MAX_WAIT_BLOCKS` so an unmatched order cannot remain open forever.
- Accept only authenticated Reactive settlement callbacks.
- Validate and execute `BatchSolution`.
- Update pool-scoped claimable balances.
- Allow users to claim output tokens through a burn plus take unlock cycle.
- Allow the owner to cancel and recover an expired, unsettled order through the same burn plus take accounting pattern.

Recommended order state:

```solidity
enum OrderStatus { NONE, PARKED, SETTLED, CANCELLED, CLAIMED }

struct Order {
    address owner;
    address recipient;
    uint64 batchId;
    uint64 deadline;
    uint64 nonce;
    bool zeroForOne;
    uint128 amountIn;
    uint128 minAmountOut;
    OrderStatus status;
}
```

Recommended settlement state:

```solidity
enum BatchStatus { OPEN, READY, SETTLING, SETTLED, FAILED }

struct BatchSolution {
    uint64 batchId;
    uint64 deadline;
    uint128 priceNumerator;
    uint128 priceDenominator;
    bool residualZeroForOne;
    uint128 residualAmountIn;
    uint160 sqrtPriceLimitX96;
    bytes32 solutionHash;
    bytes32[] orderIds;
    uint128[] payouts;
}
```

Use `mapping(bytes32 => Order) orders`, `mapping(uint64 => bytes32[]) batchOrderIds`, and `mapping(uint64 => BatchStatus) batchStatus`. Enforce a hard maximum order count before pushing.

Batch formation for the hackathon demo is intentionally deterministic:

- The first order opens the next sequential batch and records `openedAtBlock`.
- The second order marks the batch ready and emits `BatchReady`.
- If the second order never arrives, anyone may call `closeTimedOutBatch` after `MAX_WAIT_BLOCKS`.
- A timed-out one-sided batch is refundable, not solver-settled.
- General time-based or variable-size auctions are deferred until after the demo.

### `src/AuraRouter.sol`

This component is mandatory.

Responsibilities:

- Expose one user function for exact-input Aura orders.
- Build `AuraOrderData` internally using `msg.sender` as owner.
- Increment a user nonce.
- Route the swap through the v4 PoolManager or a tested v4 router path.
- Prevent callers from supplying a different owner.
- Surface order ID and transaction state to the frontend.

AuraHook must reject order-shaped hook data from any other router.

### `src/libraries/AuraClearingMath.sol`

Implement only the two-token math needed for the demo.

Responsibilities:

- Compute payouts using a rational price numerator and denominator.
- Use full-precision multiplication and division.
- Apply one documented rounding direction.
- Enforce the same directed price for all orders of the same direction.
- Compute matched token amounts and residual input.
- Reject zero price components, overflow, underflow, and payouts below user minimums.
- Return totals that the hook can independently compare with the submitted solution.

Do not copy `GPv2Settlement.sol`. Use it as an invariant and order-validation reference. Add attribution in `NOTICE.md` for any adapted algorithm or structure.

### `src/ReactiveBatchDispatcher.sol`

This is a Reactive Network contract, not a trusted payout oracle.

Responsibilities:

- Subscribe to AuraHook `OrderParked` and `BatchClosed` topics on Unichain Sepolia. `BatchReady` may be observed for telemetry only and must never trigger solution production or dispatch.
- Maintain bounded batch state inside ReactVM and preserve the frozen stored order committed by `BatchClosed.orderIdsHash`.
- Only after `BatchClosed` and membership-hash verification, derive the deterministic two-token clearing solution.
- Emit a callback whose first address argument is reserved for the RVM ID placeholder.
- Target an authenticated callback entrypoint on AuraHook.
- Mark a batch dispatched before emitting the callback to prevent duplicates.

The destination callback must verify both:

- `msg.sender` is the Reactive callback proxy.
- The injected RVM ID equals the expected Reactive deployment identity.

### Settlement accounting

Inside `unlockCallback` for settlement:

1. Set batch status to `SETTLING` before external PoolManager calls.
2. Burn the hook's parked input ERC-6909 claims for all executed orders. This creates positive currency deltas for the hook.
3. Match opposite flow internally at the validated uniform price.
4. Execute only the residual exact-input amount against the real pool with a bounded `sqrtPriceLimitX96`.
5. Mint output ERC-6909 claims to the hook equal to validated user payouts and any explicitly tracked protocol dust. This offsets the positive output deltas.
6. Require all expected totals to reconcile so PoolManager can close the unlock with zero non-settled deltas.
7. Mark orders and batch settled, then credit claimable balances.

Claim flow:

1. Zero or decrement the user's claimable balance before unlocking.
2. Burn the hook's output ERC-6909 claim.
3. Call `poolManager.take(currency, recipient, amount)`.
4. Emit `TokensClaimed`.

### `frontend/`

Use the Scaffold-ETH 2 Next.js package as the reference frontend, configured for Unichain Sepolia.

Pages or panels:

- Place Aura order: direction, amount, min output, deadline, and connected wallet.
- Live batch: order count, buy volume, sell volume, current status, and time/window.
- Settlement: uniform price, P2P matched amount, residual AMM amount, transaction hash, and explorer link.
- Claims: claimable token balances and claim action.
- Safety: clear `UNICHAIN SEPOLIA` labeling and no implied mainnet value.

Use Scaffold-ETH hooks instead of raw Wagmi where available. Configure a short but sane polling interval for Unichain and use event-history backfill so a refresh does not erase the demo state.

## Dependency strategy

Pin the working Argos versions first. Upgrade only after the baseline suite is green.

```text
forge-std               v1.15.0
OpenZeppelin hooks      v1.2.1
hookmate                v0.5.1
reactive-lib            v0.2.0
Solidity                0.8.30
EVM                     cancun
Foundry                  stable
```

Do not install independent top-level copies of v4-core, v4-periphery, or OpenZeppelin Contracts in Sprint 1. `OpenZeppelin/uniswap-hooks` already carries them as recursive submodules, matching the official v4-template structure.

Recommended root remappings:

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

## File structure

```text
Aura/
├── AGENTS.md
├── BASELINE.md
├── NOTICE.md
├── README.md
├── foundry.toml
├── foundry.lock
├── remappings.txt
├── src/
│   ├── AuraHook.sol
│   ├── AuraRouter.sol
│   ├── ReactiveBatchDispatcher.sol
│   ├── interfaces/
│   │   ├── IAuraHook.sol
│   │   └── IAuraRouter.sol
│   ├── libraries/
│   │   ├── AuraClearingMath.sol
│   │   └── AuraOrderHash.sol
│   └── types/
│       └── AuraTypes.sol
├── test/
│   ├── AuraParking.t.sol
│   ├── AuraSettlement.t.sol
│   ├── AuraClaim.t.sol
│   ├── AuraSecurity.t.sol
│   ├── AuraInvariants.t.sol
│   ├── ReactiveBatchDispatcher.t.sol
│   └── utils/BaseTest.sol
├── script/
│   ├── DeployAura.s.sol
│   ├── CreateAuraPool.s.sol
│   └── DemoAuraBatch.s.sol
├── frontend/
├── docs/
│   ├── design.md
│   ├── agent.md
│   ├── skill.md
│   ├── security.md
│   ├── remix-audit.md
│   ├── demo-runbook.md
│   └── progress-updates/
└── .github/workflows/
    ├── contracts.yml
    └── frontend.yml
```

## Sprint plan and verification gates

### Sprint 1, August 18 through August 24: custody and authenticated parking

Deliverables:

- Create the Aura repository and baseline documentation.
- Repair CI paths and pin dependencies.
- Add the missing v4 security checklist.
- Implement `AuraRouter`.
- Implement `AuraHook` parking through `BaseAsyncSwap`.
- Bind the hook to one PoolKey.
- Add bounded order and batch storage.
- Emit complete `OrderParked` evidence.

Required tests:

- Hook permission bits and mined address.
- Exact-input parking mints the correct ERC-6909 claim.
- Pool liquidity, slot0, and curve state remain unchanged after parking.
- Exact-output does not enter Aura parking.
- Non-Aura router is rejected.
- Spoofed owner or recipient is rejected.
- Expired order, zero amount, overflow, duplicate nonce, and excess batch size are rejected.
- Two currencies and repeated user orders remain separately accounted.
- A one-sided timed-out batch can be cancelled and fully refunded.

Gate for first progress update:

```text
forge fmt --check
forge build --sizes
forge test --match-path "test/AuraParking.t.sol" -vv
forge test --match-path "test/AuraSecurity.t.sol" -vv
```

No Sprint 2 work starts until this gate is green in GitHub Actions.

### Sprint 2, August 25 through August 31: clearing, settlement, claims, and Reactive dispatch

Deliverables:

- Implement `AuraClearingMath`.
- Implement typed batch solution validation.
- Implement settlement unlock flow.
- Implement residual pool swap.
- Implement claim withdrawal.
- Implement Reactive subscription and callback payload.
- Implement callback proxy plus RVM-ID authorization.

Required tests:

- Perfect 1:1 two-sided CoW with zero pool swap.
- Unequal sides with only the residual touching the AMM curve.
- Both residual directions.
- Payout conservation and rounding dust.
- User minimum output enforcement.
- Expired and replayed solution rejection.
- Duplicate order ID, wrong pool, wrong batch, wrong token, and altered payout rejection.
- Unauthorized solver, callback proxy, and RVM identity rejection.
- PoolManager unlock ends with zero outstanding deltas.
- Claim is fully backed, CEI-safe, and cannot be replayed.
- Expired unsettled orders can be refunded once and only once.
- Invariant: total user liabilities plus tracked dust never exceed hook ERC-6909 holdings per currency.

Gate for second progress update:

```text
forge fmt --check
forge build --sizes
forge test -vv
forge test --match-contract AuraInvariants -vv
```

### Sprint 3, September 1 through September 3: UI, deployment, and proof

Deliverables:

- Scaffold-ETH 2 dashboard.
- Unichain Sepolia deployment and pool setup.
- Public testnet pool using Circle's official Unichain Sepolia USDC, with the address pinned and verified in deployment tests.
- Optional Circle App Kit funding or bridge proof only after the core dashboard and settlement demo are green.
- Verified contracts on Blockscout.
- Reactive deployment funded for callback execution.
- One scripted happy-path demo with two opposite orders and one residual.
- One fallback local/anvil demo with the same transaction sequence.
- Public README, architecture diagram, security notes, and attribution.
- Demo video no longer than 3 minutes.

Deployment gate:

- Contract and frontend CI green at the exact deployment commit.
- Hook address flags verified.
- One live order parked.
- One live batch settled by authenticated callback.
- One live claim withdrawn.
- Transaction hashes and explorer links captured in `docs/demo-runbook.md`.
- No private keys, RPC secrets, or funded account details committed.
- Circle or Arc UX remains isolated from the hook and has a documented fallback that uses an already funded wallet.

## Pull request sequence

1. `PR 1: chore(aura): establish audited Argos baseline`
2. `PR 2: feat(router): add authenticated Aura order entry`
3. `PR 3: feat(hook): park exact-input orders as ERC-6909 claims`
4. `PR 4: feat(settlement): validate and settle bounded CoW batches`
5. `PR 5: feat(reactive): dispatch authenticated batch callbacks`
6. `PR 6: feat(frontend): add live batch and claims dashboard`
7. `PR 7: chore(release): deploy, verify, document, and rehearse`

Every PR must include tests, exact commands and results, security impact, and a rollback note. Do not merge a PR with failing contract CI.

## Codex execution rules

Use this at the top of every implementation prompt:

> Work only on the named branch and bounded issue. Read `AGENTS.md`, `BASELINE.md`, `docs/design.md`, `docs/agent.md` when Reactive or solver code is in scope, `docs/skill.md`, `docs/security.md`, the current code, and relevant installed dependency source before editing. Do not copy large external contracts. Preserve licenses and attribution. Add tests with every accounting change. Run `forge fmt --check`, the narrow tests first, then the full suite. Report changed files, exact test results, unresolved risks, and the commit SHA. Do not deploy, merge, close issues, or change unrelated files without explicit approval.

## Revised Codex prompts

### Prompt 0: baseline audit

> Create a new Aura working branch from Argos_LTS commit `4603269e8af7dbbff6e337546fd9d7be27deb34c`. Do not modify Argos main. Audit the repo root, submodules, remappings, Foundry lock, workflows, and deployment scripts. Confirm the CI path mismatch, inventory reusable files, and install `docs/design.md`, `docs/agent.md`, `docs/skill.md`, `BASELINE.md`, `NOTICE.md`, `docs/security.md`, and an Aura-specific `AGENTS.md`. Make `AGENTS.md` require the Three-Pillar documents before edits. Remove legacy Argos product code from Aura's active compilation paths while preserving it in Git history. Do not implement AuraHook yet.

### Prompt 1: dependency and CI foundation

> Pin the existing working dependency graph: forge-std v1.15.0, OpenZeppelin uniswap-hooks v1.2.1 with recursive v4 submodules, hookmate v0.5.1, and reactive-lib v0.2.0. Do not add duplicate top-level v4-core or v4-periphery copies. Keep `evm_version = "cancun"` and Solidity 0.8.30. Correct the GitHub Actions working directories for a repository-root Foundry project. Run `forge build`, `forge test`, and report whether any failure is source-related or workflow-related.

### Prompt 2: authenticated parking

> Implement `AuraRouter.sol` and `AuraHook.sol` for one PoolKey and exact-input orders only. AuraHook should inherit OpenZeppelin `BaseAsyncSwap`, require calls from AuraRouter, validate versioned hook data, call `super._beforeSwap` for ERC-6909 parking, record a bounded order by orderId, and emit `OrderParked`. Never treat the generic v4 hook sender as the wallet. Add `AuraParking.t.sol` and security tests proving the pool curve is untouched and owner spoofing is impossible.

### Prompt 3: bounded settlement

> Implement `AuraClearingMath.sol` and typed `BatchSolution` validation for a maximum of 8 full-fill orders in one two-token pool. Use a uniform rational price, enforce every user's minAmountOut, compute P2P matching and one residual exact-input AMM swap, and reconcile PoolManager deltas by burning input claims and minting backed output claims. Add replay protection, solution deadlines, batch status transitions, and invariant tests. Do not port GPv2Settlement or allow arbitrary interactions.

### Prompt 4: claims

> Implement pool-scoped `claimableBalances` and `claimTokens`. Apply CEI before `poolManager.unlock`, burn the hook's output ERC-6909 claim, take the underlying to the recipient, and emit a claim event. Add full, partial, repeated, cross-user, cross-currency, underfunded, and reentrancy-oriented tests.

Also implement `cancelExpiredOrder` for orders in timed-out, unsettled batches. It must mark the order cancelled before unlocking, burn only that order's parked input claim, return the underlying input to its owner, and reject double cancellation or cancellation after settlement.

### Prompt 5: Reactive dispatch

> Implement `ReactiveBatchDispatcher.sol` using `reactive-lib` and the current Reactive demo subscription and callback interfaces as references. Subscribe to `OrderParked` and `BatchClosed`; `BatchReady` is telemetry only and must never trigger solution production. Aggregate only the bounded Aura batch in frozen stored order, require the ingested IDs to reproduce `BatchClosed.orderIdsHash`, then compute or encode the deterministic solution. Reserve the first callback argument for the injected RVM ID and dispatch to AuraHook. AuraHook must verify both the callback proxy and expected RVM identity. Do not copy the stop-order demo's business logic or its known TODOs. Add Foundry Reactive tests for one callback, no callback before `BatchClosed`, membership-hash mismatch, replay suppression, wrong proxy, and wrong RVM identity.

### Prompt 6: frontend

> Create `frontend/` from the Scaffold-ETH 2 Next.js package pattern. Configure Unichain Sepolia, Aura contract ABIs, wallet connection, order placement, event-history backfill, live event watching, batch visualization, settlement proof, and token claims. Prefer Scaffold-ETH hooks over raw Wagmi. Label all amounts and transactions as Unichain Sepolia testnet. Add lint, typecheck, and production build checks.

### Prompt 7: release proof

> Prepare deployment scripts for AuraHook, AuraRouter, the demo pool, and ReactiveBatchDispatcher. Mine and verify the hook flags. Perform a read-only preflight before any broadcast. After explicit approval, deploy to Unichain Sepolia, verify contracts on Blockscout, fund the Reactive callback path, execute one two-sided batch with a non-zero residual, claim the output, and record every address, transaction hash, block, and explorer URL in `docs/demo-runbook.md`. Do not claim success without on-chain evidence.

### Prompt 8: Remix visual audit and debugging runbook

> Create `docs/remix-audit.md` for the exact audited commit. Open the Aura repository as a Foundry project in Remix Desktop, verify package-root remappings, and compile with Solidity 0.8.30 and Cancun using settings aligned with `foundry.toml`. Connect Remix Foundry Provider to local Anvil, reproduce the parking, settlement, timeout refund, and claim flows, and inspect PoolManager deltas plus ERC-6909 backing. Run Remix static analysis and a Slither-backed audit when available. Classify every finding as fixed, accepted, false positive, or deferred, with evidence. Convert confirmed defects into Foundry regression tests. Do not deploy or sign a Unichain transaction during this task.

## Demo story

1. Alice submits an exact-input order through AuraRouter.
2. Bob submits the opposite order.
3. AuraHook parks both inputs as ERC-6909 claims without moving the AMM curve.
4. The dashboard shows the live batch and the shared clearing price.
5. Reactive Network dispatches the authenticated settlement callback.
6. The majority of volume matches peer-to-peer.
7. Only the residual reaches the Uniswap v4 curve.
8. Alice and Bob see claimable outputs and withdraw them.
9. The dashboard links to the verified hook and settlement transaction.

This tells the MEV-protection story with visible proof: orders are batched, reordering has no price advantage inside the batch, direct CoW flow avoids unnecessary pool impact, and only the unmatched remainder touches public liquidity.

## Go or no-go rules

### Go

- New Aura repository or isolated Aura branch exists.
- Baseline commit and reused code are disclosed.
- CI is green before accounting work begins.
- Dedicated router and authenticated user attribution are included.
- Settlement verifies the solver's proposal rather than trusting it.
- Demo is limited to one pool and bounded orders.

### No-go

- Building directly on Argos `main`.
- Installing duplicate v4 dependency trees.
- Crediting balances to the generic hook `sender`.
- Accepting arbitrary `users` and `payouts` arrays from an authorized solver.
- Copying CoW's full settlement contract or Reactive's stop-order business logic.
- Starting the frontend before parking and settlement tests are green.
- Calling the project live without one authenticated callback and one successful claim transaction.

## Primary references

- [Argos_LTS base repository](https://github.com/rainwaters11/Argos_LTS)
- [Uniswap v4 template](https://github.com/Uniswap/v4-template)
- [Uniswap v4 PoolManager](https://github.com/Uniswap/v4-core/blob/main/src/PoolManager.sol)
- [OpenZeppelin BaseAsyncSwap](https://github.com/OpenZeppelin/uniswap-hooks/blob/acbd604c409a827f7f98c9517236da860c4fca1a/src/base/BaseAsyncSwap.sol)
- [OpenZeppelin Uniswap Hooks documentation](https://docs.openzeppelin.com/uniswap-hooks/api/base)
- [CoW GPv2Settlement architecture](https://docs.cow.fi/cow-protocol/reference/contracts/core/settlement)
- [CoW auction solution schema](https://docs.cow.fi/cow-protocol/reference/core/auctions/schema)
- [Reactive Network events and callbacks](https://dev.reactive.network/legacy/events-%26-callbacks)
- [Reactive stop-order reference](https://github.com/Reactive-Network/reactive-smart-contract-demos/tree/main/src/demos/uniswap-v2-stop-order)
- [Scaffold-ETH 2](https://github.com/scaffold-eth/scaffold-eth-2)
- [Unichain developer documentation](https://docs.unichain.org/)
- [Remix Desktop local filesystem workflow](https://remix-ide.readthedocs.io/en/latest/desktop.html)
- [Remix Foundry integration and remappings](https://remix-ide.readthedocs.io/en/latest/foundry.html)
- [RemixAI Slither audit workflow](https://remix-ide.readthedocs.io/en/latest/ai.html)
