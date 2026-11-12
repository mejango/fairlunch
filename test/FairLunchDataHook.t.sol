// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {JBCashOuts} from "@bananapus/core-v6/src/libraries/JBCashOuts.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {Test} from "forge-std/Test.sol";

import {FairLunchDataHook} from "../src/FairLunchDataHook.sol";

/// @notice Refunds priced by the data hook alone, with this contract standing in for `FairLunch`.
contract FairLunchDataHookTest is Test {
    uint256 public constant TOKENS_PER_UNIT = 1_000_000;

    FairLunchDataHook internal hook;

    function setUp() public {
        hook = new FairLunchDataHook(IJBBuybackHookRegistry(address(0)));
    }

    function _context(
        uint256 count,
        uint256 supply,
        uint256 surplus,
        uint8 decimals
    )
        internal
        pure
        returns (JBBeforeCashOutRecordedContext memory context)
    {
        context.holder = address(0xA11CE);
        context.projectId = 7;
        context.cashOutCount = count;
        context.totalSupply = supply;
        context.surplus.value = surplus;
        context.surplus.decimals = decimals;
    }

    /// @notice A lunch that's still selling takes payments from payers, and none from another project's payout.
    function test_pay_refusesPayoutsWhileSelling() public {
        JBBeforePayRecordedContext memory context;
        context.terminal = address(0x7E);
        context.payer = address(0xA11CE);
        context.projectId = 7;
        context.weight = 1_000_000e18;
        (uint256 weight,) = hook.beforePayRecordedWith(context);
        assertEq(weight, 1_000_000e18);

        context.payer = context.terminal;
        vm.expectRevert(abi.encodeWithSelector(FairLunchDataHook.FairLunchDataHook_NoPayouts.selector, 7));
        hook.beforePayRecordedWith(context);
    }

    /// @notice The only token of a 24-decimal lunch can't take a balance someone else added.
    function test_refund_leavesWhatWasntPaidForIt() public {
        vm.expectRevert(abi.encodeWithSelector(FairLunchDataHook.FairLunchDataHook_NothingToRefund.selector, 7));
        hook.beforeCashOutRecordedWith(_context(1, 1, 1e30, 24));

        // With two sold, one of them takes back its one unit.
        (, uint256 count, uint256 supply, uint256 surplus,) = hook.beforeCashOutRecordedWith(_context(1, 2, 2, 24));
        assertEq(JBCashOuts.cashOutFrom(surplus, count, supply, 0), 1);
    }

    /// @notice A refund is never more than the tokens were sold for, and never burns tokens for nothing.
    function testFuzz_refund_neverPaysMoreThanThePrice(
        uint256 count,
        uint256 supply,
        uint256 surplus,
        uint8 decimals
    )
        public
        view
    {
        decimals = uint8(bound(decimals, 0, 24));
        supply = bound(supply, 1, type(uint208).max);
        count = bound(count, 1, supply);
        surplus = bound(surplus, 0, type(uint224).max);
        uint256 price = mulDiv(count, 10 ** decimals, TOKENS_PER_UNIT * 1e18);

        try hook.beforeCashOutRecordedWith(_context(count, supply, surplus, decimals)) returns (
            uint256 tax,
            uint256 pricedCount,
            uint256 pricedSupply,
            uint256 pricedSurplus,
            JBCashOutHookSpecification[] memory
        ) {
            uint256 reclaimed = JBCashOuts.cashOutFrom(pricedSurplus, pricedCount, pricedSupply, tax);
            assertLe(reclaimed, price, "more than the price");
            assertGt(reclaimed, 0, "burned for nothing");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), FairLunchDataHook.FairLunchDataHook_NothingToRefund.selector);
        }
    }
}
