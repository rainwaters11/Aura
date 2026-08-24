# Aura Reactive Solver Agent Specification

Status: normative MVP agent specification  
Version: 1.5  
Companion protocol: `docs/design.md`

## 1. Persona and objective

The Aura solver is a deterministic, bounded batch auctioneer split between an RPC-backed production solution builder and an authenticated Reactive transport. Its job is to observe a closed Aura batch, construct one mathematically valid uniform-price solution from authoritative finalized Unichain pool state, publish the bounded proposal, and dispatch that exact proposal through the Reactive Network callback path.

The agent is not a custodian and is not trusted to decide final balances. It cannot move user funds directly. `AuraHook` independently validates order membership, price, payouts, residual direction, residual amount, deadlines, replay state, and realized PoolManager conservation.

Success means:

- compatible flow is matched peer-to-peer at one price;
- only the residual reaches the pool curve;
- every user minimum is honored;
- the destination callback is authenticated;
- a failed proposal leaves the batch and funds recoverable.

## 2. Runtime split

Aura uses four cooperating solver surfaces:

| Surface | Responsibility | Authority |
| --- | --- | --- |
| Production `AuraSolutionBuilder` | Read finalized Aura events and complete PoolManager state through Unichain Sepolia RPC, run pinned v4 swap math, construct the canonical bounded solution, and submit it to the inbox. | Operational proposal source only. It cannot move funds or bypass hook validation. |
| `AuraSolutionInbox.sol` on Unichain Sepolia | Accept a bounded encoded solution from the configured MVP publisher and emit `SolutionProposed`. | Authenticated/rate-limited event ingress only; no custody or settlement authority. |
| `ReactiveBatchDispatcher.sol` in ReactVM | Subscribe to Aura batch evidence and inbox proposals, verify frozen membership plus the canonical envelope, and emit the exact callback. | Authenticated transport only. It does not read RPC state or quote the pool. |
| Local simulation worker | Reproduce the builder algorithm against fixtures and forked state before deployment. | No production authority. Used for tests and debugging. |

The production builder is a disclosed MVP component, distinct from the local simulator. Its publisher credential is an availability and spam-control boundary, not a financial authorization: `AuraHook` independently validates every field and realized delta. Compromise may waste inbox or callback gas but cannot redirect funds, weaken minimums, or prevent timeout refunds.

## 3. Authoritative event sources

The builder reads only the configured Unichain Sepolia RPC and immutable AuraHook, PoolManager, pool, and state-view addresses. The dispatcher subscribes only to the configured chain ID, immutable AuraHook address, and immutable AuraSolutionInbox address. No frontend or indexer response is authoritative.

### 3.1 Order event

Solidity declaration:

```solidity
event OrderParked(
    uint64 indexed batchId,
    bytes32 indexed orderId,
    address indexed owner,
    address recipient,
    Currency tokenIn,
    Currency tokenOut,
    uint128 amountIn,
    uint128 minAmountOut
);
```

Canonical ABI topic signature:

```text
OrderParked(uint64,bytes32,address,address,address,address,uint128,uint128)
```

```text
topic0 = keccak256(canonical signature)
topic1 = uint256(batchId)
topic2 = uint256(orderId)
topic3 = uint256(uint160(owner))
data   = abi.encode(recipient, tokenIn, tokenOut, amountIn, minAmountOut)
```

`Currency` is an address-valued type in the event ABI. The agent must use the canonical underlying ABI signature when deriving `topic0`.

### 3.2 Batch-ready event

```solidity
event BatchReady(
    uint64 indexed batchId,
    uint64 openedAtBlock,
    uint8 orderCount,
    uint160 referenceSqrtPriceX96
);
```

The hook emits this only when the batch has both directions. `referenceSqrtPriceX96` is optional pool-drift telemetry only; it never selects the canonical candidate and is not trusted by the destination in place of payout and conservation validation.

### 3.3 Destination evidence

The dispatcher also subscribes to:

- `BatchSettled(batchId, solutionHash, ...)`
- `OrderCancelled(orderId, owner, token, amount)`

It marks a batch complete only after observing `BatchSettled` from the configured AuraHook. Emitting a callback is not settlement proof.

### 3.4 Batch-closed event

```solidity
event BatchClosed(
    uint64 indexed batchId,
    uint64 closedAtBlock,
    uint64 closedAtTimestamp,
    uint8 orderCount,
    bytes32 orderIdsHash,
    uint160 referenceSqrtPriceX96
);
```

`BatchClosed`, rather than `BatchReady`, is the sole solution-production trigger. Its close block, close timestamp, count, and hash describe immutable membership. The builder and dispatcher preserve the hook's frozen stored order and verify `keccak256(abi.encode(orderIds))` against `orderIdsHash`. `referenceSqrtPriceX96` is telemetry only and never participates in canonical price selection, payout computation, or solution validation.

### 3.5 Retry clock

The dispatcher also subscribes to the configured Reactive cron source. A cron log is only a monotonic retry trigger; it carries no settlement authority and cannot alter a solution. The dispatcher accepts a tick only from the immutable cron contract and topic, then evaluates the bounded `DISPATCHED` retry transition in Section 11. A missing callback-failure receipt is handled by this timeout path, while `BatchSettled` remains the only success evidence.

### 3.6 Production solution proposal

After quoting from finalized complete pool state, the builder calls the configured inbox, which emits:

```solidity
event SolutionProposed(
    uint64 indexed batchId,
    bytes32 indexed solutionHash,
    bytes encodedSolution
);
```

`encodedSolution` is exactly `abi.encode(BatchSolution)` and remains bounded by `MAX_BATCH_ORDERS`. The inbox accepts only the configured MVP publisher, rejects an empty payload and oversized order or payout arrays, and stores no user funds. The dispatcher decodes the payload, requires the event batch and hash to match the decoded solution, recomputes the canonical hash, and requires the ordered IDs to reproduce the previously observed `BatchClosed.orderIdsHash`. It never edits or recomputes the quoted solution.

## 4. Subscription rules

The constructor or initialization path subscribes through the Reactive service when not running in ReactVM, following the `AbstractReactive` pattern.

Log validation branches by authenticated source before decoding event-specific fields:

1. If `log.chain_id == REACTIVE_CHAIN_ID`, require `log._contract == REACTIVE_CRON_CONTRACT` and `log.topic_0 == REACTIVE_CRON_TOPIC`. Process only the bounded retry tick from Section 11 and return immediately. The cron branch never decodes an Aura batch or order record and cannot ingest, alter, or settle a solution.
2. Otherwise require `log.chain_id == UNICHAIN_SEPOLIA_CHAIN_ID`, then require `log._contract` to be the immutable AuraHook or AuraSolutionInbox expected for the decoded topic. Only this branch accepts Aura batch, destination-evidence, or `SolutionProposed` topics.
3. Reject every other chain, contract, topic, or mixed-source combination before state mutation.

For accepted hook or inbox logs, additionally require:

- every indexed field decodes without truncation;
- the batch is not terminal;
- the event has not already been ingested under its exact event identity.

The state key for hook/inbox ingestion is scoped to the source and event kind:

```text
eventKey = keccak256(
    abi.encode(log.chain_id, log._contract, log.topic_0, log.topic_1, log.topic_2, log.topic_3)
)
payloadHash = keccak256(log.data)
```

Store `payloadHash` by `eventKey`. An exact redelivery with the same key and payload hash is ignored. Reuse of the same event key with different data marks the batch invalid and suppresses dispatch. Including the emitting contract and every topic prevents batch-level events with no `orderId`—such as `BatchClosed`, `BatchSettled`, and inbox evidence—from colliding merely because an absent order topic decodes to zero. Authenticated Reactive cron ticks use the separate retry-only branch and never enter this ingestion-deduplication map.

## 5. Bounded agent state

Recommended ReactVM state:

```solidity
enum DispatchStatus { NONE, COLLECTING, READY, DISPATCHED, SETTLED, INVALID, EXPIRED }

struct SolverOrder {
    bytes32 orderId;
    address owner;
    address recipient;
    address tokenIn;
    address tokenOut;
    uint128 amountIn;
    uint128 minAmountOut;
    bool zeroForOne;
}

struct SolverBatch {
    DispatchStatus status;
    uint64 openedAtBlock;
    uint64 closedAtBlock;
    uint8 expectedOrderCount;
    uint160 referenceSqrtPriceX96;
    uint64 closedAtTimestamp;
    uint64 lastDispatchTimestamp;
    uint8 callbackAttempts;
    bytes32 pendingSolutionHash;
    bytes pendingEncodedSolution;
    bytes32[] orderIds;
}

uint64[MAX_PENDING_RETRY_BATCHES] pendingRetryBatchIds;
uint8 retryCursor;
uint8 pendingRetryCount;
mapping(uint64 batchId => uint8 slotPlusOne) retrySlotPlusOne;
```

The dispatcher enforces the same `MAX_BATCH_ORDERS` as the hook and `MAX_PENDING_RETRY_BATCHES = 8` from `BASELINE.md`. It never loops over unbounded log history or batch IDs. Retry selection scans only the fixed eight-slot ring.

## 6. Batch window

The MVP uses block-based intake and settlement windows, not wall-clock time.

- A batch begins when AuraHook emits its first `OrderParked` for the batch ID.
- `BatchReady` records that both directions exist but does not close the batch or permit dispatch.
- While a batch is one-sided, the hook reserves its final slot for the missing direction by rejecting a same-direction order when `orderCount == MAX_BATCH_ORDERS - 1`. Every admitted order must also leave at least `MIN_ORDER_LIFETIME_SECONDS` before its deadline and must preserve a nonempty prospective two-sided feasible price interval. Reaching the four-order cap therefore requires both directions; closure records `closedAtBlock` plus `closedAtTimestamp` and emits `BatchClosed` only after the canonical preflight confirms a nonempty feasible interval, every order deadline covers the fixed finality-plus-grace horizon, and every individual payout is encodable.
- After `block.number > openedAtBlock + MAX_BATCH_WINDOW`, anyone may call `closeBatch`. A two-sided batch transitions to `CLOSED`, records `closedAtBlock` and `closedAtTimestamp`, and emits `BatchClosed` only when the feasible interval remains nonempty, every order deadline is at least `closedAtTimestamp + MAX_FINALITY_LAG_SECONDS + SETTLEMENT_GRACE_SECONDS`, and every canonical individual payout fits `type(int128).max`; otherwise it transitions directly to `REFUNDABLE`. A one-sided batch also transitions directly to `REFUNDABLE` and is never dispatched.
- A two-sided batch becomes solver-eligible only after the matching `BatchClosed` event and all of the event's `orderCount` records have been ingested in frozen stored order and reproduce its `orderIdsHash`.
- A closed two-sided batch becomes refundable only when `block.timestamp > closedAtTimestamp + MAX_FINALITY_LAG_SECONDS + SETTLEMENT_GRACE_SECONDS`. The fixed 12-hour finality buffer precedes the five-minute settlement grace, so finalized closure observation cannot consume the callback opportunity.
- A preflight-valid two-sided `READY` batch must first close and wait through finality plus grace before refund eligibility. A one-sided or failed-preflight timeout closure transitions directly to `REFUNDABLE` without `BatchClosed`; this exception is determined inside `closeBatch`, not by a separate refund entrypoint or builder acknowledgment.
- Live demo batches contain no more than 4 orders.
- Contract and property tests cover no more than 8 orders.

`MAX_BATCH_WINDOW = 20`, `MIN_ORDER_LIFETIME_SECONDS = 13 hours`, `MAX_FINALITY_LAG_SECONDS = 12 hours`, `SETTLEMENT_GRACE_SECONDS = 5 minutes`, `CALLBACK_RETRY_DELAY_SECONDS = 60 seconds`, `MAX_CALLBACK_ATTEMPTS = 3`, and `MAX_PENDING_RETRY_BATCHES = 8` are recorded in `BASELINE.md`; a deployment must not override them without a normative specification change. Order and solution deadlines are Unix timestamps valid through equality (`block.timestamp <= deadline`); they are never compared with block numbers.

## 7. Deterministic clearing algorithm

All production-builder and simulation-worker arithmetic uses unsigned integers plus full-precision multiplication and division. JavaScript `number`, floating-point math, and decimal string rounding are forbidden. Use `bigint`.

### Step 1: validate the batch snapshot

1. Require the expected number of unique orders.
2. Require at least one order in each direction.
3. Require the two currencies match the configured pool.
4. Require nonzero input and minimum output amounts, each no larger than `type(int128).max`.
5. Require every order deadline to cover the closure's fixed finality-plus-grace horizon and reject a snapshot containing an already expired or inevitably expiring order.
6. Recompute per-direction input aggregates and require each to be at most `type(int128).max`. Recompute per-output-currency aggregate minimum liabilities in full-width `uint256`; they may exceed the signed-operation limit but remain bounded by `MAX_BATCH_ORDERS * type(int128).max` and must be processed in deterministic chunks.
7. Recompute the two-sided feasible interval and require it to be nonempty.
8. Preserve the exact frozen stored order committed by `BatchClosed`; detect duplicates without reordering, require the ingested array length to equal `orderCount`, and require `keccak256(abi.encode(orderIds)) == orderIdsHash`.

### Step 2: derive user price bounds

For token0 input order $i$:

$$
P \geq \frac{minOut_i}{amountIn_i}
$$

For token1 input order $j$:

$$
P \leq \frac{amountIn_j}{minOut_j}
$$

Compute the greatest lower bound and least upper bound by cross multiplication. Admission already rejects an incoming order that would make a prospective two-sided interval empty; the builder independently recomputes that invariant from the frozen batch and refuses dispatch on any mismatch.

### Step 3: derive bounded candidate prices

The one canonical target is the exact rational midpoint of the normalized feasible bounds, derived only from frozen user orders:

$$
P_{target} = \frac{l_n u_d + u_n l_d}{2 l_d u_d}
$$

where `L = l_n/l_d` is the greatest lower bound and `U = u_n/u_d` is the least upper bound. Both exist for a closable two-sided batch. Compute and GCD-reduce the midpoint with checked full-precision integer arithmetic. Token decimal normalization remains outside settlement math because the price convention uses raw token units.

If the reduced midpoint fits two nonzero `uint128` values, use that reduced midpoint. Otherwise apply the same deployable bounded fallback as `AuraHook`: select normalized `1/1` when it lies in the closed feasible interval; if it does not, select the normalized greatest lower bound `L`. Apply this rule before payout validation. `AuraHook` and the builder recompute and require this exact tuple. `BatchClosed.referenceSqrtPriceX96` is telemetry only; the closer, fourth-order submitter, a temporary pool-price movement, builder, and publisher cannot select the clearing price. If the canonical tuple is not fundable against finalized pool state, the builder publishes nothing and the batch eventually refunds.

Canonical builder and destination vectors use `M = type(int128).max` and `H = (M - 1) / 2`:

| Frozen feasible interval | Exact midpoint encoding | Canonical tuple |
| --- | --- | --- |
| `[1/2, 3/2]` | fits | `1/1` |
| `[(M-1)/M, M/(M-1)]` | oversized | `1/1` |
| `[1/M, M/1]` | oversized | `1/1` |
| `[(M-2)/H, M/(H-1)]` | oversized and excludes `1/1` | `(M-2)/H` |

The TypeScript builder fixtures and Solidity parity tests must assert these normalized tuples exactly; a decimal approximation, unreduced equivalent, or prior continued-fraction candidate is invalid.

### Step 4: calculate uniform payouts

For token0 input:

$$
payout_1 = \left\lfloor \frac{amountIn_0 \cdot p_n}{p_d} \right\rfloor
$$

For token1 input:

$$
payout_0 = \left\lfloor \frac{amountIn_1 \cdot p_d}{p_n} \right\rfloor
$$

Require each individual payout to meet its stored minimum and fit `type(int128).max`, which also guarantees `uint128[]` encoding. The hook performs the same calculation before closure: an invalid at-cap candidate reverts the incoming parking transaction, and an invalid timeout-close candidate becomes directly `REFUNDABLE` without `BatchClosed`. Aggregate payout totals use full-width `uint256` and may exceed the signed limit; builder fixtures and destination execution split PoolManager mint/burn/take work into deterministic frozen-order chunks no larger than `type(int128).max`. The payout array follows the frozen stored order committed by `BatchClosed`.

### Step 5: calculate direct match and residual

Let $I_0$ and $I_1$ be total inputs. Compare:

$$
I_0 p_n \quad\text{and}\quad I_1 p_d
$$

- Equal cross products produce zero residual.
- Token0 excess produces `residualZeroForOne = true` and:

$$
R_0 = I_0 - \left\lfloor \frac{I_1 p_d}{p_n} \right\rfloor
$$

- Token1 excess produces `residualZeroForOne = false` and:

$$
R_1 = I_1 - \left\lfloor \frac{I_0 p_n}{p_d} \right\rfloor
$$

The direct matched amounts are the non-residual portions. The destination recomputes these values.

### Step 6: select the price limit

The solver derives a bounded `sqrtPriceLimitX96` from the deployment configuration and user limits. It must:

- use the correct side of the current/reference price for the residual direction;
- remain within the Uniswap v4 valid tick range;
- not permit a pool move that would make the uniform liabilities underfunded;
- be included in the canonical solution hash.

If the agent cannot derive a safe bound, it suppresses dispatch. It never substitutes an unbounded price limit.

### Step 6a: production builder quotes residual execution and finalizes the price

ReactVM cannot access authoritative RPC state, liquidity, fee configuration, tick bitmaps, or initialized tick data. It therefore performs no residual quote. After finalized `BatchClosed` evidence, the production `AuraSolutionBuilder` reads slot0, active liquidity, LP and protocol fees, the tick bitmap, and every initialized tick crossed by the candidate through the configured Unichain Sepolia RPC and pinned v4 state-view interfaces.

For the sole destination-verifiable canonical candidate, the builder runs integer-identical pinned v4 swap math for the exact-input residual and proposed price limit. An RPC price estimate or decimal approximation is insufficient. It applies the realized-conservation equations in `docs/design.md` and rejects the proposal when that canonical price is underfunded; it never substitutes pool spot state or searches away from the hook-derived canonical candidate for another feasible price. The builder records the source block number and hash, re-reads that block immediately before inbox submission, and abandons the proposal if the finalized pool state changed.

`AuraSolutionInbox` emits the exact bounded solution, and ReactVM only verifies and transports it. `AuraHook` remains authoritative: it recomputes order math, executes against current PoolManager state, measures the actual `BalanceDelta`, and atomically reverts stale or underfunded execution. If the builder cannot obtain complete state or find a funded candidate, it publishes nothing and the refund path remains available.

### Step 7: construct the solution hash

The production builder, dispatcher, inbox fixtures, and destination use the identical canonical type hash and preimage:

```solidity
bytes32 constant SOLUTION_TYPEHASH = keccak256(
    "AuraBatchSolution(uint256 chainId,address auraHook,bytes32 poolId,uint64 batchId,uint64 deadline,uint128 priceNumerator,uint128 priceDenominator,bool residualZeroForOne,uint128 residualAmountIn,uint160 sqrtPriceLimitX96,bytes32 orderIdsHash,bytes32 payoutsHash)"
);

bytes32 orderIdsHash = keccak256(abi.encode(solution.orderIds));
bytes32 payoutsHash = keccak256(abi.encode(solution.payouts));

bytes32 expectedSolutionHash = keccak256(
    abi.encode(
        SOLUTION_TYPEHASH,                 // bytes32
        uint256(UNICHAIN_SEPOLIA_CHAIN_ID),// uint256
        auraHook,                          // address
        poolId,                            // bytes32
        solution.batchId,                  // uint64
        solution.deadline,                 // uint64
        solution.priceNumerator,           // uint128
        solution.priceDenominator,         // uint128
        solution.residualZeroForOne,       // bool
        solution.residualAmountIn,         // uint128
        solution.sqrtPriceLimitX96,        // uint160
        orderIdsHash,                      // bytes32
        payoutsHash                        // bytes32
    )
);
```

The literal type string, outer `abi.encode`, field order, Solidity widths, and ordered-array hashes are normative and match `docs/design.md`. The dispatcher must not use packed encoding or alternate integer widths. The `solutionHash` field equals `expectedSolutionHash` and cannot hash itself.

## 8. Callback payload

The Reactive callback payload uses the exact destination ABI:

```solidity
bytes memory payload = abi.encodeCall(
    IAuraHook.settleBatch,
    (address(0), solution)
);
```

The first address is reserved for Reactive Network to inject the RVM identity. The dispatcher must not place an arbitrary solver address there.

Dispatch event:

```solidity
emit Callback(
    UNICHAIN_SEPOLIA_CHAIN_ID,
    auraHook,
    CALLBACK_GAS_LIMIT,
    payload
);
```

Before the first emission, allocate exactly one vacant slot in the fixed retry ring, store the batch ID and reverse slot index, store the exact encoded solution and hash, set `callbackAttempts = 1`, record `lastDispatchTimestamp`, and set the ReactVM batch status to `DISPATCHED`. If all eight slots are occupied, keep the candidate out of `DISPATCHED`, mark its local transport state `EXPIRED`, emit no callback, and never overwrite or evict another pending batch; the on-chain batch remains governed by its permissionless refund boundary. `DISPATCHED` means pending, not terminal. An authenticated cron tick may perform the bounded, round-robin `DISPATCHED -> READY -> DISPATCHED` retry transition in Section 11 using the identical stored payload. The dispatcher must never change price, arrays, price limit, or hash. Destination replay protection remains mandatory because a late success followed by an evidence delay can produce a harmless duplicate attempt.

## 9. Authentication model

The destination accepts a solution only when both conditions are true:

```text
msg.sender == configured Reactive callback proxy
injected rvmId == configured Aura Reactive deployment identity
```

An authorized callback is permission to attempt settlement, not permission to bypass any mathematical or state validation.

## 10. Failure modes and fallbacks

External Circle, Arc, or Chainalysis services are not dependencies of the solver loop. The production builder reads finalized Aura evidence and complete Unichain pool state, publishes through AuraSolutionInbox, and the dispatcher transports the exact proposal through the authenticated Reactive callback path. Funding, bridging, screening, and monitoring services may enrich operator workflows but cannot alter the canonical batch calculation or retry rules.

| Failure | Required behavior | User-fund outcome |
| --- | --- | --- |
| No opposite-side order | Do not dispatch. Wait for the block window, then allow hook timeout. | Owner refunds input. |
| Empty feasible price interval | Mark candidate invalid and do not dispatch. | Batch expires and becomes refundable. |
| Builder RPC or state-view failure | Publish no proposal; never substitute partial state or a spot-price estimate. | Funds stay parked and refundable after timeout. |
| Inbox publisher outage | Publish no proposal; do not introduce a privileged direct-settlement bypass. | Funds stay parked and refundable after timeout. |
| Gas price or callback funding spike | Delay dispatch while the solution remains valid. Do not mark settled. | Funds stay parked and refundable after timeout. |
| Callback transaction reverts or no success evidence arrives | Keep destination batch nonterminal. A later authenticated cron tick selects the batch through the bounded round-robin retry ring after its retry delay and reopens the identical pending payload. | Atomic revert preserves backing; destination replay protection makes late duplicates harmless. |
| Residual output is insufficient | Destination reverts settlement. Do not lower user payouts. | Funds stay parked. |
| Duplicate event | Ignore exact duplicate. | No effect. |
| Conflicting duplicate | Mark batch invalid and suppress dispatch. | Refund path remains. |
| Chain reorganization | Rebuild nonterminal batch state from finalized logs before retry. | Destination replay and membership checks prevent double settlement. |
| Wrong chain, hook, or topic | Ignore and emit diagnostic evidence in tests only. | No effect. |
| Callback replay | Destination rejects used solution or terminal batch. | No effect. |
| Dispatcher outage | No privileged fallback settlement in the MVP. | Timeout refund is the safety path. |

## 11. Retry policy

- A callback is considered pending after emission, not successful. Only an observed configured-hook `BatchSettled(batchId, solutionHash, ...)` transitions `DISPATCHED -> SETTLED`.
- The dispatcher stores the exact canonical encoded solution, solution hash, `lastDispatchTimestamp`, and `callbackAttempts`. `CALLBACK_RETRY_DELAY_SECONDS = 60 seconds` and `MAX_CALLBACK_ATTEMPTS = 3`, including the first attempt.
- Every `DISPATCHED` batch occupies exactly one of `MAX_PENDING_RETRY_BATCHES = 8` fixed slots, and `retrySlotPlusOne[batchId]` prevents duplicate insertion. Settlement evidence, attempt exhaustion, solution expiry, or the refund boundary clears that exact slot and reverse index.
- Because Reactive transport exposes no authoritative revert receipt, an authenticated cron log wakes the bounded selector. Starting at `retryCursor`, the selector inspects at most eight slots and chooses at most one eligible `DISPATCHED` batch. Empty, terminal, expired, capped, or not-yet-due slots are skipped without external calls. After the scan, `retryCursor` advances to the slot after the selected slot, or after the last inspected slot when none is eligible, so concurrent pending batches receive deterministic round-robin consideration and no lower batch ID can starve another.
- A selected batch may transition `DISPATCHED -> READY` only when no matching `BatchSettled` has been observed, `block.timestamp >= lastDispatchTimestamp + CALLBACK_RETRY_DELAY_SECONDS`, `callbackAttempts < MAX_CALLBACK_ATTEMPTS`, `block.timestamp <= solution.deadline`, and `block.timestamp < closedAtTimestamp + MAX_FINALITY_LAG_SECONDS + SETTLEMENT_GRACE_SECONDS`. Retry time is the ReactVM execution timestamp, not an untrusted cron field.
- The dispatcher increments `callbackAttempts`, updates `lastDispatchTimestamp`, returns the selected batch to `DISPATCHED`, and emits the byte-identical stored callback. It never recomputes price, payout, residual, price limit, arrays, or hash.
- A delayed settlement-evidence log can race a retry tick; destination terminal-batch and solution-hash replay protection makes the second callback revert without changing funds.
- After the attempt cap, solution deadline, or refund boundary, transition the local batch to `EXPIRED`, clear its retry slot, and emit no more callbacks. A full retry ring suppresses a new initial dispatch rather than overwriting pending state. No queue or retry transition may suppress, reset, or delay the permissionless refund path.

## 12. Local solver simulation

The local script is `scripts/simulate-solver.js` or a TypeScript equivalent. It shares the production builder's pure math package but has no publisher credential or production authority. It must consume JSON fixtures containing only integer strings and output:

- frozen stored-order IDs and the matching `BatchClosed.orderIdsHash`;
- feasible price interval;
- selected rational price;
- payouts;
- matched amounts;
- residual direction and input;
- solution hash inputs;
- a pass/fail conservation preview.

Required fixtures:

1. Perfect 1:1 match with zero residual.
2. Token0 residual.
3. Token1 residual.
4. Non-18-decimal tokens.
5. Rounding dust.
6. Empty price interval.
7. Duplicate order.
8. Maximum bounded batch.
9. Overflow boundary.
10. Expired solution.

The JavaScript results must be checked against Solidity `AuraClearingMath` vectors.

## 13. Observability

The agent and destination must expose enough evidence to answer:

- Which batch and exact orders were considered?
- What uniform price and rounding rule were used?
- How much volume matched peer-to-peer?
- What residual amount touched the pool and in which direction?
- Which callback transaction was emitted?
- Did the destination settle, revert, expire, or become refundable?

Production secrets, signing material, private RPC URLs, and funded account details never appear in logs, screenshots, fixtures, or committed files.

## 14. Acceptance criteria

The Reactive integration is complete only when:

- subscription tests route only the configured Reactive chain/cron contract/topic into retry and only configured Unichain hook/inbox sources into ingestion; mixed-source logs are rejected before mutation;
- event-kind-scoped ingestion is idempotent: exact redelivery is ignored, conflicting payload reuse invalidates the batch, and distinct batch-level event topics cannot collide;
- zero minimums, deadlines shorter than `MIN_ORDER_LIFETIME_SECONDS`, prospectively empty feasible intervals, and per-direction input aggregates above `type(int128).max` are rejected before custody; a one-sided batch reserves its final slot for the missing direction; no `BatchClosed` is emitted when a canonical individual payout is unencodable, while aggregate payout liabilities above the signed limit are conserved in full width and executed through deterministic chunks;
- the hook and builder derive the same sole canonical price from the frozen feasible-interval midpoint plus the oversized bounded fallback, pass every canonical vector above, ignore close-time pool spot telemetry, reject alternate feasible prices, and the builder's fork quote matches pinned v4 execution for both residual directions;
- unauthorized inbox publication and altered inbox payloads are rejected;
- the dispatcher produces the same canonical envelope as the builder and Solidity math without quoting pool state;
- the callback reserves the first address for RVM injection;
- wrong proxy and wrong RVM callbacks revert;
- one perfect CoW batch settles with no pool swap;
- both residual directions settle with exactly one pool swap;
- a callback revert leaves all inputs backed and exercises the authenticated delayed retry path no more than three total attempts; concurrent pending batches occupy unique retry slots, each cron tick performs no more than eight inspections and one retry, the cursor advances deterministically, and no occupied slot starves;
- a live Unichain Sepolia callback and destination settlement hash are recorded in `docs/demo-runbook.md`.
