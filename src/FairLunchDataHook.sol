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

import {IFairLunch} from "./interfaces/IFairLunch.sol";
import {FairLunchRecord} from "./structs/FairLunchRecord.sol";

/// @notice The rules for paying and cashing out a lunch.
/// @dev Every lunch's rulesets name this contract as their data hook, wrapped by `JBOmnichainDeployer`. While a lunch
/// is cooking it sells at the fixed price until the deadline. Once it's served, payments and cash outs go to the
/// Juicebox
/// buyback hook, which trades them in the lunch's pool. Deployed by `FairLunch`, which it reads each lunch's record
/// from.
contract FairLunchDataHook is IJBRulesetDataHook {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error FairLunchDataHook_Closed(uint256 projectId, uint256 deadline);
    error FairLunchDataHook_NoSale(uint256 projectId);

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The registry of the buyback hook that routes a served lunch's payments and cash outs through its pool.
    IJBBuybackHookRegistry public immutable BUYBACK_REGISTRY;

    /// @notice The contract that owns every lunch.
    IFairLunch public immutable FAIR_LUNCH;

    /// @notice The number of seconds after serving before the buyback hook's price is trusted.
    uint256 public immutable TWAP_WINDOW;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @dev Deployed by `FairLunch` from its constructor.
    /// @param buybackRegistry The registry of the buyback hook.
    /// @param twapWindow The number of seconds after serving before the buyback hook's price is trusted.
    constructor(IJBBuybackHookRegistry buybackRegistry, uint256 twapWindow) {
        BUYBACK_REGISTRY = buybackRegistry;
        FAIR_LUNCH = IFairLunch(msg.sender);
        TWAP_WINDOW = twapWindow;
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Lets Fair Lunch cash out a lunch's whole balance for free, and sells everyone else's cash outs into the
    /// pool once the lunch is served.
    /// @dev Part of `IJBRulesetDataHook`. Every lunch's rulesets tax cash outs at 100%, so no holder can ever reclaim
    /// anything from the balance. Fair Lunch cashing out zero tokens is how `burn` takes the balance without a fee:
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

        uint256 servedAt = FAIR_LUNCH.recordOf(context.projectId).servedAt;

        // Before serving, and everywhere but the host, there's no pool to sell into.
        if (servedAt == 0) {
            return (
                context.cashOutTaxRate,
                context.cashOutCount,
                context.totalSupply,
                context.surplus.value,
                hookSpecifications
            );
        }

        (cashOutTaxRate, cashOutCount, totalSupply, effectiveSurplusValue, hookSpecifications) =
            BUYBACK_REGISTRY.beforeCashOutRecordedWith(context);

        // `(uint256 minimumSwapAmountOut, bool skip)`.
        if (
            hookSpecifications.length == 0 || hookSpecifications[0].noop
                || (block.timestamp < servedAt + TWAP_WINDOW
                    && _minimumIn({metadata: context.metadata, purpose: "cashOut", word: 0}) == 0)
        ) revert FairLunchDataHook_NoSale(context.projectId);
    }

    /// @notice Sells tokens at the fixed price while a lunch is cooking, and buys them from the pool once it's served.
    /// @dev Part of `IJBRulesetDataHook`. A served lunch mints nothing for a payment: the buyback hook buys from the
    /// pool for the beneficiary, and a payment it can't buy with stays in the balance for `burn`.
    /// @param context The payment's context.
    /// @return weight The number of tokens to mint per ETH paid, as a fixed point number with 18 decimals.
    /// @return hookSpecifications The buyback hook, when it buys from the pool.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        FairLunchRecord memory record = FAIR_LUNCH.recordOf(context.projectId);

        // Everywhere but the host, payments mint nothing and wait to be sent home.
        if (record.hostChainId != block.chainid) return (context.weight, hookSpecifications);

        if (record.servedAt != 0) {
            // Until the pool has a window of its own price history, the hook's price can't be trusted: a payment that
            // doesn't name its own minimum waits in the balance. `(uint256 amountToSwapWith, uint256
            // minimumSwapAmountOut, bool skipSplits)`.
            if (
                block.timestamp < uint256(record.servedAt) + TWAP_WINDOW
                    && _minimumIn({metadata: context.metadata, purpose: "pay", word: 1}) == 0
            ) return (0, hookSpecifications);

            return BUYBACK_REGISTRY.beforePayRecordedWith(context);
        }

        // The fundraise is over once the deadline passes.
        if (block.timestamp > record.deadline) {
            revert FairLunchDataHook_Closed({projectId: context.projectId, deadline: record.deadline});
        }

        return (context.weight, hookSpecifications);
    }

    /// @notice Lets a lunch's buyback hook mint its tokens: it mints what it buys to a payment's beneficiary, and
    /// remints what a cash out sells.
    /// @dev Part of `IJBRulesetDataHook`. Fair Lunch mints as the project's owner, and suckers mint through the
    /// omnichain deployer.
    function hasMintPermissionFor(
        uint256 projectId,
        JBRuleset calldata ruleset,
        address addr
    )
        external
        view
        override
        returns (bool)
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
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IERC165).interfaceId;
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
}
