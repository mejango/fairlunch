// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {IJBOmnichainDeployer} from "@bananapus/omnichain-deployers-v6/src/interfaces/IJBOmnichainDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IGeomeanOracle} from "@bananapus/univ4-router-v6/src/interfaces/IGeomeanOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Test} from "forge-std/Test.sol";

import {FairLunch} from "../../src/FairLunch.sol";
import {FairLunchVestingDeployer} from "../../src/FairLunchVestingDeployer.sol";
import {FairLunchConfig} from "../../src/structs/FairLunchConfig.sol";
import {FairLunchRecord} from "../../src/structs/FairLunchRecord.sol";
import {PoolProbe} from "../PoolProbe.sol";

/// @notice A plain 18-decimal token.
contract Money is ERC20("Money", "MONEY") {}

/// @notice The life of a lunch that raises an ERC-20, against live V6 and Uniswap V4 on Base. Each contract below runs
/// it with another token. The fuzzed cases run 64 times each, not the default 512: every run reads fresh pool and
/// router state from the fork's RPC, and 512 of them take twenty minutes.
abstract contract FairLunchErc20 is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IJBOmnichainDeployer internal constant OMNI = IJBOmnichainDeployer(0xB853758A70a6b4216c09f1d071eA2344AbA0a34f);
    IJBMultiTerminal internal constant TERMINAL = IJBMultiTerminal(0x130f5Dd2bD8805443Cf41755253D778a75a67f53);
    IJBTerminal internal constant ROUTER_REGISTRY = IJBTerminal(0xe0427F250fdb0379c8E98e884Ee4570521208CbC);
    IJBTerminalStore internal constant STORE = IJBTerminalStore(0x7497ae014A60561925B51C0A3B4adE7460B9927C);
    IJBTokens internal constant TOKENS = IJBTokens(0x1f80d8f057eE36b4C2656D107E4e4558B71bA7D9);
    IJBProjects internal constant PROJECTS = IJBProjects(0x6017d1FBa9DC279BFA0B03fD931C22E242AB3691);
    IJBBuybackHookRegistry internal constant BUYBACK =
        IJBBuybackHookRegistry(0x72F55a54CD53410a5Ff175508a5A384227081788);
    IJBSuckerRegistry internal constant REGISTRY = IJBSuckerRegistry(0x7903a854aE91eAf635430D120a1a434085cEf297);
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0x7C5f5A4bBd8fD63184577525326123B519429bDc);
    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IGeomeanOracle internal constant ORACLE = IGeomeanOracle(0xB436Cedbee8F191A3860719b4B0f474434F315c8);

    FairLunch internal lunch;
    IERC20 internal money;
    uint256 internal unit;
    address internal creator = address(0xC0FFEE0001);
    address internal alice = address(0xA11CE0001);
    address internal bob = address(0xB0B0001);
    uint48 internal deadline;

    /// @notice The token this run's lunches raise.
    function _money() internal virtual returns (IERC20);

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", 56_216_000);
        lunch = new FairLunch({
            omnichainDeployer: OMNI,
            buybackRegistry: BUYBACK,
            terminal: TERMINAL,
            routerTerminalRegistry: ROUTER_REGISTRY,
            suckerRegistry: REGISTRY,
            permit2: PERMIT2,
            vestingDeployer: new FairLunchVestingDeployer(),
            deployer: address(this)
        });
        lunch.setChainSpecificConstants({positionManager: POSITION_MANAGER, oracleHook: ORACLE});
        deadline = uint48(block.timestamp + 7 days);

        money = _money();
        unit = 10 ** IERC20Metadata(address(money)).decimals();
        deal(address(money), alice, 1_000_000 * unit);
        deal(address(money), bob, 1_000_000 * unit);
        vm.prank(alice);
        money.approve(address(TERMINAL), type(uint256).max);
        vm.prank(bob);
        money.approve(address(TERMINAL), type(uint256).max);
    }

    //*********************************************************************//
    // ----------------------------- helpers ----------------------------- //
    //*********************************************************************//

    function _create(uint32 keepPercent, uint104 keepCap, uint32 tokenPercent) internal returns (uint256) {
        FairLunchConfig memory config;
        config.name = "Sandwich";
        config.symbol = "SAND";
        config.hostChainId = uint64(block.chainid);
        config.token = address(money);
        config.deadline = deadline;
        config.creator = creator;
        config.keepPercent = keepPercent;
        config.keepCap = keepCap;
        config.tokenPercent = tokenPercent;
        config.vestingDuration = 52 weeks;
        return lunch.createFor{value: PROJECTS.creationFee()}(config);
    }

    /// @notice Pay a lunch. Returns the tokens the payer ended up with.
    function _pay(uint256 id, address from, uint256 amount, bytes memory metadata) internal returns (uint256) {
        uint256 before = _token(id).balanceOf(from);
        vm.prank(from);
        TERMINAL.pay(id, address(money), amount, from, 0, "", metadata);
        return _token(id).balanceOf(from) - before;
    }

    /// @notice A lunch that raised 10,000 and was served.
    function _served(uint32 keepPercent, uint104 keepCap, uint32 tokenPercent) internal returns (uint256 id) {
        id = _create(keepPercent, keepCap, tokenPercent);
        _pay(id, alice, 10_000 * unit, "");
        vm.warp(deadline + 1);
        lunch.serve(id);
    }

    /// @notice When `_served` serves. Warps are absolute: via-IR caches `block.timestamp` across `vm.warp`.
    function _servedAt() internal view returns (uint256) {
        return uint256(deadline) + 1;
    }

    /// @notice What a payment tells the buyback hook: the fewest tokens it will take.
    function _minimum(uint256 minimum) internal pure returns (bytes memory) {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = JBMetadataResolver.getId("pay", address(BUYBACK));
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encode(uint256(0), minimum, true);
        return JBMetadataResolver.createMetadata(ids, datas);
    }

    function _balance(uint256 id) internal view returns (uint256) {
        return STORE.balanceOf(address(TERMINAL), id, address(money));
    }

    function _token(uint256 id) internal view returns (IERC20) {
        return IERC20(address(TOKENS.tokenOf(id)));
    }

    /// @notice Whether the money is the currency0 of a lunch's pool.
    function _moneyIs0(uint256 id) internal view returns (bool) {
        return Currency.unwrap(lunch.poolKeyOf(id).currency0) == address(money);
    }

    /// @notice The pool's price as tokens per whole unit of money, with 18 decimals.
    function _tokensPerUnit(uint256 id) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(lunch.poolKeyOf(id).toId());
        // The square root price is the square root of token1 per token0, with 96 fractional bits.
        return _moneyIs0(id)
            ? Math.mulDiv(Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96), unit, 1 << 96)
            : Math.mulDiv(Math.mulDiv(unit, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
    }

    function _assertHoldsNothing(uint256 id) internal view {
        assertEq(money.balanceOf(address(lunch)), 0, "lunch holds money");
        assertEq(money.balanceOf(address(lunch.POOL())), 0, "pool contract holds money");
        assertEq(TOKENS.totalBalanceOf(address(lunch.POOL()), id), 0, "pool contract holds tokens");
        assertEq(TOKENS.totalBalanceOf(address(lunch), id), 0, "lunch holds tokens");
        assertEq(TOKENS.totalBalanceOf(address(lunch), 1), 0, "lunch holds JBP6");
    }

    //*********************************************************************//
    // ------------------------------ tests ------------------------------ //
    //*********************************************************************//

    function test_createFor_takesTheMoneyAndRoutesTheRest() public {
        uint256 id = _create(0, 0, 0);
        IJBDirectory directory = lunch.DIRECTORY();

        assertEq(lunch.recordOf(id).token, address(money));
        assertEq(address(directory.primaryTerminalOf(id, address(money))), address(TERMINAL), "money to the terminal");
        IJBTerminal[] memory terminals = directory.terminalsOf(id);
        assertEq(terminals.length, 2);
        assertEq(address(terminals[1]), address(ROUTER_REGISTRY), "everything else to the router");
        assertEq(
            TERMINAL.accountingContextForTokenOf(id, address(money)).decimals, IERC20Metadata(address(money)).decimals()
        );
    }

    function test_pay_mintsOneMillionPerUnit() public {
        uint256 id = _create(0, 0, 0);
        assertEq(_pay(id, alice, 3 * unit, ""), 3_000_000e18);
        assertEq(_pay(id, bob, unit / 100, ""), 10_000e18);
        assertEq(_balance(id), 3 * unit + unit / 100);
    }

    /// @notice The creator gets the keep, the rest is pooled at the price payers paid, and nothing is left behind.
    function test_serve_splitsTheRaise() public {
        uint256 id = _served(uint32(200_000_000), uint104(1500 * unit), uint32(100_000_000));

        // 20% of 10,000 is over the 1,500 cap. Both sides pay the 2.5% Juicebox fee.
        assertApproxEqAbs(money.balanceOf(creator), 1500 * unit * 975 / 1000, 2, "keep");
        uint256 pooled = 8500 * unit * 975 / 1000;
        assertApproxEqRel(_tokensPerUnit(id), 1_000_000e18, 0.0001e18, "opens at the raise price");
        assertGt(POSITION_MANAGER.getPositionLiquidity(lunch.recordOf(id).positionId), 0, "locked");
        assertGe(money.balanceOf(address(POOL_MANAGER)), pooled - pooled / 1e9 - 2, "the money is in the pool");

        // Funders, as many again for each unit pooled, and the creator's tenth of the total.
        uint256 marketed = 10_000_000_000e18 + pooled * 1_000_000e18 / unit;
        assertApproxEqRel(TOKENS.totalSupplyOf(id), marketed * 10 / 9, 0.0001e18, "supply");
        assertApproxEqRel(
            _token(id).balanceOf(lunch.recordOf(id).vestingWallet), marketed / 9, 0.0001e18, "creator's tokens"
        );
        _assertHoldsNothing(id);
    }

    /// @notice Once served, a payment that names a minimum buys from the pool, and one that doesn't waits for `burn`.
    function test_afterServe_paysBuyAndBurn() public {
        uint256 id = _served(0, 0, 0);
        uint256 supply = TOKENS.totalSupplyOf(id);

        // 10 units buy just under 10M tokens after the 1% fee.
        vm.warp(_servedAt() + 1 minutes);
        assertApproxEqRel(_pay(id, bob, 10 * unit, _minimum(9_800_000e18)), 9_900_000e18, 0.01e18, "bought");
        assertEq(TOKENS.totalSupplyOf(id), supply, "from the pool, not minted");

        // Revenue without a minimum mints nothing and waits.
        uint256 waiting = _balance(id);
        assertEq(_pay(id, bob, 20 * unit, ""), 0, "nothing minted");
        assertEq(_balance(id), waiting + 20 * unit, "waits");

        vm.expectRevert();
        lunch.burn(id);

        vm.warp(_servedAt() + 31 minutes);
        (uint256 spent, uint256 burned) = lunch.burn(id);
        assertApproxEqAbs(spent, waiting + 20 * unit, 2, "spent it all");
        assertApproxEqRel(burned, spent * 1_000_000e18 / unit, 0.05e18, "bought near the raise price");
        assertEq(TOKENS.totalSupplyOf(id), supply - burned, "burned");
        _assertHoldsNothing(id);
    }

    /// @notice An oversized burn stops 200 ticks from the average price and puts the rest back.
    function test_burn_stopsAtTheBound() public {
        uint256 id = _served(0, 0, 0);
        vm.warp(_servedAt() + 1 minutes);
        _pay(id, bob, unit, _minimum(1));
        _pay(id, bob, 5000 * unit, "");
        vm.warp(_servedAt() + 31 minutes);

        (uint256 spent,) = lunch.burn(id);
        assertGt(spent, 0, "bought some");
        assertLt(spent, 5000 * unit, "not all of it");
        // 200 ticks is 2.02%, and the earlier trade moved the price a hair.
        assertGt(_tokensPerUnit(id), uint256(1_000_000e18) * 1000 / 1021, "no further than the bound");
        assertApproxEqRel(_balance(id), 5000 * unit - spent, 1e9, "the rest waits");
        _assertHoldsNothing(id);
    }

    /// @notice Trading around a burn never pays, whichever way the push goes.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_burn_sandwichNeverProfits(uint256 push, uint256 waiting, bool moneyFirst) public {
        uint256 id = _served(0, 0, 0);
        PoolKey memory key = lunch.poolKeyOf(id);
        PoolProbe probe = new PoolProbe(POSITION_MANAGER, PERMIT2);
        vm.warp(_servedAt() + 1 minutes);
        _pay(id, bob, unit, _minimum(1));
        _pay(id, bob, bound(waiting, unit, 5000 * unit), "");
        vm.warp(_servedAt() + 31 minutes);

        // Up to twice the pool's money, or most of its tokens.
        if (moneyFirst) {
            push = bound(push, unit / 10, 20_000 * unit);
            deal(address(money), address(probe), push);
        } else {
            push = bound(push, 100_000e18, 9_000_000_000e18);
            IERC20 token = _token(id);
            vm.prank(alice);
            token.transfer(address(probe), push);
        }

        (uint256 back,) =
            probe.sandwich(key, moneyFirst == _moneyIs0(id), push, address(lunch), 0, abi.encodeCall(lunch.burn, (id)));
        assertLe(back, push, "the round trip paid");
    }

    /// @notice A pool someone made early at a far-off price, either way, doesn't move where the lunch opens.
    /// forge-config: default.fuzz.runs = 64
    function test_serve_overAnEarlyPool(bool dear) public {
        uint256 id = _create(0, 0, 0);
        _pay(id, alice, 10_000 * unit, "");
        PoolKey memory key = lunch.poolKeyOf(id);
        POOL_MANAGER.initialize(key, dear ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);

        vm.warp(deadline + 1);
        lunch.serve(id);

        // Within what the 1% fee makes of the raise price on either side.
        assertApproxEqRel(_tokensPerUnit(id), 1_000_000e18, 0.0102e18, "opens at the raise price");
        assertGt(POSITION_MANAGER.getPositionLiquidity(lunch.recordOf(id).positionId), 0, "locked");
        _assertHoldsNothing(id);
    }

    /// @notice Whatever is raised, the pool opens at the raise price with nothing left behind.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_serve_anyRaise(uint256 raised, uint32 keepPercent) public {
        raised = bound(raised, unit / 100, 500_000 * unit);
        uint256 id = _create(uint32(bound(keepPercent, 0, 500_000_000)), type(uint104).max, 0);
        _pay(id, alice, raised, "");
        vm.warp(deadline + 1);
        lunch.serve(id);

        assertApproxEqRel(_tokensPerUnit(id), 1_000_000e18, 0.0001e18, "opens at the raise price");
        _assertHoldsNothing(id);
    }

    /// @notice Pool fees burn the token side. The money side buys the creator JBP6 where JBP6 takes it, and feeds the
    /// next burn where it doesn't.
    function test_collect_burnsTokensAndPassesOnTheMoney() public {
        uint256 id = _served(0, 0, 0);
        PoolProbe trader = new PoolProbe(POSITION_MANAGER, PERMIT2);
        deal(address(money), address(trader), 100 * unit);
        bool moneyIs0 = _moneyIs0(id);
        uint256 bought = trader.swap(lunch.poolKeyOf(id), moneyIs0, 100 * unit);
        trader.swap(lunch.poolKeyOf(id), !moneyIs0, bought);

        uint256 supply = TOKENS.totalSupplyOf(id);
        uint256 balance = _balance(id);
        uint256 jbp6 = TOKENS.totalBalanceOf(creator, 1);
        bool jbp6TakesIt = address(lunch.DIRECTORY().primaryTerminalOf(1, address(money))) == address(TERMINAL);

        (uint256 tokensBurned, uint256 paid) = lunch.collect(id);

        assertApproxEqRel(paid, unit, 0.02e18, "1% of the money traded");
        assertApproxEqRel(tokensBurned, bought / 100, 0.02e18, "1% of the tokens traded");
        assertEq(TOKENS.totalSupplyOf(id), supply - tokensBurned, "burned");
        if (jbp6TakesIt) {
            assertGt(TOKENS.totalBalanceOf(creator, 1), jbp6, "JBP6 to the creator");
            assertEq(_balance(id), balance, "nothing waits");
        } else {
            assertEq(_balance(id), balance + paid, "waits for the burn");
        }
        _assertHoldsNothing(id);
    }
}

/// @notice USDC, with 6 decimals.
contract FairLunchUsdc is FairLunchErc20 {
    function _money() internal pure override returns (IERC20) {
        return IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    }

    /// @notice ETH paid through the router terminal is swapped into USDC and counts like USDC.
    function test_pay_inEthThroughTheRouter() public {
        uint256 id = _create(0, 0, 0);
        vm.deal(bob, 1 ether);

        vm.prank(bob);
        ROUTER_REGISTRY.pay{value: 1 ether}(id, JBConstants.NATIVE_TOKEN, 1 ether, bob, 0, "", "");

        uint256 raised = _balance(id);
        assertGt(raised, 1000 * unit, "an ETH's worth of USDC");
        assertEq(_token(id).balanceOf(bob), raised * 1_000_000e18 / unit, "a million per USDC it became");
        assertEq(address(lunch).balance, 0, "lunch holds ETH");
        _assertHoldsNothing(id);
    }

    /// @notice Once served, routed revenue with no minimum waits for `burn` like any other.
    function test_pay_inEthThroughTheRouter_afterServe() public {
        uint256 id = _served(0, 0, 0);
        uint256 waiting = _balance(id);
        vm.deal(bob, 1 ether);

        vm.prank(bob);
        ROUTER_REGISTRY.pay{value: 1 ether}(id, JBConstants.NATIVE_TOKEN, 1 ether, bob, 0, "", "");

        assertGt(_balance(id), waiting + 1000 * unit, "waits as USDC");
        assertEq(_token(id).balanceOf(bob), 0, "nothing minted");
    }
}

/// @notice An 18-decimal token whose address sorts before every lunch's token.
contract FairLunchMoneyFirst is FairLunchErc20 {
    function _money() internal override returns (IERC20) {
        vm.etch(address(0x1000), address(new Money()).code);
        return IERC20(address(0x1000));
    }

    function test_moneyIsCurrency0() public {
        assertTrue(_moneyIs0(_create(0, 0, 0)));
    }
}

/// @notice An 18-decimal token whose address sorts after every lunch's token.
contract FairLunchMoneyLast is FairLunchErc20 {
    function _money() internal override returns (IERC20) {
        address last = address(uint160(type(uint160).max - 0x1000));
        vm.etch(last, address(new Money()).code);
        return IERC20(last);
    }

    function test_moneyIsCurrency1() public {
        assertFalse(_moneyIs0(_create(0, 0, 0)));
    }
}
