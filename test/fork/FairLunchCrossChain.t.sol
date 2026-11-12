// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJBOmnichainDeployer} from "@bananapus/omnichain-deployers-v6/src/interfaces/IJBOmnichainDeployer.sol";
import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBTokenMapping} from "@bananapus/suckers-v6/src/structs/JBTokenMapping.sol";
import {IGeomeanOracle} from "@bananapus/univ4-router-v6/src/interfaces/IGeomeanOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Test} from "forge-std/Test.sol";

import {FairLunch} from "../../src/FairLunch.sol";
import {FairLunchVestingDeployer} from "../../src/FairLunchVestingDeployer.sol";
import {FairLunchConfig} from "../../src/structs/FairLunchConfig.sol";

/// @notice A lunch hosted on Base that collects revenue on Optimism, against the live CCIP suckers on both chains.
/// @dev The bridge's delivery isn't simulated. The remote half is tested through `toRemote` on Optimism, and the host
/// half is tested by doing on Base exactly what a sucker's `claim` does: add the ETH to the balance and mint the
/// bridged tokens to the beneficiary, as the sucker.
/// @notice The fee a sucker kept for an account whose fee it couldn't pay.
interface IJBSuckerFees {
    function retainedToRemoteFeeOf(address account) external view returns (uint256);
}

contract FairLunchCrossChain is Test {
    IJBOmnichainDeployer internal constant OMNI = IJBOmnichainDeployer(0xB853758A70a6b4216c09f1d071eA2344AbA0a34f);
    IJBController internal constant CONTROLLER = IJBController(0x3Fcec3572e84b624477BcfF4E2CF1f7dEAb648F1);
    IJBMultiTerminal internal constant TERMINAL = IJBMultiTerminal(0x130f5Dd2bD8805443Cf41755253D778a75a67f53);
    IJBTerminalStore internal constant STORE = IJBTerminalStore(0x7497ae014A60561925B51C0A3B4adE7460B9927C);
    IJBTokens internal constant TOKENS = IJBTokens(0x1f80d8f057eE36b4C2656D107E4e4558B71bA7D9);
    IJBProjects internal constant PROJECTS = IJBProjects(0x6017d1FBa9DC279BFA0B03fD931C22E242AB3691);
    IJBBuybackHookRegistry internal constant BUYBACK =
        IJBBuybackHookRegistry(0x72F55a54CD53410a5Ff175508a5A384227081788);
    IJBSuckerRegistry internal constant REGISTRY = IJBSuckerRegistry(0x7903a854aE91eAf635430D120a1a434085cEf297);
    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    // The CCIP sucker deployer for the other chain of the pair has the same address on Base and Optimism.
    IJBSuckerDeployer internal constant CCIP_DEPLOYER = IJBSuckerDeployer(0x8f6f0a70939997310309d7ab66B1B199faAfE7F0);

    uint256 internal baseFork;
    uint256 internal optimismFork;
    FairLunch internal lunch;
    address internal creator = address(0xC0FFEE0001);
    address internal alice = address(0xA11CE0001);
    uint48 internal deadline;

    function setUp() public {
        baseFork = vm.createFork("https://mainnet.base.org", 56_216_000);
        optimismFork = vm.createFork("https://mainnet.optimism.io", 159_417_000);

        // The same address on both chains, as the deploy script guarantees.
        vm.selectFork(baseFork);
        deadline = uint48(block.timestamp + 7 days);
        lunch = _deploy();
        lunch.setChainSpecificConstants({
            positionManager: IPositionManager(0x7C5f5A4bBd8fD63184577525326123B519429bDc),
            oracleHook: IGeomeanOracle(0xB436Cedbee8F191A3860719b4B0f474434F315c8)
        });

        vm.selectFork(optimismFork);
        vm.warp(deadline - 7 days);
        assertEq(address(_deploy()), address(lunch), "same address on both chains");
        lunch.setChainSpecificConstants({
            positionManager: IPositionManager(0x3C3Ea4B57a46241e54610e5f022E5c45859A1017),
            oracleHook: IGeomeanOracle(0x850eC1a2aDcB2126d823632e60441De2926fD5C8)
        });

        vm.deal(alice, 1000 ether);
        vm.makePersistent(alice);
    }

    function _deploy() internal returns (FairLunch) {
        FairLunchVestingDeployer vestingDeployer = new FairLunchVestingDeployer{salt: "lunch"}();
        return new FairLunch{salt: "lunch"}({
            omnichainDeployer: OMNI,
            buybackRegistry: BUYBACK,
            terminal: TERMINAL,
            suckerRegistry: REGISTRY,
            permit2: PERMIT2,
            vestingDeployer: vestingDeployer,
            deployer: address(this)
        });
    }

    function _config(bool mapNative) internal view returns (FairLunchConfig memory config) {
        config.name = "Sandwich";
        config.symbol = "SAND";
        config.hostChainId = 8453;
        config.deadline = deadline;
        config.creator = creator;
        config.vestingDuration = 52 weeks;
        config.salt = "sandwich";

        JBTokenMapping[] memory mappings = new JBTokenMapping[](mapNative ? 1 : 0);
        if (mapNative) {
            mappings[0] = JBTokenMapping({
                localToken: JBConstants.NATIVE_TOKEN,
                minGas: 200_000,
                remoteToken: bytes32(uint256(uint160(JBConstants.NATIVE_TOKEN)))
            });
        }
        config.suckerDeploymentConfiguration.deployerConfigurations = new JBSuckerDeployerConfig[](1);
        config.suckerDeploymentConfiguration.deployerConfigurations[0] =
            JBSuckerDeployerConfig({deployer: CCIP_DEPLOYER, peer: bytes32(0), mappings: mappings});
    }

    function _pay(uint256 id, uint256 amount) internal returns (uint256) {
        vm.prank(alice);
        return TERMINAL.pay{value: amount}(id, JBConstants.NATIVE_TOKEN, amount, alice, 0, "", "");
    }

    function _balance(uint256 id) internal view returns (uint256) {
        return STORE.balanceOf(address(TERMINAL), id, JBConstants.NATIVE_TOKEN);
    }

    /// @notice What a sucker's `claim` does on the host: add the bridged ETH and mint the bridged tokens.
    function _claimOnHost(uint256 id, uint256 eth, uint256 tokens) internal {
        address sucker = REGISTRY.suckersOf(id)[0];
        vm.deal(sucker, eth);
        vm.startPrank(sucker);
        TERMINAL.addToBalanceOf{value: eth}(id, JBConstants.NATIVE_TOKEN, eth, false, "", "");
        CONTROLLER.mintTokensOf(id, tokens, address(lunch), "", false);
        vm.stopPrank();
    }

    //*********************************************************************//
    // ------------------------------ remote ----------------------------- //
    //*********************************************************************//

    function test_remote_paysMintNothingAndSendHome() public {
        vm.selectFork(optimismFork);
        uint256 id = lunch.createFor{value: PROJECTS.creationFee()}(_config(true));

        assertEq(_pay(id, 1 ether), 0, "remote payments mint nothing");
        assertEq(TOKENS.totalSupplyOf(id), 0);
        assertEq(_balance(id), 1 ether);

        // Nobody can cash out here either, and the lunch can't be served here.
        vm.warp(uint256(deadline) + 1);
        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_NotHost.selector, id, 8453));
        lunch.serve(id);

        // Anyone sends the revenue home, paying the bridge.
        address caller = address(0xCA11E40001);
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        lunch.sendHome{value: 0.1 ether}(id);

        assertEq(_balance(id), 0, "the whole balance left");
        assertEq(TOKENS.totalSupplyOf(id), 0, "the carrier token was burned");
        assertEq(address(lunch).balance, 0, "no ETH stranded on the lunch contract");
        assertGt(caller.balance, 0.9 ether + 0.05 ether, "unused bridge payment refunded to the caller");
        assertEq(TOKENS.totalBalanceOf(address(lunch), id), 0, "no tokens stranded on the lunch contract");

        // The sucker's fee bought JBP6. It went to the caller who paid it, not to the lunch contract.
        assertEq(TOKENS.totalBalanceOf(address(lunch), 1), 0, "no JBP6 stranded on the lunch contract");
        if (REGISTRY.toRemoteFee() != 0) {
            assertGt(TOKENS.totalBalanceOf(caller, 1), 0, "the caller got the fee's JBP6");
        }
    }

    /// @notice When the sucker can't pay its fee to JBP6 it keeps the fee for whoever called it. That's the lunch
    /// contract, which takes it back and returns it to the caller who paid.
    function test_sendHome_returnsAFeeTheSuckerCouldntPay() public {
        vm.selectFork(optimismFork);
        uint256 id = lunch.createFor{value: PROJECTS.creationFee()}(_config(true));
        _pay(id, 1 ether);
        address sucker = REGISTRY.suckersOf(id)[0];

        // A fee is due.
        vm.mockCall(
            address(REGISTRY), abi.encodeWithSelector(IJBSuckerRegistry.toRemoteFee.selector), abi.encode(0.01 ether)
        );

        address caller = address(0xCA11E40002);
        vm.deal(caller, 1 ether);

        // First with the fee paid, to know what the same call leaves the caller when it is.
        uint256 snapshot = vm.snapshotState();
        vm.prank(caller);
        lunch.sendHome{value: 0.1 ether}(id);
        uint256 leftWhenPaid = caller.balance;
        assertGt(TOKENS.totalBalanceOf(caller, 1), 0, "the paid fee bought the caller JBP6");
        vm.revertToState(snapshot);

        // Then with JBP6 refusing it.
        vm.mockCallRevert(address(TERMINAL), abi.encodeWithSelector(IJBTerminal.pay.selector, uint256(1)), "");
        vm.prank(caller);
        lunch.sendHome{value: 0.1 ether}(id);

        assertEq(_balance(id), 0, "the balance still left");
        assertEq(caller.balance, leftWhenPaid + 0.01 ether, "the caller has exactly the fee back");
        assertEq(IJBSuckerFees(sucker).retainedToRemoteFeeOf(address(lunch)), 0, "nothing left in the sucker");
        assertEq(address(lunch).balance, 0, "nothing left on the lunch contract");
        assertEq(TOKENS.totalBalanceOf(caller, 1), 0, "no JBP6 was bought");
    }

    /// @notice Holders can bridge their tokens to a copy's chain. Sending home then carries all but a millionth of the
    /// balance, and leaves their tokens alone.
    function test_sendHome_withHoldersOnTheRemote() public {
        vm.selectFork(optimismFork);
        uint256 id = lunch.createFor{value: PROJECTS.creationFee()}(_config(true));
        _pay(id, 1 ether);

        // What a sucker's `claim` does for a holder who bridged 100 tokens here.
        vm.prank(REGISTRY.suckersOf(id)[0]);
        CONTROLLER.mintTokensOf(id, 100e18, alice, "", false);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        lunch.sendHome{value: 0.1 ether}(id);

        // 100 tokens of 100,000,100 share what's left: one part in a million and one.
        assertEq(_balance(id), 1 ether - (1 ether * uint256(1_000_000)) / 1_000_001, "a millionth stays");
        assertEq(TOKENS.totalBalanceOf(alice, id), 100e18, "the holder's tokens are untouched");
        assertEq(TOKENS.totalSupplyOf(id), 100e18, "every carrier token was burned");
        assertEq(TOKENS.totalBalanceOf(address(lunch), id), 0, "no tokens stranded on the lunch contract");
    }

    /// @notice A remote lunch with no bridge home, or one that can't carry ETH, would only trap what it's paid.
    function test_createFor_remoteNeedsARouteHome() public {
        vm.selectFork(optimismFork);
        uint256 fee = PROJECTS.creationFee();

        FairLunchConfig memory unmapped = _config(false);
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(unmapped);

        // Mapped, then switched off: the sucker remembers the address but won't send.
        FairLunchConfig memory disabled = _config(true);
        JBTokenMapping[] memory mappings = new JBTokenMapping[](2);
        mappings[0] = disabled.suckerDeploymentConfiguration.deployerConfigurations[0].mappings[0];
        mappings[1] = JBTokenMapping({localToken: JBConstants.NATIVE_TOKEN, minGas: 200_000, remoteToken: bytes32(0)});
        disabled.suckerDeploymentConfiguration.deployerConfigurations[0].mappings = mappings;
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(disabled);

        // More gas than any bridge message can carry.
        FairLunchConfig memory greedy = _config(true);
        greedy.suckerDeploymentConfiguration.deployerConfigurations[0].mappings[0].minGas = type(uint32).max;
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(greedy);

        // ETH that arrives on the host as wrapped ETH, which the host can't take. Today the bridge refuses the mapping
        // itself; if it ever allowed it, Fair Lunch refuses.
        FairLunchConfig memory wrapped = _config(true);
        wrapped.suckerDeploymentConfiguration.deployerConfigurations[0].mappings[0].remoteToken =
            bytes32(uint256(uint160(0x4200000000000000000000000000000000000006)));
        vm.expectRevert();
        lunch.createFor{value: fee}(wrapped);

        FairLunchConfig memory bridgeless = _config(true);
        bridgeless.suckerDeploymentConfiguration.deployerConfigurations = new JBSuckerDeployerConfig[](0);
        vm.expectPartialRevert(FairLunch.FairLunch_NoHostSucker.selector);
        lunch.createFor{value: fee}(bridgeless);
    }

    /// @notice A copy that couldn't be made in time can still be made after the deadline, with the host's terms, and
    /// pairs with the host. The host itself can't be made late.
    function test_createFor_copyAfterTheDeadline() public {
        uint256 fee = PROJECTS.creationFee();
        vm.selectFork(baseFork);
        FairLunchConfig memory hostConfig = _config(false);
        address hostSucker = REGISTRY.suckersOf(lunch.createFor{value: fee}(hostConfig))[0];

        vm.selectFork(optimismFork);
        vm.warp(uint256(hostConfig.deadline) + 1 days);
        FairLunchConfig memory copyConfig = _config(true);
        copyConfig.deadline = hostConfig.deadline;
        assertEq(REGISTRY.suckersOf(lunch.createFor{value: fee}(copyConfig))[0], hostSucker, "pairs with the host");

        vm.selectFork(baseFork);
        vm.warp(uint256(hostConfig.deadline) + 1 days);
        hostConfig.salt = bytes32(uint256(hostConfig.salt) + 1);
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(hostConfig);
    }

    /// @notice A chosen peer could be any project's sucker, minting this lunch's token from nothing.
    function test_createFor_revertsWithAChosenPeer() public {
        vm.selectFork(baseFork);
        FairLunchConfig memory config = _config(false);
        config.suckerDeploymentConfiguration.deployerConfigurations[0].peer = bytes32(uint256(1));
        uint256 fee = PROJECTS.creationFee();
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);
    }

    /// @notice A copy with other terms on another chain gets a sucker at another address, so the two never pair.
    function test_copyWithOtherTerms_isNotAPeer() public {
        uint256 fee = PROJECTS.creationFee();
        vm.selectFork(baseFork);
        address hostSucker = REGISTRY.suckersOf(lunch.createFor{value: fee}(_config(false)))[0];

        // The same caller and salt, with the creator taking half the tokens at once.
        vm.selectFork(optimismFork);
        FairLunchConfig memory other = _config(true);
        other.tokenPercent = 500_000_000;
        other.vestingDuration = 0;
        assertNotEq(REGISTRY.suckersOf(lunch.createFor{value: fee}(other))[0], hostSucker, "other terms, other sucker");

        // The same terms pair.
        assertEq(
            REGISTRY.suckersOf(lunch.createFor{value: fee}(_config(true)))[0], hostSucker, "same terms, same sucker"
        );
    }

    //*********************************************************************//
    // ------------------------------- host ------------------------------ //
    //*********************************************************************//

    function test_host_mapsNothingUntilServed() public {
        vm.selectFork(baseFork);
        uint256 fee = PROJECTS.creationFee();

        // The host can't be created with a mapping.
        FairLunchConfig memory mapped = _config(true);
        vm.expectRevert(FairLunch.FairLunch_HostMapsNoTokens.selector);
        lunch.createFor{value: fee}(mapped);

        uint256 id = lunch.createFor{value: fee}(_config(false));
        IJBSucker sucker = IJBSucker(REGISTRY.suckersOf(id)[0]);
        assertEq(sucker.peerChainId(), 10);
        assertFalse(sucker.isMapped(JBConstants.NATIVE_TOKEN));

        // So the raise can't be bridged away while cooking.
        _pay(id, 10 ether);
        IERC20 token = IERC20(address(TOKENS.tokenOf(id)));
        vm.startPrank(alice);
        token.approve(address(sucker), 1_000_000e18);
        vm.expectRevert();
        sucker.prepare(1_000_000e18, bytes32(uint256(uint160(alice))), 0, JBConstants.NATIVE_TOKEN, bytes32(0));
        vm.stopPrank();

        // Serving opens the bridge.
        vm.warp(uint256(deadline) + 1);
        lunch.serve(id);
        assertTrue(sucker.isMapped(JBConstants.NATIVE_TOKEN));
    }

    function test_host_claimBeforeServe_countsAsRaised() public {
        vm.selectFork(baseFork);
        uint256 id = lunch.createFor{value: PROJECTS.creationFee()}(_config(false));
        _pay(id, 10 ether);

        // What serving leaves when the same 1 ETH arrives with no token carrying it.
        uint256 snapshot = vm.snapshotState();
        address sucker = REGISTRY.suckersOf(id)[0];
        vm.deal(sucker, 1 ether);
        vm.prank(sucker);
        TERMINAL.addToBalanceOf{value: 1 ether}(id, JBConstants.NATIVE_TOKEN, 1 ether, false, "", "");
        vm.warp(uint256(deadline) + 1);
        lunch.serve(id);
        uint256 supplyWithoutCarrier = TOKENS.totalSupplyOf(id);
        vm.revertToState(snapshot);

        // A remote chain with no holders sends 1 ETH home carried by one wei of token.
        _claimOnHost({id: id, eth: 1 ether, tokens: 1});
        assertEq(_balance(id), 11 ether);

        vm.warp(uint256(deadline) + 1);
        lunch.serve(id);

        // All 11 ETH less the fee is pooled beside 10.725M tokens, and the carrier wei is gone.
        assertApproxEqAbs(TOKENS.totalSupplyOf(id), 10_000_000e18 + 10_725_000e18, 1e12);
        assertEq(TOKENS.totalBalanceOf(address(lunch), id), 0);
        assertEq(address(lunch).balance, 0);

        // To the wei: the supply is what it would be had no carrier come, payers hold what they bought, and every
        // other token is in the pool. The carrier diluted nobody.
        assertEq(TOKENS.totalSupplyOf(id), supplyWithoutCarrier, "the same supply as with no carrier");
        IERC20 token = IERC20(address(TOKENS.tokenOf(id)));
        assertEq(token.balanceOf(alice), 10_000_000e18, "the payer's tokens");
        assertEq(
            TOKENS.totalSupplyOf(id), 10_000_000e18 + token.balanceOf(address(lunch.POOL_MANAGER())), "payer plus pool"
        );
    }

    function test_host_claimAfterServe_feedsTheBurn() public {
        vm.selectFork(baseFork);
        uint256 id = lunch.createFor{value: PROJECTS.creationFee()}(_config(false));
        _pay(id, 10 ether);
        vm.warp(uint256(deadline) + 1);
        lunch.serve(id);
        uint256 supply = TOKENS.totalSupplyOf(id);

        // A remote chain with holders sends 0.01 ETH home carried by a large token count.
        _claimOnHost({id: id, eth: 0.01 ether, tokens: 5_000_000_000_000e18});

        vm.warp(uint256(deadline) + 1 + 30 minutes);
        (uint256 spent, uint256 burned) = lunch.burn(id);

        assertApproxEqAbs(spent, 0.01 ether, 1e9, "bridged ETH bought tokens");
        assertGt(burned, 5_000_000_000_000e18, "carrier tokens and bought tokens burned");
        assertLt(TOKENS.totalSupplyOf(id), supply, "supply ends below where it started");
        assertEq(TOKENS.totalBalanceOf(address(lunch), id), 0);
        assertEq(address(lunch).balance, 0);
    }
}
