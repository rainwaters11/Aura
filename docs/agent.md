# Aura Reactive Solver Agent Specification

Status: normative MVP agent specification  
Version: 1.0  
Companion protocol: `docs/design.md`

## 1. Persona and objective

The Aura solver is a deterministic, bounded batch auctioneer. Its job is to observe Aura order events on Unichain Sepolia, construct one mathematically valid uniform-price solution for a closed two-sided batch, and dispatch that proposal through the Reactive Network callback path.

The agent is not a custodian and is not trusted to decide final balances. It cannot move user funds directly. `AuraHook` independently validates order membership, price, payouts, residual direction, residual amount, deadlines, replay state, and realized PoolManager conservation.

Success means:

- compatible flow is matched peer-to-peer at one price;
- only the residual reaches the pool curve;
- every user minimum is honored;
- the destination callback is authenticated;
- a failed proposal leaves the batch and funds recoverable.

## 2. Runtime split

Aura uses two cooperating solver surfaces:

| Surface | Responsibility | Authority |
| --- | --- | --- |
| `ReactiveBatchDispatcher.sol` in ReactVM | Subscribe to Aura logs, reconstruct bounded batch state, choose or encode the deterministic candidate, and emit a callback. | Can propose only. |
| Local simulation worker | Reproduce the same algorithm against fixtures and forked state before deployment. | No production authority. Used for tests and debugging. |

The local worker must not become an undisclosed privileged relayer. If a future design adds signed off-chain solutions, that is a protocol change requiring updates to `docs/design.md`.

## 3. Authoritative event sources

The dispatcher subscribes only to the configured Unichain Sepolia chain ID and immutable AuraHook address.

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
    uint8 orderCount,
    bytes32 orderIdsHash,
    uint160 referenceSqrtPriceX96
);
```

`BatchClosed`, rather than `BatchReady`, is the sole solution-production trigger. Its close block, count, and hash describe immutable membership. The dispatcher preserves the hook's frozen stored order and verifies `keccak256(abi.encode(orderIds))` against `orderIdsHash` before dispatch.

## 4. Subscription rules

The constructor or initialization path subscribes through the Reactive service when not running in ReactVM, following the `AbstractReactive` pattern.

Every accepted log must satisfy:

- `log.chain_id == UNICHAIN_SEPOLIA_CHAIN_ID`;
- `log._contract == auraHook`;
- `log.topic_0` is one of the configured Aura event topics;
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
    bytes32[] orderIds;
}
```

The dispatcher enforces the same `MAX_BATCH_ORDERS` as the hook. It never loops over an unbounded log history.

## 6. Batch window

The MVP uses block-based intake and settlement windows, not wall-clock time.

- A batch begins when AuraHook emits its first `OrderParked` for the batch ID.
- `BatchReady` records that both directions exist but does not close the batch or permit dispatch.
- Reaching the four-order cap freezes membership immediately, records `closedAtBlock`, and emits `BatchClosed`.
- After `block.number > openedAtBlock + MAX_BATCH_WINDOW`, anyone may call `closeBatch`. A two-sided batch transitions to `CLOSED`, records `closedAtBlock`, and emits `BatchClosed`; a one-sided batch transitions directly to `REFUNDABLE` and is never dispatched.
- A two-sided batch becomes solver-eligible only after the matching `BatchClosed` event and all of the event's `orderCount` records have been ingested in frozen stored order and reproduce its `orderIdsHash`.
- A closed two-sided batch receives `SETTLEMENT_GRACE_BLOCKS` before refunds can win. It becomes refundable only when `block.number > max(openedAtBlock + MAX_BATCH_WINDOW, closedAtBlock + SETTLEMENT_GRACE_BLOCKS)`.
- The refund entrypoint cannot transition a two-sided `READY` batch directly to `REFUNDABLE`; it must first be closed, and the grace boundary must elapse. This gives closure deterministic precedence over refund eligibility.
- Live demo batches contain no more than 4 orders.
- Contract and property tests cover no more than 8 orders.

`MAX_BATCH_WINDOW = 20` and `SETTLEMENT_GRACE_BLOCKS = 20` are recorded in `BASELINE.md`; a deployment must not override either value without a normative specification change.

## 7. Deterministic clearing algorithm

All arithmetic uses unsigned integers and full-precision multiplication and division. JavaScript `number`, floating-point math, and decimal string rounding are forbidden in the simulation worker. Use `bigint`.

### Step 1: validate the batch snapshot

1. Require the expected number of unique orders.
2. Require at least one order in each direction.
3. Require the two currencies match the configured pool.
4. Require nonzero input and minimum output amounts.
5. Preserve the exact frozen stored order committed by `BatchClosed`; detect duplicates without reordering, require the ingested array length to equal `orderCount`, and require `keccak256(abi.encode(orderIds)) == orderIdsHash`.

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

Convert `referenceSqrtPriceX96` to a token1-per-token0 rational target without floating point:

$$
P_{ref} = \frac{sqrtPriceX96^2}{2^{192}}
$$

Token decimal normalization must be explicit. The on-chain price convention remains raw token units, so any human decimal formatting is outside the settlement math.

Clamp the target to the feasible interval:

$$
P_{target} = clamp(P_{ref}, P_{lower}, P_{upper})
$$

The exact target need not be representable by two `uint128` values. Generate a deterministic bounded rational using the continued-fraction/Stern--Brocot best approximation with `1 <= p_n,p_d <= type(uint128).max`, constrained to the closed feasible interval. Reduce every candidate by `gcd(p_n, p_d)` before comparison, deduplication, encoding, or hashing, and require `gcd(p_n, p_d) == 1` in both the solver and destination validation. Normalize exact interval bounds the same way. Rank candidates by absolute error from `P_target` using full-precision cross products, then by smaller numeric rational, then lexicographically by smaller normalized numerator and denominator. The canonical `solutionHash` includes only this normalized tuple. If no bounded rational lies in the interval, the candidate is invalid. Never reject a batch merely because the unreduced `sqrtPriceX96^2 / 2^192` components exceed `uint128`.

### Step 4: calculate uniform payouts

For token0 input:

$$
payout_1 = \left\lfloor \frac{amountIn_0 \cdot p_n}{p_d} \right\rfloor
$$

For token1 input:

$$
payout_0 = \left\lfloor \frac{amountIn_1 \cdot p_d}{p_n} \right\rfloor
$$

Require each payout to meet its stored minimum and the installed PoolManager signed-operation limit. The payout array follows the frozen stored order committed by `BatchClosed`.

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

### Step 6a: quote residual execution and finalize the price

The starting spot price is not an executable average price. For every bounded candidate, run the installed v4 swap math against the finalized pool state, including the configured LP fee, protocol fee, tick crossings, liquidity, exact-input residual, and proposed price limit. Use integer arithmetic identical to the pinned v4 dependency; an RPC quote or decimal estimate is insufficient.

Apply the realized-conservation equations in `docs/design.md` to the simulated output and the uniformly rounded payouts. Reject a candidate when quoted output does not fully back every payout. Search deterministically away from $P_{target}$ within the feasible interval (toward lower prices for a token0 residual and toward higher prices for a token1 residual), using bounded-rational mediants and the same tie rule, and select the closest candidate that passes conservation. Stop after the finite continued-fraction boundary search over the `uint128` domain; if none passes, do not dispatch. Re-quote immediately before callback emission and suppress dispatch if pool state changed. The hook still measures the actual `BalanceDelta` and reverts on underfunding.

### Step 7: construct the solution hash

The dispatcher and destination use the identical canonical type hash and preimage:

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

Before emitting, set the ReactVM batch status to `DISPATCHED` to suppress duplicate callbacks. Destination replay protection remains mandatory because ReactVM state is not the final security boundary.

## 9. Authentication model

The destination accepts a solution only when both conditions are true:

```text
msg.sender == configured Reactive callback proxy
injected rvmId == configured Aura Reactive deployment identity
```

An authorized callback is permission to attempt settlement, not permission to bypass any mathematical or state validation.

## 10. Failure modes and fallbacks

External Circle, Arc, or Chainalysis services are not dependencies of the solver loop. The dispatcher reads Aura events and Unichain state, computes a bounded deterministic solution, and submits through the authenticated Reactive callback path. Funding, bridging, screening, and monitoring services may enrich operator workflows but cannot alter the canonical batch calculation or retry rules.

| Failure | Required behavior | User-fund outcome |
| --- | --- | --- |
| No opposite-side order | Do not dispatch. Wait for the block window, then allow hook timeout. | Owner refunds input. |
| Empty feasible price interval | Mark candidate invalid and do not dispatch. | Batch expires and becomes refundable. |
| Gas price or callback funding spike | Delay dispatch while the solution remains valid. Do not mark settled. | Funds stay parked and refundable after timeout. |
| Callback transaction reverts | Keep destination batch nonterminal. Record failure evidence and retry only if the same solution remains valid. | Atomic revert preserves backing. |
| Residual output is insufficient | Destination reverts settlement. Do not lower user payouts. | Funds stay parked. |
| Duplicate event | Ignore exact duplicate. | No effect. |
| Conflicting duplicate | Mark batch invalid and suppress dispatch. | Refund path remains. |
| Chain reorganization | Rebuild nonterminal batch state from finalized logs before retry. | Destination replay and membership checks prevent double settlement. |
| Wrong chain, hook, or topic | Ignore and emit diagnostic evidence in tests only. | No effect. |
| Callback replay | Destination rejects used solution or terminal batch. | No effect. |
| Dispatcher outage | No privileged fallback settlement in the MVP. | Timeout refund is the safety path. |

## 11. Retry policy

- A callback is considered pending after emission, not successful.
- Observe `BatchSettled` before marking `SETTLED`.
- Retry only the exact same canonical solution while its deadline and batch status permit.
- Do not recompute a different price for the same closed batch without a new solution hash and an explicit retry policy accepted by `AuraHook`.
- Cap retries before `max(openedAtBlock + MAX_BATCH_WINDOW, closedAtBlock + SETTLEMENT_GRACE_BLOCKS)`.
- Never suppress or delay the permissionless refund path after the deterministic grace boundary.

## 12. Local solver simulation

The local script is `scripts/simulate-solver.js` or a TypeScript equivalent. It must consume JSON fixtures containing only integer strings and output:

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
- the agent produces the same vector outputs as Solidity math;
- the callback reserves the first address for RVM injection;
- wrong proxy and wrong RVM callbacks revert;
- one perfect CoW batch settles with no pool swap;
- both residual directions settle with exactly one pool swap;
- a callback revert leaves all inputs backed and refundable;
- a live Unichain Sepolia callback and destination settlement hash are recorded in `docs/demo-runbook.md`.
