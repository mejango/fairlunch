// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {IJBOmnichainDeployer} from "@bananapus/omnichain-deployers-v6/src/interfaces/IJBOmnichainDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IGeomeanOracle} from "@bananapus/univ4-router-v6/src/interfaces/IGeomeanOracle.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {FairLunchVestingDeployer} from "../FairLunchVestingDeployer.sol";
import {FairLunchConfig} from "../structs/FairLunchConfig.sol";
import {FairLunchRecord} from "../structs/FairLunchRecord.sol";

/// @notice A token launcher. A lunch raises ETH at a fixed price until a deadline, is then served into a locked Uniswap
/// V4 pool by anyone, and from then on turns every payment it receives into a buyback and burn.
interface IFairLunch {
    /// @notice Emitted when a lunch's balance is used to buy its token from the pool and burn it.
    /// @param projectId The ID of the lunch's project.
    /// @param spent The amount of ETH spent buying tokens.
    /// @param burned The number of tokens burned.
    /// @param caller The address that called the function.
    event Burn(uint256 indexed projectId, uint256 spent, uint256 burned, address caller);

    /// @notice Emitted when a lunch's liquidity fees are collected.
    /// @param projectId The ID of the lunch's project.
    /// @param tokensBurned The number of tokens collected and burned.
    /// @param ethPaid The amount of ETH collected and paid into JBP6 on the creator's behalf.
    /// @param caller The address that called the function.
    event Collect(uint256 indexed projectId, uint256 tokensBurned, uint256 ethPaid, address caller);

    /// @notice Emitted when a lunch is created on this chain.
    /// @param projectId The ID of the lunch's project on this chain.
    /// @param hostChainId The ID of the chain the lunch takes place on.
    /// @param creator The address that receives the kept ETH, the JBP6 minted by fees, and the vested tokens.
    /// @param deadline The timestamp after which the fundraise stops and the lunch can be served.
    /// @param caller The address that called the function.
    event Create(
        uint256 indexed projectId,
        uint256 indexed hostChainId,
        address indexed creator,
        uint256 deadline,
        address caller
    );

    /// @notice Emitted when a chain's revenue is sent to the lunch's host chain.
    /// @param projectId The ID of the lunch's project on this chain.
    /// @param sucker The sucker the revenue was sent through.
    /// @param tokenCount The number of tokens minted to carry the revenue.
    /// @param caller The address that called the function.
    event SendHome(uint256 indexed projectId, address sucker, uint256 tokenCount, address caller);

    /// @notice Emitted when a lunch is served.
    /// @param projectId The ID of the lunch's project.
    /// @param raised The amount of ETH the fundraise ended with.
    /// @param poolEth The amount of ETH available to the pool once the creator's keep and the JB fee were paid.
    /// @param poolTokens The number of tokens minted for the pool's other side.
    /// @param creatorTokens The number of tokens minted to the creator's vesting wallet.
    /// @param vestingWallet The creator's vesting wallet.
    /// @param positionId The ID of the Uniswap V4 liquidity position.
    /// @param caller The address that called the function.
    event Serve(
        uint256 indexed projectId,
        uint256 raised,
        uint256 poolEth,
        uint256 poolTokens,
        uint256 creatorTokens,
        address vestingWallet,
        uint256 positionId,
        address caller
    );

    /// @notice The controller every lunch is launched with.
    function CONTROLLER() external view returns (IJBController);

    /// @notice The directory of terminals and controllers.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The most the creator can keep of the raise or of the token supply, out of
    /// `JBConstants.SPLITS_TOTAL_PERCENT`.
    function MAX_CREATOR_PERCENT() external view returns (uint256);

    /// @notice The deployer every lunch is launched through, which wires up its suckers.
    function OMNICHAIN_DEPLOYER() external view returns (IJBOmnichainDeployer);

    /// @notice The Uniswap V4 hook every lunch's pool uses, which records the price history buybacks are bounded by.
    function ORACLE_HOOK() external view returns (IGeomeanOracle);

    /// @notice The Permit2 contract the position manager pulls tokens through.
    function PERMIT2() external view returns (IAllowanceTransfer);

    /// @notice The fee of every lunch's pool, in hundredths of a basis point.
    function POOL_FEE() external view returns (uint24);

    /// @notice The Uniswap V4 pool manager.
    function POOL_MANAGER() external view returns (IPoolManager);

    /// @notice The Uniswap V4 position manager.
    function POSITION_MANAGER() external view returns (IPositionManager);

    /// @notice The registry of every lunch's suckers.
    function SUCKER_REGISTRY() external view returns (IJBSuckerRegistry);

    /// @notice The terminal every lunch accepts ETH through.
    function TERMINAL() external view returns (IJBMultiTerminal);

    /// @notice The tick spacing of every lunch's pool.
    function TICK_SPACING() external view returns (int24);

    /// @notice The token ledger.
    function TOKENS() external view returns (IJBTokens);

    /// @notice The number of tokens a payer receives per ETH during the fundraise, and the price the pool opens at.
    function TOKENS_PER_ETH() external view returns (uint256);

    /// @notice The farthest a buyback can push the price past its time-weighted average, in ticks.
    function TWAP_MAX_DEVIATION() external view returns (int24);

    /// @notice The number of seconds of price history a buyback is bounded by, and the wait after serving before the
    /// first buyback.
    function TWAP_WINDOW() external view returns (uint32);

    /// @notice The Uniswap V4 pool of a lunch.
    /// @param projectId The ID of the lunch's project.
    /// @return key The pool's key.
    function poolKeyOf(uint256 projectId) external view returns (PoolKey memory key);

    /// @notice What Fair Lunch remembers about a lunch.
    /// @param projectId The ID of the lunch's project.
    /// @return record The lunch's record.
    function recordOf(uint256 projectId) external view returns (FairLunchRecord memory record);

    /// @notice The deployer of the wallets that vest creators' tokens.
    function VESTING_DEPLOYER() external view returns (FairLunchVestingDeployer);

    /// @notice Use a served lunch's whole balance to buy its token from the pool and burn it.
    /// @param projectId The ID of the lunch's project.
    /// @return spent The amount of ETH spent buying tokens.
    /// @return burned The number of tokens burned.
    function burn(uint256 projectId) external returns (uint256 spent, uint256 burned);

    /// @notice Collect a served lunch's liquidity fees, burning the token side and paying the ETH side into JBP6 with
    /// the creator as beneficiary.
    /// @param projectId The ID of the lunch's project.
    /// @return tokensBurned The number of tokens collected and burned.
    /// @return ethPaid The amount of ETH paid into JBP6.
    function collect(uint256 projectId) external returns (uint256 tokensBurned, uint256 ethPaid);

    /// @notice Make a lunch on this chain.
    /// @param config The lunch's configuration.
    /// @return projectId The ID of the lunch's project on this chain.
    function createFor(FairLunchConfig calldata config) external payable returns (uint256 projectId);

    /// @notice Send this chain's revenue to the lunch's host chain.
    /// @param projectId The ID of the lunch's project on this chain.
    function sendHome(uint256 projectId) external payable;

    /// @notice One-shot setter for this chain's Uniswap V4 addresses.
    /// @param positionManager The Uniswap V4 position manager.
    /// @param oracleHook The Uniswap V4 hook every lunch's pool uses.
    function setChainSpecificConstants(IPositionManager positionManager, IGeomeanOracle oracleHook) external;

    /// @notice Serve a lunch once its deadline has passed.
    /// @param projectId The ID of the lunch's project.
    function serve(uint256 projectId) external;
}
