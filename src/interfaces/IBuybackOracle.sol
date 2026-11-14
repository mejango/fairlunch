// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice The one read Fair Lunch needs from a buyback hook that `IJBBuybackHook` doesn't declare.
interface IBuybackOracle {
    /// @notice The Uniswap V4 hook the buyback hook prices with, and requires of every pool it routes through.
    /// @return hook The hook.
    function oracleHook() external view returns (IHooks hook);
}
