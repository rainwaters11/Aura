# Aura Security Model

Status: mandatory review checklist  
Target: Aura MVP on Unichain Sepolia

## Assets at risk

- User inputs parked as PoolManager ERC-6909 claims
- User output liabilities recorded by Aura
- Pool liquidity touched by the residual swap
- Solver and Reactive callback authorization
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

## Mandatory controls

- Accept orders only from the immutable `AuraRouter`; the router derives owner from `msg.sender`.
- Bind the hook, order IDs, batches, solutions, and liabilities to one immutable PoolKey.
- Validate every solution field on-chain even when the solver is authorized.
- Use full-precision rational math with explicit, tested rounding direction.
- Update liability and terminal-order state before external unlock operations.
- Require PoolManager as `unlockCallback` caller and authenticate the active action context.
- Enforce hard batch-size bounds and one terminal transition per order.
- Provide one-time permissionless user claims and owner-only timeout refunds.
- Keep Circle, Arc, Chainalysis, indexers, and frontend services outside the accounting safety path.

## Required tests

- Parking leaves price, tick, liquidity, and reserves unchanged.
- Owner spoofing and arbitrary router calls fail.
- Perfect CoW settlement performs no pool swap.
- Both residual directions touch the pool only for the residual amount.
- Payouts conserve value within documented rounding dust.
- Minimum output, deadline, duplicate order, wrong pool, wrong batch, and altered payout checks fail safely.
- Unauthorized callback proxy, RVM, and unlock callers fail.
- Claims and refunds are CEI-safe and cannot replay.
- Invariant: liabilities plus tracked dust never exceed ERC-6909 holdings for each pool and currency.

## Review evidence

Every accounting pull request must include Foundry unit, fuzz, and relevant invariant results. Before deployment, record Remix and Slither findings against the exact commit in `docs/remix-audit.md`, including fixed, accepted, false-positive, and deferred dispositions.

## Stop conditions

Stop implementation or deployment if an invariant is ambiguous, backing cannot be proven, an unlock ends with unresolved deltas, the callback identity is not authenticated, dependency revisions are unpinned, tests are failing, or a secret appears in source or logs.
