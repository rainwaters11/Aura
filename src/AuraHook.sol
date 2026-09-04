// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseAsyncSwap} from "@openzeppelin/uniswap-hooks/src/base/BaseAsyncSwap.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

import {IAuraRouter} from "./interfaces/IAuraRouter.sol";
import {AuraOrderData, ParkedOrder, OrderStatus, BatchStatus, BatchSolution, ClaimData} from "./types/AuraTypes.sol";
import {IAuraSettlementVerifier} from "./interfaces/IAuraSettlementVerifier.sol";

/// @title AuraHook
/// @notice Authenticated parking, bounded settlement, sovereign claims, and timeout refunds for one Aura pool.
contract AuraHook is BaseAsyncSwap, IUnlockCallback, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint8 public constant ORDER_DATA_VERSION = 1;
    uint8 public constant MAX_BATCH_ORDERS = 4;
    uint64 public constant MAX_BATCH_WINDOW = 20;
    uint64 public constant MAX_FINALITY_LAG_SECONDS = 12 hours;
    uint64 public constant SETTLEMENT_GRACE_SECONDS = 5 minutes;
    uint64 public constant MIN_ORDER_LIFETIME_SECONDS = 13 hours;

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "AuraOrder(uint256 chainId,address auraHook,bytes32 poolId,address owner,address recipient,uint64 nonce,uint64 deadline,bool zeroForOne,uint128 amountIn,uint128 minAmountOut)"
    );

    IAuraRouter public immutable auraRouter;
    IAuraSettlementVerifier public immutable settlementVerifier;
    address public immutable reactiveCallbackProxy;
    address public immutable expectedRvmId;
    PoolId public immutable auraPoolId;
    Currency private immutable _currency0;
    Currency private immutable _currency1;
    uint24 private immutable _fee;
    int24 private immutable _tickSpacing;

    uint64 public activeBatchId;
    mapping(bytes32 orderId => ParkedOrder) public orders;
    mapping(uint64 batchId => bytes32[]) internal _batchOrderIds;
    mapping(uint64 batchId => BatchStatus) public batchStatus;
    mapping(uint64 batchId => uint64) public openedAtBlock;
    mapping(uint64 batchId => uint64) public closedAtBlock;
    mapping(uint64 batchId => uint64) public closedAtTimestamp;
    mapping(uint64 batchId => uint256) public aggregateToken0Input;
    mapping(uint64 batchId => uint256) public aggregateToken1Input;
    mapping(uint64 batchId => uint256) public aggregateMinToken0Output;
    mapping(uint64 batchId => uint256) public aggregateMinToken1Output;
    mapping(bytes32 solutionHash => bool) public usedSolutions;
    mapping(PoolId poolId => mapping(address account => mapping(Currency token => uint256 amount))) public
        claimableBalances;
    mapping(PoolId poolId => mapping(Currency token => uint256 amount)) public protocolDust;

    enum UnlockAction {
        NONE,
        REFUND,
        SETTLE_BATCH,
        CLAIM
    }

    UnlockAction private _unlockAction;
    bytes32 private _refundOrderId;
    bytes32 private _residualSolutionHash;
    bool private _residualZeroForOne;
    uint128 private _residualAmountIn;
    uint160 private _residualPriceLimit;
    bytes32 private _claimContextHash;

    error InvalidRouter();
    error InvalidPoolManager();
    error InvalidSettlementVerifier();
    error InvalidSettlementAuthority();
    error UnauthorizedSettlement();
    error InvalidRvmIdentity();
    error BatchNotClosed();
    error SettlementWindowExpired();
    error InvalidUnlockContext();
    error InvalidResidualSwap();
    error UnderfundedSettlement();
    error SettlementOrderInvalid();
    error InvalidClaim();
    error InsufficientClaimBalance();
    error UnauthorizedRouter();
    error InvalidPool();
    error AuraPoolAlreadyInitialized(PoolId poolId);
    error InvalidInitialSqrtPriceX96(uint160 sqrtPriceX96);
    error ExactOutputUnsupported();
    error MalformedOrderData();
    error InvalidOrder();
    error ExpiredOrder();
    error InvalidNonce();
    error AmountOverflow();
    error OrderReplay();
    error BatchCapacityExceeded();
    error DirectionCapacityReserved();
    error IncompatibleLimits();
    error BatchNotOpen();
    error BatchNotRefundable();
    error BatchWindowActive();
    error BatchRefundGraceActive();
    error BatchIntakeClosed();
    error BatchClosurePreflightFailed();
    error TwoSidedBatch();
    error OrderNotParked();
    error UnauthorizedUnlockCallback();
    error InvalidRefundContext();
    error BatchIdOverflow();

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

    event BatchReady(uint64 indexed batchId, uint64 openedAtBlock, uint8 orderCount, uint160 referenceSqrtPriceX96);

    event BatchClosed(
        uint64 indexed batchId,
        uint64 closedAtBlock,
        uint64 closedAtTimestamp,
        uint8 orderCount,
        bytes32 orderIdsHash,
        uint160 referenceSqrtPriceX96
    );

    event OrderCancelled(bytes32 indexed orderId, address indexed owner, Currency token, uint256 amount);
    event BatchSettled(
        uint64 indexed batchId,
        bytes32 indexed solutionHash,
        uint128 priceNumerator,
        uint128 priceDenominator,
        bool residualZeroForOne,
        uint128 residualAmountIn
    );
    event TokensClaimed(
        bytes32 indexed poolId, address indexed account, address indexed recipient, Currency token, uint256 amount
    );

    struct Admission {
        uint64 batchId;
        uint256 count;
        uint256 nextAggregate;
        bool hasZeroForOne;
        bool hasOneForZero;
    }

    struct PendingOrder {
        AuraOrderData data;
        Admission admission;
        bytes32 orderId;
        uint128 amountIn;
    }

    struct SettlementTotals {
        uint256 input0;
        uint256 input1;
        uint256 payout0;
        uint256 payout1;
    }

    constructor(
        IPoolManager manager,
        IAuraRouter router,
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        IAuraSettlementVerifier verifier,
        address callbackProxy,
        address rvmId,
        uint160 initialSqrtPriceX96
    ) BaseHook(manager) {
        if (address(router) == address(0)) revert InvalidRouter();
        if (address(router.poolManager()) != address(manager)) revert InvalidPoolManager();
        if (address(verifier) == address(0) || address(verifier).code.length == 0) {
            revert InvalidSettlementVerifier();
        }
        if (callbackProxy == address(0) || rvmId == address(0)) revert InvalidSettlementAuthority();
        auraRouter = router;
        settlementVerifier = verifier;
        reactiveCallbackProxy = callbackProxy;
        expectedRvmId = rvmId;
        _currency0 = currency0;
        _currency1 = currency1;
        _fee = fee;
        _tickSpacing = tickSpacing;
        if (initialSqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || initialSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidInitialSqrtPriceX96(initialSqrtPriceX96);
        }
        PoolKey memory key = PoolKey(currency0, currency1, fee, tickSpacing, this);
        auraPoolId = key.toId();
        if (PoolId.unwrap(router.auraPoolId()) != PoolId.unwrap(auraPoolId)) revert InvalidPool();
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(auraPoolId);
        if (sqrtPriceX96 != 0) revert AuraPoolAlreadyInitialized(auraPoolId);
        manager.initialize(key, initialSqrtPriceX96);
    }

    function settleBatch(address rvmId, BatchSolution calldata solution) external {
        if (msg.sender != reactiveCallbackProxy) revert UnauthorizedSettlement();
        if (rvmId != expectedRvmId) revert InvalidRvmIdentity();
        if (batchStatus[solution.batchId] != BatchStatus.CLOSED) revert BatchNotClosed();
        if (
            block.timestamp
                > uint256(closedAtTimestamp[solution.batchId]) + MAX_FINALITY_LAG_SECONDS + SETTLEMENT_GRACE_SECONDS
        ) revert SettlementWindowExpired();
        if (_unlockAction != UnlockAction.NONE) revert InvalidUnlockContext();
        if (settlementVerifier.validate(solution) != IAuraSettlementVerifier.validate.selector) {
            revert InvalidSettlementVerifier();
        }

        usedSolutions[solution.solutionHash] = true;
        batchStatus[solution.batchId] = BatchStatus.SETTLING;
        _unlockAction = UnlockAction.SETTLE_BATCH;
        _residualSolutionHash = solution.solutionHash;
        _residualZeroForOne = solution.residualZeroForOne;
        _residualAmountIn = solution.residualAmountIn;
        _residualPriceLimit = solution.sqrtPriceLimitX96;
        poolManager.unlock(abi.encode(UnlockAction.SETTLE_BATCH, solution));
        _residualSolutionHash = bytes32(0);
        _residualAmountIn = 0;
        _residualPriceLimit = 0;
        _unlockAction = UnlockAction.NONE;
    }

    /// @notice Redeems a bounded portion of the caller's settled output balance.
    function claimTokens(PoolId poolId, Currency token, address recipient, uint256 amount) external nonReentrant {
        if (
            PoolId.unwrap(poolId) != PoolId.unwrap(auraPoolId) || recipient == address(0) || amount == 0
                || (Currency.unwrap(token) != Currency.unwrap(_currency0)
                    && Currency.unwrap(token) != Currency.unwrap(_currency1))
                || amount > uint256(uint128(type(int128).max)) || _unlockAction != UnlockAction.NONE
        ) revert InvalidClaim();
        uint256 balance = claimableBalances[poolId][msg.sender][token];
        if (amount > balance) revert InsufficientClaimBalance();
        ClaimData memory claim = ClaimData({
            poolId: PoolId.unwrap(poolId),
            account: msg.sender,
            recipient: recipient,
            currency: Currency.unwrap(token),
            amount: uint128(amount)
        });

        claimableBalances[poolId][msg.sender][token] = balance - amount;
        _unlockAction = UnlockAction.CLAIM;
        _claimContextHash = keccak256(abi.encode(claim));
        poolManager.unlock(abi.encode(UnlockAction.CLAIM, claim));
        _claimContextHash = bytes32(0);
        _unlockAction = UnlockAction.NONE;
        emit TokensClaimed(PoolId.unwrap(poolId), msg.sender, recipient, token, amount);
    }

    function batchOrderIds(uint64 batchId) external view returns (bytes32[] memory) {
        return _batchOrderIds[batchId];
    }

    function batchOrderCount(uint64 batchId) external view returns (uint256) {
        return _batchOrderIds[batchId].length;
    }

    /// @notice Advances a timed-out batch through its bounded close and refund lifecycle.
    function closeBatch(uint64 batchId) external {
        BatchStatus status = batchStatus[batchId];
        if (status == BatchStatus.CLOSED) {
            if (
                block.timestamp
                    <= uint256(closedAtTimestamp[batchId]) + MAX_FINALITY_LAG_SECONDS + SETTLEMENT_GRACE_SECONDS
            ) revert BatchRefundGraceActive();
            batchStatus[batchId] = BatchStatus.REFUNDABLE;
            return;
        }
        if (status != BatchStatus.OPEN && status != BatchStatus.READY) revert BatchNotOpen();
        if (block.number <= uint256(openedAtBlock[batchId]) + MAX_BATCH_WINDOW) revert BatchWindowActive();

        if (status == BatchStatus.READY && _readyClosurePreflight(batchId)) {
            _closeReadyBatch(batchId);
        } else {
            batchStatus[batchId] = BatchStatus.REFUNDABLE;
        }
    }

    /// @notice Permissionlessly refunds one parked order after its batch becomes refundable.
    /// @dev The caller cannot choose the destination; the underlying input always returns to the stored owner.
    function cancelExpiredOrder(bytes32 orderId) external nonReentrant {
        ParkedOrder storage order = orders[orderId];
        if (order.status != OrderStatus.PARKED) revert OrderNotParked();
        if (batchStatus[order.batchId] != BatchStatus.REFUNDABLE) revert BatchNotRefundable();

        order.status = OrderStatus.CANCELLED;
        if (_unlockAction != UnlockAction.NONE) revert InvalidRefundContext();
        _unlockAction = UnlockAction.REFUND;
        _refundOrderId = orderId;
        poolManager.unlock(abi.encode(UnlockAction.REFUND, orderId));
        _unlockAction = UnlockAction.NONE;
        _refundOrderId = bytes32(0);

        Currency token = order.zeroForOne ? _currency0 : _currency1;
        emit OrderCancelled(orderId, order.owner, token, order.amountIn);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedUnlockCallback();
        UnlockAction action = abi.decode(rawData, (UnlockAction));
        if (action == UnlockAction.NONE || action != _unlockAction) revert InvalidUnlockContext();
        if (action == UnlockAction.SETTLE_BATCH) {
            (, BatchSolution memory solution) = abi.decode(rawData, (UnlockAction, BatchSolution));
            if (solution.solutionHash != _residualSolutionHash) revert InvalidUnlockContext();
            _executeSettlement(solution);
            return "";
        }
        if (action == UnlockAction.CLAIM) {
            (, ClaimData memory claim) = abi.decode(rawData, (UnlockAction, ClaimData));
            if (keccak256(abi.encode(claim)) != _claimContextHash) revert InvalidUnlockContext();
            Currency claimToken = Currency.wrap(claim.currency);
            poolManager.burn(address(this), claimToken.toId(), claim.amount);
            poolManager.take(claimToken, claim.recipient, claim.amount);
            return "";
        }
        (, bytes32 orderId) = abi.decode(rawData, (UnlockAction, bytes32));
        if (orderId != _refundOrderId) revert InvalidRefundContext();

        ParkedOrder storage order = orders[orderId];
        if (order.status != OrderStatus.CANCELLED) revert InvalidRefundContext();
        Currency token = order.zeroForOne ? _currency0 : _currency1;
        poolManager.burn(address(this), token.toId(), order.amountIn);
        poolManager.take(token, order.owner, order.amountIn);
        return "";
    }

    function computeOrderId(AuraOrderData memory order, bool zeroForOne, uint128 amountIn)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                block.chainid,
                address(this),
                PoolId.unwrap(auraPoolId),
                order.owner,
                order.recipient,
                order.nonce,
                order.deadline,
                zeroForOne,
                amountIn,
                order.minAmountOut
            )
        );
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_unlockAction == UnlockAction.SETTLE_BATCH && sender == address(this)) {
            if (
                PoolId.unwrap(key.toId()) != PoolId.unwrap(auraPoolId) || params.amountSpecified >= 0
                    || params.zeroForOne != _residualZeroForOne || uint256(-params.amountSpecified) != _residualAmountIn
                    || params.sqrtPriceLimitX96 != _residualPriceLimit || hookData.length != 32
                    || abi.decode(hookData, (bytes32)) != _residualSolutionHash
            ) revert InvalidResidualSwap();
            return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }
        // BaseAsyncSwap deliberately lets exact-output swaps execute on the PoolManager normally.
        if (params.amountSpecified >= 0) return super._beforeSwap(sender, key, params, hookData);

        if (sender != address(auraRouter)) revert UnauthorizedRouter();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(auraPoolId)) revert InvalidPool();
        PendingOrder memory pending = _prepareOrder(params, hookData);

        // The audited OpenZeppelin path takes the exact input as a PoolManager ERC-6909 claim.
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = super._beforeSwap(sender, key, params, hookData);

        _recordOrder(pending.admission, pending.orderId, pending.data, params.zeroForOne, pending.amountIn);
        _emitOrderParked(pending, params.zeroForOne, key.currency0, key.currency1);
        return (selector, delta, fee);
    }

    function _executeSettlement(BatchSolution memory solution) internal {
        if (batchStatus[solution.batchId] != BatchStatus.SETTLING) revert InvalidUnlockContext();
        bytes32[] storage ids = _batchOrderIds[solution.batchId];
        SettlementTotals memory totals = _burnInputs(solution, ids);
        (int256 delta0, int256 delta1) = _executeResidual(solution);
        _finalizeSettlement(solution, ids, totals, delta0, delta1);
    }

    function _burnInputs(BatchSolution memory solution, bytes32[] storage ids)
        internal
        returns (SettlementTotals memory totals)
    {
        for (uint256 i; i < ids.length; ++i) {
            ParkedOrder storage order = orders[ids[i]];
            if (order.status != OrderStatus.PARKED || order.batchId != solution.batchId) {
                revert SettlementOrderInvalid();
            }
            poolManager.burn(address(this), (order.zeroForOne ? _currency0 : _currency1).toId(), order.amountIn);
            if (order.zeroForOne) {
                totals.input0 += order.amountIn;
                totals.payout1 += solution.payouts[i];
            } else {
                totals.input1 += order.amountIn;
                totals.payout0 += solution.payouts[i];
            }
        }
    }

    function _executeResidual(BatchSolution memory solution) internal returns (int256 delta0, int256 delta1) {
        if (solution.residualAmountIn == 0) return (0, 0);
        BalanceDelta delta = poolManager.swap(
            PoolKey(_currency0, _currency1, _fee, _tickSpacing, this),
            SwapParams({
                zeroForOne: solution.residualZeroForOne,
                amountSpecified: -int256(uint256(solution.residualAmountIn)),
                sqrtPriceLimitX96: solution.sqrtPriceLimitX96
            }),
            abi.encode(solution.solutionHash)
        );
        delta0 = BalanceDeltaLibrary.amount0(delta);
        delta1 = BalanceDeltaLibrary.amount1(delta);
        int256 expectedInput = -int256(uint256(solution.residualAmountIn));
        if (solution.residualZeroForOne ? delta0 != expectedInput || delta1 < 0 : delta1 != expectedInput || delta0 < 0)
        {
            revert InvalidResidualSwap();
        }
    }

    function _finalizeSettlement(
        BatchSolution memory solution,
        bytes32[] storage ids,
        SettlementTotals memory totals,
        int256 delta0,
        int256 delta1
    ) internal {
        int256 signedAvailable0 = int256(totals.input0) + delta0;
        int256 signedAvailable1 = int256(totals.input1) + delta1;
        if (signedAvailable0 < 0 || signedAvailable1 < 0) revert UnderfundedSettlement();
        uint256 available0 = uint256(signedAvailable0);
        uint256 available1 = uint256(signedAvailable1);
        if (available0 < totals.payout0 || available1 < totals.payout1) revert UnderfundedSettlement();

        _mintClaims(_currency0, available0);
        _mintClaims(_currency1, available1);
        protocolDust[auraPoolId][_currency0] += available0 - totals.payout0;
        protocolDust[auraPoolId][_currency1] += available1 - totals.payout1;
        for (uint256 i; i < ids.length; ++i) {
            ParkedOrder storage order = orders[ids[i]];
            Currency output = order.zeroForOne ? _currency1 : _currency0;
            claimableBalances[auraPoolId][order.recipient][output] += solution.payouts[i];
            order.status = OrderStatus.SETTLED;
        }
        batchStatus[solution.batchId] = BatchStatus.SETTLED;
        emit BatchSettled(
            solution.batchId,
            solution.solutionHash,
            solution.priceNumerator,
            solution.priceDenominator,
            solution.residualZeroForOne,
            solution.residualAmountIn
        );
    }

    function _mintClaims(Currency token, uint256 amount) internal {
        uint256 maxChunk = uint256(uint128(type(int128).max));
        while (amount != 0) {
            uint256 chunk = amount > maxChunk ? maxChunk : amount;
            poolManager.mint(address(this), token.toId(), chunk);
            amount -= chunk;
        }
    }

    function _emitOrderParked(PendingOrder memory pending, bool zeroForOne, Currency currency0, Currency currency1)
        internal
    {
        emit OrderParked(
            pending.admission.batchId,
            pending.orderId,
            pending.data.owner,
            pending.data.recipient,
            zeroForOne ? currency0 : currency1,
            zeroForOne ? currency1 : currency0,
            pending.amountIn,
            pending.data.minAmountOut
        );
    }

    function _prepareOrder(SwapParams calldata params, bytes calldata hookData)
        internal
        view
        returns (PendingOrder memory pending)
    {
        if (hookData.length != 32 * 6) revert MalformedOrderData();
        pending.data = abi.decode(hookData, (AuraOrderData));
        uint256 rawAmount = uint256(-params.amountSpecified);
        if (rawAmount == 0 || rawAmount > uint256(uint128(type(int128).max))) revert AmountOverflow();
        pending.amountIn = uint128(rawAmount);
        if (
            pending.data.version != ORDER_DATA_VERSION || pending.data.owner == address(0)
                || pending.data.recipient == address(0) || pending.data.minAmountOut == 0
                || pending.data.minAmountOut > uint128(type(int128).max)
        ) revert InvalidOrder();
        if (
            block.timestamp > pending.data.deadline
                || uint256(pending.data.deadline) < block.timestamp + MIN_ORDER_LIFETIME_SECONDS
        ) revert ExpiredOrder();
        if (
            pending.data.nonce == type(uint64).max || auraRouter.nextNonce(pending.data.owner) != pending.data.nonce + 1
        ) revert InvalidNonce();
        pending.orderId = computeOrderId(pending.data, params.zeroForOne, pending.amountIn);
        if (orders[pending.orderId].status != OrderStatus.NONE) revert OrderReplay();
        pending.admission = _validateBatch(params.zeroForOne, pending.amountIn, pending.data.minAmountOut);
    }

    function _recordOrder(
        Admission memory admission,
        bytes32 orderId,
        AuraOrderData memory order,
        bool zeroForOne,
        uint128 amountIn
    ) internal {
        uint64 batchId = admission.batchId;
        activeBatchId = batchId;
        if (admission.count == 0) {
            batchStatus[batchId] = BatchStatus.OPEN;
            openedAtBlock[batchId] = uint64(block.number);
        }
        orders[orderId] = ParkedOrder({
            owner: order.owner,
            recipient: order.recipient,
            batchId: batchId,
            deadline: order.deadline,
            nonce: order.nonce,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            minAmountOut: order.minAmountOut,
            status: OrderStatus.PARKED
        });
        _batchOrderIds[batchId].push(orderId);
        if (zeroForOne) {
            aggregateToken0Input[batchId] = admission.nextAggregate;
            aggregateMinToken1Output[batchId] += order.minAmountOut;
            admission.hasZeroForOne = true;
        } else {
            aggregateToken1Input[batchId] = admission.nextAggregate;
            aggregateMinToken0Output[batchId] += order.minAmountOut;
            admission.hasOneForZero = true;
        }
        uint256 orderCount = admission.count + 1;
        if (admission.hasZeroForOne && admission.hasOneForZero && batchStatus[batchId] == BatchStatus.OPEN) {
            batchStatus[batchId] = BatchStatus.READY;
            emit BatchReady(batchId, openedAtBlock[batchId], uint8(orderCount), 0);
        }
        if (orderCount == MAX_BATCH_ORDERS) _closeReadyBatch(batchId);
    }

    function _validateBatch(bool zeroForOne, uint128 amountIn, uint128 minAmountOut)
        internal
        view
        returns (Admission memory admission)
    {
        admission.batchId = activeBatchId == 0 ? 1 : activeBatchId;
        BatchStatus status = batchStatus[admission.batchId];
        if (status == BatchStatus.OPEN || status == BatchStatus.READY) {
            if (block.number > uint256(openedAtBlock[admission.batchId]) + MAX_BATCH_WINDOW) {
                revert BatchIntakeClosed();
            }
        } else if (status != BatchStatus.NONE) {
            if (admission.batchId == type(uint64).max) revert BatchIdOverflow();
            ++admission.batchId;
        }
        admission.count = _batchOrderIds[admission.batchId].length;
        if (admission.count >= MAX_BATCH_ORDERS) revert BatchCapacityExceeded();
        (admission.hasZeroForOne, admission.hasOneForZero) = _directions(admission.batchId);
        if (
            admission.count == MAX_BATCH_ORDERS - 1 && admission.hasZeroForOne != admission.hasOneForZero
                && zeroForOne == admission.hasZeroForOne
        ) revert DirectionCapacityReserved();
        admission.nextAggregate = zeroForOne
            ? aggregateToken0Input[admission.batchId] + amountIn
            : aggregateToken1Input[admission.batchId] + amountIn;
        if (admission.nextAggregate > uint256(uint128(type(int128).max))) revert AmountOverflow();
        _requireCompatible(admission.batchId, zeroForOne, amountIn, minAmountOut);
    }

    function _readyClosurePreflight(uint64 batchId) internal view returns (bool) {
        (uint256 lowerNum, uint256 lowerDen, uint256 upperNum, uint256 upperDen, bool valid) = _frozenBounds(batchId);
        if (!valid) return false;

        uint256 priceNum = lowerNum * upperDen + upperNum * lowerDen;
        uint256 priceDen = 2 * lowerDen * upperDen;
        uint256 divisor = _gcd(priceNum, priceDen);
        priceNum /= divisor;
        priceDen /= divisor;
        if (priceNum == 0 || priceDen == 0) return false;

        if (priceNum > type(uint128).max || priceDen > type(uint128).max) {
            (priceNum, priceDen) = _boundedMidpointFallback(priceNum, priceDen, lowerNum, lowerDen, upperNum, upperDen);
            if (priceNum == 0 || priceDen == 0) return false;
        }

        return _payoutsEncodable(batchId, priceNum, priceDen);
    }

    function _frozenBounds(uint64 batchId)
        internal
        view
        returns (uint256 lowerNum, uint256 lowerDen, uint256 upperNum, uint256 upperDen, bool valid)
    {
        (bool hasZeroForOne, bool hasOneForZero) = _directions(batchId);
        if (!hasZeroForOne || !hasOneForZero) return (0, 0, 0, 0, false);

        lowerDen = 1;
        uint256 refundBoundary = block.timestamp + MAX_FINALITY_LAG_SECONDS + SETTLEMENT_GRACE_SECONDS;
        bytes32[] storage ids = _batchOrderIds[batchId];

        for (uint256 i; i < ids.length; ++i) {
            ParkedOrder storage order = orders[ids[i]];
            if (uint256(order.deadline) < refundBoundary) return (0, 0, 0, 0, false);

            if (order.zeroForOne) {
                if (lowerNum * order.amountIn < uint256(order.minAmountOut) * lowerDen) {
                    (lowerNum, lowerDen) = (order.minAmountOut, order.amountIn);
                }
            } else if (upperDen == 0 || upperNum * order.minAmountOut > uint256(order.amountIn) * upperDen) {
                (upperNum, upperDen) = (order.amountIn, order.minAmountOut);
            }
        }

        if (lowerNum == 0 || upperDen == 0) return (0, 0, 0, 0, false);
        uint256 lowerDivisor = _gcd(lowerNum, lowerDen);
        lowerNum /= lowerDivisor;
        lowerDen /= lowerDivisor;
        uint256 upperDivisor = _gcd(upperNum, upperDen);
        upperNum /= upperDivisor;
        upperDen /= upperDivisor;
        valid = true;
    }

    function _payoutsEncodable(uint64 batchId, uint256 priceNum, uint256 priceDen) internal view returns (bool) {
        bytes32[] storage ids = _batchOrderIds[batchId];
        for (uint256 i; i < ids.length; ++i) {
            ParkedOrder storage order = orders[ids[i]];
            uint256 payout = order.zeroForOne
                ? FullMath.mulDiv(order.amountIn, priceNum, priceDen)
                : FullMath.mulDiv(order.amountIn, priceDen, priceNum);
            if (payout < order.minAmountOut || payout > uint256(uint128(type(int128).max))) return false;
        }
        return true;
    }

    /// @dev Canonical uint128-bounded fallback for an oversized exact midpoint.
    /// A unit price is the least-complex neutral price whenever it is feasible;
    /// otherwise the normalized lower endpoint is deterministic and feasible.
    function _boundedMidpointFallback(
        uint256,
        uint256,
        uint256 lowerNum,
        uint256 lowerDen,
        uint256 upperNum,
        uint256 upperDen
    ) internal pure returns (uint256 priceNum, uint256 priceDen) {
        if (_withinInterval(1, 1, lowerNum, lowerDen, upperNum, upperDen)) return (1, 1);
        return (lowerNum, lowerDen);
    }

    function _withinInterval(
        uint256 numerator,
        uint256 denominator,
        uint256 lowerNum,
        uint256 lowerDen,
        uint256 upperNum,
        uint256 upperDen
    ) internal pure returns (bool) {
        return numerator * lowerDen >= lowerNum * denominator && numerator * upperDen <= upperNum * denominator;
    }

    function _gcd(uint256 a, uint256 b) internal pure returns (uint256) {
        while (b != 0) {
            (a, b) = (b, a % b);
        }
        return a;
    }

    function _closeReadyBatch(uint64 batchId) internal {
        if (!_readyClosurePreflight(batchId)) revert BatchClosurePreflightFailed();

        uint64 closedBlock = uint64(block.number);
        uint64 closedTimestamp = uint64(block.timestamp);
        batchStatus[batchId] = BatchStatus.CLOSED;
        closedAtBlock[batchId] = closedBlock;
        closedAtTimestamp[batchId] = closedTimestamp;
        emit BatchClosed(
            batchId,
            closedBlock,
            closedTimestamp,
            uint8(_batchOrderIds[batchId].length),
            keccak256(abi.encode(_batchOrderIds[batchId])),
            0
        );
    }

    function _directions(uint64 batchId) internal view returns (bool zeroForOne, bool oneForZero) {
        bytes32[] storage ids = _batchOrderIds[batchId];
        for (uint256 i; i < ids.length; ++i) {
            if (orders[ids[i]].zeroForOne) zeroForOne = true;
            else oneForZero = true;
        }
    }

    function _requireCompatible(uint64 batchId, bool zeroForOne, uint128 amountIn, uint128 minAmountOut) internal view {
        uint256 lowerNum;
        uint256 lowerDen = 1;
        uint256 upperNum;
        uint256 upperDen;
        bytes32[] storage ids = _batchOrderIds[batchId];
        for (uint256 i; i <= ids.length; ++i) {
            bool direction;
            uint128 input;
            uint128 minimum;
            if (i == ids.length) {
                (direction, input, minimum) = (zeroForOne, amountIn, minAmountOut);
            } else {
                ParkedOrder storage parked = orders[ids[i]];
                (direction, input, minimum) = (parked.zeroForOne, parked.amountIn, parked.minAmountOut);
            }
            if (direction) {
                if (lowerNum * input < uint256(minimum) * lowerDen) (lowerNum, lowerDen) = (minimum, input);
            } else if (upperDen == 0 || upperNum * minimum > uint256(input) * upperDen) {
                (upperNum, upperDen) = (input, minimum);
            }
        }
        if (lowerNum != 0 && upperDen != 0 && lowerNum * upperDen > upperNum * lowerDen) {
            revert IncompatibleLimits();
        }
    }
}
