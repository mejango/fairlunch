// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBCashOutTerminal} from "@bananapus/core-v6/src/interfaces/IJBCashOutTerminal.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplitGroupIds} from "@bananapus/core-v6/src/libraries/JBSplitGroupIds.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBCurrencyAmount} from "@bananapus/core-v6/src/structs/JBCurrencyAmount.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {IJBOmnichainDeployer} from "@bananapus/omnichain-deployers-v6/src/interfaces/IJBOmnichainDeployer.sol";
import {JBSuckerDeploymentConfig} from "@bananapus/omnichain-deployers-v6/src/structs/JBSuckerDeploymentConfig.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Test, console} from "forge-std/Test.sol";

/// @notice Throwaway owner + extra data hook used to settle the spec's unknowns against live V6 on Base.
contract SpikeHarness is IJBRulesetDataHook, IJBPayHook {
    IJBController internal constant CONTROLLER = IJBController(0x3Fcec3572e84b624477BcfF4E2CF1f7dEAb648F1);
    IJBMultiTerminal internal constant TERMINAL = IJBMultiTerminal(0x130f5Dd2bD8805443Cf41755253D778a75a67f53);
    IJBOmnichainDeployer internal constant OMNI = IJBOmnichainDeployer(0xB853758A70a6b4216c09f1d071eA2344AbA0a34f);

    uint256 public projectId;
    bool public drainOnPay;
    bool public drainOnPaySucceeded;
    uint256 public drainCount;

    receive() external payable {}

    function launch() external payable {
        JBRulesetConfig[] memory rulesets = new JBRulesetConfig[](1);
        rulesets[0] = _ruleset({weight: 1_000_000e18, payoutLimit: 0, split: address(0)});

        JBAccountingContext[] memory contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: JBConstants.NATIVE_TOKEN_CURRENCY
        });
        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](1);
        terminals[0] =
            JBTerminalConfig({terminal: IJBTerminal(address(TERMINAL)), accountingContextsToAccept: contexts});

        JBSuckerDeploymentConfig memory suckers;
        (projectId,,) = OMNI.launchProjectFor{value: msg.value}({
            owner: address(this),
            projectUri: "",
            rulesetConfigurations: rulesets,
            terminalConfigurations: terminals,
            memo: "",
            suckerDeploymentConfiguration: suckers
        });
        CONTROLLER.deployERC20For({projectId: projectId, name: "Spike", symbol: "SPK", salt: bytes32(0)});
    }

    function queue(uint224 payoutLimit, address split) external {
        JBRulesetConfig[] memory rulesets = new JBRulesetConfig[](1);
        rulesets[0] = _ruleset({weight: 0, payoutLimit: payoutLimit, split: split});
        OMNI.queueRulesetsOf({projectId: projectId, rulesetConfigurations: rulesets, memo: ""});
    }

    function grantQueue(IJBPermissions permissions) external {
        uint8[] memory ids = new uint8[](1);
        ids[0] = JBPermissionIds.QUEUE_RULESETS;
        permissions.setPermissionsFor({
            account: address(this),
            permissionsData: JBPermissionsData({
                operator: address(OMNI), projectId: uint64(projectId), permissionIds: ids
            })
        });
    }

    function setDrain(bool onPay, uint256 count) external {
        drainOnPay = onPay;
        drainCount = count;
    }

    function drain(uint256 count) public returns (uint256) {
        if (count != 0) {
            CONTROLLER.mintTokensOf({
                projectId: projectId, tokenCount: count, beneficiary: address(this), memo: "", useReservedPercent: false
            });
        }
        return TERMINAL.cashOutTokensOf({
            holder: address(this),
            projectId: projectId,
            cashOutCount: count,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(address(this)),
            metadata: ""
        });
    }

    function payouts(uint256 amount) external returns (uint256) {
        return TERMINAL.sendPayoutsOf({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            currency: JBConstants.NATIVE_TOKEN_CURRENCY,
            minTokensPaidOut: 0
        });
    }

    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory specs)
    {
        weight = context.weight;
        if (drainOnPay) {
            specs = new JBPayHookSpecification[](1);
            specs[0] = JBPayHookSpecification({hook: IJBPayHook(address(this)), noop: false, amount: 0, metadata: ""});
        }
    }

    function afterPayRecordedWith(JBAfterPayRecordedContext calldata) external payable override {
        try this.drain(drainCount) {
            drainOnPaySucceeded = true;
        } catch {}
    }

    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        external
        view
        override
        returns (uint256, uint256, uint256, uint256, JBCashOutHookSpecification[] memory specs)
    {
        if (context.holder == address(this)) {
            return (0, context.totalSupply, context.totalSupply, context.surplus.value, specs);
        }
        return (context.cashOutTaxRate, context.cashOutCount, context.totalSupply, context.surplus.value, specs);
    }

    function hasMintPermissionFor(uint256, JBRuleset calldata, address) external pure override returns (bool) {
        return false;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IJBPayHook).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _ruleset(
        uint112 weight,
        uint224 payoutLimit,
        address split
    )
        internal
        view
        returns (JBRulesetConfig memory config)
    {
        config.weight = weight;
        config.approvalHook = IJBRulesetApprovalHook(address(0));
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
        if (payoutLimit != 0) {
            JBCurrencyAmount[] memory limits = new JBCurrencyAmount[](1);
            limits[0] = JBCurrencyAmount({amount: payoutLimit, currency: JBConstants.NATIVE_TOKEN_CURRENCY});
            config.fundAccessLimitGroups = new JBFundAccessLimitGroup[](1);
            config.fundAccessLimitGroups[0] = JBFundAccessLimitGroup({
                terminal: address(TERMINAL),
                token: JBConstants.NATIVE_TOKEN,
                payoutLimits: limits,
                surplusAllowances: new JBCurrencyAmount[](0)
            });
            JBSplit[] memory splits = new JBSplit[](1);
            splits[0] = JBSplit({
                percent: JBConstants.SPLITS_TOTAL_PERCENT / 5,
                projectId: 0,
                beneficiary: payable(split),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(0))
            });
            config.splitGroups = new JBSplitGroup[](1);
            config.splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});
        }
    }
}

contract FairLunchSpikes is Test {
    IJBMultiTerminal internal constant TERMINAL = IJBMultiTerminal(0x130f5Dd2bD8805443Cf41755253D778a75a67f53);
    IJBTerminalStore internal constant STORE = IJBTerminalStore(0x7497ae014A60561925B51C0A3B4adE7460B9927C);
    IJBTokens internal constant TOKENS = IJBTokens(0x1f80d8f057eE36b4C2656D107E4e4558B71bA7D9);
    IJBProjects internal constant PROJECTS = IJBProjects(0x6017d1FBa9DC279BFA0B03fD931C22E242AB3691);

    SpikeHarness internal harness;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", 56_216_000);
        harness = new SpikeHarness();
        harness.launch{value: PROJECTS.creationFee()}();
        vm.deal(alice, 100 ether);
        _pay(1 ether);
    }

    function _pay(uint256 amount) internal returns (uint256) {
        vm.prank(alice);
        return TERMINAL.pay{value: amount}({
            projectId: harness.projectId(),
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: alice,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    function _balance() internal view returns (uint256) {
        return STORE.balanceOf(address(TERMINAL), harness.projectId(), JBConstants.NATIVE_TOKEN);
    }

    function test_payMintsOneMillionPerEth() public view {
        assertEq(TOKENS.totalBalanceOf(alice, harness.projectId()), 1_000_000e18);
    }

    function test_strangerReclaimsNothing() public {
        uint256 id = harness.projectId();
        vm.prank(alice);
        uint256 reclaimed = TERMINAL.cashOutTokensOf({
            holder: alice,
            projectId: id,
            cashOutCount: 500_000e18,
            tokenToReclaim: JBConstants.NATIVE_TOKEN,
            minTokensReclaimed: 0,
            beneficiary: payable(alice),
            metadata: ""
        });
        assertEq(reclaimed, 0);
        assertEq(_balance(), 1 ether);
    }

    function test_wholeBalanceCashOut_zeroTokens() public {
        try harness.drain(0) returns (uint256 reclaimed) {
            console.log("drain(0) reclaimed", reclaimed);
            console.log("harness eth", address(harness).balance, "left", _balance());
        } catch (bytes memory err) {
            console.log("drain(0) reverted");
            console.logBytes(err);
        }
    }

    function test_wholeBalanceCashOut_oneWei() public {
        uint256 reclaimed = harness.drain(1);
        assertEq(reclaimed, 1 ether, "fee-free whole balance");
        assertEq(address(harness).balance, 1 ether);
        assertEq(_balance(), 0);
        assertEq(TOKENS.totalBalanceOf(address(harness), harness.projectId()), 0);
    }

    function test_wholeBalanceCashOutInsidePayHook() public {
        harness.setDrain(true, 1);
        _pay(1 ether);
        console.log("drain inside pay hook succeeded", harness.drainOnPaySucceeded());
        console.log("harness eth", address(harness).balance, "left", _balance());
    }

    function test_payoutFeeBeneficiary() public {
        vm.warp(block.timestamp + 1);
        try harness.queue(1 ether, bob) {}
        catch {
            console.log("queue needs QUEUE_RULESETS grant to the deployer");
            harness.grantQueue(IJBPermissions(0xf92AC1aB5A00033E35a3975739124F61928C36B0));
            harness.queue(1 ether, bob);
        }
        uint256 paidOut = harness.payouts(1 ether);
        console.log("paid out", paidOut);
        console.log("bob eth", bob.balance, "harness eth", address(harness).balance);
        console.log("left in balance", _balance());
        console.log("JBP6 to harness", TOKENS.totalBalanceOf(address(harness), 1));
        console.log("JBP6 to bob", TOKENS.totalBalanceOf(bob, 1));
        console.log("JBP6 to this", TOKENS.totalBalanceOf(address(this), 1));
        // Does a weight-0 pay after this land in the balance and drain fee-free?
        _pay(1 ether);
        console.log("alice tokens after weight-0 pay", TOKENS.totalBalanceOf(alice, harness.projectId()));
        uint256 reclaimed = harness.drain(1);
        console.log("post-payout drain reclaimed", reclaimed);
    }

    function test_liveAddresses() public view {
        address hook = 0xB436Cedbee8F191A3860719b4B0f474434F315c8;
        assertGt(hook.code.length, 0, "v4 hook");
        assertGt(0x7903a854aE91eAf635430D120a1a434085cEf297.code.length, 0, "sucker registry");
        assertGt(0x000000000022D473030F116dDEE9F6B43aC78BA3.code.length, 0, "permit2");
    }
}
