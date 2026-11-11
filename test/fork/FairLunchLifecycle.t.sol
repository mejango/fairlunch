// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IJBOmnichainDeployer} from "@bananapus/omnichain-deployers-v6/src/interfaces/IJBOmnichainDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IGeomeanOracle} from "@bananapus/univ4-router-v6/src/interfaces/IGeomeanOracle.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Test} from "forge-std/Test.sol";

import {FairLunch} from "../../src/FairLunch.sol";
import {IFairLunch} from "../../src/interfaces/IFairLunch.sol";
import {FairLunchConfig} from "../../src/structs/FairLunchConfig.sol";
import {FairLunchRecord} from "../../src/structs/FairLunchRecord.sol";

/// @notice A creator that can't receive ETH.
contract Picky {}

/// @notice Pays a project from inside the pool manager's lock, the way a router mid-swap would.
contract LockedPayer is IUnlockCallback {
    IPoolManager internal immutable POOL_MANAGER;
    IJBMultiTerminal internal immutable TERMINAL;

    constructor(IPoolManager poolManager, IJBMultiTerminal terminal) {
        POOL_MANAGER = poolManager;
        TERMINAL = terminal;
    }

    function payWhileUnlocked(uint256 projectId) external payable {
        POOL_MANAGER.unlock(abi.encode(projectId, msg.value));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint256 projectId, uint256 amount) = abi.decode(data, (uint256, uint256));
        TERMINAL.pay{value: amount}(projectId, JBConstants.NATIVE_TOKEN, amount, address(this), 0, "", "");
        return "";
    }
}

/// @notice The whole life of a lunch on its host chain, against live V6 and Uniswap V4 on Base.
contract FairLunchLifecycle is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IJBOmnichainDeployer internal constant OMNI = IJBOmnichainDeployer(0xB853758A70a6b4216c09f1d071eA2344AbA0a34f);
    IJBMultiTerminal internal constant TERMINAL = IJBMultiTerminal(0x130f5Dd2bD8805443Cf41755253D778a75a67f53);
    IJBTerminalStore internal constant STORE = IJBTerminalStore(0x7497ae014A60561925B51C0A3B4adE7460B9927C);
    IJBTokens internal constant TOKENS = IJBTokens(0x1f80d8f057eE36b4C2656D107E4e4558B71bA7D9);
    IJBProjects internal constant PROJECTS = IJBProjects(0x6017d1FBa9DC279BFA0B03fD931C22E242AB3691);
    IJBSuckerRegistry internal constant REGISTRY = IJBSuckerRegistry(0x7903a854aE91eAf635430D120a1a434085cEf297);
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0x7C5f5A4bBd8fD63184577525326123B519429bDc);
    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IGeomeanOracle internal constant ORACLE = IGeomeanOracle(0xB436Cedbee8F191A3860719b4B0f474434F315c8);

    uint256 internal constant RAISE_SQRT_PRICE_X96 = 1000 << 96;
    uint32 internal constant HALF = JBConstants.SPLITS_TOTAL_PERCENT / 2;
    uint32 internal constant FIFTH = JBConstants.SPLITS_TOTAL_PERCENT / 5;
    uint32 internal constant TENTH = JBConstants.SPLITS_TOTAL_PERCENT / 10;

    FairLunch internal lunch;
    address internal creator = address(0xC0FFEE0001);
    address internal alice = address(0xA11CE0001);
    address internal bob = address(0xB0B0001);
    uint48 internal deadline;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", 56_216_000);
        lunch = new FairLunch({
            omnichainDeployer: OMNI,
            terminal: TERMINAL,
            suckerRegistry: REGISTRY,
            permit2: PERMIT2,
            deployer: address(this)
        });
        lunch.setChainSpecificConstants({positionManager: POSITION_MANAGER, oracleHook: ORACLE});
        deadline = uint48(block.timestamp + 7 days);
        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
    }

    //*********************************************************************//
    // ----------------------------- helpers ----------------------------- //
    //*********************************************************************//

    function _config(
        address to,
        uint32 keepPercent,
        uint104 keepCap,
        uint32 tokenPercent
    )
        internal
        view
        returns (FairLunchConfig memory config)
    {
        config.name = "Sandwich";
        config.symbol = "SAND";
        config.hostChainId = uint64(block.chainid);
        config.deadline = deadline;
        config.creator = to;
        config.keepPercent = keepPercent;
        config.keepCap = keepCap;
        config.tokenPercent = tokenPercent;
        config.vestingDuration = 52 weeks;
    }

    function _create(uint32 keepPercent, uint104 keepCap, uint32 tokenPercent) internal returns (uint256) {
        return lunch.createFor{value: PROJECTS.creationFee()}(_config(creator, keepPercent, keepCap, tokenPercent));
    }

    function _pay(uint256 id, address from, uint256 amount) internal returns (uint256) {
        vm.prank(from);
        return TERMINAL.pay{value: amount}({
            projectId: id,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: from,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    /// @notice When `_served` serves. Warps are absolute: via-IR caches `block.timestamp` across `vm.warp`.
    function _servedAt() internal view returns (uint256) {
        return uint256(deadline) + 1;
    }

    function _balance(uint256 id) internal view returns (uint256) {
        return STORE.balanceOf(address(TERMINAL), id, JBConstants.NATIVE_TOKEN);
    }

    function _token(uint256 id) internal view returns (IERC20) {
        return IERC20(address(TOKENS.tokenOf(id)));
    }

    function _sqrtPrice(uint256 id) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(lunch.poolKeyOf(id).toId());
    }

    function _tick(uint256 id) internal view returns (int24 tick) {
        (, tick,,) = POOL_MANAGER.getSlot0(lunch.poolKeyOf(id).toId());
    }

    /// @notice A lunch that raised 10 ETH and was served.
    function _served(uint32 keepPercent, uint104 keepCap, uint32 tokenPercent) internal returns (uint256 id) {
        id = _create(keepPercent, keepCap, tokenPercent);
        _pay(id, alice, 10 ether);
        vm.warp(deadline + 1);
        lunch.serve(id);
    }

    function _assertHoldsNothing(uint256 id) internal view {
        assertEq(address(lunch).balance, 0, "lunch holds ETH");
        assertEq(TOKENS.totalBalanceOf(address(lunch), id), 0, "lunch holds tokens");
        assertEq(TOKENS.totalBalanceOf(address(lunch), 1), 0, "lunch holds JBP6");
    }

    //*********************************************************************//
    // ----------------------------- cooking ----------------------------- //
    //*********************************************************************//

    function test_createFor_storesRecord() public {
        uint256 id = _create(FIFTH, 5 ether, TENTH);
        FairLunchRecord memory record = lunch.recordOf(id);
        assertEq(record.hostChainId, block.chainid);
        assertEq(record.deadline, deadline);
        assertEq(record.servedAt, 0);
        assertEq(record.creator, creator);
        assertEq(record.keepPercent, FIFTH);
        assertEq(record.keepCap, 5 ether);
        assertEq(record.tokenPercent, TENTH);
        assertEq(record.vestingDuration, 52 weeks);
        assertEq(PROJECTS.ownerOf(id), address(lunch));
    }

    function test_createFor_revertsOnBadConfig() public {
        uint256 fee = PROJECTS.creationFee();

        FairLunchConfig memory config = _config(creator, HALF + 1, 0, 0);
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);

        config = _config(creator, 0, 0, HALF + 1);
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);

        config = _config(address(0), 0, 0, 0);
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);

        config = _config(creator, 0, 0, 0);
        config.deadline = uint48(block.timestamp);
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);

        config = _config(creator, 0, 0, 0);
        config.hostChainId = 0;
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);
    }

    function test_pay_mintsOneMillionPerEth() public {
        uint256 id = _create(FIFTH, 5 ether, TENTH);
        assertEq(_pay(id, alice, 1 ether), 1_000_000e18);
        assertEq(_token(id).balanceOf(alice), 1_000_000e18, "paid as ERC-20");

        // Right up to the deadline.
        vm.warp(deadline);
        assertEq(_pay(id, bob, 0.5 ether), 500_000e18);
    }

    function test_pay_revertsAfterDeadline() public {
        uint256 id = _create(FIFTH, 5 ether, TENTH);
        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert();
        TERMINAL.pay{value: 1 ether}(id, JBConstants.NATIVE_TOKEN, 1 ether, alice, 0, "", "");
    }

    function test_cashOut_reclaimsNothing_everyPhase() public {
        uint256 id = _create(FIFTH, 5 ether, TENTH);
        _pay(id, alice, 10 ether);

        vm.prank(alice);
        uint256 reclaimed =
            TERMINAL.cashOutTokensOf(alice, id, 1_000_000e18, JBConstants.NATIVE_TOKEN, 0, payable(alice), "");
        assertEq(reclaimed, 0, "cooking");
        assertEq(_balance(id), 10 ether);

        vm.warp(deadline + 1);
        lunch.serve(id);
        _pay(id, bob, 1 ether);

        vm.prank(alice);
        reclaimed = TERMINAL.cashOutTokensOf(alice, id, 1_000_000e18, JBConstants.NATIVE_TOKEN, 0, payable(alice), "");
        assertEq(reclaimed, 0, "served");
        assertApproxEqAbs(_balance(id), 1 ether, 1e9);
    }

    //*********************************************************************//
    // ------------------------------ serve ------------------------------ //
    //*********************************************************************//

    function test_serve_reverts() public {
        uint256 id = _create(FIFTH, 5 ether, TENTH);

        // Not a lunch.
        vm.expectRevert();
        lunch.serve(1);

        // Before the deadline.
        _pay(id, alice, 1 ether);
        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_TooEarly.selector, id, uint256(deadline) + 1));
        lunch.serve(id);

        // Twice.
        vm.warp(deadline + 1);
        lunch.serve(id);
        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_AlreadyServed.selector, id));
        lunch.serve(id);
    }

    function test_serve_revertsWithNothingRaised() public {
        uint256 id = _create(FIFTH, 5 ether, TENTH);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_NothingRaised.selector, id));
        lunch.serve(id);

        // And payments stay closed.
        vm.prank(alice);
        vm.expectRevert();
        TERMINAL.pay{value: 1 ether}(id, JBConstants.NATIVE_TOKEN, 1 ether, alice, 0, "", "");
    }

    function test_serve_keepBelowCap() public {
        uint256 id = _served(FIFTH, 5 ether, 0);
        // 20% of 10 ETH, less the 2.5% fee.
        assertEq(creator.balance, 1.95 ether);
        assertGt(TOKENS.totalBalanceOf(creator, 1), 0, "creator got the fee's JBP6");
        _assertHoldsNothing(id);
    }

    function test_serve_keepAboveCap() public {
        uint256 id = _served(FIFTH, 1 ether, 0);
        // Capped at 1 ETH, less the 2.5% fee.
        assertApproxEqAbs(creator.balance, 0.975 ether, 1e9);
        _assertHoldsNothing(id);
    }

    function test_serve_poolOpensAtRaisePrice() public {
        uint256 supplyBefore;
        uint256 id = _create(FIFTH, 5 ether, 0);
        _pay(id, alice, 10 ether);
        supplyBefore = TOKENS.totalSupplyOf(id);
        vm.warp(deadline + 1);
        lunch.serve(id);

        assertEq(_sqrtPrice(id), RAISE_SQRT_PRICE_X96, "opens at the fundraise's price");

        // 8 ETH less the fee went to the pool, with a million tokens per ETH beside it.
        uint256 poolEth = 7.8 ether;
        assertApproxEqAbs(TOKENS.totalSupplyOf(id), supplyBefore + poolEth * 1_000_000, 1e12, "pool tokens");
        assertApproxEqAbs(_balance(id), 0, 1e9, "nothing left in the balance");
        assertEq(lunch.recordOf(id).servedAt, _servedAt());
        assertEq(
            IERC721Like(address(POSITION_MANAGER)).ownerOf(lunch.recordOf(id).positionId),
            address(lunch),
            "lunch holds the position"
        );
        _assertHoldsNothing(id);
    }

    function test_serve_creatorTokensVest() public {
        uint256 id = _served(0, 0, TENTH);
        FairLunchRecord memory record = lunch.recordOf(id);
        VestingWallet wallet = VestingWallet(payable(record.vestingWallet));
        IERC20 token = _token(id);

        // A tenth of the total supply.
        assertApproxEqAbs(token.balanceOf(address(wallet)) * 10, token.totalSupply(), 1e6, "10% of supply");
        assertEq(wallet.owner(), creator);
        assertEq(wallet.start(), _servedAt());
        assertEq(wallet.duration(), 52 weeks);

        uint256 total = token.balanceOf(address(wallet));
        vm.warp(_servedAt() + 13 weeks);
        wallet.release(address(token));
        assertApproxEqAbs(token.balanceOf(creator), total / 4, 1, "a quarter after a quarter");

        vm.warp(_servedAt() + 65 weeks);
        wallet.release(address(token));
        assertEq(token.balanceOf(creator), total, "all of it at the end");
    }

    function test_serve_noCreatorShares() public {
        uint256 id = _served(0, 0, 0);
        assertEq(creator.balance, 0);
        assertEq(lunch.recordOf(id).vestingWallet, address(0));
        // The whole raise less the fee is in the pool.
        assertEq(_sqrtPrice(id), RAISE_SQRT_PRICE_X96);
        _assertHoldsNothing(id);
    }

    function test_serve_creatorRejectsEth() public {
        Picky picky = new Picky();
        uint256 id =
            lunch.createFor{value: PROJECTS.creationFee()}(_config(address(picky), FIFTH, 5 ether, 0));
        _pay(id, alice, 10 ether);
        vm.warp(deadline + 1);
        lunch.serve(id);

        // The keep couldn't be delivered, so it stays in the lunch's balance, where the burn will use it.
        assertEq(address(picky).balance, 0);
        assertApproxEqAbs(_balance(id), 2 ether, 1e9, "undeliverable keep waits for the burn");
        assertEq(_sqrtPrice(id), RAISE_SQRT_PRICE_X96);
        _assertHoldsNothing(id);
    }

    function test_serve_hostilePoolTooHigh() public {
        _serveOverHostilePool(TickMath.getSqrtPriceAtTick(TickMath.getTickAtSqrtPrice(uint160(RAISE_SQRT_PRICE_X96)) + 46_000));
    }

    function test_serve_hostilePoolTooLow() public {
        _serveOverHostilePool(TickMath.getSqrtPriceAtTick(TickMath.getTickAtSqrtPrice(uint160(RAISE_SQRT_PRICE_X96)) - 46_000));
    }

    /// @notice A stranger creates the pool at a price about 100x off before the lunch is served.
    function _serveOverHostilePool(uint160 hostileSqrtPriceX96) internal {
        uint256 id = _create(FIFTH, 5 ether, TENTH);
        _pay(id, alice, 10 ether);

        vm.prank(bob);
        POOL_MANAGER.initialize(lunch.poolKeyOf(id), hostileSqrtPriceX96);

        vm.warp(deadline + 1);
        lunch.serve(id);

        assertEq(_sqrtPrice(id), RAISE_SQRT_PRICE_X96, "moved back to the fundraise's price for free");
        assertApproxEqAbs(_balance(id), 0, 1e9, "the whole pool share was pooled");
        _assertHoldsNothing(id);
    }

    /// @notice A stranger creates the pool with tokens priced dear and bids 1 ETH for them above the fundraise's
    /// price. Serving sells into that bid on the way to the fundraise's price, so the lunch ends up with more ETH.
    function test_serve_strangerLiquidity() public {
        uint256 id = _create(0, 0, 0);
        _pay(id, alice, 10 ether);
        PoolKey memory key = lunch.poolKeyOf(id);

        // The fundraise's price is tick 138,162. Start well below it, with ETH resting between here and there.
        vm.startPrank(bob);
        POOL_MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(92_000));
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(130_000), TickMath.getSqrtPriceAtTick(136_000), 1 ether
        );
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, int24(130_000), int24(136_000), uint256(liquidity), uint128(1 ether), uint128(0), bob, "");
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, bob);
        POSITION_MANAGER.modifyLiquidities{value: 1 ether}(abi.encode(actions, params), block.timestamp);
        vm.stopPrank();

        uint256 supplyBefore = TOKENS.totalSupplyOf(id);
        vm.warp(deadline + 1);
        lunch.serve(id);

        assertEq(_sqrtPrice(id), RAISE_SQRT_PRICE_X96, "ends at the fundraise's price");
        // The stranger's ETH was bought with fewer tokens than the fundraise would have charged for it, so fewer than
        // 9.75M tokens were needed beside the pool's ETH, and the extra ETH is waiting for the burn.
        assertLt(TOKENS.totalSupplyOf(id) - supplyBefore, 9_750_000e18, "sold tokens dear");
        assertGt(_balance(id), 0.9 ether, "the stranger's ETH is the lunch's now");
        _assertHoldsNothing(id);
    }

    //*********************************************************************//
    // ------------------------------ eating ----------------------------- //
    //*********************************************************************//

    function test_burn_reverts() public {
        uint256 id = _create(0, 0, 0);
        _pay(id, alice, 10 ether);

        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_NotServed.selector, id));
        lunch.burn(id);

        vm.warp(deadline + 1);
        lunch.serve(id);
        uint256 readyAt = _servedAt() + 30 minutes;

        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_TooEarly.selector, id, readyAt));
        lunch.burn(id);
    }

    function test_pay_afterServe_waitsThirtyMinutes() public {
        uint256 id = _served(0, 0, 0);
        uint256 supply = TOKENS.totalSupplyOf(id);

        assertEq(_pay(id, bob, 1 ether), 0, "mints nothing");
        assertEq(TOKENS.totalSupplyOf(id), supply, "nothing bought yet");
        assertApproxEqAbs(_balance(id), 1 ether, 1e9, "the payment waits in the balance");
        _assertHoldsNothing(id);
    }

    function test_pay_buysAndBurnsInTheSameTransaction() public {
        uint256 id = _served(0, 0, 0);
        uint256 supply = TOKENS.totalSupplyOf(id);
        vm.warp(_servedAt() + 30 minutes);

        // A small payment against 9.75 ETH of liquidity fits under the bound.
        vm.expectEmit(true, false, false, false, address(lunch));
        emit IFairLunch.Burn(id, 0, 0, address(0));
        assertEq(_pay(id, bob, 0.01 ether), 0, "mints nothing");

        assertLt(TOKENS.totalSupplyOf(id), supply, "supply fell");
        // 0.01 ETH buys just under 10,000 tokens after the 1% fee and a little slippage.
        assertApproxEqRel(supply - TOKENS.totalSupplyOf(id), 9900e18, 0.01e18);
        assertEq(_balance(id), 0, "all of it was spent");
        assertEq(_token(id).balanceOf(bob), 0, "the payer gets nothing");
        _assertHoldsNothing(id);
    }

    function test_pay_oversized_stopsAtTheBound() public {
        uint256 id = _served(0, 0, 0);
        int24 servedTick = _tick(id);
        vm.warp(_servedAt() + 30 minutes);

        // A hundred times the pool's ETH.
        _pay(id, bob, 975 ether);

        // Buying lowers the tick. It stops 200 ticks past the average, which is the tick the pool opened at.
        assertApproxEqAbs(_tick(id), servedTick - 200, 1, "stopped at the bound");
        assertGt(_balance(id), 960 ether, "the rest waits");
        _assertHoldsNothing(id);

        // Nothing more to buy until the average follows.
        uint256 balance = _balance(id);
        (uint256 spent,) = lunch.burn(id);
        assertEq(spent, 0);
        assertEq(_balance(id), balance);

        // As it follows, later calls spend more.
        vm.warp(_servedAt() + 60 minutes);
        (spent,) = lunch.burn(id);
        assertGt(spent, 0, "spends more as the average follows");
        assertLt(_tick(id), servedTick - 200);
        _assertHoldsNothing(id);
    }

    function test_pay_succeedsWhilePoolManagerIsUnlocked() public {
        uint256 id = _served(0, 0, 0);
        vm.warp(_servedAt() + 30 minutes);
        uint256 supply = TOKENS.totalSupplyOf(id);

        LockedPayer payer = new LockedPayer(POOL_MANAGER, TERMINAL);
        payer.payWhileUnlocked{value: 0.01 ether}(id);

        // The buyback couldn't take the lock, so the payment waits.
        assertEq(TOKENS.totalSupplyOf(id), supply);
        assertApproxEqAbs(_balance(id), 0.01 ether, 1e9);
        _assertHoldsNothing(id);

        // The next call spends it.
        (uint256 spent,) = lunch.burn(id);
        assertApproxEqAbs(spent, 0.01 ether, 1e9);
    }

    /// @notice Whatever the pool's price is when a buyback runs, it never ends past the bound.
    function testFuzz_burn_neverBuysPastTheBound(uint256 firstBuy, uint256 secondBuy) public {
        firstBuy = bound(firstBuy, 0.001 ether, 500 ether);
        secondBuy = bound(secondBuy, 0.001 ether, 500 ether);

        uint256 id = _served(0, 0, 0);
        int24 servedTick = _tick(id);

        vm.warp(_servedAt() + 30 minutes);
        _pay(id, bob, firstBuy);
        assertGe(_tick(id), servedTick - 201, "first buy");

        // Fifteen minutes on, the average is at most halfway to wherever the first buy left the price.
        int24 afterFirst = _tick(id);
        vm.warp(_servedAt() + 45 minutes);
        _pay(id, bob, secondBuy);
        assertGe(_tick(id), (servedTick + afterFirst) / 2 - 202, "second buy");
        _assertHoldsNothing(id);
    }

    function test_burn_anyoneCanCall() public {
        uint256 id = _served(0, 0, 0);
        _pay(id, bob, 0.01 ether);
        vm.warp(_servedAt() + 30 minutes);

        uint256 supply = TOKENS.totalSupplyOf(id);
        vm.prank(address(0xDEAD0001));
        (uint256 spent, uint256 burned) = lunch.burn(id);

        assertApproxEqAbs(spent, 0.01 ether, 1e9);
        assertEq(supply - TOKENS.totalSupplyOf(id), burned);
        _assertHoldsNothing(id);
    }

    function test_afterPay_onlyTerminal() public {
        uint256 id = _served(0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_Unauthorized.selector, address(this)));
        lunch.afterPayRecordedWith(_emptyContext(id));
    }

    function test_collect_burnsTokensAndPaysJbp6() public {
        uint256 id = _served(0, 0, 0);
        vm.warp(_servedAt() + 30 minutes);

        // Trade both ways through the pool to earn fees on both sides: buybacks pay ETH fees.
        _pay(id, bob, 0.05 ether);

        uint256 jbp6Before = TOKENS.totalBalanceOf(creator, 1);
        uint256 supply = TOKENS.totalSupplyOf(id);
        (uint256 tokensBurned, uint256 ethPaid) = lunch.collect(id);

        // 1% of 0.05 ETH, to the wei of rounding.
        assertApproxEqAbs(ethPaid, 0.0005 ether, 1e9, "ETH fees");
        assertGt(TOKENS.totalBalanceOf(creator, 1), jbp6Before, "creator earned JBP6");
        assertEq(supply - TOKENS.totalSupplyOf(id), tokensBurned);
        _assertHoldsNothing(id);

        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_NotServed.selector, 1));
        lunch.collect(1);
    }

    function test_sendHome_revertsOnHost() public {
        uint256 id = _create(0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_NotRemote.selector, id));
        lunch.sendHome(id);
    }

    function test_setChainSpecificConstants_onlyDeployerOnce() public {
        assertEq(address(lunch.POOL_MANAGER()), address(POOL_MANAGER), "pool manager read from the position manager");

        vm.expectRevert(FairLunch.FairLunch_AlreadyConfigured.selector);
        lunch.setChainSpecificConstants({positionManager: POSITION_MANAGER, oracleHook: ORACLE});

        FairLunch fresh =
            new FairLunch({omnichainDeployer: OMNI, terminal: TERMINAL, suckerRegistry: REGISTRY, permit2: PERMIT2, deployer: bob});
        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_Unauthorized.selector, address(this)));
        fresh.setChainSpecificConstants({positionManager: POSITION_MANAGER, oracleHook: ORACLE});

        // No lunches until this chain is configured.
        FairLunchConfig memory config = _config(creator, 0, 0, 0);
        uint256 fee = PROJECTS.creationFee();
        vm.expectRevert(FairLunch.FairLunch_NotConfigured.selector);
        fresh.createFor{value: fee}(config);
    }

    function test_createFor_creditsTheCreationFeeToThePayer() public {
        uint256 before = TOKENS.totalBalanceOf(address(lunch), 1);
        _create(0, 0, 0);
        assertEq(TOKENS.totalBalanceOf(address(lunch), 1), before, "no JBP6 stranded on the lunch contract");
        assertEq(lunch.originalPayer(), address(0), "cleared");
    }

    function test_onlyLunchNftsAccepted() public {
        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_Unauthorized.selector, address(this)));
        lunch.onERC721Received(address(0), address(0), 0, "");
    }

    function _emptyContext(uint256 id)
        internal
        pure
        returns (JBAfterPayRecordedContext memory context)
    {
        context.projectId = id;
    }
}

import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";

interface IERC721Like {
    function ownerOf(uint256 tokenId) external view returns (address);
}
