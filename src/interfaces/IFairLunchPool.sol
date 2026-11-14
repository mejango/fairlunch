// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IGeomeanOracle} from "@bananapus/univ4-router-v6/src/interfaces/IGeomeanOracle.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {IFairLunch} from "./IFairLunch.sol";

/// @notice The holder of every lunch's liquidity, and the only thing that trades for a lunch in its pool.
interface IFairLunchPool {
    /// @notice The only address this contract takes calls from.
    function FAIR_LUNCH() external view returns (IFairLunch);

    /// @notice The Permit2 contract the position manager pulls tokens through.
    function PERMIT2() external view returns (IAllowanceTransfer);

    /// @notice The Uniswap V4 hook every lunch's pool uses, which records the price history buybacks are bounded by.
    function oracleHook() external view returns (IGeomeanOracle);

    /// @notice The Uniswap V4 pool manager.
    function poolManager() external view returns (IPoolManager);

    /// @notice The Uniswap V4 position manager.
    function positionManager() external view returns (IPositionManager);

    /// @notice Buy a lunch's token from its pool, as far as the price bound allows.
    /// @param key The pool's key.
    /// @param moneyIs0 Whether the money is the pool's currency0.
    /// @param amount The amount of money to buy with, already sent to this contract (as `msg.value` if it's ETH).
    /// @param twapWindow The number of seconds of price history the buy is bounded by.
    /// @param maxDeviation The farthest the buy can push the price past that history's average, in ticks.
    /// @return spent The amount of money spent.
    function buy(
        PoolKey calldata key,
        bool moneyIs0,
        uint256 amount,
        uint32 twapWindow,
        int24 maxDeviation
    )
        external
        payable
        returns (uint256 spent);

    /// @notice Collect a position's fees and send both sides to `FAIR_LUNCH`.
    /// @param key The pool's key.
    /// @param positionId The ID of the position.
    function collect(PoolKey calldata key, uint256 positionId) external;

    /// @notice Put the money and the tokens this contract was given into a lunch's pool as one full-range position.
    /// @param key The pool's key.
    /// @param moneyIs0 Whether the money is the pool's currency0.
    /// @param money The amount of money to pool, already sent to this contract (as `msg.value` if it's ETH).
    /// @param tokens The number of tokens to pool, already sent to this contract.
    /// @return positionId The ID of the position.
    function open(
        PoolKey calldata key,
        bool moneyIs0,
        uint256 money,
        uint256 tokens
    )
        external
        payable
        returns (uint256 positionId);

    /// @notice One-shot setter for this chain's Uniswap V4 addresses.
    /// @param newPositionManager The Uniswap V4 position manager. The pool manager is read from it.
    /// @param newOracleHook The Uniswap V4 hook every lunch's pool uses.
    function setChainSpecificConstants(IPositionManager newPositionManager, IGeomeanOracle newOracleHook) external;
}
