# Aura Protocol and System Architecture

Status: normative MVP specification  
Version: 1.1  
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
| `ReactiveBatchDispatcher` | Subscribes to Aura events and sends bounded settlement callbacks. | Trigger and proposal source only. Its payload is untrusted until validated by `AuraHook`. |
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

### 4.3 `_beforeSwap` interception

For `params.amountSpecified < 0`:

1. Verify the caller is the authorized router.
2. Verify the supplied `PoolKey` hashes to the immutable Aura pool ID.
3. Decode and validate `AuraOrderData`.
4. Derive `amountIn = uint256(-params.amountSpecified)` with checked conversion.
5. Verify direction, amount, nonce, owner, recipient, deadline, minimum output, batch capacity, and aggregate signed-delta bounds.
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
- Additional orders may join a ready batch only until its deterministic close condition. The demo configuration closes at 4 orders or at the configured block window.
- Reaching 4 orders closes the batch in the parking transaction. After the block window, anyone may call `closeBatch(batchId)`; it closes a two-sided batch or makes a one-sided batch refundable. Closure freezes membership and emits `BatchClosed(batchId, orderCount, orderIdsHash, referenceSqrtPriceX96)`. The canonical hash is `keccak256(abi.encode(batchOrderIds[batchId]))` in stored order. `BatchReady` is only an early eligibility signal and never authorizes dispatch or settlement.
- A batch with only one direction never settles in the MVP. After timeout, its orders become refundable.

### 4.5 Settlement entry

The destination entrypoint is conceptually:

```solidity
function settleBatch(address rvmId, BatchSolution calldata solution) external;
```

It requires:

- `msg.sender == reactiveCallbackProxy`.
- `rvmId == expectedRvmId`.
- The batch is `READY` and has been closed, and the solution's order count and membership hash equal the frozen `BatchClosed` snapshot.
- The solution has not expired or been used.
- `solutionHash` equals the canonical hash of every solution field.

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
    bytes32 orderId;
    address account;
    address recipient;
    address currency;
    uint128 amount;
}
```

`orderIds[i]` and `payouts[i]` are index-aligned. The payout currency is derived from the stored order direction and cannot be selected independently by the solver.

The order ID is:

```text
keccak256(abi.encode(
  ORDER_TYPEHASH,
  chainId,
  auraHook,
  poolId,
  owner,
  recipient,
  nonce,
  deadline,
  zeroForOne,
  amountIn,
  minAmountOut
))
```

Domain separation prevents cross-chain, cross-hook, and cross-pool replay.

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

where `p_n = priceNumerator`, `p_d = priceDenominator`, and both values are nonzero.

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

Order admission maintains checked token0-input and token1-input aggregates and requires each aggregate to remain at most `type(int128).max`. Consequently every derived residual also fits PoolManager's signed `BalanceDelta` representation. This is stricter than the `uint128` storage fields by design: the installed v4 `Pool.swap` converts final swap amounts with `toInt128()`. An order that would cross either aggregate bound reverts at parking rather than creating a batch that can only time out. Aggregate payout calculations and every amount passed to `swap`, `mint`, `burn`, `take`, or delta conversion are checked against the applicable installed-v4 signed range before interaction.

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

## 8. Settlement accounting sequence

Within the settlement unlock:

1. Revalidate batch status and the canonical solution hash.
2. Require unique order IDs, exact batch membership, `PARKED` status, valid deadlines, and array length equality.
3. Sum inputs and derive every payout using `AuraClearingMath`.
4. Burn the hook's parked input ERC-6909 claims. This exposes the underlying inputs as positive hook deltas.
5. If residual is nonzero, call `poolManager.swap` once with exact input and the submitted price limit.
6. Measure the returned delta and enforce realized conservation.
7. Mint hook-owned ERC-6909 claims for user output liabilities and tracked dust.
8. Update each order to `SETTLED`, credit its recipient, mark the solution used, and set the batch to `SETTLED`.
9. Return from unlock only when every currency delta is resolved.

No arbitrary calls, tokens, pools, recipients, or interactions can be supplied in a solution.

## 9. Claims

`claimTokens(PoolId poolId, Currency token, address recipient, uint256 amount)` follows checks, effects, interactions:

1. Require a nonzero recipient and amount.
2. Require `amount <= claimableBalances[poolId][msg.sender][token]`.
3. Decrement the claimable balance before unlocking.
4. Enter the `CLAIM` unlock context with canonical `ClaimData`.
5. In the callback, burn the same amount of the hook's output ERC-6909 claim.
6. Call `poolManager.take(token, recipient, amount)`.
7. Emit `TokensClaimed`.

The entrypoint is non-reentrant. A callback failure reverts the prior balance decrement. Claims may be partial, but each unit can be claimed only once.

## 10. Timeout and refunds

`MAX_BATCH_WINDOW` is fixed to 20 blocks for the MVP, as recorded in `BASELINE.md`. The close boundary is `block.number > openedAtBlock[batchId] + MAX_BATCH_WINDOW`; implementations and tests must use this strict comparison without a wall-clock substitute.

When `block.number > openedAtBlock[batchId] + MAX_BATCH_WINDOW` and the batch has not settled:

1. Anyone may mark the batch `REFUNDABLE`.
2. Only an order owner may call `cancelExpiredOrder(orderId)` for that owner's `PARKED` order.
3. The hook marks the order `CANCELLED` before unlocking.
4. The refund callback burns exactly that order's parked input claim and takes the underlying input to the owner.
5. The hook emits `OrderCancelled`.

Refund after settlement, double refund, refund to a different recipient, and refund of another user's order revert.

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
3. **Parking neutrality:** parking never changes pool price, tick, liquidity, or reserves.
4. **Backing:** claimable liabilities plus protocol dust never exceed hook ERC-6909 holdings per pool and currency.
5. **Conservation:** settlement closes the PoolManager unlock with zero unresolved currency deltas.
6. **Uniformity:** every executed order uses the same directed rational price and deterministic rounding rule.
7. **Minimum output:** no order settles below its `minAmountOut`.
8. **One execution:** an order leaves `PARKED` exactly once, by settlement or cancellation.
9. **Replay resistance:** a batch and solution hash settle at most once.
10. **Bounded work:** settlement cannot iterate more than `MAX_BATCH_ORDERS`.
11. **Callback authentication:** both callback proxy and injected RVM identity must match immutable configuration.
12. **Unlock authentication:** only PoolManager can invoke `unlockCallback`, and only an active action context is accepted.
13. **Claim CEI:** liability is reduced before the external unlock and claim entry is non-reentrant.
14. **No trapped funds:** every parked order eventually becomes settled and claimable or refundable.
15. **No arbitrary interaction:** a solver cannot select arbitrary targets, calldata, pools, currencies, or recipients.
16. **External-service independence:** Circle, Arc, Chainalysis, indexers, and frontend services can fail without blocking on-chain settlement validation, claims, or timeout refunds.

## 13. Required verification

At minimum, the implementation must provide:

- Unit tests for every validation branch and state transition.
- Fuzz tests for rational price calculations, rounding, minimum output, casts, and overflow boundaries.
- Invariant tests for backing, order terminal-state uniqueness, replay resistance, and zero unlock deltas.
- A perfect CoW case with no pool swap.
- Both residual directions with only the residual touching the pool.
- Timeout and one-time refund cases.
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
