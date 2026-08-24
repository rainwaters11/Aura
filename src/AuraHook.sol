// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseAsyncSwap} from "@openzeppelin/uniswap-hooks/src/base/BaseAsyncSwap.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IAuraRouter} from "./interfaces/IAuraRouter.sol";
import {AuraOrderData, ParkedOrder, OrderStatus, BatchStatus} from "./types/AuraTypes.sol";

/// @title AuraHook
/// @notice Authenticated, bounded exact-input order parking for one Aura pool.
/// @dev Settlement and redemption deliberately remain outside this Sprint 1 contract.
contract AuraHook is BaseAsyncSwap, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint8 public constant ORDER_DATA_VERSION = 1;
    uint8 public constant MAX_BATCH_ORDERS = 4;
    uint64 public constant MAX_BATCH_WINDOW = 20;
    uint64 public constant MAX_FINALITY_LAG_SECONDS = 12 hours;
    uint64 public constant SETTLEMENT_GRACE_SECONDS = 5 minutes;
    uint64 public constant MIN_ORDER_LIFETIME_SECONDS = 13 hours;

    struct Uint768 {
        uint256 top;
        uint256 middle;
        uint256 bottom;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "AuraOrder(uint256 chainId,address auraHook,bytes32 poolId,address owner,address recipient,uint64 nonce,uint64 deadline,bool zeroForOne,uint128 amountIn,uint128 minAmountOut)"
    );

    IAuraRouter public immutable auraRouter;
    PoolId public immutable auraPoolId;
    Currency private immutable _currency0;
    Currency private immutable _currency1;

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

    bool private _refundUnlocking;
    bytes32 private _refundOrderId;

    error InvalidRouter();
    error InvalidPoolManager();
    error UnauthorizedRouter();
    error InvalidPool();
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
    error UnauthorizedOrderOwner();
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

    constructor(
        IPoolManager manager,
        IAuraRouter router,
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing
    ) BaseHook(manager) {
        if (address(router) == address(0)) revert InvalidRouter();
        if (address(router.poolManager()) != address(manager)) revert InvalidPoolManager();
        auraRouter = router;
        _currency0 = currency0;
        _currency1 = currency1;
        auraPoolId = PoolKey(currency0, currency1, fee, tickSpacing, this).toId();
        if (PoolId.unwrap(router.auraPoolId()) != PoolId.unwrap(auraPoolId)) revert InvalidPool();
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

    /// @notice Cancels one caller-owned parked order after its batch becomes refundable.
    function cancelExpiredOrder(bytes32 orderId) external {
        ParkedOrder storage order = orders[orderId];
        if (order.status != OrderStatus.PARKED) revert OrderNotParked();
        if (order.owner != msg.sender) revert UnauthorizedOrderOwner();
        if (batchStatus[order.batchId] != BatchStatus.REFUNDABLE) revert BatchNotRefundable();

        order.status = OrderStatus.CANCELLED;
        _refundUnlocking = true;
        _refundOrderId = orderId;
        poolManager.unlock(abi.encode(orderId));
        _refundUnlocking = false;
        _refundOrderId = bytes32(0);

        Currency token = order.zeroForOne ? _currency0 : _currency1;
        emit OrderCancelled(orderId, order.owner, token, order.amountIn);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedUnlockCallback();
        if (!_refundUnlocking) revert InvalidRefundContext();
        bytes32 orderId = abi.decode(rawData, (bytes32));
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
            (priceNum, priceDen) = _bestBoundedMidpoint(priceNum, priceDen, lowerNum, lowerDen, upperNum, upperDen);
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
    function _bestBoundedMidpoint(
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
