// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseAsyncSwap} from "@openzeppelin/uniswap-hooks/src/base/BaseAsyncSwap.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {IAuraRouter} from "./interfaces/IAuraRouter.sol";
import {AuraOrderData, ParkedOrder, OrderStatus, BatchStatus} from "./types/AuraTypes.sol";

/// @title AuraHook
/// @notice Authenticated, bounded exact-input order parking for one Aura pool.
/// @dev Settlement and redemption deliberately remain outside this Sprint 1 contract.
contract AuraHook is BaseAsyncSwap {
    using PoolIdLibrary for PoolKey;

    uint8 public constant ORDER_DATA_VERSION = 1;
    uint8 public constant MAX_BATCH_ORDERS = 4;
    uint64 public constant MIN_ORDER_LIFETIME_SECONDS = 13 hours;

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "AuraOrder(uint256 chainId,address auraHook,bytes32 poolId,address owner,address recipient,uint64 nonce,uint64 deadline,bool zeroForOne,uint128 amountIn,uint128 minAmountOut)"
    );

    IAuraRouter public immutable auraRouter;
    PoolId public immutable auraPoolId;

    uint64 public activeBatchId;
    mapping(bytes32 orderId => ParkedOrder) public orders;
    mapping(uint64 batchId => bytes32[]) internal _batchOrderIds;
    mapping(uint64 batchId => BatchStatus) public batchStatus;
    mapping(uint64 batchId => uint64) public openedAtBlock;
    mapping(uint64 batchId => uint256) public aggregateToken0Input;
    mapping(uint64 batchId => uint256) public aggregateToken1Input;
    mapping(uint64 batchId => uint256) public aggregateMinToken0Output;
    mapping(uint64 batchId => uint256) public aggregateMinToken1Output;

    error InvalidRouter();
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
        auraRouter = router;
        auraPoolId = PoolKey(currency0, currency1, fee, tickSpacing, this).toId();
        if (PoolId.unwrap(router.auraPoolId()) != PoolId.unwrap(auraPoolId)) revert InvalidPool();
    }

    function batchOrderIds(uint64 batchId) external view returns (bytes32[] memory) {
        return _batchOrderIds[batchId];
    }

    function batchOrderCount(uint64 batchId) external view returns (uint256) {
        return _batchOrderIds[batchId].length;
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
        if (sender != address(auraRouter)) revert UnauthorizedRouter();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(auraPoolId)) revert InvalidPool();
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported();
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
        if (admission.hasZeroForOne && admission.hasOneForZero && batchStatus[batchId] == BatchStatus.OPEN) {
            batchStatus[batchId] = BatchStatus.READY;
            emit BatchReady(batchId, openedAtBlock[batchId], uint8(admission.count + 1), 0);
        }
    }

    function _validateBatch(bool zeroForOne, uint128 amountIn, uint128 minAmountOut)
        internal
        view
        returns (Admission memory admission)
    {
        admission.batchId = activeBatchId == 0 ? 1 : activeBatchId;
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
