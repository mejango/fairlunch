// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBPayerTracker} from "@bananapus/core-v6/src/interfaces/IJBPayerTracker.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPayerTrackerLib} from "@bananapus/core-v6/src/libraries/JBPayerTrackerLib.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBCurrencyAmount} from "@bananapus/core-v6/src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
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
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {FairLunchVestingDeployer} from "./FairLunchVestingDeployer.sol";
import {IFairLunch} from "./interfaces/IFairLunch.sol";
import {FairLunchConfig} from "./structs/FairLunchConfig.sol";
import {FairLunchRecord} from "./structs/FairLunchRecord.sol";

/// @notice Tasty token launcher.
/// @dev A lunch is a Juicebox project this contract owns forever, so nobody can ever change it.
///
/// Cooking: until its deadline, a lunch sells its token for ETH at a fixed price on its host chain. Nothing can be
/// cashed out.
///
/// Served: once the deadline passes, anyone can serve the lunch. The raise leaves the project through a normal payout
/// (so the JB fee applies, and the JBP6 it mints goes to the creator), the creator gets the share they asked for up to
/// their cap, their token allocation starts vesting, and everything else becomes one full-range Uniswap V4 position
/// that this contract holds forever.
///
/// Eating: from then on the project's balance is a sink. Every payment lands in it, mints nothing, and is immediately
/// used to buy the token from the pool and burn it, never paying more than a bound above the pool's time-weighted
/// average price. Whatever a bounded buy can't spend waits in the balance for the next one. Revenue paid in on other
/// chains is carried to the host chain's balance through the lunch's suckers.
///
/// This contract is each lunch's owner, its data hook (wrapped by `JBOmnichainDeployer`), its pay hook, and the holder
/// of its liquidity. It holds no ETH or tokens between calls.
contract FairLunch is
    ERC2771Context,
    ReentrancyGuardTransient,
    IFairLunch,
    IJBRulesetDataHook,
    IJBPayHook,
    IJBPayerTracker,
    IUnlockCallback,
    IERC721Receiver
{
    // A library that reverts instead of truncating when narrowing a number.
    using SafeCast for uint256;

    // A library that adds default safety checks to ERC-20 functionality.
    using SafeERC20 for IERC20;

    // A library that derives a Uniswap V4 pool's ID from its key.
    using PoolIdLibrary for PoolKey;

    // A library that reads Uniswap V4 pool state.
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error FairLunch_AlreadyConfigured();
    error FairLunch_AlreadyServed(uint256 projectId);
    error FairLunch_Closed(uint256 projectId, uint256 deadline);
    error FairLunch_HostMapsNoTokens();
    error FairLunch_InvalidConfig();
    error FairLunch_NoHostSucker(uint256 projectId, uint256 hostChainId);
    error FairLunch_NoLiquidity(uint256 projectId);
    error FairLunch_NotConfigured();
    error FairLunch_NotHost(uint256 projectId, uint256 hostChainId);
    error FairLunch_NotRemote(uint256 projectId);
    error FairLunch_NotServed(uint256 projectId);
    error FairLunch_NothingRaised(uint256 projectId);
    error FairLunch_TooEarly(uint256 projectId, uint256 readyAt);
    error FairLunch_Unauthorized(address caller);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The most the creator can keep of the raise or of the token supply, out of
    /// `JBConstants.SPLITS_TOTAL_PERCENT`.
    uint256 public constant override MAX_CREATOR_PERCENT = JBConstants.SPLITS_TOTAL_PERCENT / 2;

    /// @notice The fee of every lunch's pool, in hundredths of a basis point (1%).
    uint24 public constant override POOL_FEE = 10_000;

    /// @notice The tick spacing of every lunch's pool.
    int24 public constant override TICK_SPACING = 200;

    /// @notice The number of tokens a payer receives per ETH during the fundraise, and the price the pool opens at.
    uint256 public constant override TOKENS_PER_ETH = 1_000_000;

    /// @notice The farthest a buyback can push the price past its time-weighted average, in ticks (about 2%).
    int24 public constant override TWAP_MAX_DEVIATION = 200;

    /// @notice The number of seconds of price history a buyback is bounded by, and the wait after serving before the
    /// first buyback.
    uint32 public constant override TWAP_WINDOW = 30 minutes;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The ID of the project that takes fees, whose token is JBP6.
    uint256 internal constant _FEE_PROJECT_ID = 1;

    /// @notice How many times the local supply `sendHome` mints, so its pro rata cash out carries all but a millionth
    /// of the balance.
    uint256 internal constant _SEND_HOME_MULTIPLE = 1_000_000;

    /// @notice The gas a sucker reserves on the remote chain for a native token claim.
    uint32 internal constant _SUCKER_MIN_GAS = 200_000;

    /// @notice The pool price that matches the fundraise's price: `sqrt(TOKENS_PER_ETH)` as a Q64.96. ETH is always
    /// currency0, so the pool's price is tokens per ETH.
    uint160 internal constant _RAISE_SQRT_PRICE_X96 = 1000 << 96;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The controller every lunch is launched with.
    IJBController public immutable override CONTROLLER;

    /// @notice The directory of terminals and controllers.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The deployer every lunch is launched through, which wires up its suckers.
    IJBOmnichainDeployer public immutable override OMNICHAIN_DEPLOYER;

    /// @notice The Permit2 contract the position manager pulls tokens through.
    IAllowanceTransfer public immutable override PERMIT2;

    /// @notice The registry of every lunch's suckers.
    IJBSuckerRegistry public immutable override SUCKER_REGISTRY;

    /// @notice The terminal every lunch accepts ETH through.
    IJBMultiTerminal public immutable override TERMINAL;

    /// @notice The token ledger.
    IJBTokens public immutable override TOKENS;

    /// @notice The deployer of the wallets that vest creators' tokens.
    FairLunchVestingDeployer public immutable override VESTING_DEPLOYER;

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

    /// @notice The Uniswap V4 hook every lunch's pool uses, which records the price history buybacks are bounded by.
    /// @dev Set once by `_DEPLOYER` through `setChainSpecificConstants`. Zero until then.
    IGeomeanOracle public override ORACLE_HOOK;

    /// @notice The Uniswap V4 pool manager.
    /// @dev Set once by `_DEPLOYER` through `setChainSpecificConstants`. Zero until then.
    IPoolManager public override POOL_MANAGER;

    /// @notice The Uniswap V4 position manager.
    /// @dev Set once by `_DEPLOYER` through `setChainSpecificConstants`. Zero until then.
    IPositionManager public override POSITION_MANAGER;

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

    /// @dev Every argument is the same address on every supported chain. The trusted forwarder is the one the
    /// omnichain deployer trusts, so relayed creations resolve the signer instead of the forwarder.
    /// @param omnichainDeployer The deployer every lunch is launched through.
    /// @param terminal The terminal every lunch accepts ETH through.
    /// @param suckerRegistry The registry of every lunch's suckers.
    /// @param permit2 The Permit2 contract the position manager pulls tokens through.
    /// @param vestingDeployer The deployer of the wallets that vest creators' tokens.
    /// @param deployer The address allowed to set the chain-specific constants, once.
    constructor(
        IJBOmnichainDeployer omnichainDeployer,
        IJBMultiTerminal terminal,
        IJBSuckerRegistry suckerRegistry,
        IAllowanceTransfer permit2,
        FairLunchVestingDeployer vestingDeployer,
        address deployer
    )
        ERC2771Context(ERC2771Context(address(omnichainDeployer)).trustedForwarder())
    {
        OMNICHAIN_DEPLOYER = omnichainDeployer;
        CONTROLLER = omnichainDeployer.CONTROLLER();
        DIRECTORY = terminal.DIRECTORY();
        TERMINAL = terminal;
        TOKENS = terminal.TOKENS();
        SUCKER_REGISTRY = suckerRegistry;
        PERMIT2 = permit2;
        VESTING_DEPLOYER = vestingDeployer;
        _DEPLOYER = deployer;
    }

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Accept ETH from payouts, cash outs, the pool manager and the position manager.
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Runs the buyback for a payment a served lunch just received.
    /// @dev Part of `IJBPayHook`. The payment itself stays in the project's balance; this only triggers `burn`. A
    /// buyback that can't run right now (the price history is too short, or the pool manager is mid-swap) never blocks
    /// the payment: the ETH waits in the balance for the next attempt.
    /// @param context The payment's context.
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable override {
        // Only a lunch's own terminal runs its buyback.
        if (!DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})) {
            revert FairLunch_Unauthorized(msg.sender);
        }

        // The price history is still too short, or the payment came from inside a swap: leave the ETH in the balance
        // for the next call. Anything else runs the buyback now. It's deliberately not wrapped in a try: a wallet
        // estimating a payment's gas would settle on an amount that starves a caught call, and every payment would
        // quietly skip its buyback.
        bool tooEarly = block.timestamp < uint256(_recordOf[context.projectId].servedAt) + TWAP_WINDOW;
        if (tooEarly || POOL_MANAGER.isUnlocked() || _reentrancyGuardEntered()) return;

        // slither-disable-next-line unused-return
        this.burn(context.projectId);
    }

    /// @notice Use a served lunch's whole balance to buy its token from the pool and burn it.
    /// @dev Anyone can call this. The buy stops at a price `TWAP_MAX_DEVIATION` ticks above the pool's average over the
    /// last `TWAP_WINDOW`, and whatever it couldn't spend goes back into the balance. The first buyback waits a full
    /// `TWAP_WINDOW` after serving so that the average holds only prices from the served pool: anyone can create the
    /// pool early and leave misleading history in it.
    /// @param projectId The ID of the lunch's project.
    /// @return spent The amount of ETH spent buying tokens.
    /// @return burned The number of tokens burned.
    function burn(uint256 projectId) external override nonReentrant returns (uint256 spent, uint256 burned) {
        FairLunchRecord storage record = _recordOf[projectId];

        // Only a served lunch buys back.
        if (record.servedAt == 0) revert FairLunch_NotServed(projectId);

        // Wait for a window of the served pool's own price history.
        if (block.timestamp < uint256(record.servedAt) + TWAP_WINDOW) {
            revert FairLunch_TooEarly({projectId: projectId, readyAt: uint256(record.servedAt) + TWAP_WINDOW});
        }

        // Take the lunch's whole balance. This contract's data hook lets it, and only it, cash out everything for free.
        uint256 amount = TERMINAL.cashOutTokensOf({
            holder: address(this),
            projectId: projectId,
            cashOutCount: 0,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(address(this)),
            metadata: ""
        });

        if (amount != 0) {
            // Revenue that reached the lunch as another project's payout pays its Juicebox fee here. The JBP6 that buys
            // belongs to the creator.
            _sendFeeTokensTo(record.creator);

            PoolKey memory key = poolKeyOf(projectId);

            // Buying the token lowers the pool's tokens-per-ETH price, so the bound sits below the reference.
            uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(_boundTickOf(key) - TWAP_MAX_DEVIATION);

            // Buy as much as the bound allows.
            // slither-disable-next-line unused-return
            (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
            if (sqrtPriceX96 > sqrtPriceLimitX96) {
                (spent,) = _swap({key: key, zeroForOne: true, amountIn: amount, sqrtPriceLimitX96: sqrtPriceLimitX96});
            }

            // Put back what the buy couldn't spend.
            if (amount != spent) _addToBalanceOf({projectId: projectId, amount: amount - spent});
        }

        // Burn everything bought, along with any tokens that arrived carrying revenue from other chains.
        burned = _burnTokensOf(projectId);

        emit Burn({projectId: projectId, spent: spent, burned: burned, caller: _msgSender()});
    }

    /// @notice Collect a served lunch's liquidity fees, burning the token side and paying the ETH side into JBP6 with
    /// the creator as beneficiary.
    /// @dev Anyone can call this. The position's liquidity is never touched.
    /// @param projectId The ID of the lunch's project.
    /// @return tokensBurned The number of tokens collected and burned.
    /// @return ethPaid The amount of ETH paid into JBP6.
    function collect(uint256 projectId) external override nonReentrant returns (uint256 tokensBurned, uint256 ethPaid) {
        FairLunchRecord storage record = _recordOf[projectId];

        // Only a served lunch has a position.
        if (record.servedAt == 0) revert FairLunch_NotServed(projectId);

        PoolKey memory key = poolKeyOf(projectId);
        uint256 ethBefore = address(this).balance;

        // Decreasing liquidity by zero collects the position's fees without touching its principal.
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(record.positionId, uint256(0), uint128(0), uint128(0), "");
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        POSITION_MANAGER.modifyLiquidities({unlockData: abi.encode(actions, params), deadline: block.timestamp});

        // Burn the token side.
        tokensBurned = _burnTokensOf(projectId);

        // Pay the ETH side into JBP6, which mints JBP6 to the creator.
        ethPaid = address(this).balance - ethBefore;
        if (ethPaid != 0) {
            // slither-disable-next-line unused-return
            DIRECTORY.primaryTerminalOf({
                projectId: _FEE_PROJECT_ID, token: JBConstants.NATIVE_TOKEN
            }).pay{value: ethPaid}({
                projectId: _FEE_PROJECT_ID,
                token: JBConstants.NATIVE_TOKEN,
                amount: ethPaid,
                beneficiary: record.creator,
                minReturnedTokens: 0,
                memo: "",
                metadata: ""
            });
        }

        emit Collect({projectId: projectId, tokensBurned: tokensBurned, ethPaid: ethPaid, caller: _msgSender()});
    }

    /// @notice Make a lunch on this chain.
    /// @dev Call this with the same configuration, from the same address, on the host chain and on every other chain
    /// the lunch should collect revenue from. `msg.value` must be the project creation fee, if there is one.
    /// @param config The lunch's configuration.
    /// @return projectId The ID of the lunch's project on this chain.
    function createFor(FairLunchConfig calldata config) external payable override returns (uint256 projectId) {
        if (
            config.creator == address(0) || config.hostChainId == 0 || config.deadline <= block.timestamp
                || config.keepPercent > MAX_CREATOR_PERCENT || config.tokenPercent > MAX_CREATOR_PERCENT
        ) revert FairLunch_InvalidConfig();

        // A lunch needs this chain's Uniswap addresses.
        if (address(POSITION_MANAGER) == address(0)) revert FairLunch_NotConfigured();

        bool isHost = config.hostChainId == block.chainid;

        // Scope the salt to the caller so nobody else can take a lunch's addresses on another chain, and to the
        // lunch's terms so only copies with the very same terms are bridged to each other. A copy with another host,
        // deadline or creator share would otherwise be a second mint of the same token.
        bytes32 salt = keccak256(
            abi.encode(
                _msgSender(),
                config.salt,
                config.hostChainId,
                config.deadline,
                config.creator,
                config.keepPercent,
                config.keepCap,
                config.tokenPercent,
                config.vestingDuration
            )
        );

        JBSuckerDeploymentConfig memory suckerDeploymentConfiguration = config.suckerDeploymentConfiguration;
        if (suckerDeploymentConfiguration.deployerConfigurations.length != 0) {
            suckerDeploymentConfiguration.salt = salt;
        }

        for (uint256 i; i < suckerDeploymentConfiguration.deployerConfigurations.length; i++) {
            // A lunch's suckers only ever pair with the same lunch's suckers on other chains, never a chosen peer.
            if (suckerDeploymentConfiguration.deployerConfigurations[i].peer != bytes32(0)) {
                revert FairLunch_InvalidConfig();
            }

            // The host's suckers start with nothing mapped, so the raise can't be bridged away. `serve` maps the
            // native token.
            if (isHost && suckerDeploymentConfiguration.deployerConfigurations[i].mappings.length != 0) {
                revert FairLunch_HostMapsNoTokens();
            }
        }

        // Only the host sells tokens. Everywhere else, payments mint nothing and wait to be sent home.
        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0] = _rulesetConfigOf({
            weight: isHost ? uint112(TOKENS_PER_ETH * 1e18) : 0,
            splitGroups: new JBSplitGroup[](0),
            fundAccessLimitGroups: new JBFundAccessLimitGroup[](0)
        });

        // Accept ETH.
        JBAccountingContext[] memory accountingContexts = new JBAccountingContext[](1);
        accountingContexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBConstants.NATIVE_TOKEN_CURRENCY
        });
        JBTerminalConfig[] memory terminalConfigurations = new JBTerminalConfig[](1);
        terminalConfigurations[0] = JBTerminalConfig({
            terminal: IJBTerminal(address(TERMINAL)), accountingContextsToAccept: accountingContexts
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
        // ETH they'd be stuck, so there's no lunch.
        if (
            !isHost
                && !_hostSuckerOf({
                    projectId: projectId, hostChainId: config.hostChainId
                }).isMapped(JBConstants.NATIVE_TOKEN)
        ) revert FairLunch_InvalidConfig();

        // Deploy the token up front so payers hold a real ERC-20 from their first payment.
        // slither-disable-next-line unused-return
        CONTROLLER.deployERC20For({projectId: projectId, name: config.name, symbol: config.symbol, salt: salt});

        FairLunchRecord storage record = _recordOf[projectId];
        record.hostChainId = config.hostChainId;
        record.deadline = config.deadline;
        record.creator = config.creator;
        record.keepPercent = config.keepPercent;
        record.keepCap = config.keepCap;
        record.tokenPercent = config.tokenPercent;
        record.vestingDuration = config.vestingDuration;

        emit Create({
            projectId: projectId,
            hostChainId: config.hostChainId,
            creator: config.creator,
            deadline: config.deadline,
            caller: _msgSender()
        });
    }

    /// @notice Accept only a lunch's project NFT and its liquidity position.
    /// @dev Part of `IERC721Receiver`.
    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (msg.sender != address(CONTROLLER.PROJECTS()) && msg.sender != address(POSITION_MANAGER)) {
            revert FairLunch_Unauthorized(msg.sender);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Send this chain's revenue to the lunch's host chain.
    /// @dev Anyone can call this on a chain other than the host. `msg.value` pays the sucker's fee and the bridge, and
    /// whatever they don't use is refunded to the caller.
    /// Suckers only carry ETH that backs tokens being bridged, so this mints tokens to carry it: one wei of token when
    /// nobody holds the token on this chain (cashing out the whole supply reclaims the whole balance), otherwise
    /// `_SEND_HOME_MULTIPLE` times the supply, which carries all but a sliver. The tokens are minted to this contract
    /// on the host chain, where the next `burn` burns them.
    /// @param projectId The ID of the lunch's project on this chain.
    function sendHome(uint256 projectId) external payable override nonReentrant {
        uint256 hostChainId = _recordOf[projectId].hostChainId;

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
            token: JBConstants.NATIVE_TOKEN,
            metadata: bytes32(0)
        });
        sucker.toRemote{value: msg.value}(JBConstants.NATIVE_TOKEN);

        // The sucker's fee bought JBP6 for this contract. It belongs to the caller who paid it. If the fee couldn't be
        // paid, the sucker kept it for this contract to take back.
        _sendFeeTokensTo(_msgSender());
        try IJBSuckerExtended(address(sucker)).claimRetainedToRemoteFee(payable(address(this))) {} catch {}

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
        if (record.servedAt != 0) revert FairLunch_AlreadyServed(projectId);
        if (block.timestamp <= record.deadline) {
            revert FairLunch_TooEarly({projectId: projectId, readyAt: uint256(record.deadline) + 1});
        }

        uint256 raised = TERMINAL.STORE()
            .balanceOf({terminal: address(TERMINAL), projectId: projectId, token: JBConstants.NATIVE_TOKEN});
        if (raised == 0) revert FairLunch_NothingRaised(projectId);

        // From here on the lunch is served: payments stop minting and start buying back.
        record.servedAt = uint48(block.timestamp);

        // Anything this contract holds beyond this was sent to it by mistake and isn't the lunch's.
        uint256 ethBefore = address(this).balance;

        // Pay the whole raise out: the creator's keep to the creator, everything else to this contract as the owner.
        _queuePayoutOf({
            projectId: projectId,
            raised: raised,
            creator: record.creator,
            keep: _min(mulDiv(raised, record.keepPercent, JBConstants.SPLITS_TOTAL_PERCENT), record.keepCap)
        });
        // slither-disable-next-line unused-return
        TERMINAL.sendPayoutsOf({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: raised,
            currency: JBConstants.NATIVE_TOKEN_CURRENCY,
            minTokensPaidOut: 0
        });
        uint256 poolEth = address(this).balance - ethBefore;

        // The payout's fee minted JBP6 to this contract as the project's owner. It belongs to the creator.
        _sendFeeTokensTo(record.creator);

        // Mint the other side of the market: as many tokens as the pool's ETH would have bought during the fundraise,
        // so the pool opens at the price payers paid.
        uint256 poolTokens = poolEth * TOKENS_PER_ETH;

        _mintTokensOf({projectId: projectId, tokenCount: poolTokens, beneficiary: address(this)});

        // Put the ETH and the tokens in the pool, forever.
        record.positionId = _openPoolOf({projectId: projectId, eth: poolEth, tokens: poolTokens});

        // Whatever the pool's price didn't take: burn the tokens, and leave the ETH in the balance for the burn.
        // slither-disable-next-line unused-return
        _burnTokensOf(projectId);
        uint256 ethLeft = address(this).balance - ethBefore;
        if (ethLeft != 0) _addToBalanceOf({projectId: projectId, amount: ethLeft});

        // Mint the creator's share of the total supply, now that it's settled, into a wallet that vests it linearly
        // from now.
        uint256 creatorTokens = mulDiv(
            TOKENS.totalSupplyOf(projectId), record.tokenPercent, JBConstants.SPLITS_TOTAL_PERCENT - record.tokenPercent
        );
        if (creatorTokens != 0) {
            record.vestingWallet = VESTING_DEPLOYER.deployFor({
                beneficiary: record.creator,
                startTimestamp: uint64(block.timestamp),
                durationSeconds: record.vestingDuration
            });
            _mintTokensOf({projectId: projectId, tokenCount: creatorTokens, beneficiary: record.vestingWallet});
        }

        // Open the bridges now that there is no raise left to bridge away.
        address[] memory suckers = SUCKER_REGISTRY.suckersOf(projectId);
        for (uint256 i; i < suckers.length; i++) {
            IJBSucker(suckers[i])
                .mapToken(
                    JBTokenMapping({
                    localToken: JBConstants.NATIVE_TOKEN,
                    minGas: _SUCKER_MIN_GAS,
                    remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
                })
                );
        }

        emit Serve({
            projectId: projectId,
            raised: raised,
            poolEth: poolEth,
            poolTokens: poolTokens,
            creatorTokens: creatorTokens,
            vestingWallet: record.vestingWallet,
            positionId: record.positionId,
            caller: _msgSender()
        });
    }

    /// @notice One-shot setter for this chain's Uniswap V4 addresses.
    /// @dev Callable only by `_DEPLOYER` and only once. After this call the values are effectively immutable. Keeping
    /// them out of the constructor keeps this contract's address the same on every chain.
    /// @param positionManager The Uniswap V4 position manager. The pool manager is read from it.
    /// @param oracleHook The Uniswap V4 hook every lunch's pool uses.
    function setChainSpecificConstants(IPositionManager positionManager, IGeomeanOracle oracleHook) external override {
        if (msg.sender != _DEPLOYER) revert FairLunch_Unauthorized(msg.sender);
        if (address(POSITION_MANAGER) != address(0)) revert FairLunch_AlreadyConfigured();
        if (address(positionManager) == address(0) || address(oracleHook) == address(0)) {
            revert FairLunch_InvalidConfig();
        }

        POSITION_MANAGER = positionManager;
        POOL_MANAGER = positionManager.poolManager();
        ORACLE_HOOK = oracleHook;
    }

    /// @notice Swaps inside the pool manager's lock.
    /// @dev Part of `IUnlockCallback`. Only reachable through `_swap`.
    /// @param data The encoded pool key, direction, input amount and price limit.
    /// @return The encoded amounts spent and received.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert FairLunch_Unauthorized(msg.sender);

        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 sqrtPriceLimitX96) =
            abi.decode(data, (PoolKey, bool, uint256, uint160));

        // A negative amount means exact input. The swap stops early if it reaches the price limit.
        BalanceDelta delta = POOL_MANAGER.swap({
            key: key,
            params: SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            hookData: ""
        });

        // The input side is owed to the pool manager (negative) and the output side is owed to this contract.
        (int128 deltaIn, int128 deltaOut) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 spent = uint256(uint128(-deltaIn));
        uint256 received = uint256(uint128(deltaOut));

        if (spent != 0) {
            if (zeroForOne) {
                // slither-disable-next-line unused-return
                POOL_MANAGER.settle{value: spent}();
            } else {
                POOL_MANAGER.sync(key.currency1);
                IERC20(Currency.unwrap(key.currency1)).safeTransfer({to: address(POOL_MANAGER), value: spent});
                // slither-disable-next-line unused-return
                POOL_MANAGER.settle();
            }
        }

        if (received != 0) {
            POOL_MANAGER.take({
                currency: zeroForOne ? key.currency1 : key.currency0, to: address(this), amount: received
            });
        }

        return abi.encode(spent, received);
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Lets this contract, and nobody else, cash out a lunch's whole balance for free.
    /// @dev Part of `IJBRulesetDataHook`. Every lunch's rulesets tax cash outs at 100%, so no holder can ever reclaim
    /// anything. This contract cashing out zero tokens is how `burn` moves the balance to the pool without a fee:
    /// reporting the whole supply as the cash out count reclaims the whole balance.
    /// @param context The cash out's context.
    /// @return cashOutTaxRate The cash out tax rate to use.
    /// @return cashOutCount The number of tokens to price the cash out with.
    /// @return totalSupply The total supply to price the cash out with.
    /// @return effectiveSurplusValue The surplus to price the cash out with.
    /// @return hookSpecifications No cash out hooks are used.
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
        if (context.holder == address(this)) {
            return (0, context.totalSupply, context.totalSupply, context.surplus.value, hookSpecifications);
        }

        return
            (
                context.cashOutTaxRate,
                context.cashOutCount,
                context.totalSupply,
                context.surplus.value,
                hookSpecifications
            );
    }

    /// @notice Sells tokens at the fixed price while a lunch is cooking, and turns payments into buybacks once it's
    /// served.
    /// @dev Part of `IJBRulesetDataHook`.
    /// @param context The payment's context.
    /// @return weight The number of tokens to mint per ETH paid, as a fixed point number with 18 decimals.
    /// @return hookSpecifications This contract as a pay hook, once the lunch is served.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        FairLunchRecord storage record = _recordOf[context.projectId];

        // Everywhere but the host, payments mint nothing and wait to be sent home.
        if (record.hostChainId != block.chainid) return (context.weight, hookSpecifications);

        // Once served, payments mint nothing and trigger the buyback. The payment itself stays in the balance.
        if (record.servedAt != 0) {
            hookSpecifications = new JBPayHookSpecification[](1);
            hookSpecifications[0] =
                JBPayHookSpecification({hook: IJBPayHook(address(this)), noop: false, amount: 0, metadata: ""});
            return (0, hookSpecifications);
        }

        // The fundraise is over once the deadline passes.
        if (block.timestamp > record.deadline) {
            revert FairLunch_Closed({projectId: context.projectId, deadline: record.deadline});
        }

        return (context.weight, hookSpecifications);
    }

    /// @notice Nobody gets to mint a lunch's tokens through this hook.
    /// @dev Part of `IJBRulesetDataHook`. This contract mints as the project's owner, and suckers mint through the
    /// omnichain deployer.
    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external pure override returns (bool) {
        return false;
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
    /// @dev ETH is always currency0: the native currency's address is zero, which sorts before every token.
    /// @param projectId The ID of the lunch's project.
    /// @return key The pool's key.
    function poolKeyOf(uint256 projectId) public view override returns (PoolKey memory key) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(TOKENS.tokenOf(projectId))),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(ORACLE_HOOK))
        });
    }

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See `IERC165.supportsInterface`.
    /// @param interfaceId The ID of the interface to check for adherence to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IFairLunch).interfaceId || interfaceId == type(IJBRulesetDataHook).interfaceId
            || interfaceId == type(IJBPayHook).interfaceId || interfaceId == type(IERC721Receiver).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Add ETH to a lunch's balance.
    /// @param projectId The ID of the lunch's project.
    /// @param amount The amount of ETH to add.
    function _addToBalanceOf(uint256 projectId, uint256 amount) internal {
        TERMINAL.addToBalanceOf{value: amount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "",
            metadata: ""
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

    /// @notice Put a lunch's ETH and tokens into its pool as one full-range position.
    /// @dev Anyone can create the pool, or add liquidity to it, before the lunch is served. So before adding liquidity,
    /// this trades toward the fundraise's price with that price as the limit. An empty pool moves there for free. Any
    /// liquidity in the way is traded against at a price better for the lunch than the fundraise's price: tokens
    /// offered below it are bought, and ETH bid above it is sold to.
    /// @param projectId The ID of the lunch's project.
    /// @param eth The amount of ETH to pool.
    /// @param tokens The number of tokens to pool.
    /// @return positionId The ID of the position.
    function _openPoolOf(uint256 projectId, uint256 eth, uint256 tokens) internal returns (uint256 positionId) {
        PoolKey memory key = poolKeyOf(projectId);

        // slither-disable-next-line unused-return
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());

        if (sqrtPriceX96 == 0) {
            // Nobody made the pool yet. Open it at the fundraise's price.
            // slither-disable-next-line unused-return
            POOL_MANAGER.initialize({key: key, sqrtPriceX96: _RAISE_SQRT_PRICE_X96});
        } else if (sqrtPriceX96 > _RAISE_SQRT_PRICE_X96) {
            // Tokens are cheaper than the fundraise's price. Buy them down to it, with at most half the ETH so there's
            // always a position left to make however much liquidity is in the way.
            (uint256 spent, uint256 received) =
                _swap({key: key, zeroForOne: true, amountIn: eth / 2, sqrtPriceLimitX96: _RAISE_SQRT_PRICE_X96});
            eth -= spent;
            tokens += received;
        } else if (sqrtPriceX96 < _RAISE_SQRT_PRICE_X96) {
            // Tokens are dearer than the fundraise's price. Sell them up to it, with at most half the tokens.
            (uint256 spent, uint256 received) =
                _swap({key: key, zeroForOne: false, amountIn: tokens / 2, sqrtPriceLimitX96: _RAISE_SQRT_PRICE_X96});
            tokens -= spent;
            eth += received;
        }

        // Size the position at wherever the price ended up.
        // slither-disable-next-line unused-return
        (sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts({
            sqrtPriceX96: sqrtPriceX96,
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(tickUpper),
            amount0: eth,
            amount1: tokens
        });

        // Someone traded one whole side away at a better-than-fundraise price. Arbitrage will clear that; try again.
        if (liquidity == 0) revert FairLunch_NoLiquidity(projectId);

        // Let the position manager pull the tokens through Permit2, for this call only.
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        token.forceApprove({spender: address(PERMIT2), value: tokens});
        PERMIT2.approve({
            token: address(token),
            spender: address(POSITION_MANAGER),
            amount: tokens.toUint160(),
            expiration: uint48(block.timestamp)
        });

        // Mint the position to this contract, settle both sides, and sweep back what the price didn't take.
        positionId = POSITION_MANAGER.nextTokenId();
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(liquidity), eth.toUint128(), tokens.toUint128(), address(this), ""
        );
        params[1] = abi.encode(key.currency0, uint256(0), true);
        params[2] = abi.encode(key.currency1, uint256(0), true);
        params[3] = abi.encode(key.currency0, address(this));
        params[4] = abi.encode(key.currency1, address(this));
        POSITION_MANAGER.modifyLiquidities{value: eth}({
            unlockData: abi.encode(actions, params), deadline: block.timestamp
        });

        // Leave no pull authority behind.
        PERMIT2.approve({token: address(token), spender: address(POSITION_MANAGER), amount: 0, expiration: 1});
        token.forceApprove({spender: address(PERMIT2), value: 0});
    }

    /// @notice Queue the ruleset a lunch keeps forever, set up to pay its whole raise out once.
    /// @dev The payout limit can only ever be used once because the ruleset never cycles. The creator's keep is a
    /// split, and the rest of the payout goes to this contract as the project's owner.
    /// @param projectId The ID of the lunch's project.
    /// @param raised The amount of ETH to make payable.
    /// @param creator The address that receives the keep.
    /// @param keep The amount of ETH the creator keeps, before the JB fee.
    function _queuePayoutOf(uint256 projectId, uint256 raised, address creator, uint256 keep) internal {
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({amount: uint224(raised), currency: JBConstants.NATIVE_TOKEN_CURRENCY});
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
        fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
            terminal: address(TERMINAL),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        JBSplitGroup[] memory splitGroups;
        uint256 splitPercent = mulDiv(keep, JBConstants.SPLITS_TOTAL_PERCENT, raised);
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
            splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});
        }

        JBRulesetConfig[] memory rulesetConfigurations = new JBRulesetConfig[](1);
        rulesetConfigurations[0] =
            _rulesetConfigOf({weight: 0, splitGroups: splitGroups, fundAccessLimitGroups: fundAccessLimitGroups});

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

    /// @notice Swap an exact input in a lunch's pool, stopping at a price limit.
    /// @param key The pool's key.
    /// @param zeroForOne Whether ETH is being sold for tokens (true) or tokens for ETH (false).
    /// @param amountIn The most to sell.
    /// @param sqrtPriceLimitX96 The price at which the swap stops.
    /// @return spent The amount sold.
    /// @return received The amount bought.
    function _swap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    )
        internal
        returns (uint256 spent, uint256 received)
    {
        if (amountIn == 0) return (0, 0);

        return
            abi.decode(
                POOL_MANAGER.unlock(abi.encode(key, zeroForOne, amountIn, sqrtPriceLimitX96)), (uint256, uint256)
            );
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

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

    /// @notice The tick a buyback's price bound is measured from: the pool's average tick over the last `TWAP_WINDOW`,
    /// or its tick a second ago if that's higher (cheaper tokens).
    /// @dev The average keeps a buyback from chasing a price that was pushed up over several blocks. The tick a second
    /// ago is the price before anything traded in this block, which keeps a buyback from chasing a price that was
    /// pushed up just ahead of it. Reverts if the pool's history doesn't reach `TWAP_WINDOW` back.
    /// @param key The pool's key.
    /// @return tick The reference tick, rounded toward negative infinity.
    function _boundTickOf(PoolKey memory key) internal view returns (int24 tick) {
        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 1;

        // slither-disable-next-line unused-return
        (int56[] memory tickCumulatives,) = ORACLE_HOOK.observe({key: key, secondsAgos: secondsAgos});

        int56 delta = tickCumulatives[2] - tickCumulatives[0];
        tick = int24(delta / int56(uint56(TWAP_WINDOW)));
        if (delta < 0 && delta % int56(uint56(TWAP_WINDOW)) != 0) tick--;

        // Over one second the cumulative's change is the tick itself.
        int24 lastTick = int24(tickCumulatives[2] - tickCumulatives[1]);
        if (lastTick > tick) tick = lastTick;
    }

    /// @notice The smaller of two numbers.
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice The ruleset every lunch uses: no reserved tokens, no cash outs, no owner powers beyond minting, and this
    /// contract as the data hook for payments and cash outs.
    /// @param weight The number of tokens minted per ETH paid, as a fixed point number with 18 decimals.
    /// @param splitGroups The ruleset's splits.
    /// @param fundAccessLimitGroups The ruleset's payout limits.
    /// @return config The ruleset's configuration.
    function _rulesetConfigOf(
        uint112 weight,
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundAccessLimitGroups
    )
        internal
        view
        returns (JBRulesetConfig memory config)
    {
        config.weight = weight;
        config.approvalHook = IJBRulesetApprovalHook(address(0));
        config.splitGroups = splitGroups;
        config.fundAccessLimitGroups = fundAccessLimitGroups;
        config.metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: JBConstants.MAX_CASH_OUT_TAX_RATE,
            baseCurrency: JBConstants.NATIVE_TOKEN_CURRENCY,
            pausePay: false,
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
            dataHook: address(this),
            metadata: 0
        });
    }
}
