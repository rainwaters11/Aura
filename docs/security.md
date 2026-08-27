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
12. Zero minimum output, oversized individual or aggregate inputs, unsafe payout chunking, or oversized claim operations creating unexecutable custody state
13. Unauthorized or altered solution-inbox publication wasting callback funding
14. Publisher-selected alternate feasible prices redistributing value between sides
15. Finality lag consuming the settlement interval before the builder can act
16. Permanent `DISPATCHED` state after a transient callback failure
17. Same-direction orders exhausting every batch slot before opposite flow can join
18. A fourth-order submitter, permissionless closer, or temporary pool-price movement manipulating the canonical clearing reference
19. A canonical individual payout exceeding the solution schema or PoolManager signed-operation range
20. An order deadline too short to survive finalized closure observation plus settlement grace
21. An incompatible incoming limit making the prospective two-sided feasible price interval empty and poisoning the batch
22. Deduplication collisions between distinct batch-level hook or inbox event kinds
23. Contradictory timeout transitions sending a failed-preflight batch through solver dispatch or delaying its refund
24. A generic cron tick selecting pending batches through an unbounded scan or starving concurrent retries

## Mandatory controls

- Accept orders only from the immutable `AuraRouter`; the router derives owner from `msg.sender`.
- Bind the hook, order IDs, batches, solutions, and liabilities to one immutable PoolKey.
- Validate every solution field on-chain even when the production builder, inbox publisher, and Reactive transport are authorized.
- Require the production builder to quote from finalized complete PoolManager state through pinned v4 state-view interfaces; ReactVM never substitutes a spot-price estimate for liquidity, fees, bitmap, or initialized-tick state.
- Authenticate the AuraSolutionInbox publisher, bound the encoded solution arrays, and require the dispatcher to transport the exact recomputed canonical envelope.
- Reserve the final slot of a one-sided batch for the missing direction by rejecting another present-direction order at `MAX_BATCH_ORDERS - 1`.
- Before custody, require `deadline >= block.timestamp + MIN_ORDER_LIFETIME_SECONDS`, with the normative minimum fixed at 13 hours, and reject an incoming order that would make a prospective two-sided feasible interval empty.
- Before closure, recompute the feasible interval and require every order deadline to cover `closedAtTimestamp + MAX_FINALITY_LAG_SECONDS + SETTLEMENT_GRACE_SECONDS`. A preflight-valid two-sided timeout closure alone enters `CLOSED` and emits `BatchClosed`; a one-sided or failed-preflight timeout closure enters `REFUNDABLE` immediately, emits no `BatchClosed`, and never reaches solver dispatch.
- Derive exactly one canonical rational price from the exact midpoint of the frozen orders' feasible interval. When that reduced midpoint exceeds the `uint128` tuple bounds, select normalized `1/1` if feasible, otherwise normalized `L`, before validating payouts. Treat `BatchClosed.referenceSqrtPriceX96` as telemetry only and require the hook to reject every alternative feasible price.
- Before emitting `BatchClosed`, require every canonical individual payout to fit `type(int128).max` and the `uint128[]` schema. Revert an invalid at-cap admission atomically and send an invalid timeout-close batch directly to `REFUNDABLE`.
- Use full-precision rational math with explicit, tested rounding direction.
- Update liability and terminal-order state before external unlock operations.
- Require PoolManager as `unlockCallback` caller and authenticate the active action context.
- Reject zero minimum output and enforce `type(int128).max` on each input, minimum output, per-direction input aggregate, individual payout, residual, and PoolManager operation. Keep aggregate payout liabilities in full-width `uint256` and split execution into deterministic signed-range chunks.
- Enforce hard batch-size bounds and one terminal transition per order.
- Limit each claim operation to `type(int128).max` while preserving repeated partial redemption of larger account-level balances.
- Record a two-sided closure timestamp and delay refunds by the fixed 12-hour finality buffer plus five-minute settlement grace; no operator acknowledgment may extend this bound.
- Treat `DISPATCHED` as pending and permit at most three byte-identical callback attempts, one minute apart, through the authenticated cron trigger. Track no more than eight pending batches in unique fixed retry slots; each cron tick scans at most eight slots, selects at most one eligible batch, advances a persistent round-robin cursor, and clears terminal slots. A full ring suppresses new dispatch without overwriting pending state, and retries never extend the refund boundary.
- Deduplicate AuraHook and AuraSolutionInbox logs with an event identity derived from chain, emitting contract, and all topics, storing the data payload hash separately. Ignore only exact redelivery, invalidate conflicting reuse, keep distinct event kinds distinct, and exclude retry-only cron ticks from the ingestion map.
- Provide one-time sovereign user claims and permissionless timeout-refund triggering; every refund destination is fixed to the stored order owner.
- Keep Circle, Arc, Chainalysis, indexers, and frontend services outside the accounting safety path.

## Required tests

- Parking leaves price, tick, active liquidity, and curve state unchanged. Separately, PoolManager ERC-20 custody and the hook's newly minted ERC-6909 input-claim balance must each increase by exactly the parked input amount.
- Owner spoofing and arbitrary router calls fail.
- Perfect CoW settlement performs no pool swap.
- Both residual directions touch the pool only for the residual amount, and the RPC-backed production quote matches pinned v4 fork execution.
- Missing, partial, stale, or changed pool state suppresses publication or causes an atomic destination revert without weakening refunds.
- Unauthorized inbox publication, oversized solution arrays, and altered inbox payloads fail safely.
- Three same-direction orders reserve the final slot; a fourth same-direction order reverts, while a missing-direction order can join and close if preflight-valid.
- A deadline equal to now or shorter than `MIN_ORDER_LIFETIME_SECONDS` rejects before custody; closure also refuses any batch whose remaining deadlines do not cover finality plus grace.
- An incompatible incoming limit that would make the prospective two-sided feasible interval empty rejects before custody, while compatible limits preserve a nonempty interval through closure.
- The hook rejects every funded but noncanonical price; builder and hook derive the identical tuple from the frozen feasible-interval midpoint and oversized bounded-fallback vectors, and close-time pool manipulation cannot change it.
- Canonical individual payouts above `type(int128).max` never enter solver dispatch: at-cap admission reverts atomically and timeout closure becomes directly refundable. Payouts otherwise conserve value within documented rounding dust, including cases whose full-width aggregate payout exceeds the signed limit and is executed in multiple chunks.
- Zero minimum output, individual signed-range overflow, aggregate input overflow, wrong deadline clock/boundary, duplicate order, wrong pool, wrong batch, and altered payout checks fail safely.
- A claim request above `type(int128).max` reverts before casting or mutation; a larger accumulated balance is fully redeemable through multiple bounded partial claims.
- A one-sided or failed-preflight timeout batch never emits `BatchClosed` and becomes immediately owner-refundable; a preflight-valid closed batch alone waits through finality plus grace, and finality lag cannot consume the post-finality grace.
- A configured Reactive cron log reaches the retry-only branch without passing Unichain hook/inbox checks; wrong chain, cron contract, cron topic, or mixed-source logs fail before mutation. Concurrent `DISPATCHED` batches occupy unique slots in the fixed eight-slot retry ring; each tick performs no more than eight inspections and one callback, advances the cursor fairly, clears terminal slots, never overwrites a full ring, and triggers no more than three identical attempts per batch. A delayed `BatchSettled` makes later retries harmless, and retry state cannot postpone refunds.
- `BatchClosed`, `BatchSettled`, `OrderCancelled`, and `SolutionProposed` produce distinct event keys even when no order topic exists; exact redelivery is ignored and same-key/different-data reuse invalidates the batch.
- Unauthorized callback proxy, RVM, cron source, and unlock callers fail.
- Claims and refunds are non-reentrant, CEI-safe, and cannot replay; a reverting recipient or refund owner can block only that individual operation.
- Invariant: liabilities plus tracked dust never exceed ERC-6909 holdings for each pool and currency.

## Review evidence

Every accounting pull request must include Foundry unit, fuzz, and relevant invariant results. Before deployment, record Remix and Slither findings against the exact commit in `docs/remix-audit.md`, including fixed, accepted, false-positive, and deferred dispositions.

## Stop conditions

Stop implementation or deployment if an invariant is ambiguous, backing cannot be proven, an unlock ends with unresolved deltas, the callback identity is not authenticated, dependency revisions are unpinned, tests are failing, or a secret appears in source or logs.
