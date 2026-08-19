# Aura Protocol and System Architecture

Status: normative MVP specification  
Version: 1.4  
Baseline: `rainwaters11/Argos_LTS@4603269e8af7dbbff6e337546fd9d7be27deb34c`  
Target: Unichain Sepolia, chain ID 1301  
Compiler: Solidity 0.8.30, Cancun EVM

## 1. Purpose and authority

Aura is a bounded, discrete batch-auction settlement hook for Uniswap v4. It parks exact-input orders as ERC-6909 claims, clears compatible flow at one uniform price, and sends only the unmatched residual to the pool curve. The MVP targets the Sustainable Liquidity and MEV Protection track.

This document is the protocol source of truth. Contract code, tests, solver behavior, UI copy, and deployment scripts must conform to it. A change to a protocol invariant requires a dedicated pull request that updates this document and its tests before implementation merges.

Document precedence is:

1. `docs/design.md` for on-chain behavior, accounting, state, and invariants.
2. `docs/agent.md` for Reactive Network ingestion, solution production, and dispatch.
3. `docs/skill.md` for commands, tool permissions, and verification evidence.
4. Implementation comments and user-interface copy.

When two documents disagree, the higher item controls. Ambiguity is a build blocker, not permission to guess.

## 2. Locked MVP boundary

### Included

- One `AuraHook` deployment bound immutably to one `PoolKey`.
- One authorized `AuraRouter` for authenticated user attribution.
- Exact-input, full-fill orders only.
- Token0-to-token1 and token1-to-token0 orders in the same pool.
- At most 8 orders per batch in tests and at most 4 in the live demo.
- One rational uniform price per settled batch.
- Peer-to-peer Coincidence of Wants matching.
- At most one residual exact-input swap against the Uniswap v4 pool.
- ERC-6909 custody for parked inputs and settled output claims.
- Authenticated Reactive Network callback dispatch.
- User claims and owner-controlled timeout refunds.

### Excluded

- Exact-output orders, partial fills, multi-hop swaps, multiple pools, solver competition, arbitrary solver interactions, gas sponsorship, mainnet deployment, and production economic optimization.
- Automatic AMM pass-through for one-sided batches. A batch without both directions remains open until timeout and becomes refundable.

### External integration boundary

- The public Unichain Sepolia deployment uses Circle's official testnet USDC at `0x31d0220469e10c4E71834a79b1f276d740d3768F`; local tests use controlled mock tokens.
- Circle App Kit, Bridge Kit, Wallets, Gateway, CCTP, and Paymaster integrations are optional UX or operator layers. No Circle SDK or bridge dependency belongs in the hook, router, clearing library, solution validation, claims, or refunds.
- Chainalysis KYT, Address Screening, and Hexagate monitoring are deferred. No synchronous screening call may gate `_beforeSwap`, settlement, claims, or timeout refunds.
- Future compliance or monitoring adapters must fail independently from Aura accounting and cannot make custody irrecoverable.

## 3. Components and trust boundaries

| Component | Responsibility | Trust model |
| --- | --- | --- |
| `AuraRouter` | Builds authenticated order metadata from `msg.sender` and calls the v4 swap path. | Only router accepted by the hook. It cannot choose a different owner. |
| `AuraHook` | Parks inputs, validates solutions, performs residual execution, accounts for claims, and processes refunds. | Protocol authority. It verifies every externally supplied field. |
| `AuraClearingMath` | Full-precision rational-price, payout, residual, and conservation calculations. | Pure library with fuzz and invariant coverage. |
| `PoolManager` | Holds underlying assets, ERC-6909 claims, pool liquidity, and flash-accounting deltas. | Canonical Uniswap v4 dependency. |
| Production `AuraSolutionBuilder` | Reads finalized Unichain state through RPC and the pinned v4 state-view interfaces, simulates complete residual execution, and publishes a bounded solution. | Operational proposal source only. It never holds funds, and every proposal remains untrusted by `AuraHook`. |
| `AuraSolutionInbox` | Accepts a bounded encoded solution from the configured MVP publisher and emits `SolutionProposed` for Reactive transport. | Rate-limited/authenticated event ingress only. Compromise can waste callback funding but cannot bypass destination validation or block refunds. |
| `ReactiveBatchDispatcher` | Subscribes to Aura batch events plus `SolutionProposed`, verifies the frozen membership and canonical solution envelope, and sends the exact bounded callback. | Authenticated transport only. ReactVM does not quote Uniswap pool state. |
| Reactive callback proxy | Delivers the callback and injects the RVM identity. | Authorized transport. Both proxy and RVM identity are checked. |
| Frontend | Places orders and displays indexed state. | Untrusted convenience layer. Never an accounting source. |

## 4. Hook lifecycle

### 4.1 Hook permissions

`AuraHook` inherits OpenZeppelin `BaseAsyncSwap`, which inherits `BaseHook`. Permissions are fixed to:

```solidity
beforeSwap: true
beforeSwapReturnDelta: true
```

All other hook permission flags are false. Deployment must mine an address whose low bits match those flags and tests must compare the deployed address with `Hooks.validateHookPermissions` behavior.

### 4.2 Order entry and identity

Users do not call the hook directly. They call `AuraRouter.placeOrder`.

The router:

1. Uses `msg.sender` as `owner`.
2. Uses the requested recipient, or defaults it to `owner`.
3. Increments the owner's nonce.
4. Builds versioned `AuraOrderData`.
5. Routes an exact-input swap with the encoded data as `hookData`.

The hook requires `sender == address(auraRouter)`. An address decoded from `hookData` is never accepted as proof of identity by itself.

`AuraOrderData.deadline` and `BatchSolution.deadline` are Unix timestamps in seconds. An order or solution is valid while `block.timestamp <= deadline` and expired only when `block.timestamp > deadline`. Batch intake, close, and dispatcher retry counters use their separately specified block or timestamp clocks; implementations must never compare a Unix deadline with `block.number`.

### 4.3 `_beforeSwap` interception

For `params.amountSpecified < 0`:

1. Verify the caller is the authorized router.
2. Verify the supplied `PoolKey` hashes to the immutable Aura pool ID.
3. Decode and validate `AuraOrderData`.
4. Derive `amountIn = uint256(-params.amountSpecified)` with checked conversion.
5. Verify direction, amount, nonce, owner, recipient, the Unix-timestamp deadline, batch capacity, `amountIn <= type(int128).max`, `0 < minAmountOut <= type(int128).max`, and checked per-direction input aggregates. Each input aggregate must remain at most `type(int128).max`. Accumulate per-output-currency minimum liabilities in full-width `uint256`; the hard order-count bound and individual minimum bound limit each total to `MAX_BATCH_ORDERS * type(int128).max`.
6. Compute an immutable `orderId`.
7. Call `super._beforeSwap(sender, key, params, hookData)`.
8. `BaseAsyncSwap` takes the full specified input as an ERC-6909 claim owned by the hook and returns:

```solidity
toBeforeSwapDelta(int128(uint128(amountIn)), 0)
```

9. Store the order, append its ID to the active bounded batch, and emit `OrderParked`.

The returned delta nets the user's specified input out of the normal swap path, so the v4 pool curve, tick, price, and active liquidity do not move during parking.

For `params.amountSpecified >= 0`, Aura does not park the order. Exact-output behavior follows the inherited base behavior and must not create Aura order state.

### 4.4 Batch formation

- The first eligible order opens the next sequential batch and records `openedAtBlock`.
- A batch becomes `READY` only when it contains at least one order in each direction and at least two total orders.
- The hook rejects an order that would exceed `MAX_BATCH_ORDERS`.
- Additional orders may join a ready batch only until its deterministic close condition.
- Reaching 4 orders freezes membership in the parking transaction only when the batch is two-sided; it records `closedAtBlock` and `closedAtTimestamp`, transitions to `CLOSED`, and emits `BatchClosed`. A full one-sided batch remains `OPEN`, accepts no fifth order, and transitions directly to `REFUNDABLE` at the intake timeout without emitting `BatchClosed`.
- After `block.number > openedAtBlock + MAX_BATCH_WINDOW`, anyone may call `closeBatch(batchId)`. A two-sided `READY` batch records `closedAtBlock` and `closedAtTimestamp`, transitions to `CLOSED`, and emits `BatchClosed`. A one-sided batch transitions directly to `REFUNDABLE` and never enters solver dispatch.
- `BatchClosed` commits `keccak256(abi.encode(batchOrderIds[batchId]))` in frozen stored order. Duplicate detection must not reorder the array. `BatchReady` is only an early eligibility signal and never authorizes dispatch or settlement.
- A closed two-sided batch cannot become refundable until the settlement grace boundary defined in Section 10. The refund entrypoint cannot skip `CLOSED` or race the same boundary used to close a `READY` batch.

### 4.5 Settlement entry

The destination entrypoint is conceptually:

```solidity
function settleBatch(address rvmId, BatchSolution calldata solution) external;
```

It requires:

- `msg.sender == reactiveCallbackProxy`.
- `rvmId == expectedRvmId`.
- The batch is `CLOSED`, contains both directions, and the solution's order count, frozen stored order, and membership hash equal the `BatchClosed` snapshot.
- The solution has not expired or been used.
- `solutionHash` equals the canonical typed hash in Section 5, including the domain values and the hashes of the ordered ID and payout arrays.

After validation, it marks the batch `SETTLING` and calls `poolManager.unlock` with an action-tagged payload. A revert rolls back all status and accounting changes atomically.

### 4.6 Unlock callback routing

`unlockCallback(bytes calldata rawData)` accepts calls only from `PoolManager` and only while an internal unlock context is active. The payload begins with an `UnlockAction` discriminator:

```solidity
enum UnlockAction { NONE, SETTLE_BATCH, CLAIM, REFUND }

struct UnlockPayload {
    UnlockAction action;
    bytes data;
}
```

The callback routes to exactly one internal handler:

- `SETTLE_BATCH`: burn parked input claims, perform optional residual swap, validate realized deltas, mint output claims, and credit liabilities.
- `CLAIM`: burn an output ERC-6909 claim and take its underlying asset to the recipient.
- `REFUND`: burn the parked input claim for one cancelled order and return the underlying input.

Unknown actions, nested unlocks, a missing context, or an action/context mismatch revert.

## 5. Canonical data schemas

The exact shared types belong in `src/types/AuraTypes.sol`.

```solidity
enum OrderStatus {
    NONE,
    PARKED,
    SETTLED,
    CANCELLED,
    CLAIMED
}

enum BatchStatus {
    NONE,
    OPEN,
    READY,
    CLOSED,
    SETTLING,
    SETTLED,
    FAILED,
    REFUNDABLE
}

struct AuraOrderData {
    uint8 version;
    address owner;
    address recipient;
    uint64 nonce;
    uint64 deadline;
    uint128 minAmountOut;
}

struct ParkedOrder {
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

struct ClaimData {
    bytes32 poolId;
    address account;
    address recipient;
    address currency;
    uint128 amount;
}
```

`orderIds[i]` and `payouts[i]` are index-aligned. The payout currency is derived from the stored order direction and cannot be selected independently by the solver.

`ClaimData` is account- and currency-scoped because `claimableBalances` aggregates liabilities from any number of settled orders. It intentionally contains no `orderId`; the canonical claim payload is exactly `(poolId, account, recipient, currency, amount)`, and the callback validates those fields against the active claim unlock context. Although `amount` is stored as `uint128`, every claim entrypoint and callback additionally require `amount <= type(int128).max` before any PoolManager operation.

The order ID uses this exact type hash and ABI preimage:

```solidity
bytes32 constant ORDER_TYPEHASH = keccak256(
    "AuraOrder(uint256 chainId,address auraHook,bytes32 poolId,address owner,address recipient,uint64 nonce,uint64 deadline,bool zeroForOne,uint128 amountIn,uint128 minAmountOut)"
);

bytes32 orderId = keccak256(
    abi.encode(
        ORDER_TYPEHASH,                    // bytes32
        uint256(block.chainid),            // uint256
        address(this),                     // address
        PoolId.unwrap(auraPoolId),         // bytes32
        order.owner,                       // address
        order.recipient,                   // address
        order.nonce,                       // uint64
        order.deadline,                    // uint64
        order.zeroForOne,                  // bool
        order.amountIn,                    // uint128
        order.minAmountOut                 // uint128
    )
);
```

The literal type string, field order, and Solidity widths above are normative. Implementations use `abi.encode`, never `abi.encodePacked`. Domain separation prevents cross-chain, cross-hook, and cross-pool replay.

The solution hash uses this exact type hash and ABI preimage:

```solidity
bytes32 constant SOLUTION_TYPEHASH = keccak256(
    "AuraBatchSolution(uint256 chainId,address auraHook,bytes32 poolId,uint64 batchId,uint64 deadline,uint128 priceNumerator,uint128 priceDenominator,bool residualZeroForOne,uint128 residualAmountIn,uint160 sqrtPriceLimitX96,bytes32 orderIdsHash,bytes32 payoutsHash)"
);

bytes32 orderIdsHash = keccak256(abi.encode(solution.orderIds));
bytes32 payoutsHash = keccak256(abi.encode(solution.payouts));

bytes32 expectedSolutionHash = keccak256(
    abi.encode(
        SOLUTION_TYPEHASH,                 // bytes32
        uint256(block.chainid),            // uint256
        address(this),                     // address
        PoolId.unwrap(auraPoolId),         // bytes32
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

The `solutionHash` field must equal `expectedSolutionHash` and is never included in its own preimage. Both arrays preserve frozen stored order. The literal type string, outer `abi.encode`, field order, and Solidity widths are normative; packed encoding or alternate widths are invalid.

## 6. State layout

```solidity
PoolId public immutable auraPoolId;
IAuraRouter public immutable auraRouter;
address public immutable reactiveCallbackProxy;
address public immutable expectedRvmId;

uint64 public activeBatchId;
mapping(bytes32 orderId => ParkedOrder) public orders;
mapping(uint64 batchId => bytes32[]) internal batchOrderIds;
mapping(uint64 batchId => BatchStatus) public batchStatus;
mapping(uint64 batchId => uint64) public openedAtBlock;
mapping(uint64 batchId => uint64) public closedAtBlock;
mapping(uint64 batchId => uint64) public closedAtTimestamp;
mapping(uint64 batchId => uint160) public referenceSqrtPriceX96;
mapping(uint64 batchId => uint256) public aggregateToken0Input;
mapping(uint64 batchId => uint256) public aggregateToken1Input;
mapping(uint64 batchId => uint256) public aggregateMinToken0Output;
mapping(uint64 batchId => uint256) public aggregateMinToken1Output;
mapping(bytes32 solutionHash => bool) public usedSolutions;
mapping(PoolId poolId => mapping(address account => mapping(Currency token => uint256 amount)))
    public claimableBalances;
mapping(PoolId poolId => mapping(Currency token => uint256 amount)) public protocolDust;
```

`blockBatches[block.number]` is not the primary store. Block numbers are metadata, not stable order identifiers, and array indexes become unsafe after status changes. Aura stores immutable order IDs and uses bounded batch indexes.

## 7. Uniform clearing price

### 7.1 Price convention

The uniform price is token1 per token0:

$$
P = \frac{p_n}{p_d}
$$

where `p_n = priceNumerator`, `p_d = priceDenominator`, both values are nonzero, and `gcd(p_n, p_d) == 1`. Every equivalent fraction is reduced before comparison, storage, ABI encoding, fixture generation, and `solutionHash` construction. The destination rejects a non-coprime tuple.

For each closed batch there is exactly one destination-verifiable price candidate. The hook derives `P_target` from the stored `BatchClosed.referenceSqrtPriceX96`, clamps it to the feasible interval, and applies the normative continued-fraction/Stern--Brocot bounded-rational approximation. Candidate selection uses absolute error, then smaller numeric rational, then the lexicographically smaller normalized `(p_n, p_d)` tuple as deterministic tie-breaks. `AuraHook` recomputes this candidate from stored closure evidence and rejects every other feasible price; the publisher is therefore not a financial price-selection authority.

For a token0 input order:

$$
q_1 = \left\lfloor \frac{a_0 p_n}{p_d} \right\rfloor
$$

For a token1 input order:

$$
q_0 = \left\lfloor \frac{a_1 p_d}{p_n} \right\rfloor
$$

All multiplication and division use a full-precision `mulDiv` implementation. User payouts round down. Any realized excess remains protocol dust backed by ERC-6909 claims. Dust can never be assigned to a solver.

Every payout must satisfy:

```text
payout[i] == clearingPayout(order[i], p_n, p_d)
payout[i] >= order[i].minAmountOut
```

The solver cannot reduce one user's payout to subsidize another.

### 7.2 Feasible price interval

Each token0 input order creates a lower bound:

$$
P \geq \frac{minOut}{amountIn}
$$

Each token1 input order creates an upper bound:

$$
P \leq \frac{amountIn}{minOut}
$$

The solution is feasible only when the greatest lower bound does not exceed the least upper bound. Comparisons use cross multiplication with full precision, not floating point.

### 7.3 Direction and residual

Let:

- $I_0$ be total parked token0 input.
- $I_1$ be total parked token1 input.
- $Q_0$ be total token0 payout liability.
- $Q_1$ be total token1 payout liability.

Compare $I_0 p_n$ with $I_1 p_d$.

If $I_0 p_n > I_1 p_d$, token0 is the excess input and the residual direction is token0 to token1:

$$
R_0 = I_0 - \left\lfloor \frac{I_1 p_d}{p_n} \right\rfloor
$$

If $I_0 p_n < I_1 p_d$, token1 is the excess input and the residual direction is token1 to token0:

$$
R_1 = I_1 - \left\lfloor \frac{I_0 p_n}{p_d} \right\rfloor
$$

If the cross products are equal, `residualAmountIn` must be zero. A nonzero residual must match the derived direction and amount exactly.

Order admission rejects zero `amountIn` or zero `minAmountOut`. Each individual value and each checked token0-input and token1-input aggregate must remain at most `type(int128).max` after adding the order. A token0-input order increments `aggregateMinToken1Output`; a token1-input order increments `aggregateMinToken0Output`; those liability totals use checked `uint256` arithmetic and may exceed `type(int128).max` because the bounded settlement sequence processes them in signed-range chunks. The hard order-count bound plus the individual minimum bound provides the explicit aggregate ceiling `MAX_BATCH_ORDERS * type(int128).max`.

Candidate validation requires every individual payout and the residual swap amount to fit `type(int128).max`. Aggregate computed payout liabilities `Q_0` and `Q_1` remain full-width `uint256` conservation values and may exceed that limit. Every PoolManager `mint`, `burn`, `take`, or delta conversion is split deterministically into the minimum number of chunks, each `<= type(int128).max`, in frozen order; chunking never changes an order payout, recipient, solution hash, or aggregate conservation result. Consequently a representable feasible batch is not rejected merely because an aggregate payout crosses the signed-operation limit.

### 7.4 Realized conservation

The hook measures the residual swap's actual `BalanceDelta`; it never trusts a quoted output. Let $A_0$ or $A_1$ be actual output received from the pool and $D_0$, $D_1$ be explicitly recorded dust.

For residual token0 to token1:

$$
I_0 - R_0 = Q_0 + D_0
$$

$$
I_1 + A_1 = Q_1 + D_1
$$

For residual token1 to token0:

$$
I_0 + A_0 = Q_0 + D_0
$$

$$
I_1 - R_1 = Q_1 + D_1
$$

For zero residual:

$$
I_0 = Q_0 + D_0, \qquad I_1 = Q_1 + D_1
$$

If actual pool output cannot fully back all payouts, settlement reverts. If output exceeds liabilities, the excess is minted as a hook-owned ERC-6909 dust claim and recorded by pool and currency.

### 7.5 Production residual quoting

ReactVM has no authoritative RPC or complete Uniswap v4 tick-state view and therefore must not quote residual execution. The production `AuraSolutionBuilder` is the only MVP component responsible for pre-dispatch quoting. After finalized `BatchClosed` evidence, it:

1. derives the one canonical price from the stored `BatchClosed.referenceSqrtPriceX96` and feasible interval exactly as the destination does; it never searches for or substitutes another funded price;
2. reads finalized PoolManager slot0, liquidity, LP and protocol fees, tick bitmap, and every initialized tick crossed by that canonical candidate through a configured Unichain Sepolia RPC and the pinned v4 state-view interfaces;
3. records the source block number and block hash in operator evidence;
4. runs integer-identical pinned v4 swap math for the exact residual and proposed `sqrtPriceLimitX96`;
5. applies the realized-conservation equations to the simulated output;
6. re-reads the source block before publishing and abandons the candidate if the state changed; and
7. submits the bounded `BatchSolution` to `AuraSolutionInbox`, which emits the proposal for Reactive delivery.

The configured publisher is an operational spam-control boundary, not a settlement or price-selection authority. `AuraHook` recomputes the sole canonical price from stored closure evidence, recomputes all order math, executes against live PoolManager state, measures the actual `BalanceDelta`, and atomically reverts a noncanonical, stale, or underfunded proposal. Builder, inbox, RPC, or Reactive failure cannot block the permissionless refund path.

## 8. Settlement accounting sequence

Within the settlement unlock:

1. Revalidate batch status and the canonical solution hash.
2. Require unique order IDs, exact batch membership, `PARKED` status, valid deadlines, and array length equality.
3. Sum inputs and derive every payout using `AuraClearingMath`.
4. Burn the hook's parked input ERC-6909 claims in frozen-order signed-range chunks. This exposes the underlying inputs as positive hook deltas.
5. If residual is nonzero, call `poolManager.swap` once with exact input and the submitted price limit.
6. Measure the returned delta and enforce full-width realized conservation.
7. Mint hook-owned ERC-6909 claims for user output liabilities and tracked dust in deterministic frozen-order chunks no larger than `type(int128).max`.
8. Update each order to `SETTLED`, credit its recipient, mark the solution used, and set the batch to `SETTLED`.
9. Return from unlock only when every currency delta is resolved.

No arbitrary calls, tokens, pools, recipients, or interactions can be supplied in a solution.

## 9. Claims

`claimTokens(PoolId poolId, Currency token, address recipient, uint256 amount)` follows checks, effects, interactions:

1. Require a nonzero recipient and `0 < amount <= uint256(type(int128).max)`.
2. Require `amount <= claimableBalances[poolId][msg.sender][token]`.
3. Convert to `uint128` only after the signed-range check and place that value in canonical `ClaimData`.
4. Decrement the claimable balance before unlocking.
5. Enter the `CLAIM` unlock context with canonical `ClaimData`.
6. In the callback, burn the same signed-range amount of the hook's output ERC-6909 claim.
7. Call `poolManager.take(token, recipient, amount)`.
8. Emit `TokensClaimed`.

The entrypoint is non-reentrant. A callback failure reverts the prior balance decrement. An account-level `uint256` balance may exceed the per-operation signed limit after accumulating claims across batches; the user redeems it through repeated partial calls, each no larger than `type(int128).max`. A request above that limit reverts before any cast or balance mutation. Each unit can be claimed only once.

## 10. Timeout and refunds

`MAX_BATCH_WINDOW = 20` Unichain blocks, `MAX_FINALITY_LAG_SECONDS = 12 hours`, and `SETTLEMENT_GRACE_SECONDS = 5 minutes` are fixed for the MVP and recorded in `BASELINE.md`. The intake-close boundary is `block.number > openedAtBlock[batchId] + MAX_BATCH_WINDOW`; implementations and tests use this strict block comparison.

At the intake-close boundary:

1. A one-sided nonterminal batch may transition directly to `REFUNDABLE`.
2. A two-sided `READY` batch must transition to `CLOSED`, record both `closedAtBlock` and `closedAtTimestamp = uint64(block.timestamp)`, freeze membership, and emit `BatchClosed`; it cannot transition directly to `REFUNDABLE`.

A closed two-sided batch becomes refund-eligible only when:

```text
block.timestamp > closedAtTimestamp[batchId]
                + MAX_FINALITY_LAG_SECONDS
                + SETTLEMENT_GRACE_SECONDS
```

The 12-hour finality buffer covers the documented OP Stack maximum normal finalized-head lag; the additional five-minute grace begins after that bound and reserves time for inbox publication plus up to three one-minute callback attempts. This conservative on-chain bound is independent of an untrusted builder acknowledgment, so no operator can extend custody by withholding or delaying a finality signal. Closure wins over refund at the intake boundary, while refunds remain permissionless after the fixed bound. After the applicable refund boundary and only while the batch remains unsettled:

1. Anyone may mark the batch `REFUNDABLE`.
2. Only an order owner may call `cancelExpiredOrder(orderId)` for that owner's `PARKED` order.
3. The hook marks the order `CANCELLED` before unlocking.
4. The refund callback burns exactly that order's parked input claim and takes the underlying input to the owner.
5. The hook emits `OrderCancelled`.

Refund before the applicable boundary, refund after settlement, double refund, refund to a different recipient, and refund of another user's order revert.

## 11. Events

Normative event declarations:

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

event BatchReady(
    uint64 indexed batchId,
    uint64 openedAtBlock,
    uint8 orderCount,
    uint160 referenceSqrtPriceX96
);

event BatchClosed(
    uint64 indexed batchId,
    uint64 closedAtBlock,
    uint64 closedAtTimestamp,
    uint8 orderCount,
    bytes32 orderIdsHash,
    uint160 referenceSqrtPriceX96
);

event BatchSettled(
    uint64 indexed batchId,
    bytes32 indexed solutionHash,
    uint128 priceNumerator,
    uint128 priceDenominator,
    bool residualZeroForOne,
    uint128 residualAmountIn
);

event TokensClaimed(
    bytes32 indexed poolId,
    address indexed account,
    address indexed recipient,
    Currency token,
    uint256 amount
);

event OrderCancelled(bytes32 indexed orderId, address indexed owner, Currency token, uint256 amount);
```

For log subscription, `Currency` is represented by its underlying ABI type, `address`.

## 12. Security invariants

The following properties must hold in tests and production:

1. **Router identity:** only `AuraRouter` can create Aura orders, and the router cannot forge `owner`.
2. **Pool binding:** all order, claim, and settlement accounting belongs to the immutable Aura pool.
3. **Parking curve neutrality:** parking never changes pool price, tick, active liquidity, or other AMM curve state. PoolManager's underlying token custody increases when the router settles the parked input delta.
4. **Parking custody backing:** for each parked ERC-20 input, the increase in PoolManager custody equals the input backing added for the hook's newly minted ERC-6909 claim.
5. **Admission and operation bounds:** zero minimum output is rejected; each input, minimum output, per-direction input aggregate, payout, residual, and PoolManager operation fits `type(int128).max`. Full-width aggregate output liabilities may exceed that limit only when deterministic signed-range chunking preserves exact conservation.
6. **Backing:** claimable liabilities plus protocol dust never exceed hook ERC-6909 holdings per pool and currency.
7. **Conservation:** settlement closes the PoolManager unlock with zero unresolved currency deltas.
8. **Uniformity:** every executed order uses the same directed rational price and deterministic rounding rule.
9. **Minimum output:** no order settles below its `minAmountOut`.
10. **One execution:** an order leaves `PARKED` exactly once, by settlement or cancellation.
11. **Replay resistance:** a batch and solution hash settle at most once.
12. **Bounded work:** settlement cannot iterate more than `MAX_BATCH_ORDERS`.
13. **Callback authentication:** both callback proxy and injected RVM identity must match immutable configuration.
14. **Unlock authentication:** only PoolManager can invoke `unlockCallback`, and only an active action context is accepted.
15. **Claim CEI and range:** liability is reduced before the external unlock, the claim entry is non-reentrant, and each claim operation is at most `type(int128).max`; larger balances remain redeemable in partial calls.
16. **No trapped funds:** every parked order eventually becomes settled and claimable or refundable; a closed batch cannot become refundable until the fixed finality buffer and post-finality settlement grace have elapsed.
17. **No arbitrary interaction:** a builder or dispatcher cannot select arbitrary targets, calldata, pools, currencies, or recipients.
18. **External-service independence:** the solution builder, inbox, RPC, Reactive transport, Circle, Arc, Chainalysis, indexers, and frontend services can fail without blocking on-chain validation, claims, or timeout refunds.

## 13. Required verification

At minimum, the implementation must provide:

- Unit tests for every validation branch and state transition.
- Fuzz tests for rational price calculations, canonical-price rejection, rounding, zero minimum rejection, aggregate input bounds, full-width payout totals, settlement and claim chunking, casts, and overflow boundaries.
- Invariant tests for backing, order terminal-state uniqueness, replay resistance, and zero unlock deltas.
- A perfect CoW case with no pool swap.
- Both residual directions with only the residual touching the pool, plus fork parity between the production builder quote and pinned v4 execution.
- Full one-sided cap, finality-buffer boundary, post-finality settlement grace, bounded callback retry, and one-time refund cases.
- Unauthorized router, callback proxy, RVM, PoolManager callback, and replay cases.
- Remix and Slither findings recorded against an exact commit in `docs/remix-audit.md`.

## 14. Change control

No agent may silently weaken an invariant to make a test pass. A proposed protocol change must identify:

- the exact invariant affected;
- the reason the current rule is insufficient;
- accounting and security impact;
- new or changed tests;
- migration impact for deployed contracts;
- explicit approval before merge.
