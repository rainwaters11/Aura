# Aura deadline demo runbook

Status: local deterministic demo is the submission-safe default

Audience: judges and technical reviewers

Target length: 3 minutes

Public-chain actions: blocked unless separately approved

## 1. Go/no-go rule

Use the local deterministic frontend for the recorded and live demo. It proves
the intended product journey without depending on a wallet, RPC, faucet,
explorer, public contract, or last-minute network condition.

Do not improvise a public deployment. Stop before any command that connects a
wallet, exposes a private key, signs, broadcasts, initializes a pool, adds
liquidity, verifies a contract, or spends funds unless that exact action and
manifest have received separate approval.

## 2. Pre-demo verification

Run from the repository root:

```bash
forge fmt --check
forge build --sizes
forge test --match-contract DeployAuraTest -vv
forge test -vv

cd frontend
npm ci
npm run format:check
npm run lint
npm run typecheck
npm test
npm run build
```

Required result:

- every command exits successfully;
- the Solidity suite has no failures;
- only the 8 documented RPC-dependent Reactive fork tests are skipped;
- `AuraHook` remains below EIP-170; and
- frontend tests and the production build pass.

Record the exact commit with:

```bash
git rev-parse HEAD
git status --short --branch
```

The worktree must be clean before recording evidence.

## 3. Start the demo

```bash
cd frontend
npm run dev
```

Open `http://localhost:5173`. Keep one terminal tab available with the successful
test summary and one browser tab on the console. Close unrelated applications
and disable notifications before recording.

## 4. Three-minute presentation

### 0:00–0:25 — Problem and promise

Say:

> Aura is a bounded batch-auction hook for Uniswap v4. Instead of sending every
> order directly through the AMM curve, it parks a small batch, clears compatible
> flow at one uniform price, and sends only the unmatched residual to the pool.

Point to the four-stage rail: Park, Match, Settle residual, Claim.

### 0:25–0:55 — Park without moving the curve

Click **Load demo orders**.

Explain:

- the router binds each owner to the actual caller;
- inputs are held as PoolManager ERC-6909 claims owned by the hook; and
- the pool price, tick, and active liquidity remain unchanged during parking.

Point to Alice and Bob's opposite directions and the displayed intake window.

### 0:55–1:20 — Freeze a bounded batch

Click **Close batch**.

Explain that closure freezes order membership and checks the feasible price
interval, deadlines, capacity, and payout encoding before settlement can begin.
The demo uses the protocol's strict 20-block intake boundary.

### 1:20–2:05 — Settle only the difference

Click **Submit solution**.

Point to:

- one uniform price for both directions;
- direct-match volume versus residual volume;
- the one residual exact-input swap; and
- zero unresolved PoolManager deltas.

Explain that the callback is only transport. `AuraHook` recomputes the solution
from frozen state and reverts a stale, noncanonical, or underfunded proposal.

### 2:05–2:30 — Sovereign claim

Click the dynamically labeled claim control, shown in this fixture as **Claim 4
WETH**. The amount and token in this label are derived from the selected
recipient's claimable output.

Explain that settlement credits a recipient-owned liability and the user pulls
the underlying output. A failed recipient transfer rolls back without consuming
the claim. An unavailable solver or callback cannot remove the fixed timeout
refund path.

### 2:30–2:55 — Perfect CoW proof

Reset the console and select **Perfect CoW**. Advance through **Load demo
orders**, **Close batch**, and **Submit solution**.

Point out that direct matching reaches 100%, residual volume is zero, and pool
price and tick remain unchanged. This is the clearest visual proof of the core
product claim.

### 2:55–3:00 — Close

Say:

> Aura makes the pool the residual venue, not the first venue, while keeping
> settlement and recovery enforced on-chain.

## 5. Evidence to capture

Capture these artifacts at the same exact commit:

1. the full-suite final line showing pass/fail/skip totals;
2. the `AuraHook` runtime size and EIP-170 margin;
3. the frontend test summary and production build result;
4. the empty-state console;
5. the settled residual scenario with zero unresolved deltas;
6. the Perfect CoW scenario showing zero pool movement; and
7. `git rev-parse HEAD` plus a clean `git status --short --branch`.

Label local traces and fixture addresses as simulation evidence. Never call them
transaction hashes or deployed addresses.

## 6. Failure recovery

| Failure | Immediate action | Fallback |
| --- | --- | --- |
| Dev server does not start | Run `npm ci`, then `npm run build` to expose dependency or compile errors | Serve the already validated production build locally only after fixing the reported error |
| Browser state is stale | Hard refresh and use the reset control | Reopen `http://localhost:5173` in a clean tab |
| An action is clicked out of order | Read the visible guard message | Reset and repeat the four-stage sequence |
| Claim error is needed for questions | Open `?preview=claim-error` | Explain that the claim remains available after recipient failure |
| Public RPC, faucet, wallet, or explorer fails | Stop public-chain activity | Continue with deterministic local evidence; do not spend deadline time debugging infrastructure |
| A test fails | Stop and save the exact output | Do not relabel a prior run as current evidence; fix and rerun the complete gate |

## 7. Submission checklist

- [ ] README describes Aura rather than the historical Argos submission.
- [ ] Exact commit is recorded in every evidence note.
- [ ] Smart-contract and frontend gates pass at that commit.
- [ ] Demo recording is under the platform limit and readable at normal speed.
- [ ] Submission copy distinguishes local simulation from public deployment.
- [ ] Repository and demo links open in a signed-out browser.
- [ ] No secret, private key, RPC credential, or wallet balance appears on screen.
- [ ] Known skipped tests are named and explained.
- [ ] Both pull requests remain draft until explicit readiness approval.
- [ ] Merge, deployment, pool initialization, signing, and broadcast remain
      separate approval gates.
