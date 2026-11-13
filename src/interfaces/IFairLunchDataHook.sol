// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";

import {IFairLunch} from "./IFairLunch.sol";

/// @notice The rules for paying and cashing out a lunch.
interface IFairLunchDataHook is IJBRulesetDataHook {
    /// @notice The registry of the buyback hook that routes a served lunch's payments and cash outs through its pool.
    function BUYBACK_REGISTRY() external view returns (IJBBuybackHookRegistry);

    /// @notice The contract that owns every lunch.
    function FAIR_LUNCH() external view returns (IFairLunch);
}
