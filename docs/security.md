# Aura Security Model

Status: mandatory review checklist  
Target: Aura MVP on Unichain Sepolia

## Assets at risk

- User inputs parked as PoolManager ERC-6909 claims
- User output liabilities recorded by Aura
- Pool liquidity touched by the residual swap
- Production solution-publisher and Reactive callback authorization
- Timeout refund rights

## Primary threats

1. Router or hook-data owner spoofing
2. Replayed, duplicated, expired, or cross-pool solutions
3. Incorrect uniform-price rounding or payout conservation
4. Residual swap direction, amount, or price-limit manipulation
5. Unresolved PoolManager deltas at unlock completion
6. Claims or refunds exceeding ERC-6909 backing
7. Reentrancy or state rollback around unlock callbacks
8. Unauthorized callback proxy or forged RVM identity
9. Unbounded batches causing gas denial of service
10. External service failure blocking sovereign fund recovery
11. Partial or stale pool state producing an underfunded residual quote
12. Zero minimum output, aggregate minimum-liability overflow, or oversized claim operations creating unexecutable custody state
13. Unauthorized or altered solution-inbox publication wasting callback funding

## Mandatory controls

- Accept orders only from the immutable `AuraRouter`; the router derives owner from `msg.sender`.
- Bind the hook, order IDs, batches, solutions, and liabilities to one immutable PoolKey.
- Validate every solution field on-chain even when the production builder, inbox publisher, and Reactive transport are authorized.
- Require the production builder to quote from finalized complete PoolManager state through pinned v4 state-view interfaces; ReactVM never substitutes a spot-price estimate for liquidity, fees, bitmap, or initialized-tick state.
- Authenticate the AuraSolutionInbox publisher, bound the encoded solution arrays, and require the dispatcher to transport the exact recomputed canonical envelope.
- Use full-precision rational math with explicit, tested rounding direction.
- Update liability and terminal-order state before external unlock operations.
- Require PoolManager as `unlockCallback` caller and authenticate the active action context.
- Reject zero minimum output and enforce `type(int128).max` on each input, each minimum output, both per-direction input aggregates, and both per-output-currency aggregate minimum liabilities at admission.
- Enforce hard batch-size bounds and one terminal transition per order.
- Limit each claim operation to `type(int128).max` while preserving repeated partial redemption of larger account-level balances.
- Provide one-time permissionless user claims and owner-only timeout refunds.
- Keep Circle, Arc, Chainalysis, indexers, and frontend services outside the accounting safety path.

## Required tests

- Parking leaves price, tick, active liquidity, and curve state unchanged. Separately, PoolManager ERC-20 custody and the hook's newly minted ERC-6909 input-claim balance must each increase by exactly the parked input amount.
- Owner spoofing and arbitrary router calls fail.
- Perfect CoW settlement performs no pool swap.
- Both residual directions touch the pool only for the residual amount, and the RPC-backed production quote matches pinned v4 fork execution.
- Missing, partial, stale, or changed pool state suppresses publication or causes an atomic destination revert without weakening refunds.
- Unauthorized inbox publication, oversized solution arrays, and altered inbox payloads fail safely.
- Payouts conserve value within documented rounding dust.
- Zero minimum output, individual signed-range overflow, aggregate input overflow, aggregate minimum-output liability overflow, deadline, duplicate order, wrong pool, wrong batch, and altered payout checks fail safely.
- A claim request above `type(int128).max` reverts before casting or mutation; a larger accumulated balance is fully redeemable through multiple bounded partial claims.
- Unauthorized callback proxy, RVM, and unlock callers fail.
- Claims and refunds are CEI-safe and cannot replay.
- Invariant: liabilities plus tracked dust never exceed ERC-6909 holdings for each pool and currency.

## Review evidence

Every accounting pull request must include Foundry unit, fuzz, and relevant invariant results. Before deployment, record Remix and Slither findings against the exact commit in `docs/remix-audit.md`, including fixed, accepted, false-positive, and deferred dispositions.

## Stop conditions

Stop implementation or deployment if an invariant is ambiguous, backing cannot be proven, an unlock ends with unresolved deltas, the callback identity is not authenticated, dependency revisions are unpinned, tests are failing, or a secret appears in source or logs.
