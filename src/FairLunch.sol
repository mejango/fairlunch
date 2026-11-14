// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBBuybackHook} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHook.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPayerTrackerLib} from "@bananapus/core-v6/src/libraries/JBPayerTrackerLib.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBCurrencyAmount} from "@bananapus/core-v6/src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJBOmnichainDeployer} from "@bananapus/omnichain-deployers-v6/src/interfaces/IJBOmnichainDeployer.sol";
import {JBSuckerDeploymentConfig} from "@bananapus/omnichain-deployers-v6/src/structs/JBSuckerDeploymentConfig.sol";
import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {IJBSuckerExtended} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerExtended.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBTokenMapping} from "@bananapus/suckers-v6/src/structs/JBTokenMapping.sol";
import {IGeomeanOracle} from "@bananapus/univ4-router-v6/src/interfaces/IGeomeanOracle.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {FairLunchClaims} from "./FairLunchClaims.sol";
import {FairLunchDataHook} from "./FairLunchDataHook.sol";
import {FairLunchPool} from "./FairLunchPool.sol";
import {IBuybackOracle} from "./interfaces/IBuybackOracle.sol";
import {IFairLunch} from "./interfaces/IFairLunch.sol";
import {IFairLunchClaims} from "./interfaces/IFairLunchClaims.sol";
import {IFairLunchDataHook} from "./interfaces/IFairLunchDataHook.sol";
import {IFairLunchPool} from "./interfaces/IFairLunchPool.sol";
import {IRevnetOperator} from "./interfaces/IRevnetOperator.sol";
import {ISuckerRoute} from "./interfaces/ISuckerRoute.sol";
import {FairLunchConfig} from "./structs/FairLunchConfig.sol";
import {FairLunchRecord} from "./structs/FairLunchRecord.sol";

/// @notice Tasty token launcher.
/// @dev A lunch is a Juicebox project this contract owns forever, so nobody can ever change it.
///
/// Cooking: until its deadline, a lunch sells its token at a fixed price on its host chain, for the money it names:
/// ETH or an ERC-20. Nothing can be cashed out. A payment in anything else is swapped into that money on the way in
/// by the Juicebox router terminal.
///
/// Served: once the deadline passes, anyone can serve the lunch. The raise leaves the project through a normal payout
/// (so the JB fee applies, and the JBP6 it mints goes to the creator), the creator gets the share they asked for up to
/// their cap, their token allocation starts vesting, and everything else becomes one full-range Uniswap V4 position
/// that this contract holds forever.
///
/// Eating: from then on the lunch's pool is the only place its token comes from. A payment or cash out that names the
/// least it will take trades in the pool through the Juicebox buyback hook: the payment buys for its beneficiary, the
/// cash out sells. Every other payment lands in the project's balance, along with revenue carried from other chains
/// through the lunch's suckers. `burn` uses the balance to buy the token and burn it, never paying more than a bound
/// above the pool's time-weighted average price. Whatever a bounded buy can't spend waits for the next one.
///
/// This contract is each lunch's owner. It deploys `FairLunchDataHook`, each lunch's data hook (wrapped by
/// `JBOmnichainDeployer`), and `FairLunchPool`, which holds each lunch's liquidity and trades in its pool. This
/// contract holds no ETH or tokens between calls.
contract FairLunch is ERC2771Context, ReentrancyGuardTransient, IFairLunch, IJBPayerTracker, IERC721Receiver {
    // A library that adds default safety checks to ERC-20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a one-shot setter is called a second time.
    error FairLunch_AlreadyConfigured();

    /// @notice Thrown when a lunch has already been served.
    error FairLunch_AlreadyServed(uint256 projectId);

    /// @notice Thrown when a lunch's host sucker has no token mapped to send revenue home with.
    error FairLunch_HostMapsNoTokens();

    /// @notice Thrown when a lunch's claims aren't given as a share, a list and a vesting duration that go together.
    error FairLunch_InvalidClaims(uint256 claimsPercent, bytes32 claimsRoot, uint256 claimsVestingDuration);

    /// @notice Thrown when a lunch has no creator.
    error FairLunch_InvalidCreator();

    /// @notice Thrown when a lunch's deadline has passed on its host chain, or is too far away.
    error FairLunch_InvalidDeadline(uint256 deadline);

    /// @notice Thrown when a lunch has no host chain.
    error FairLunch_InvalidHostChain();

    /// @notice Thrown when a lunch's creator would keep the whole raise.
    error FairLunch_InvalidKeepPercent(uint256 keepPercent);

    /// @notice Thrown when a lunch's buyback hook prices with another Uniswap V4 hook than this contract's.
    error FairLunch_InvalidOracleHook(IHooks hook);

    /// @notice Thrown when the project to share pool fees with is JBP6 or doesn't exist.
    error FairLunch_InvalidSplitProject(uint256 projectId);

    /// @notice Thrown when a lunch's suckers name a peer, or its host sucker doesn't map the lunch's money home.
    error FairLunch_InvalidSuckers();

    /// @notice Thrown when a lunch's money isn't a token a lunch can raise on this chain.
    error FairLunch_InvalidToken(address token);

    /// @notice Thrown when the creator and the claims would get more than `MAX_GRANTED_PERCENT` together.
    error FairLunch_InvalidTokenPercent(uint256 grantedPercent);

    /// @notice Thrown when a lunch has no sucker to its host chain.
    error FairLunch_NoHostSucker(uint256 projectId, uint256 hostChainId);

    /// @notice Thrown when this chain's Uniswap V4 addresses haven't been set yet.
    error FairLunch_NotConfigured();

    /// @notice Thrown when a lunch is hosted on another chain.
    error FairLunch_NotHost(uint256 projectId, uint256 hostChainId);

    /// @notice Thrown when a project isn't a lunch hosted on another chain.
    error FairLunch_NotRemote(uint256 projectId);

    /// @notice Thrown when a lunch hasn't been served yet.
    error FairLunch_NotServed(uint256 projectId);

    /// @notice Thrown when a lunch's fundraise ended with nothing to serve.
    error FairLunch_NothingRaised(uint256 projectId);

    /// @notice Thrown when it's too early: a lunch's fundraise is still open, or its first burn has to wait.
    error FairLunch_TooEarly(uint256 projectId, uint256 readyAt);

    /// @notice Thrown when the caller isn't allowed to make the call.
    error FairLunch_Unauthorized(address caller);

    /// @notice Thrown when a one-shot setter is given the zero address.
    error FairLunch_ZeroAddress();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The most of the token supply the creator and the claims can get together, out of
    /// `JBConstants.SPLITS_TOTAL_PERCENT`. Payers and the pool share the rest, so the supply is at most 100 times
    /// theirs.
    uint256 public constant override MAX_GRANTED_PERCENT = uint256(JBConstants.SPLITS_TOTAL_PERCENT) * 99 / 100;

    /// @notice The fee of every lunch's pool, in hundredths of a basis point (1%).
    uint24 public constant override POOL_FEE = 10_000;

    /// @notice The tick spacing of every lunch's pool.
    int24 public constant override TICK_SPACING = 200;

    /// @notice The number of tokens a payer receives per whole unit of the lunch's money (per ETH, per USDC) during
    /// the fundraise, and the price the pool opens at.
    uint256 public constant override TOKENS_PER_UNIT = 1_000_000;

    /// @notice The farthest a burn's buy can push the price past its time-weighted average, in ticks (about 2%).
    int24 public constant override TWAP_MAX_DEVIATION = 200;

    /// @notice The number of seconds of price history a burn's buy is bounded by, and the wait after serving before
    /// the first one.
    uint32 public constant override TWAP_WINDOW = 30 minutes;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The ID of the project that takes fees, whose token is JBP6.
    uint256 internal constant _FEE_PROJECT_ID = 1;

    /// @notice The most tokens a lunch's pool is opened with: about 1.3 trillion whole units of money's worth.
    uint256 internal constant _MAX_POOL_TOKENS = type(uint120).max;

    /// @notice How many times the local supply `sendHome` mints, so its pro rata cash out carries all but a millionth
    /// of the balance.
    uint256 internal constant _SEND_HOME_MULTIPLE = 1_000_000;

    /// @notice The gas a sucker reserves on the remote chain for a claim.
    uint32 internal constant _SUCKER_MIN_GAS = 200_000;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The registry of the buyback hook that routes a served lunch's payments and cash outs through its pool.
    IJBBuybackHookRegistry public immutable override BUYBACK_REGISTRY;

    /// @notice The holder of the tokens each lunch gives to its creator and to a list of addresses.
    IFairLunchClaims public immutable override CLAIMS;

    /// @notice The controller every lunch is launched with.
    IJBController public immutable override CONTROLLER;

    /// @notice The data hook of every lunch, which holds the rules for its payments and cash outs.
    IFairLunchDataHook public immutable override DATA_HOOK;

    /// @notice The directory of terminals and controllers.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The deployer every lunch is launched through, which wires up its suckers.
    IJBOmnichainDeployer public immutable override OMNICHAIN_DEPLOYER;

    /// @notice The holder of every lunch's liquidity, which trades in its pool.
    IFairLunchPool public immutable override POOL;

    /// @notice The terminal that takes payments in other tokens and swaps them into a lunch's money.
    IJBTerminal public immutable override ROUTER_TERMINAL_REGISTRY;

    /// @notice The registry of every lunch's suckers.
    IJBSuckerRegistry public immutable override SUCKER_REGISTRY;

    /// @notice The terminal every lunch holds its money in.
    IJBMultiTerminal public immutable override TERMINAL;

    /// @notice The token ledger.
    IJBTokens public immutable override TOKENS;

    //*********************************************************************//
    // -------------- internal immutable stored properties -------------- //
    //*********************************************************************//

    /// @notice The address allowed to set the chain-specific constants, once.
    /// @dev Every constructor argument is the same on every chain, so this contract's address is too. Lunches rely on
    /// that: a chain's revenue is bridged to this same address on the host chain. The Uniswap addresses differ per
    /// chain, so this deployer sets them afterwards through `setChainSpecificConstants`.
    address internal immutable _DEPLOYER;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The Uniswap V4 hook every lunch's pool uses, which records the price history a burn's buy is bounded by.
    /// @dev Set once by `_DEPLOYER` through `setChainSpecificConstants`. Zero until then.
    IGeomeanOracle public override oracleHook;

    /// @notice The ID of the project that gets half of the money side of every lunch's pool fees on this chain. JBP6
    /// gets the other half.
    /// @dev Set once by JBP6's operator through `setSplitProjectId`. Zero until then, and JBP6 gets it all.
    uint256 public override splitProjectId;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice What Fair Lunch remembers about each lunch.
    /// @custom:param projectId The ID of the lunch's project.
    mapping(uint256 projectId => FairLunchRecord) internal _recordOf;

    //*********************************************************************//
    // ------------------- transient stored properties ------------------- //
    //*********************************************************************//

    /// @notice The account that paid the creation fee for the lunch currently being created.
    /// @dev Part of `IJBPayerTracker`. Exposed while the launch runs so `JBProjects` credits the fee to the creator's
    /// transaction instead of this contract. Cleared once the launch returns.
    address public transient override originalPayer;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @dev Every argument is the same address on every supported chain, so this contract's address is too.
    /// @param omnichainDeployer The deployer every lunch is launched through.
    /// @param buybackRegistry The registry of the buyback hook.
    /// @param terminal The terminal every lunch holds its money in.
    /// @param routerTerminalRegistry The terminal that takes payments in other tokens.
    /// @param suckerRegistry The registry of every lunch's suckers.
    /// @param permit2 The Permit2 contract the position manager pulls tokens through.
    /// @param deployer The address allowed to set the chain-specific constants, once.
    /// @param trustedForwarder The trusted forwarder for the ERC2771Context.
    constructor(
        IJBOmnichainDeployer omnichainDeployer,
        IJBBuybackHookRegistry buybackRegistry,
        IJBMultiTerminal terminal,
        IJBTerminal routerTerminalRegistry,
        IJBSuckerRegistry suckerRegistry,
        IAllowanceTransfer permit2,
        address deployer,
        address trustedForwarder
    )
        ERC2771Context(trustedForwarder)
    {
        OMNICHAIN_DEPLOYER = omnichainDeployer;
        BUYBACK_REGISTRY = buybackRegistry;
        DATA_HOOK = new FairLunchDataHook(buybackRegistry);
        CONTROLLER = omnichainDeployer.CONTROLLER();
        DIRECTORY = terminal.DIRECTORY();
        TERMINAL = terminal;
        ROUTER_TERMINAL_REGISTRY = routerTerminalRegistry;
        TOKENS = terminal.TOKENS();
        SUCKER_REGISTRY = suckerRegistry;
        POOL = new FairLunchPool(permit2);
        CLAIMS = new FairLunchClaims();
        _DEPLOYER = deployer;
    }

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Accept ETH from payouts, cash outs, suckers and `POOL`.
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Use a served lunch's whole balance to buy its token from the pool and burn it.
    /// @dev Anyone can call this. The buy stops at a price `TWAP_MAX_DEVIATION` ticks above the pool's average over the
    /// last `TWAP_WINDOW`, and whatever it couldn't spend goes back into the balance. The first buyback waits a full
    /// `TWAP_WINDOW` after serving so that the average holds only prices from the served pool: anyone can create the
    /// pool early and leave misleading history in it.
    /// @param projectId The ID of the lunch's project.
    /// @return spent The amount of the lunch's money spent buying tokens.
    /// @return burned The number of tokens burned.
    function burn(uint256 projectId) external override nonReentrant returns (uint256 spent, uint256 burned) {
        FairLunchRecord storage record = _recordOf[projectId];

        // Only a served lunch buys back.
        uint256 servedAt = servedAtOf(projectId);
        if (servedAt == 0) revert FairLunch_NotServed(projectId);

        // Wait for a window of the served pool's own price history.
        if (block.timestamp < servedAt + TWAP_WINDOW) {
            revert FairLunch_TooEarly({projectId: projectId, readyAt: servedAt + TWAP_WINDOW});
        }

        // Take the lunch's whole balance. The data hook lets this contract, and only it, cash out everything for free.
        uint256 amount = TERMINAL.cashOutTokensOf({
            holder: address(this),
            projectId: projectId,
            cashOutCount: 0,
            tokenToReclaim: record.token,
            minTokensReclaimed: 0,
            beneficiary: payable(address(this)),
            metadata: ""
        });

        if (amount != 0) {
            // Revenue that reached the lunch as another project's payout pays its Juicebox fee here. The JBP6 that buys
            // belongs to the creator.
            _sendFeeTokensTo(record.creator);

            // Buy as much as the price bound allows. The tokens and the money the buy couldn't spend come back.
            (PoolKey memory key, bool moneyIs0) = _poolOf({projectId: projectId, token: record.token});
            spent = POOL.buy{value: _handTo({to: address(POOL), token: record.token, amount: amount})}({
                key: key, moneyIs0: moneyIs0, amount: amount, twapWindow: TWAP_WINDOW, maxDeviation: TWAP_MAX_DEVIATION
            });

            // Put back what the buy couldn't spend.
            if (amount != spent) _addToBalanceOf({projectId: projectId, token: record.token, amount: amount - spent});
        }

        // Burn everything bought, along with any tokens that arrived carrying revenue from other chains.
        burned = _burnTokensOf(projectId);

        emit Burn({projectId: projectId, spent: spent, burned: burned, caller: _msgSender()});
    }

    /// @notice Collect a served lunch's liquidity fees, burning the token side and paying the money side into JBP6 with
    /// the creator as beneficiary. Once `splitProjectId` is set, half of the money side is paid into that project
    /// the same way.
    /// @dev Anyone can call this. The position's liquidity is never touched. Whatever a project doesn't take in this
    /// contract's terminal goes into the lunch's balance instead, where `burn` uses it.
    /// @param projectId The ID of the lunch's project.
    /// @return tokensBurned The number of tokens collected and burned.
    /// @return paid The amount of the lunch's money collected.
    function collect(uint256 projectId) external override nonReentrant returns (uint256 tokensBurned, uint256 paid) {
        FairLunchRecord storage record = _recordOf[projectId];

        // Only a served lunch has a position.
        if (servedAtOf(projectId) == 0) revert FairLunch_NotServed(projectId);

        address token = record.token;
        uint256 before = _holdingOf(token);

        // Take the position's fees without touching its liquidity.
        POOL.collect({key: poolKeyOf(projectId), positionId: record.positionId});

        // Burn the token side.
        tokensBurned = _burnTokensOf(projectId);

        paid = _holdingOf(token) - before;
        if (paid != 0) {
            // Half goes to the project that shares pool fees with JBP6, once one is set.
            uint256 shared = splitProjectId == 0 ? 0 : paid / 2;

            // What neither project takes goes into the lunch's balance.
            uint256 kept = _payFeeTo({
                projectId: projectId,
                feeProjectId: _FEE_PROJECT_ID,
                token: token,
                amount: paid - shared,
                beneficiary: record.creator
            });
            if (shared != 0) {
                kept += _payFeeTo({
                    projectId: projectId,
                    feeProjectId: splitProjectId,
                    token: token,
                    amount: shared,
                    beneficiary: record.creator
                });
            }
            if (kept != 0) _addToBalanceOf({projectId: projectId, token: token, amount: kept});
        }

        emit Collect({projectId: projectId, tokensBurned: tokensBurned, paid: paid, caller: _msgSender()});
    }

    /// @notice Make a lunch on this chain.
    /// @dev Call this with the same configuration, from the same address, on the host chain and on every other chain
    /// the lunch should collect revenue from. `msg.value` must be the project creation fee, if there is one.
    /// @param config The lunch's configuration.
    /// @return projectId The ID of the lunch's project on this chain.
    function createFor(FairLunchConfig calldata config) external payable override returns (uint256 projectId) {
        bool isHost = config.hostChainId == block.chainid;

        // The money this chain's project takes: the lunch's own on the host, and on a copy whatever its first sucker
        // maps home.
        address token = config.token;
        if (!isHost && config.suckerDeploymentConfiguration.deployerConfigurations.length != 0) {
            JBTokenMapping[] calldata mappings = config.suckerDeploymentConfiguration.deployerConfigurations[0].mappings;
            if (mappings.length != 0) token = mappings[0].localToken;
        }

        // A lunch needs a creator and a host chain.
        if (config.creator == address(0)) revert FairLunch_InvalidCreator();
        if (config.hostChainId == 0) revert FairLunch_InvalidHostChain();

        // Only the host sells tokens, so only the host needs time left to sell them: two seconds at least, since
        // `serve` can't queue its ruleset in the second after the launch's two. A copy on another chain can be
        // made after the deadline: its terms, deadline included, must match the host's to pair with it.
        if ((isHost && config.deadline <= block.timestamp + 1) || config.deadline > block.timestamp + type(uint32).max)
        {
            revert FairLunch_InvalidDeadline(config.deadline);
        }

        // A lunch that raises ETH takes ETH everywhere, and one that raises an ERC-20 takes ERC-20s everywhere. None
        // takes JBP6: this contract passes on all the JBP6 it holds as fee proceeds.
        if (
            config.token == address(0)
                || (config.token == JBConstants.NATIVE_TOKEN) != (token == JBConstants.NATIVE_TOKEN)
                || token == address(TOKENS.tokenOf(_FEE_PROJECT_ID))
        ) revert FairLunch_InvalidToken(token);

        // A creator can't keep the whole raise: `serve` needs something to open the pool with, and without it the raise
        // would be stuck.
        if (config.keepPercent >= JBConstants.SPLITS_TOTAL_PERCENT) {
            revert FairLunch_InvalidKeepPercent(config.keepPercent);
        }

        // Payers and the pool need a share of the supply too.
        if (uint256(config.tokenPercent) + config.claimsPercent > MAX_GRANTED_PERCENT) {
            revert FairLunch_InvalidTokenPercent(uint256(config.tokenPercent) + config.claimsPercent);
        }

        // Claims come with a list, and only claims vest.
        if (
            (config.claimsPercent == 0) != (config.claimsRoot == bytes32(0))
                || (config.claimsPercent == 0 && config.claimsVestingDuration != 0)
        ) {
            revert FairLunch_InvalidClaims({
                claimsPercent: config.claimsPercent,
                claimsRoot: config.claimsRoot,
                claimsVestingDuration: config.claimsVestingDuration
            });
        }

        // A lunch needs this chain's Uniswap addresses.
        if (address(oracleHook) == address(0)) revert FairLunch_NotConfigured();

        // Scope the salt to the caller so nobody else can take a lunch's addresses on another chain, and to the
        // lunch's terms so only copies with the very same terms are bridged to each other. A copy with another host,
        // deadline or creator share would otherwise be a second mint of the same token.
        bytes32 salt = keccak256(
            abi.encode(
                _msgSender(),
                config.salt,
                config.hostChainId,
                config.token,
                config.deadline,
                config.creator,
                config.keepPercent,
                config.keepCap,
                config.tokenPercent,
                config.vestingDuration,
                config.claimsPercent,
                config.claimsRoot,
                config.claimsVestingDuration
            )
        );

        JBSuckerDeploymentConfig memory suckerDeploymentConfiguration = config.suckerDeploymentConfiguration;
        if (suckerDeploymentConfiguration.deployerConfigurations.length != 0) {
            suckerDeploymentConfiguration.salt = salt;
        }

        for (uint256 i; i < suckerDeploymentConfiguration.deployerConfigurations.length; i++) {
            // A lunch's suckers only ever pair with the same lunch's suckers on other chains, never a chosen peer.
            if (suckerDeploymentConfiguration.deployerConfigurations[i].peer != bytes32(0)) {
                revert FairLunch_InvalidSuckers();
            }

            // The host's suckers start with nothing mapped, so the raise can't be bridged away.
            if (isHost && suckerDeploymentConfiguration.deployerConfigurations[i].mappings.length != 0) {
                revert FairLunch_HostMapsNoTokens();
            }
        }

        // The rulesets are the lunch's clock. The host sells tokens until the deadline, then takes no payments until
        // it's served. Everywhere else takes no payments until the deadline, since a payer there would get no tokens,
        // and after it payments mint nothing and wait to be sent home.
        bool beforeDeadline = config.deadline > block.timestamp;
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](beforeDeadline ? 2 : 1);
        if (beforeDeadline) {
            rulesetConfigurations[0] = _rulesetConfigOf({
                token: token,
                duration: uint32(config.deadline - block.timestamp),
                weight: isHost ? uint112(TOKENS_PER_UNIT * 1e18) : 0,
                pausePay: !isHost,
                splitGroups: new JBSplitGroup[](0),
                fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
            });
        }
        rulesetConfigurations[beforeDeadline ? 1 : 0] = _rulesetConfigOf({
            token: token,
            duration: 0,
            weight: 0,
            pausePay: isHost,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        // Hold the money in the terminal, and take everything else through the router terminal, which swaps it into
        // the money first. The router goes second so the directory never picks it for the money itself.
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: token,
            decimals: token == JBConstants.NATIVE_TOKEN ? 18 : IERC20Metadata(token).decimals(),
            currency: uint32(uint160(token))
        });

        // A token priced in smaller pieces than the lunch's token can't be pooled at a million per unit.
        if (accountingContexts[0].decimals > 24) revert FairLunch_InvalidToken(token);
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](2);
        terminalConfigurations[0] = JBTerminalConfig({
            terminal: IJBTerminal(address(TERMINAL)), accountingContextsToAccept: accountingContexts
        });
        terminalConfigurations[1] = JBTerminalConfig({
            terminal: ROUTER_TERMINAL_REGISTRY, accountingContextsToAccept: new JBAccountingContext[](0)
        });

        // Expose who is paying the creation fee so its credit goes to them, not to this contract.
        originalPayer = JBPayerTrackerLib.resolve(_msgSender());

        // Launch the project with this contract as its owner, forever.
        // slither-disable-next-line unused-return
        (projectId,,) = OMNICHAIN_DEPLOYER.launchProjectFor{value: msg.value}({
            owner: address(this),
            projectUri: config.projectUri,
            rulesetConfigurations: rulesetConfigurations,
            terminalConfigurations: terminalConfigurations,
            memo: "",
            suckerDeploymentConfiguration: suckerDeploymentConfiguration
        });

        originalPayer = address(0);

        // Everywhere but the host, payments only ever leave through the bridge home. Without one that's ready to carry
        // this chain's money they'd be stuck, so there's no lunch. A mapping that was set and then switched off
        // doesn't count, nor does one with any gas but `_SUCKER_MIN_GAS`: set too high, it could never send. Nor does
        // one that arrives as anything but the lunch's money: the host takes nothing else.
        if (!isHost) {
            (uint256 enabled,, uint256 minGas, uint256 remoteToken) = ISuckerRoute(
                    address(_hostSuckerOf({projectId: projectId, hostChainId: config.hostChainId}))
                ).remoteTokenFor(token);
            if (enabled == 0 || minGas != _SUCKER_MIN_GAS || remoteToken != uint160(config.token)) {
                revert FairLunch_InvalidSuckers();
            }
        }

        // The host's buyback hook has to price with the same oracle the lunch's pool uses, or `serve` couldn't register
        // the pool and the raise would be stuck.
        if (isHost) {
            IHooks hook = IBuybackOracle(address(BUYBACK_REGISTRY.hookOf(projectId))).oracleHook();
            if (hook != IHooks(address(oracleHook))) revert FairLunch_InvalidOracleHook(hook);
        }

        // Deploy the token up front so payers hold a real ERC-20 from their first payment.
        // slither-disable-next-line unused-return
        CONTROLLER.deployERC20For({projectId: projectId, name: config.name, symbol: config.symbol, salt: salt});

        FairLunchRecord storage record = _recordOf[projectId];
        record.hostChainId = config.hostChainId;
        record.token = token;
        record.creator = config.creator;
        record.keepPercent = config.keepPercent;
        record.keepCap = config.keepCap;
        record.tokenPercent = config.tokenPercent;
        record.vestingDuration = config.vestingDuration;

        // The host hands out the claims.
        if (isHost && config.claimsPercent != 0) {
            CLAIMS.setTermsOf({
                projectId: projectId,
                percent: config.claimsPercent,
                root: config.claimsRoot,
                vestingDuration: config.claimsVestingDuration
            });
        }

        emit Create({
            projectId: projectId,
            hostChainId: config.hostChainId,
            creator: config.creator,
            deadline: config.deadline,
            caller: _msgSender()
        });
    }

    /// @notice Send this chain's revenue to the lunch's host chain.
    /// @dev Anyone can call this on a chain other than the host. `msg.value` pays the sucker's fee and the bridge, and
    /// whatever they don't use is refunded to the caller.
    /// Suckers only carry money that backs tokens being bridged, so this mints tokens to carry it: one wei of token
    /// when nobody holds the token on this chain (cashing out the whole supply reclaims the whole balance), otherwise
    /// `_SEND_HOME_MULTIPLE` times the supply, which carries all but a sliver. The tokens are minted to this contract
    /// on the host chain, where the next `burn` burns them.
    /// @param projectId The ID of the lunch's project on this chain.
    function sendHome(uint256 projectId) external payable override nonReentrant {
        uint256 hostChainId = _recordOf[projectId].hostChainId;
        address token = _recordOf[projectId].token;

        // The host has nowhere to send to. This also rejects projects that aren't lunches.
        if (hostChainId == 0 || hostChainId == block.chainid) revert FairLunch_NotRemote(projectId);

        // Anything this contract holds beyond `msg.value` was sent to it by mistake and isn't the caller's.
        uint256 ethBefore = address(this).balance - msg.value;

        IJBSucker sucker = _hostSuckerOf({projectId: projectId, hostChainId: hostChainId});

        // Mint the tokens that will carry the balance.
        uint256 supply = TOKENS.totalSupplyOf(projectId);
        uint256 tokenCount = supply == 0 ? 1 : supply * _SEND_HOME_MULTIPLE;
        // slither-disable-next-line unused-return
        CONTROLLER.mintTokensOf({
            projectId: projectId,
            tokenCount: tokenCount,
            beneficiary: address(this),
            memo: "",
            useReservedPercent: false
        });

        // Cash them out into the sucker for this contract on the host chain, then send.
        IERC20(address(TOKENS.tokenOf(projectId))).forceApprove({spender: address(sucker), value: tokenCount});
        sucker.prepare({
            projectTokenCount: tokenCount,
            beneficiary: bytes32(uint256(uint160(address(this)))),
            minTokensReclaimed: 0,
            token: token,
            metadata: bytes32(0)
        });
        sucker.toRemote{value: msg.value}(token);

        // The sucker's fee bought JBP6 for this contract. It belongs to the caller who paid it. If the fee couldn't be
        // paid, the sucker kept it for this contract to take back.
        _sendFeeTokensTo(_msgSender());
        try IJBSuckerExtended(address(sucker)).claimRetainedToRemoteFee(payable(address(this))) {}
            catch {
            // Nothing was kept, or this sucker can't keep any.
        }

        // The sucker refunds whatever the bridge didn't need. Pass it on to the caller who paid.
        uint256 refund = address(this).balance - ethBefore;
        if (refund != 0) Address.sendValue({recipient: payable(_msgSender()), amount: refund});

        emit SendHome({projectId: projectId, sucker: address(sucker), tokenCount: tokenCount, caller: _msgSender()});
    }

    /// @notice Serve a lunch once its deadline has passed.
    /// @dev Anyone can call this on the host chain, once.
    /// @param projectId The ID of the lunch's project.
    function serve(uint256 projectId) external override nonReentrant {
        FairLunchRecord storage record = _recordOf[projectId];

        // Only the host serves. This also rejects projects that aren't lunches.
        if (record.hostChainId != block.chainid) {
            revert FairLunch_NotHost({projectId: projectId, hostChainId: record.hostChainId});
        }

        // The ruleset tells the time: still selling, waiting to be served, or served.
        {
            (JBRuleset memory ruleset, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(projectId);
            if (ruleset.weight != 0) {
                revert FairLunch_TooEarly({projectId: projectId, readyAt: uint256(ruleset.start) + ruleset.duration});
            }
            if (!metadata.pausePay) revert FairLunch_AlreadyServed(projectId);
        }

        address token = record.token;
        uint256 perToken = TOKENS_PER_UNIT * 1e18;
        uint256 unit = 10 ** TERMINAL.accountingContextForTokenOf({projectId: projectId, token: token}).decimals;

        // The raise is what payers paid for the tokens they hold. Money that came another way, like revenue sent home
        // from another chain since the deadline, stays in the balance for `burn`. The tokens that carried it are burned
        // first so they don't count as sold.
        // slither-disable-next-line unused-return
        _burnTokensOf(projectId);
        uint256 raised = _min({
            a: _balanceOf({projectId: projectId, token: token}),
            b: mulDiv({x: TOKENS.totalSupplyOf(projectId), y: unit, denominator: perToken})
        });
        if (raised == 0) revert FairLunch_NothingRaised(projectId);

        // Anything this contract holds beyond this was sent to it by mistake and isn't the lunch's.
        uint256 before = _holdingOf(token);

        // Pay the whole raise out: the creator's keep to the creator, everything else to this contract as the owner.
        _queuePayoutOf({
            projectId: projectId,
            token: token,
            raised: raised,
            creator: record.creator,
            keep: _min({
                a: mulDiv({x: raised, y: record.keepPercent, denominator: JBConstants.SPLITS_TOTAL_PERCENT}),
                b: record.keepCap
            })
        });
        // slither-disable-next-line unused-return
        TERMINAL.sendPayoutsOf({
            projectId: projectId, token: token, amount: raised, currency: uint32(uint160(token)), minTokensPaidOut: 0
        });

        // The pool takes at most what `_MAX_POOL_TOKENS` matches, an amount Uniswap V4 can always account for. Any more
        // stays in the balance for `burn`.
        uint256 poolAmount =
            _min({a: _holdingOf(token) - before, b: mulDiv({x: _MAX_POOL_TOKENS, y: unit, denominator: perToken})});

        // The payout's fee minted JBP6 to this contract as the project's owner. It belongs to the creator.
        _sendFeeTokensTo(record.creator);

        // Mint the other side of the market: as many tokens as the pool's money would have bought during the
        // fundraise, so the pool opens at the price payers paid.
        uint256 poolTokens = mulDiv({x: poolAmount, y: perToken, denominator: unit});
        _mintTokensOf({projectId: projectId, tokenCount: poolTokens, beneficiary: address(POOL)});

        // Put the money and the tokens in the pool, forever. What the pool's price didn't take comes back.
        (PoolKey memory key, bool moneyIs0) = _poolOf({projectId: projectId, token: token});
        record.positionId = POOL.open{value: _handTo({to: address(POOL), token: token, amount: poolAmount})}({
            key: key, moneyIs0: moneyIs0, money: poolAmount, tokens: poolTokens
        });

        // From here on the buyback hook routes the lunch's payments and cash outs through that pool.
        IJBBuybackHook(address(BUYBACK_REGISTRY.hookOf(projectId)))
            .setPoolFor({
            projectId: projectId,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            twapWindow: TWAP_WINDOW,
            terminalToken: token
        });

        // Whatever the pool's price didn't take: burn the tokens, and leave the money in the balance for the burn.
        // slither-disable-next-line unused-return
        _burnTokensOf(projectId);
        uint256 left = _holdingOf(token) - before;
        if (left != 0) _addToBalanceOf({projectId: projectId, token: token, amount: left});

        // Mint the creator's and the claims' shares of the total supply, now that the rest of it is settled.
        uint256 claimsPercent = CLAIMS.percentOf(projectId);
        uint256 granted = mulDiv({
            x: TOKENS.totalSupplyOf(projectId),
            y: record.tokenPercent + claimsPercent,
            denominator: JBConstants.SPLITS_TOTAL_PERCENT - record.tokenPercent - claimsPercent
        });
        uint256 claimsTokens =
            granted == 0 ? 0 : mulDiv({x: granted, y: claimsPercent, denominator: record.tokenPercent + claimsPercent});
        uint256 creatorTokens = granted - claimsTokens;

        // Both wait in `CLAIMS`: the claims' for whoever sends each listed address its part, the creator's vesting
        // linearly from now.
        if (granted != 0) {
            _mintTokensOf({projectId: projectId, tokenCount: granted, beneficiary: address(CLAIMS)});
            CLAIMS.fund({
                projectId: projectId,
                token: IERC20(address(TOKENS.tokenOf(projectId))),
                tokenCount: claimsTokens,
                creator: record.creator,
                creatorTokenCount: creatorTokens,
                creatorVestingDuration: record.vestingDuration
            });
        }

        // Open the bridges now that there is no raise left to bridge away.
        // ponytail: only for ETH, which is the same token everywhere. An ERC-20 lunch's token stays on its host until
        // this knows each chain's address for the money.
        if (token == JBConstants.NATIVE_TOKEN) {
            address[] memory suckers = SUCKER_REGISTRY.suckersOf(projectId);
            for (uint256 i; i < suckers.length; i++) {
                IJBSucker(suckers[i])
                    .mapToken(
                        JBTokenMapping({
                        localToken: token, minGas: _SUCKER_MIN_GAS, remoteToken: bytes32(uint256(uint160(token)))
                    })
                    );
            }
        }

        emit Serve({
            projectId: projectId,
            raised: raised,
            poolAmount: poolAmount,
            poolTokens: poolTokens,
            creatorTokens: creatorTokens,
            positionId: record.positionId,
            caller: _msgSender()
        });
    }

    /// @notice One-shot setter for this chain's Uniswap V4 addresses.
    /// @dev Callable only by `_DEPLOYER` and only once. After this call the values are effectively immutable. Keeping
    /// them out of the constructor keeps this contract's address the same on every chain.
    /// @param newPositionManager The Uniswap V4 position manager. The pool manager is read from it.
    /// @param newOracleHook The Uniswap V4 hook every lunch's pool uses.
    function setChainSpecificConstants(
        IPositionManager newPositionManager,
        IGeomeanOracle newOracleHook
    )
        external
        override
    {
        // Only the deployer, and only once.
        if (msg.sender != _DEPLOYER) revert FairLunch_Unauthorized(msg.sender);
        if (address(oracleHook) != address(0)) revert FairLunch_AlreadyConfigured();

        // Both addresses are needed.
        if (address(newPositionManager) == address(0) || address(newOracleHook) == address(0)) {
            revert FairLunch_ZeroAddress();
        }

        POOL.setChainSpecificConstants({newPositionManager: newPositionManager, newOracleHook: newOracleHook});
        oracleHook = newOracleHook;
    }

    /// @notice One-shot setter for the project that shares pool fees with JBP6 on this chain.
    /// @dev Callable only by JBP6's operator, and only once: after this call the value can't be changed or cleared.
    /// It applies to every lunch on this chain, including ones already made, from the next `collect` on.
    /// @param projectId The ID of the project to pay half of the money side of pool fees into.
    function setSplitProjectId(uint256 projectId) external override {
        // Only JBP6's operator: JBP6 is a revnet, and its owner knows who operates it.
        IJBProjects projects = CONTROLLER.PROJECTS();
        if (!IRevnetOperator(projects.ownerOf(_FEE_PROJECT_ID))
                .isOperatorOf({revnetId: _FEE_PROJECT_ID, addr: _msgSender()})) {
            revert FairLunch_Unauthorized(_msgSender());
        }

        // Only once.
        if (splitProjectId != 0) revert FairLunch_AlreadyConfigured();

        // Only a project that exists and isn't JBP6 itself.
        if (projectId <= _FEE_PROJECT_ID || projectId > projects.count()) {
            revert FairLunch_InvalidSplitProject(projectId);
        }

        splitProjectId = projectId;

        emit SetSplitProjectId({projectId: projectId, caller: _msgSender()});
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Accept only a lunch's project NFT.
    /// @dev Part of `IERC721Receiver`.
    /// @return selector The selector that accepts the NFT.
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    )
        external
        view
        override
        returns (bytes4 selector)
    {
        if (msg.sender != address(CONTROLLER.PROJECTS())) revert FairLunch_Unauthorized(msg.sender);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice What Fair Lunch remembers about a lunch.
    /// @param projectId The ID of the lunch's project.
    /// @return record The lunch's record.
    function recordOf(uint256 projectId) external view override returns (FairLunchRecord memory record) {
        return _recordOf[projectId];
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The Uniswap V4 pool of a lunch.
    /// @param projectId The ID of the lunch's project.
    /// @return key The pool's key.
    function poolKeyOf(uint256 projectId) public view override returns (PoolKey memory key) {
        (key,) = _poolOf({projectId: projectId, token: _recordOf[projectId].token});
    }

    /// @notice When a lunch was served.
    /// @dev A lunch's rulesets are its clock. On the host, the ruleset that sells tokens gives way at the deadline to
    /// one that takes no payments, and `serve` replaces that with the one the lunch keeps forever, which started when
    /// it was served.
    /// @param projectId The ID of the lunch's project.
    /// @return servedAt The timestamp the lunch was served at, or zero if it hasn't been, or is served elsewhere.
    function servedAtOf(uint256 projectId) public view override returns (uint256 servedAt) {
        if (_recordOf[projectId].hostChainId != block.chainid) return 0;
        (JBRuleset memory ruleset, JBRulesetMetadata memory metadata) = CONTROLLER.currentRulesetOf(projectId);
        return ruleset.weight != 0 || metadata.pausePay ? 0 : ruleset.start;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Add money to a lunch's balance.
    /// @param projectId The ID of the lunch's project.
    /// @param token The lunch's money.
    /// @param amount The amount to add.
    function _addToBalanceOf(uint256 projectId, address token, uint256 amount) internal {
        TERMINAL.addToBalanceOf{value: _handTo({to: address(TERMINAL), token: token, amount: amount})}({
            projectId: projectId, token: token, amount: amount, shouldReturnHeldFees: false, memo: "", metadata: ""
        });
    }

    /// @notice Burn every one of a lunch's tokens this contract holds.
    /// @param projectId The ID of the lunch's project.
    /// @return tokenCount The number of tokens burned.
    function _burnTokensOf(uint256 projectId) internal returns (uint256 tokenCount) {
        tokenCount = TOKENS.totalBalanceOf({holder: address(this), projectId: projectId});
        if (tokenCount != 0) {
            CONTROLLER.burnTokensOf({holder: address(this), projectId: projectId, tokenCount: tokenCount, memo: ""});
        }
    }

    /// @notice Get an amount of money ready for a call to take: ETH is sent with the call, and an ERC-20 is sent to the
    /// pool contract or approved for the terminal.
    /// @param to The contract about to be called.
    /// @param token The money.
    /// @param amount The amount.
    /// @return value The ETH to send with the call.
    function _handTo(address to, address token, uint256 amount) internal returns (uint256 value) {
        if (token == JBConstants.NATIVE_TOKEN) return amount;
        if (to == address(POOL)) IERC20(token).safeTransfer({to: to, value: amount});
        else IERC20(token).forceApprove({spender: to, value: amount});
    }

    /// @notice Mint a lunch's tokens.
    /// @param projectId The ID of the lunch's project.
    /// @param tokenCount The number of tokens to mint.
    /// @param beneficiary The address to mint to.
    function _mintTokensOf(uint256 projectId, uint256 tokenCount, address beneficiary) internal {
        // slither-disable-next-line unused-return
        CONTROLLER.mintTokensOf({
            projectId: projectId, tokenCount: tokenCount, beneficiary: beneficiary, memo: "", useReservedPercent: false
        });
    }

    /// @notice Pay an amount of a lunch's pool fees into a project, if it takes the money in this contract's terminal.
    /// @param projectId The ID of the lunch's project.
    /// @param feeProjectId The ID of the project to pay.
    /// @param token The lunch's money.
    /// @param amount The amount to pay.
    /// @param beneficiary The address that gets the tokens the payment mints.
    /// @return kept The amount the project didn't take: all of it or none of it.
    function _payFeeTo(
        uint256 projectId,
        uint256 feeProjectId,
        address token,
        uint256 amount,
        address beneficiary
    )
        internal
        returns (uint256 kept)
    {
        // The lookup is in a try because it asks the paid project's terminals whether they take the token, and that
        // is code the project chooses.
        try DIRECTORY.primaryTerminalOf({projectId: feeProjectId, token: token}) returns (IJBTerminal terminal) {
            // Only pay through this contract's terminal.
            if (terminal != IJBTerminal(address(TERMINAL))) return amount;
        } catch (bytes memory reason) {
            // The lookup reverted, so the lunch keeps the amount.
            emit FeeReverted({
                projectId: projectId,
                token: token,
                feeProjectId: feeProjectId,
                amount: amount,
                reason: reason,
                caller: _msgSender()
            });
            return amount;
        }

        // The payment runs the paid project's hooks, so it's in a try too.
        // slither-disable-next-line unused-return
        try TERMINAL.pay{value: _handTo({to: address(TERMINAL), token: token, amount: amount})}({
            projectId: feeProjectId,
            token: token,
            amount: amount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        }) {}
        catch (bytes memory reason) {
            // The project didn't take it, so the lunch keeps the amount.
            emit FeeReverted({
                projectId: projectId,
                token: token,
                feeProjectId: feeProjectId,
                amount: amount,
                reason: reason,
                caller: _msgSender()
            });
            kept = amount;
        }
    }

    /// @notice Queue the ruleset a lunch keeps forever, set up to pay its whole raise out once.
    /// @dev The payout limit can only ever be used once because the ruleset never cycles. The creator's keep is a
    /// split, and the rest of the payout goes to this contract as the project's owner.
    /// @param projectId The ID of the lunch's project.
    /// @param token The lunch's money.
    /// @param raised The amount to make payable.
    /// @param creator The address that receives the keep.
    /// @param keep The amount the creator keeps, before the JB fee.
    function _queuePayoutOf(uint256 projectId, address token, uint256 raised, address creator, uint256 keep) internal {
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({amount: uint224(raised), currency: uint32(uint160(token))});
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(TERMINAL),
            token: token,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        JBSplitGroup[] memory splitGroups;
        uint256 splitPercent = mulDiv({x: keep, y: JBConstants.SPLITS_TOTAL_PERCENT, denominator: raised});
        if (splitPercent != 0) {
            JBSplit[] memory splits = new JBSplit[](1);
            splits[0] = JBSplit({
                percent: uint32(splitPercent),
                projectId: 0,
                beneficiary: payable(creator),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(0))
            });
            splitGroups = new JBSplitGroup[](1);
            splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(token)), splits: splits});
        }

        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0] = _rulesetConfigOf({
            token: token,
            duration: 0,
            weight: 0,
            pausePay: false,
            splitGroups: splitGroups,
            fundAccessLimitGroups: fundAccessLimitGroups
        });

        // Queue through the omnichain deployer so the ruleset keeps the wrapper that serves the lunch's suckers.
        // slither-disable-next-line unused-return
        OMNICHAIN_DEPLOYER.queueRulesetsOf({
            projectId: projectId, rulesetConfigurations: rulesetConfigurations, memo: ""
        });
    }

    /// @notice Send all the JBP6 this contract holds to an address.
    /// @dev This contract never holds JBP6 between calls, so everything it holds came from the current call's fee.
    /// Credits are claimed into the ERC-20 before sending: a transfer of credits reverts while JBP6 pauses them, and
    /// that revert would block every payment into a served lunch.
    /// @param beneficiary The address to send the JBP6 to.
    function _sendFeeTokensTo(address beneficiary) internal {
        IERC20 token = IERC20(address(TOKENS.tokenOf(_FEE_PROJECT_ID)));
        uint256 credits = TOKENS.creditBalanceOf({holder: address(this), projectId: _FEE_PROJECT_ID});

        if (credits != 0) {
            IJBController controller = IJBController(address(DIRECTORY.controllerOf(_FEE_PROJECT_ID)));

            // Without an ERC-20 there's nothing to claim into, so the credits themselves are sent.
            if (address(token) == address(0)) {
                controller.transferCreditsFrom({
                    holder: address(this), projectId: _FEE_PROJECT_ID, recipient: beneficiary, creditCount: credits
                });
                return;
            }

            controller.claimTokensFor({
                holder: address(this), projectId: _FEE_PROJECT_ID, tokenCount: credits, beneficiary: beneficiary
            });
        }

        if (address(token) != address(0)) {
            uint256 balance = token.balanceOf(address(this));
            if (balance != 0) token.safeTransfer({to: beneficiary, value: balance});
        }
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice The money in a lunch's balance.
    /// @param projectId The ID of the lunch's project.
    /// @param token The lunch's money.
    /// @return balance The balance.
    function _balanceOf(uint256 projectId, address token) internal view returns (uint256 balance) {
        return TERMINAL.STORE().balanceOf({terminal: address(TERMINAL), projectId: projectId, token: token});
    }

    /// @notice How much of a lunch's money this contract holds.
    /// @param token The money.
    /// @return holding The amount held.
    function _holdingOf(address token) internal view returns (uint256 holding) {
        return token == JBConstants.NATIVE_TOKEN ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @notice The sucker that bridges a lunch to its host chain.
    /// @dev Reverts if there isn't one.
    /// @param projectId The ID of the lunch's project on this chain.
    /// @param hostChainId The ID of the lunch's host chain.
    /// @return sucker The sucker.
    function _hostSuckerOf(uint256 projectId, uint256 hostChainId) internal view returns (IJBSucker sucker) {
        address[] memory suckers = SUCKER_REGISTRY.suckersOf(projectId);
        for (uint256 i; i < suckers.length; i++) {
            if (IJBSucker(suckers[i]).peerChainId() == hostChainId) return IJBSucker(suckers[i]);
        }
        revert FairLunch_NoHostSucker({projectId: projectId, hostChainId: hostChainId});
    }

    /// @notice The smaller of two numbers.
    /// @param a The first number.
    /// @param b The second number.
    /// @return min The smaller one.
    function _min(uint256 a, uint256 b) internal pure returns (uint256 min) {
        return a < b ? a : b;
    }

    /// @notice The Uniswap V4 pool of a lunch, and which side of it the lunch's money is on.
    /// @dev A pool's currencies are sorted by address. ETH's is zero, so it always comes first.
    /// @param projectId The ID of the lunch's project.
    /// @param token The lunch's money.
    /// @return key The pool's key.
    /// @return moneyIs0 Whether the money is the pool's currency0.
    function _poolOf(uint256 projectId, address token) internal view returns (PoolKey memory key, bool moneyIs0) {
        address money = token == JBConstants.NATIVE_TOKEN ? address(0) : token;
        address projectToken = address(TOKENS.tokenOf(projectId));
        moneyIs0 = money < projectToken;
        key = PoolKey({
            currency0: Currency.wrap(moneyIs0 ? money : projectToken),
            currency1: Currency.wrap(moneyIs0 ? projectToken : money),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(oracleHook))
        });
    }

    /// @notice The ruleset every lunch uses: no reserved tokens, no owner powers beyond minting, and `DATA_HOOK`
    /// deciding payments and cash outs. A ruleset that sells tokens doesn't tax cash outs, which is how a payer takes a
    /// refund. Every other ruleset taxes them at 100%.
    /// @param token The lunch's money, which the ruleset counts in.
    /// @param duration How long the ruleset lasts before the next one starts, in seconds. Zero lasts until another is
    /// queued.
    /// @param weight The number of tokens minted per whole unit of money paid, as a fixed point number with 18
    /// decimals.
    /// @param pausePay Whether the ruleset refuses payments.
    /// @param splitGroups The ruleset's splits.
    /// @param fundAccessLimitGroups The ruleset's payout limits.
    /// @return config The ruleset's configuration.
    function _rulesetConfigOf(
        address token,
        uint32 duration,
        uint112 weight,
        bool pausePay,
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups
    )
        internal
        view
        returns (JBRulesetConfig memory config)
    {
        config.duration = duration;
        config.weight = weight;
        config.approvalHook = IJBRulesetApprovalHook(address(0));
        config.splitGroups = splitGroups;
        config.fundAccessLimitGroups = fundAccessLimitGroups;
        config.metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: weight == 0 ? JBConstants.MAX_CASH_OUT_TAX_RATE : 0,
            baseCurrency: uint32(uint160(token)),
            pausePay: pausePay,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            scopeCashOutsToLocalBalances: true,
            useDataHookForPay: true,
            useDataHookForCashOut: true,
            dataHook: address(DATA_HOOK),
            metadata: 0
        });
    }
}
