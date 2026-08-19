# Aura Reactive Solver Agent Specification

Status: normative MVP agent specification  
Version: 1.2  
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

The hook emits this only when the batch has both directions. `referenceSqrtPriceX96` is a deterministic pool snapshot used to select a candidate inside the users' feasible interval. It is not trusted by the destination in place of payout and conservation validation.

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

`BatchClosed`, rather than `BatchReady`, is the sole solution-production trigger. Its close block, close timestamp, count, and hash describe immutable membership. The builder and dispatcher preserve the hook's frozen stored order and verify `keccak256(abi.encode(orderIds))` against `orderIdsHash`.

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

Every accepted log must satisfy:

- `log.chain_id == UNICHAIN_SEPOLIA_CHAIN_ID`;
- `log._contract` is either the immutable AuraHook or AuraSolutionInbox expected for the decoded topic;
- `log.topic_0` is one of the configured Aura batch, destination-evidence, `SolutionProposed`, or Reactive cron topics;
- the batch ID and order ID decode without truncation;
- the batch is not terminal;
- the order ID has not already been ingested.

The state key is:

```text
keccak256(chainId, auraHook, batchId, orderId)
```

Duplicate delivery is ignored. Conflicting duplicate content marks the batch invalid and suppresses dispatch.

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
```

The dispatcher enforces the same `MAX_BATCH_ORDERS` as the hook. It never loops over an unbounded log history.

## 6. Batch window

The MVP uses block-based intake and settlement windows, not wall-clock time.

- A batch begins when AuraHook emits its first `OrderParked` for the batch ID.
- `BatchReady` records that both directions exist but does not close the batch or permit dispatch.
- Reaching the four-order cap freezes membership immediately only for a two-sided batch; it records `closedAtBlock` plus `closedAtTimestamp` and emits `BatchClosed`. A full one-sided batch remains open but accepts no fifth order, then becomes refundable at the intake timeout without entering dispatch.
- After `block.number > openedAtBlock + MAX_BATCH_WINDOW`, anyone may call `closeBatch`. A two-sided batch transitions to `CLOSED`, records `closedAtBlock` and `closedAtTimestamp`, and emits `BatchClosed`; a one-sided batch transitions directly to `REFUNDABLE` and is never dispatched.
- A two-sided batch becomes solver-eligible only after the matching `BatchClosed` event and all of the event's `orderCount` records have been ingested in frozen stored order and reproduce its `orderIdsHash`.
- A closed two-sided batch becomes refundable only when `block.timestamp > closedAtTimestamp + MAX_FINALITY_LAG_SECONDS + SETTLEMENT_GRACE_SECONDS`. The fixed 12-hour finality buffer precedes the five-minute settlement grace, so finalized closure observation cannot consume the callback opportunity.
- The refund entrypoint cannot transition a two-sided `READY` batch directly to `REFUNDABLE`; it must first be closed, and the finality-plus-grace boundary must elapse. This gives closure deterministic precedence over refund eligibility without trusting a builder-supplied finality acknowledgment.
- Live demo batches contain no more than 4 orders.
- Contract and property tests cover no more than 8 orders.

`MAX_BATCH_WINDOW = 20`, `MAX_FINALITY_LAG_SECONDS = 12 hours`, `SETTLEMENT_GRACE_SECONDS = 5 minutes`, `CALLBACK_RETRY_DELAY_SECONDS = 60 seconds`, and `MAX_CALLBACK_ATTEMPTS = 3` are recorded in `BASELINE.md`; a deployment must not override them without a normative specification change. Order and solution deadlines are Unix timestamps valid through equality (`block.timestamp <= deadline`); they are never compared with block numbers.

## 7. Deterministic clearing algorithm

All production-builder and simulation-worker arithmetic uses unsigned integers plus full-precision multiplication and division. JavaScript `number`, floating-point math, and decimal string rounding are forbidden. Use `bigint`.

### Step 1: validate the batch snapshot

1. Require the expected number of unique orders.
2. Require at least one order in each direction.
3. Require the two currencies match the configured pool.
4. Require nonzero input and minimum output amounts, each no larger than `type(int128).max`.
5. Recompute per-direction input aggregates and require each to be at most `type(int128).max`. Recompute per-output-currency aggregate minimum liabilities in full-width `uint256`; they may exceed the signed-operation limit but remain bounded by `MAX_BATCH_ORDERS * type(int128).max` and must be processed in deterministic chunks.
6. Preserve the exact frozen stored order committed by `BatchClosed`; detect duplicates without reordering, require the ingested array length to equal `orderCount`, and require `keccak256(abi.encode(orderIds)) == orderIdsHash`.

### Step 2: derive user price bounds

For token0 input order $i$:

$$
P \geq \frac{minOut_i}{amountIn_i}
$$

For token1 input order $j$:

$$
P \leq \frac{amountIn_j}{minOut_j}
$$

Compute the greatest lower bound and least upper bound by cross multiplication. If the interval is empty, mark the candidate invalid and do not dispatch.

### Step 3: derive bounded candidate prices

The one canonical target comes from the stored `BatchClosed.referenceSqrtPriceX96`, so the destination can reproduce price selection without trusting the publisher:

$
P_{ref} = \frac{referenceSqrtPriceX96^2}{2^{192}}
$

Token decimal normalization must be explicit. The on-chain price convention remains raw token units, so any human decimal formatting is outside the settlement math.

Clamp the target to the feasible interval:

$
P_{target} = clamp(P_{ref}, P_{lower}, P_{upper})
$

The exact target need not be representable by two `uint128` values. Generate exactly one deterministic bounded rational using the continued-fraction/Stern--Brocot best approximation with `1 <= p_n,p_d <= type(uint128).max`, constrained to the closed feasible interval. Reduce every candidate by `gcd(p_n, p_d)` before comparison, encoding, or hashing, and require `gcd(p_n, p_d) == 1` in both builder and destination validation. Normalize exact interval bounds the same way. Rank by absolute error from `P_target` using full-precision cross products, then by smaller numeric rational, then lexicographically by smaller normalized numerator and denominator. `AuraHook` recomputes and requires this exact tuple; neither the builder nor publisher may search away from it for another funded price. If the canonical tuple is not fundable against finalized pool state, the builder publishes nothing and the batch eventually refunds.

### Step 4: calculate uniform payouts

For token0 input:

$$
payout_1 = \left\lfloor \frac{amountIn_0 \cdot p_n}{p_d} \right\rfloor
$$

For token1 input:

$$
payout_0 = \left\lfloor \frac{amountIn_1 \cdot p_d}{p_n} \right\rfloor
$$

Require each individual payout to meet its stored minimum and the installed PoolManager signed-operation limit. Aggregate payout totals use full-width `uint256` and may exceed that limit; builder fixtures and destination execution split PoolManager mint/burn/take work into deterministic frozen-order chunks no larger than `type(int128).max`. The payout array follows the frozen stored order committed by `BatchClosed`.

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

For the sole destination-verifiable canonical candidate, the builder runs integer-identical pinned v4 swap math for the exact-input residual and proposed price limit. An RPC price estimate or decimal approximation is insufficient. It applies the realized-conservation equations in `docs/design.md` and rejects the proposal when that canonical price is underfunded; it never searches away from the stored closure reference for another feasible price. The builder records the source block number and hash, re-reads that block immediately before inbox submission, and abandons the proposal if the finalized pool state changed.

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

Before the first emission, store the exact encoded solution and hash, set `callbackAttempts = 1`, record `lastDispatchTimestamp`, and set the ReactVM batch status to `DISPATCHED`. `DISPATCHED` means pending, not terminal. An authenticated cron tick may perform the bounded `DISPATCHED -> READY -> DISPATCHED` retry transition in Section 11 using the identical stored payload. The dispatcher must never change price, arrays, price limit, or hash. Destination replay protection remains mandatory because a late success followed by an evidence delay can produce a harmless duplicate attempt.

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
| Callback transaction reverts or no success evidence arrives | Keep destination batch nonterminal. The next authenticated cron tick after the retry delay reopens the pending ReactVM state for the identical bounded retry. | Atomic revert preserves backing; destination replay protection makes late duplicates harmless. |
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
- Because Reactive transport exposes no authoritative revert receipt to this contract, an authenticated cron log is the bounded retry trigger. On a tick, a batch may transition `DISPATCHED -> READY` only when no matching `BatchSettled` has been observed, `block.timestamp >= lastDispatchTimestamp + CALLBACK_RETRY_DELAY_SECONDS`, `callbackAttempts < MAX_CALLBACK_ATTEMPTS`, `block.timestamp <= solution.deadline`, and `block.timestamp < closedAtTimestamp + MAX_FINALITY_LAG_SECONDS + SETTLEMENT_GRACE_SECONDS`. The cron log only wakes the contract; retry time is the ReactVM execution timestamp, not an untrusted event field.
- The dispatcher then increments `callbackAttempts`, updates `lastDispatchTimestamp`, returns to `DISPATCHED`, and emits the byte-identical stored callback. It never recomputes price, payout, residual, price limit, arrays, or hash.
- A delayed settlement-evidence log can race a retry tick; destination terminal-batch and solution-hash replay protection makes the second callback revert without changing funds.
- After the attempt cap, solution deadline, or refund boundary, transition the local batch to `EXPIRED` and emit no more callbacks. No retry may suppress, reset, or delay the permissionless refund path.

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

- subscription tests accept only the configured chain, hook, and topics;
- duplicate ingestion is idempotent;
- zero minimums and per-direction input aggregates above `type(int128).max` are rejected before solution production; aggregate payout liabilities above that limit are conserved in full width and executed through deterministic signed-range chunks;
- the hook and builder derive the same sole canonical price from stored `BatchClosed` evidence, reject alternate feasible prices, and the builder's fork quote matches pinned v4 execution for both residual directions;
- unauthorized inbox publication and altered inbox payloads are rejected;
- the dispatcher produces the same canonical envelope as the builder and Solidity math without quoting pool state;
- the callback reserves the first address for RVM injection;
- wrong proxy and wrong RVM callbacks revert;
- one perfect CoW batch settles with no pool swap;
- both residual directions settle with exactly one pool swap;
- a callback revert leaves all inputs backed and exercises the authenticated delayed retry path no more than three total attempts;
- a live Unichain Sepolia callback and destination settlement hash are recorded in `docs/demo-runbook.md`.
