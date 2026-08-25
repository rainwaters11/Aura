// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {AuraHook} from "../src/AuraHook.sol";
import {OrderStatus} from "../src/types/AuraTypes.sol";
import {AuraParkingBase} from "./AuraParking.t.sol";

/// @notice Sprint 1 authorization and accounting regression gate.
contract AuraSecurityTest is AuraParkingBase {
    using CurrencyLibrary for Currency;

    function test_routerAlwaysAttributesOrderToCaller() public {
        address recipient = makeAddr("recipient");

        _placeWithRecipient(recipient);

        bytes32 orderId = hook.batchOrderIds(1)[0];
        (address storedOwner, address storedRecipient,,,,,,, OrderStatus status) = hook.orders(orderId);
        assertEq(storedOwner, owner);
        assertEq(storedRecipient, recipient);
        assertEq(uint8(status), uint8(OrderStatus.PARKED));
    }

    function test_unauthenticatedParkingCannotMoveFundsOrCreateClaims() public {
        uint256 claimsBefore = poolManager.balanceOf(address(hook), currency0.toId());
        uint256 custodyBefore = MockERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));

        vm.prank(address(poolManager));
        vm.expectRevert(AuraHook.UnauthorizedRouter.selector);
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -int256(uint256(AMOUNT)), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        hook.beforeSwap(makeAddr("attacker"), key, params, _data(0));

        assertEq(hook.batchOrderCount(1), 0);
        assertEq(poolManager.balanceOf(address(hook), currency0.toId()), claimsBefore);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager)), custodyBefore);
    }

    function test_perDirectionAggregateCannotExceedSignedPoolManagerLimit() public {
        uint128 maximum = uint128(type(int128).max);
        _place(true, maximum, 1);

        uint64 deadline = uint64(block.timestamp + router.MIN_ORDER_LIFETIME_SECONDS());
        vm.prank(owner);
        vm.expectRevert();
        router.placeOrder(true, 1, 1, owner, deadline);

        assertEq(hook.aggregateToken0Input(1), maximum);
        assertEq(poolManager.balanceOf(address(hook), currency0.toId()), maximum);
        assertEq(hook.batchOrderCount(1), 1);
    }

    function test_fifthOrderStartsNewBatchWithoutMutatingClosedBatchAccounting() public {
        _place(true, AMOUNT, MINIMUM);
        _place(false, AMOUNT, MINIMUM);
        _place(true, AMOUNT, MINIMUM);
        _place(false, AMOUNT, MINIMUM);

        uint256 token0Input = hook.aggregateToken0Input(1);
        uint256 token1Input = hook.aggregateToken1Input(1);
        _place(true, AMOUNT, MINIMUM);

        assertEq(hook.batchOrderCount(1), hook.MAX_BATCH_ORDERS());
        assertEq(hook.aggregateToken0Input(1), token0Input);
        assertEq(hook.aggregateToken1Input(1), token1Input);
        assertEq(hook.batchOrderCount(2), 1);
    }

    function _placeWithRecipient(address recipient) internal {
        uint64 deadline = uint64(block.timestamp + router.MIN_ORDER_LIFETIME_SECONDS());
        vm.prank(owner);
        router.placeOrder(true, AMOUNT, MINIMUM, recipient, deadline);
    }
}
