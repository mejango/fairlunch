// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {IFairLunch} from "./interfaces/IFairLunch.sol";
import {IFairLunchDataHook} from "./interfaces/IFairLunchDataHook.sol";

/// @notice The rules for paying and cashing out a lunch.
/// @dev Every lunch's rulesets name this contract as their data hook, wrapped by `JBOmnichainDeployer`. While a lunch
/// is cooking its ruleset sells at the fixed price, and its payers can cash out for what they paid. Once it's served, a
/// payment or cash out that names the least it will take goes to the Juicebox buyback hook, which trades it in the
/// lunch's pool. The hook's own price check is too loose to rely on here, since a served lunch has no issuance price
/// under it. So a payment without a minimum lands in the balance for `FairLunch.burn`, and a cash out without one
/// reverts.
/// @dev Deployed by `FairLunch`, which it reads each lunch's record from.
contract FairLunchDataHook is IFairLunchDataHook {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a cash out reaches a lunch that has no pool to sell into.
    error FairLunchDataHook_Closed(uint256 projectId);

    /// @notice Thrown when another project's payout pays a lunch that's still selling tokens.
    error FairLunchDataHook_NoPayouts(uint256 projectId);

    /// @notice Thrown when a cash out names no minimum, or the buyback hook wouldn't sell it.
    error FairLunchDataHook_NoSale(uint256 projectId);

    /// @notice Thrown when a refund would burn tokens and return nothing.
    error FairLunchDataHook_NothingToRefund(uint256 projectId);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The registry of the buyback hook that routes a served lunch's payments and cash outs through its pool.
    IJBBuybackHookRegistry public immutable override BUYBACK_REGISTRY;

    /// @notice The contract that owns every lunch.
    IFairLunch public immutable override FAIR_LUNCH;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @dev Deployed by `FairLunch` from its constructor.
    /// @param buybackRegistry The registry of the buyback hook.
    constructor(IJBBuybackHookRegistry buybackRegistry) {
        BUYBACK_REGISTRY = buybackRegistry;
        FAIR_LUNCH = IFairLunch(msg.sender);
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Lets Fair Lunch cash out a lunch's whole balance for free, and sells everyone else's cash outs into the
    /// pool once the lunch is served.
    /// @dev Part of `IJBRulesetDataHook`. While the host is still selling, a holder cashes out for what their tokens
    /// were paid for. After that every lunch's rulesets tax cash outs at 100%, so no holder can reclaim anything from
    /// the balance. Fair Lunch cashing out zero tokens is how `burn` takes the balance without a fee:
    /// reporting the whole supply as the cash out count reclaims the whole balance. Once served, the buyback hook
    /// sells a holder's cash out into the pool instead. A cash out it wouldn't sell reverts, because the terminal
    /// would burn the tokens for nothing.
    /// @param context The cash out's context.
    /// @return cashOutTaxRate The cash out tax rate to use.
    /// @return cashOutCount The number of tokens to price the cash out with.
    /// @return totalSupply The total supply to price the cash out with.
    /// @return effectiveSurplusValue The surplus to price the cash out with.
    /// @return hookSpecifications The buyback hook, when it sells the cash out into the pool.
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            uint256 effectiveSurplusValue,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        if (context.holder == address(FAIR_LUNCH)) {
            return (0, context.totalSupply, context.totalSupply, context.surplus.value, hookSpecifications);
        }

        // Only the ruleset that sells tokens doesn't tax cash outs. While it lasts a holder takes back what the tokens
        // were paid for, or their share of the balance if that's less.
        if (context.cashOutTaxRate == 0) {
            uint256 refund = mulDiv({
                x: context.cashOutCount,
                y: 10 ** context.surplus.decimals,
                denominator: FAIR_LUNCH.TOKENS_PER_UNIT() * 1e18
            });
            cashOutCount = context.cashOutCount;

            // Money that reached the balance any other way isn't a payer's to take. The terminal pays a cash out its
            // share of the whole balance, so price the cash out with the largest count whose share is no more than the
            // refund. OpenZeppelin's `mulDiv` does this one because it can round up.
            if (_shareOf({context: context, count: cashOutCount}) > refund) {
                cashOutCount = Math.mulDiv({
                    x: refund + 1,
                    y: context.totalSupply,
                    denominator: context.surplus.value,
                    rounding: Math.Rounding.Ceil
                }) - 1;
            }

            // A cash out that would reclaim nothing would still burn its tokens.
            if (_shareOf({context: context, count: cashOutCount}) == 0) {
                revert FairLunchDataHook_NothingToRefund(context.projectId);
            }

            return (0, cashOutCount, context.totalSupply, context.surplus.value, hookSpecifications);
        }

        // Until a lunch is served, and everywhere but its host, there's no pool to sell into, and a cash out would burn
        // the tokens for nothing.
        if (FAIR_LUNCH.servedAtOf(context.projectId) == 0) revert FairLunchDataHook_Closed(context.projectId);

        (cashOutTaxRate, cashOutCount, totalSupply, effectiveSurplusValue, hookSpecifications) =
            BUYBACK_REGISTRY.beforeCashOutRecordedWith(context);

        // The sale has to name the least money it will take, `(uint256 minimumSwapAmountOut, bool skip)`, and the hook
        // has to be selling it: left to the terminal, the tokens would burn for nothing.
        if (
            hookSpecifications.length == 0 || hookSpecifications[0].noop
                || _minimumIn({metadata: context.metadata, purpose: "cashOut", word: 0}) == 0
        ) revert FairLunchDataHook_NoSale(context.projectId);
    }

    /// @notice Sells tokens at the fixed price while a lunch is cooking, and buys them from the pool once it's served.
    /// @dev Part of `IJBRulesetDataHook`. A served lunch mints nothing for a payment: the buyback hook buys from the
    /// pool for the beneficiary, and a payment it can't buy with stays in the balance for `burn`.
    /// @param context The payment's context.
    /// @return weight The number of tokens to mint per unit of money paid, as a fixed point number with 18 decimals.
    /// @return hookSpecifications The buyback hook, when it buys from the pool.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        // The ruleset that sells tokens is the only one with a price. A lunch that isn't served yet, or is served
        // elsewhere, mints nothing: its payments wait to be sent home. The rulesets refuse payments while a payer would
        // expect tokens and get none.
        if (context.weight != 0) {
            // Another project's payout arrives owing Juicebox's fee, which the terminal would take from whichever
            // payer is refunded next. So a lunch that's still selling doesn't sell to payouts.
            if (context.payer == context.terminal) revert FairLunchDataHook_NoPayouts(context.projectId);
            return (context.weight, hookSpecifications);
        }
        if (FAIR_LUNCH.servedAtOf(context.projectId) == 0) return (0, hookSpecifications);

        // A payment that doesn't name the fewest tokens it will take, `(uint256 amountToSwapWith, uint256
        // minimumSwapAmountOut, bool skipSplits)`, lands in the balance for `burn`.
        if (_minimumIn({metadata: context.metadata, purpose: "pay", word: 1}) == 0) {
            return (0, hookSpecifications);
        }

        return BUYBACK_REGISTRY.beforePayRecordedWith(context);
    }

    /// @notice Lets a lunch's buyback hook mint its tokens: it mints what it buys to a payment's beneficiary, and
    /// remints what a cash out sells.
    /// @dev Part of `IJBRulesetDataHook`. Fair Lunch mints as the project's owner, and suckers mint through the
    /// omnichain deployer.
    /// @param projectId The ID of the lunch's project.
    /// @param ruleset The lunch's current ruleset.
    /// @param addr The address to check.
    /// @return flag A flag indicating whether the address can mint the lunch's tokens.
    function hasMintPermissionFor(
        uint256 projectId,
        JBRuleset calldata ruleset,
        address addr
    )
        external
        view
        override
        returns (bool flag)
    {
        return BUYBACK_REGISTRY.hasMintPermissionFor({projectId: projectId, ruleset: ruleset, addr: addr});
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See `IERC165.supportsInterface`.
    /// @param interfaceId The ID of the interface to check for adherence to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IFairLunchDataHook).interfaceId
            || interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice The minimum a payment or cash out asks of the buyback hook, read from its metadata.
    /// @param metadata The payment's or cash out's metadata.
    /// @param purpose The buyback registry's metadata entry to read: "pay" or "cashOut".
    /// @param word The index of the minimum among the entry's words.
    /// @return minimum The minimum, or zero if there isn't one.
    function _minimumIn(
        bytes calldata metadata,
        string memory purpose,
        uint256 word
    )
        internal
        view
        returns (uint256 minimum)
    {
        (bool found, bytes memory data) = JBMetadataResolver.getDataFor({
            id: JBMetadataResolver.getId({purpose: purpose, target: address(BUYBACK_REGISTRY)}), metadata: metadata
        });
        if (found && data.length >= (word + 1) * 32) {
            // slither-disable-next-line assembly
            assembly {
                minimum := mload(add(data, mul(add(word, 1), 32)))
            }
        }
    }

    /// @notice What the terminal reclaims for an untaxed cash out priced with a count of tokens.
    /// @dev Mirrors `JBCashOuts.cashOutFrom` at a tax rate of zero.
    /// @param context The cash out's context.
    /// @param count The number of tokens to price the cash out with.
    /// @return share The amount reclaimed.
    function _shareOf(
        JBBeforeCashOutRecordedContext calldata context,
        uint256 count
    )
        internal
        pure
        returns (uint256 share)
    {
        if (count == 0) return 0;
        if (count >= context.totalSupply) return context.surplus.value;
        return mulDiv({x: context.surplus.value, y: count, denominator: context.totalSupply});
    }
}
