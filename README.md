# Aura

Aura is a bounded batch-auction settlement hook for Uniswap v4. It parks
exact-input orders without moving the pool curve, clears compatible flow at one
uniform price, and sends at most one unmatched residual swap to the pool.

The on-chain MVP slice is deliberately narrow: one pool, full fills, no
arbitrary solver interactions, sovereign output claims, and a permissionless
timeout-refund path. The judge-facing interface runs from deterministic local
evidence and does not require a wallet or public deployment.

A production-complete MVP additionally requires the solution builder, solution
inbox, authenticated Reactive dispatcher, and callback transport described in
the normative specifications. Those components are required but deferred and
unimplemented on this delivery branch. This branch therefore has no live-user
transport path and is not production ready.

## Why Aura

Ordinary AMM execution exposes every order directly to the curve. Aura first
collects a small, bounded batch and finds Coincidence of Wants (CoW) between its
two directions. Compatible volume clears peer to peer; only the difference
touches Uniswap v4 liquidity.

This gives the demo four visible properties:

- parking does not change pool price, tick, or active liquidity;
- every settled order uses the same canonical rational price;
- no more than one exact-input residual swap reaches the curve; and
- users pull their settled output or recover timed-out input without operator
  custody.

## Lifecycle

1. **Park** — users call `AuraRouter.placeOrder`; the router binds the owner to
   `msg.sender`, and `AuraHook` holds the input as a PoolManager ERC-6909 claim.
2. **Close** — a two-sided batch closes at four orders or after the strict
   20-block intake window, subject to feasibility and deadline checks.
3. **Settle** — the configured callback boundary delivers a bounded solution.
   The hook independently authenticates the caller and recomputes membership,
   price, payouts, residual, and accounting before executing.
4. **Claim or refund** — recipients pull settled output. Unsettled orders become
   owner-refundable at the protocol's fixed timeout boundary.

## Architecture

| Component | Responsibility | Trust boundary |
| --- | --- | --- |
| `AuraRouter` | Authenticates order ownership and submits the single immutable pool key | Cannot choose a different owner or pool |
| `AuraHook` | Parks input, freezes batches, validates settlement, resolves PoolManager deltas, and accounts for claims/refunds | On-chain protocol authority; rechecks all external fields |
| `AuraClearingMath` | Derives the canonical uniform price, payouts, residual, and conservation bounds | Pure, fuzzed, and invariant-tested |
| `AuraSettlementVerifier` | Reconstructs frozen order state and validates the typed solution domain | Reads trusted state from the calling hook |
| Settlement callback boundary | Accepts a bounded proposal only from the approved proxy and RVM identity | Production builder, inbox, authenticated Reactive dispatcher, and callback transport are required for a production-complete MVP but deferred and unimplemented on this branch |
| Frontend | Demonstrates the lifecycle and evidence | Untrusted convenience layer; never an accounting source |

## Specifications and gate evidence

Aura's Three-Pillar architecture separates authority:

1. [`docs/design.md`](./docs/design.md) defines the protocol, accounting, and
   on-chain invariants.
2. [`docs/agent.md`](./docs/agent.md) specifies the required production
   builder, solution inbox, authenticated Reactive dispatcher, and callback
   transport boundary. These components are deferred and unimplemented here.
3. [`docs/skill.md`](./docs/skill.md) defines allowed commands, evidence, and
   approval gates.

The consolidated
[`AURA_CODEX_BUILD_REPORT.md`](./docs/AURA_CODEX_BUILD_REPORT.md#three-pillar-architecture)
records the architecture decisions. The
[`Sprint 1 parking and custody gate`](./docs/progress-updates/sprint-1-parking-gate.md)
and [merged Settlement Console PR #29](https://github.com/rainwaters11/Aura/pull/29)
provide the late-August implementation evidence used by this delivery branch.

## Safety invariants

- Only router-authenticated exact-input orders can be parked.
- The MVP accepts at most four orders in the live batch and reserves room for
  the missing direction while a batch is one-sided.
- The canonical clearing price is the normalized midpoint of the frozen
  feasible interval; the publisher cannot choose a more favorable price.
- Settlement executes no arbitrary calls and uses at most one residual swap.
- Every PoolManager delta must resolve to zero before the unlock returns.
- Claim liabilities and recorded dust remain fully backed by hook-owned claims.
- Callback proxy and RVM identity are independently authenticated.
- The deferred builder, inbox, RPC, dispatcher, or callback transport cannot
  block the fixed timeout-refund path.
- Deployment rejects an already initialized final PoolId both before broadcast
  and inside the hook constructor's CREATE2 transaction.

## Run the judge demo

Prerequisites: Node.js `^20.19.0` or `>=22.12.0`, and npm.

```bash
cd frontend
npm ci
npm run dev
```

Open `http://localhost:5173` and follow the on-screen sequence. **Load demo
orders** creates deterministic local demonstration data, not live user orders
or evidence of an implemented production transport path:

1. Park the deterministic two-sided orders.
2. Close the batch after its displayed intake window.
3. Settle and inspect direct-match volume, the single residual, and zero
   unresolved deltas.
4. Claim Alice's output to the selected recipient.
5. Reset, select **Perfect CoW**, and show that 100% direct matching leaves the
   pool price and tick unchanged.

The displayed identifiers are labeled local simulation evidence; they are not
represented as public transaction hashes. See
[`docs/demo-runbook.md`](./docs/demo-runbook.md) for the presentation script,
failure recovery, and capture checklist.

## Verify the project

### Smart contracts

Prerequisite: Foundry 1.7.1.

```bash
forge fmt --check
forge build --sizes
forge test --match-contract DeployAuraTest -vv
forge test -vv
```

At the current reviewed tree, the complete suite reports 211 passing tests, no
failures, and 8 intentionally skipped RPC-dependent Reactive fork tests. The
optimized `AuraHook` runtime is 21,716 bytes, leaving 2,860 bytes below EIP-170.
Treat these numbers as local exact-tree evidence until the stacked pull request
is incorporated into the `main`-targeting branch and CI reruns there.

### Frontend

```bash
cd frontend
npm ci
npm run format:check
npm run lint
npm run typecheck
npm test
npm run build
```

The deterministic data source is behind the typed `AuraDataSource` boundary.
Preview failure states with:

- `?preview=disconnected`
- `?preview=wrong-network`
- `?preview=unavailable`
- `?preview=claim-error`

## Repository map

```text
src/
  AuraHook.sol                 Protocol state machine and accounting authority
  AuraRouter.sol               Authenticated order entrypoint
  AuraSettlementVerifier.sol   Frozen-state solution validation
  libraries/AuraClearingMath.sol
  types/AuraTypes.sol
test/                          Unit, fuzz, integration, and invariant coverage
script/DeployAura.s.sol        Typed, fail-closed Aura Core deployment script
deployments/                   Public manifest template; undecided values stay REQUIRED
frontend/                      Deterministic React judge console
docs/design.md                 Normative protocol specification
docs/agent.md                  Builder, inbox, Reactive, and callback design
docs/security.md               Threat model and verified invariants
docs/skill.md                  Approved commands and operational controls
docs/demo-runbook.md           Deadline presentation and evidence checklist
```

Legacy Argos contracts remain in the repository as historical code. The Aura
files and normative documents above define the current project.

## Deployment status

Aura Core is **not publicly deployed**. The checked-in Unichain Sepolia manifest
contains explicit `REQUIRED_*` placeholders for operator-controlled identities,
nonce, predicted addresses, salt, and bytecode hashes. That file is intentionally
non-runnable until every value is reviewed and approved.

The deployment package covers only `AuraSettlementVerifier`, `AuraRouter`, and
`AuraHook`. It does not initialize a pool, add liquidity, connect a wallet,
sign, broadcast, verify publicly, or spend funds. Follow
[`docs/issue-15-deployment-preflight.md`](./docs/issue-15-deployment-preflight.md)
for the fail-closed procedure.

## Scope

Included in the MVP:

- one immutable Unichain Sepolia PoolKey;
- exact-input, full-fill, two-direction orders;
- one canonical uniform rational price;
- peer-to-peer matching plus at most one residual pool swap;
- ERC-6909-backed claims, tracked dust, and timeout refunds;
- an authenticated settlement callback boundary for bounded solutions; and
- the production solution builder, solution inbox, authenticated Reactive
  dispatcher, and callback transport required for a production-complete MVP,
  which are deferred and unimplemented on this delivery branch.

Explicitly excluded:

- exact-output and partial-fill orders;
- multi-hop or multi-pool execution;
- arbitrary solver calls or solver competition;
- mainnet deployment and production economic optimization; and
- synchronous compliance services that could block claims or refunds.

## License

MIT. See [`LICENSE`](./LICENSE) and [`NOTICE.md`](./NOTICE.md).
