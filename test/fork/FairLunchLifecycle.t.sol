// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBBuybackHook} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHook.sol";
import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {IJBOmnichainDeployer} from "@bananapus/omnichain-deployers-v6/src/interfaces/IJBOmnichainDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IGeomeanOracle} from "@bananapus/univ4-router-v6/src/interfaces/IGeomeanOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Test} from "forge-std/Test.sol";

import {FairLunchPool} from "../../src/FairLunchPool.sol";
import {FairLunch} from "../../src/FairLunch.sol";
import {FairLunchClaims} from "../../src/FairLunchClaims.sol";
import {FairLunchDataHook} from "../../src/FairLunchDataHook.sol";
import {IFairLunch} from "../../src/interfaces/IFairLunch.sol";
import {PoolProbe} from "../PoolProbe.sol";
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

/// @notice A creator that spends what it's paid on another lunch.
contract ForwardingCreator {
    IJBMultiTerminal internal immutable TERMINAL;
    uint256 public payInto;

    constructor(IJBMultiTerminal terminal) {
        TERMINAL = terminal;
    }

    function setPayInto(uint256 projectId) external {
        payInto = projectId;
    }

    receive() external payable {
        TERMINAL.pay{value: msg.value}(payInto, JBConstants.NATIVE_TOKEN, msg.value, address(this), 0, "", "");
    }
}

/// @notice The whole life of a lunch on its host chain, against live V6 and Uniswap V4 on Base.
contract FairLunchLifecycle is Test {
    using stdStorage for StdStorage;

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

    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    uint256 internal constant RAISE_SQRT_PRICE_X96 = 1000 << 96;
    // Where a trade costs the fundraise's price once the pool's 1% fee is counted: 1% more tokens per ETH, and 1%
    // fewer.
    uint160 internal constant CHEAPEST_SQRT_PRICE_X96 = 79_627_299_360_338_032_629_969_613_668_148;
    uint160 internal constant DEAREST_SQRT_PRICE_X96 = 78_831_026_366_734_652_303_669_917_531_468;
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
            buybackRegistry: BUYBACK,
            terminal: TERMINAL,
            routerTerminalRegistry: ROUTER_REGISTRY,
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
        config.token = JBConstants.NATIVE_TOKEN;
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

    /// @notice What a payment tells the buyback hook: the fewest tokens it will take.
    function _payMetadata(uint256 minimum) internal pure returns (bytes memory) {
        return _metadata("pay", abi.encode(uint256(0), minimum, true));
    }

    /// @notice What a cash out tells the buyback hook: the least ETH it will take.
    function _sellMetadata(uint256 minimum) internal pure returns (bytes memory) {
        return _metadata("cashOut", abi.encode(minimum, false));
    }

    function _metadata(string memory purpose, bytes memory data) internal pure returns (bytes memory) {
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = JBMetadataResolver.getId(purpose, address(BUYBACK));
        bytes[] memory datas = new bytes[](1);
        datas[0] = data;
        return JBMetadataResolver.createMetadata(ids, datas);
    }

    /// @notice Pay a lunch with metadata. Returns the tokens the payer ended up with.
    function _buy(uint256 id, address from, uint256 amount, bytes memory metadata) internal returns (uint256) {
        uint256 before = _token(id).balanceOf(from);
        vm.prank(from);
        TERMINAL.pay{value: amount}(id, JBConstants.NATIVE_TOKEN, amount, from, 0, "", metadata);
        return _token(id).balanceOf(from) - before;
    }

    /// @notice Cash a lunch's tokens out. Returns the ETH the holder ended up with.
    function _sell(uint256 id, address from, uint256 count, bytes memory metadata) internal returns (uint256) {
        uint256 before = from.balance;
        vm.prank(from);
        TERMINAL.cashOutTokensOf(from, id, count, JBConstants.NATIVE_TOKEN, 0, payable(from), metadata);
        return from.balance - before;
    }

    /// @notice A first trade in a served lunch's pool, a minute after serving. The buyback hook prices from the pool's
    /// history, and there's none to read until something has traded.
    function _trade(uint256 id) internal {
        vm.warp(_servedAt() + 1 minutes);
        _buy(id, bob, 0.0001 ether, _payMetadata(1));
    }

    function _assertHoldsNothing(uint256 id) internal view {
        assertEq(address(lunch).balance, 0, "lunch holds ETH");
        assertEq(address(lunch.POOL()).balance, 0, "pool contract holds ETH");
        assertEq(TOKENS.totalBalanceOf(address(lunch.POOL()), id), 0, "pool contract holds tokens");
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
        assertEq(lunch.servedAtOf(id), 0);
        assertEq(record.creator, creator);
        assertEq(record.keepPercent, FIFTH);
        assertEq(record.keepCap, 5 ether);
        assertEq(record.tokenPercent, TENTH);
        assertEq(record.vestingDuration, 52 weeks);
        assertEq(PROJECTS.ownerOf(id), address(lunch));
    }

    function test_createFor_revertsOnBadConfig() public {
        uint256 fee = PROJECTS.creationFee();

        // The whole raise, which would leave nothing to open the pool with.
        FairLunchConfig memory config = _config(creator, 10 * TENTH, 0, 0);
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);

        config = _config(creator, 0, 0, 10 * TENTH);
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);

        config = _config(address(0), 0, 0, 0);
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);

        config = _config(creator, 0, 0, 0);
        config.deadline = uint48(block.timestamp + 1);
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);

        // A fundraise longer than a ruleset can last.
        config = _config(creator, 0, 0, 0);
        config.deadline = uint48(block.timestamp + uint256(type(uint32).max) + 1);
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
        vm.warp(deadline - 1);
        assertEq(_pay(id, bob, 0.5 ether), 500_000e18);
    }

    /// @notice USDC paid through the router terminal is swapped into ETH and counts like ETH.
    function test_pay_inUsdcThroughTheRouter() public {
        uint256 id = _create(0, 0, 0);
        deal(address(USDC), bob, 3000e6);
        vm.prank(bob);
        USDC.approve(address(ROUTER_REGISTRY), 3000e6);

        vm.prank(bob);
        ROUTER_REGISTRY.pay(id, address(USDC), 3000e6, bob, 0, "", "");

        uint256 raised = _balance(id);
        assertGt(raised, 0.1 ether, "3000 USDC's worth of ETH");
        assertEq(_token(id).balanceOf(bob), raised * 1_000_000, "a million per ETH it became");
        assertEq(USDC.balanceOf(address(lunch)), 0, "lunch holds USDC");
        _assertHoldsNothing(id);
    }

    /// @notice Once served, routed revenue with no minimum waits for `burn` like any other.
    function test_pay_inUsdcThroughTheRouter_afterServe() public {
        uint256 id = _served(0, 0, 0);
        uint256 waiting = _balance(id);
        deal(address(USDC), bob, 3000e6);
        vm.prank(bob);
        USDC.approve(address(ROUTER_REGISTRY), 3000e6);

        vm.prank(bob);
        ROUTER_REGISTRY.pay(id, address(USDC), 3000e6, bob, 0, "", "");

        assertGt(_balance(id), waiting + 0.1 ether, "waits as ETH");
        assertEq(_token(id).balanceOf(bob), 0, "nothing minted");
        _assertHoldsNothing(id);
    }

    /// @notice The router terminal comes second, so ETH itself always goes straight to the terminal.
    function test_createFor_routesOtherTokens() public {
        uint256 id = _create(0, 0, 0);
        IJBTerminal[] memory terminals = lunch.DIRECTORY().terminalsOf(id);
        assertEq(terminals.length, 2);
        assertEq(address(terminals[1]), address(ROUTER_REGISTRY));
        assertEq(address(lunch.DIRECTORY().primaryTerminalOf(id, JBConstants.NATIVE_TOKEN)), address(TERMINAL));
    }

    /// @notice A lunch can't raise JBP6: the lunch passes on all the JBP6 it holds as fee proceeds.
    function test_createFor_revertsRaisingJbp6OrNothing() public {
        uint256 fee = PROJECTS.creationFee();
        FairLunchConfig memory config = _config(creator, 0, 0, 0);
        config.token = address(TOKENS.tokenOf(1));
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);

        config.token = address(0);
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);

        // More than 24 decimals.
        config.token = address(USDC);
        vm.mockCall(address(USDC), abi.encodeWithSignature("decimals()"), abi.encode(uint8(25)));
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);
    }

    //*********************************************************************//
    // ------------------------------ claims ----------------------------- //
    //*********************************************************************//

    function _leaf(address account, uint256 shares) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, shares))));
    }

    /// @notice A two-entry list: `first` and `second`, with their shares.
    function _root(
        address first,
        uint256 firstShares,
        address second,
        uint256 secondShares
    )
        internal
        pure
        returns (bytes32)
    {
        (bytes32 a, bytes32 b) = (_leaf(first, firstShares), _leaf(second, secondShares));
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @notice The tokens `CLAIMS` holds for a lunch's list, which shares it with the creator's.
    function _heldForList(uint256 id) internal view returns (uint256) {
        FairLunchClaims claims = lunch.CLAIMS();
        return _token(id).balanceOf(address(claims)) - (claims.creatorTokenCountOf(id) - claims.creatorClaimedOf(id));
    }

    function _proof(address other, uint256 otherShares) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = _leaf(other, otherShares);
    }

    /// @notice A lunch that gives `claimsPercent` of its supply to alice (75%) and bob (25%), served.
    function _servedWithClaims(uint32 tokenPercent, uint32 claimsPercent) internal returns (uint256 id) {
        FairLunchConfig memory config = _config(creator, 0, 0, tokenPercent);
        config.claimsPercent = claimsPercent;
        config.claimsRoot = _root(alice, 0.75e18, bob, 0.25e18);
        id = lunch.createFor{value: PROJECTS.creationFee()}(config);
        _pay(id, address(0xFEED), 10 ether);
        vm.warp(deadline + 1);
        lunch.serve(id);
    }

    function test_claims_getTheirShareOfSupply() public {
        vm.deal(address(0xFEED), 10 ether);
        uint256 id = _servedWithClaims(TENTH, 6 * TENTH);
        FairLunchClaims claims = lunch.CLAIMS();
        uint256 supply = TOKENS.totalSupplyOf(id);

        assertApproxEqRel(claims.tokenCountOf(id), supply * 6 / 10, 1e9, "60% for the list");
        assertEq(_heldForList(id), claims.tokenCountOf(id), "held for the list");
        assertApproxEqRel(claims.creatorTokenCountOf(id), supply / 10, 1e9, "10% vesting");

        // Anyone sends alice hers.
        vm.prank(bob);
        uint256 sent = claims.claim(id, alice, 0.75e18, _proof(bob, 0.25e18));
        assertEq(sent, claims.tokenCountOf(id) * 3 / 4);
        assertEq(_token(id).balanceOf(alice), sent);

        claims.claim(id, bob, 0.25e18, _proof(alice, 0.75e18));
        assertLe(_heldForList(id), 1, "all handed out");
    }

    function test_claims_onlyOnceAndOnlyAsListed() public {
        vm.deal(address(0xFEED), 10 ether);
        uint256 id = _servedWithClaims(0, 8 * TENTH);
        FairLunchClaims claims = lunch.CLAIMS();
        assertEq(claims.creatorTokenCountOf(id), 0, "no chef tokens");

        // More than listed, or someone unlisted.
        vm.expectRevert(
            abi.encodeWithSelector(FairLunchClaims.FairLunchClaims_NotListed.selector, id, alice, uint256(1e18))
        );
        claims.claim(id, alice, 1e18, _proof(bob, 0.25e18));
        vm.expectRevert(
            abi.encodeWithSelector(FairLunchClaims.FairLunchClaims_NotListed.selector, id, creator, uint256(0.75e18))
        );
        claims.claim(id, creator, 0.75e18, _proof(bob, 0.25e18));

        claims.claim(id, alice, 0.75e18, _proof(bob, 0.25e18));
        vm.expectRevert(abi.encodeWithSelector(FairLunchClaims.FairLunchClaims_NothingToClaim.selector, id, alice));
        claims.claim(id, alice, 0.75e18, _proof(bob, 0.25e18));
    }

    /// @notice A list's tokens vest from the serve, and each claim sends what has vested since the last.
    function test_claims_vest() public {
        vm.deal(address(0xFEED), 10 ether);
        FairLunchConfig memory config = _config(creator, 0, 0, 0);
        config.claimsPercent = 6 * TENTH;
        config.claimsRoot = _root(alice, 0.75e18, bob, 0.25e18);
        config.claimsVestingDuration = 52 weeks;
        uint256 id = lunch.createFor{value: PROJECTS.creationFee()}(config);
        _pay(id, address(0xFEED), 10 ether);
        vm.warp(deadline);
        lunch.serve(id);
        FairLunchClaims claims = lunch.CLAIMS();
        uint256 whole = claims.tokenCountOf(id) * 3 / 4;

        // Nothing has vested in the block it's served in.
        vm.expectRevert(abi.encodeWithSelector(FairLunchClaims.FairLunchClaims_NothingToClaim.selector, id, alice));
        claims.claim(id, alice, 0.75e18, _proof(bob, 0.25e18));

        vm.warp(uint256(deadline) + 13 weeks);
        assertEq(claims.claim(id, alice, 0.75e18, _proof(bob, 0.25e18)), whole / 4, "a quarter after a quarter");
        vm.expectRevert(abi.encodeWithSelector(FairLunchClaims.FairLunchClaims_NothingToClaim.selector, id, alice));
        claims.claim(id, alice, 0.75e18, _proof(bob, 0.25e18));

        vm.warp(uint256(deadline) + 80 weeks);
        claims.claim(id, alice, 0.75e18, _proof(bob, 0.25e18));
        assertEq(_token(id).balanceOf(alice), whole, "all of it once it's over");
    }

    /// @notice A list whose shares add up to far more than the whole can't take tokens out ahead of the schedule.
    function test_claims_vest_asAWholeWhateverTheSharesAddUpTo() public {
        vm.deal(address(0xFEED), 10 ether);
        FairLunchConfig memory config = _config(creator, 0, 0, 0);
        config.claimsPercent = 6 * TENTH;
        // Alice's entry alone is worth the whole list a second into a year of vesting.
        config.claimsRoot = _root(alice, 52 weeks * 1e18, bob, 0.25e18);
        config.claimsVestingDuration = 52 weeks;
        uint256 id = lunch.createFor{value: PROJECTS.creationFee()}(config);
        _pay(id, address(0xFEED), 10 ether);
        vm.warp(deadline);
        lunch.serve(id);
        FairLunchClaims claims = lunch.CLAIMS();
        uint256 all = claims.tokenCountOf(id);

        vm.warp(uint256(deadline) + 13 weeks);
        assertEq(claims.claim(id, alice, 52 weeks * 1e18, _proof(bob, 0.25e18)), all / 4, "a quarter of the list");
        assertEq(claims.totalClaimedOf(id), all / 4, "counted");

        // Alice got there first, so bob waits for more to vest.
        vm.expectRevert(abi.encodeWithSelector(FairLunchClaims.FairLunchClaims_NothingToClaim.selector, id, bob));
        claims.claim(id, bob, 0.25e18, _proof(alice, 52 weeks * 1e18));

        vm.warp(uint256(deadline) + 52 weeks);
        claims.claim(id, alice, 52 weeks * 1e18, _proof(bob, 0.25e18));
        assertEq(_token(id).balanceOf(address(claims)), 0, "and no more than there is");
    }

    function test_claims_waitForServe() public {
        FairLunchConfig memory config = _config(creator, 0, 0, 0);
        config.claimsPercent = 5 * TENTH;
        config.claimsRoot = _root(alice, 0.75e18, bob, 0.25e18);
        uint256 id = lunch.createFor{value: PROJECTS.creationFee()}(config);
        FairLunchClaims claims = lunch.CLAIMS();
        assertEq(claims.percentOf(id), 5 * TENTH);

        vm.expectRevert(abi.encodeWithSelector(FairLunchClaims.FairLunchClaims_NotServed.selector, id));
        claims.claim(id, alice, 0.75e18, _proof(bob, 0.25e18));
    }

    function test_claims_onlyFairLunchSetsAndFunds() public {
        FairLunchClaims claims = lunch.CLAIMS();
        vm.expectRevert(abi.encodeWithSelector(FairLunchClaims.FairLunchClaims_Unauthorized.selector, address(this)));
        claims.setTermsOf(1, TENTH, bytes32(uint256(1)), 0);
        vm.expectRevert(abi.encodeWithSelector(FairLunchClaims.FairLunchClaims_Unauthorized.selector, address(this)));
        claims.fund(1, IERC20(address(1)), 1, address(1), 1, 0);
    }

    function test_createFor_revertsOnBadClaims() public {
        uint256 fee = PROJECTS.creationFee();

        // The chef and the list can't get more than 99% of the supply together.
        FairLunchConfig memory config = _config(creator, 0, 0, 6 * TENTH);
        config.claimsPercent = 390_000_001;
        config.claimsRoot = bytes32(uint256(1));
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);

        // Vesting with nothing to vest.
        config = _config(creator, 0, 0, 0);
        config.claimsVestingDuration = 1;
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);

        // A share with no list, and a list with no share.
        config = _config(creator, 0, 0, 0);
        config.claimsPercent = TENTH;
        config.claimsRoot = bytes32(0);
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);
        config.claimsPercent = 0;
        config.claimsRoot = bytes32(uint256(1));
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);
    }

    /// @notice Whatever the shares, the chef and the list get their percents of the supply and the list is never short.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_claims_anySplit(uint32 tokenPercent, uint32 claimsPercent, uint256 aliceShares) public {
        tokenPercent = uint32(bound(tokenPercent, 0, 9 * TENTH));
        claimsPercent = uint32(bound(claimsPercent, 1, 990_000_000 - tokenPercent));
        // A share too small to be worth a token has nothing to claim.
        aliceShares = bound(aliceShares, 1e9, 1e18 - 1e9);

        FairLunchConfig memory config = _config(creator, 0, 0, tokenPercent);
        config.claimsPercent = claimsPercent;
        config.claimsRoot = _root(alice, aliceShares, bob, 1e18 - aliceShares);
        uint256 id = lunch.createFor{value: PROJECTS.creationFee()}(config);
        _pay(id, alice, 1 ether);
        vm.warp(deadline + 1);
        lunch.serve(id);

        FairLunchClaims claims = lunch.CLAIMS();
        uint256 supply = TOKENS.totalSupplyOf(id);
        assertApproxEqRel(claims.tokenCountOf(id), supply * claimsPercent / 1e9, 1e12, "the list's percent");
        claims.claim(id, alice, aliceShares, _proof(bob, 1e18 - aliceShares));
        claims.claim(id, bob, 1e18 - aliceShares, _proof(alice, aliceShares));
        assertLe(_heldForList(id), 1, "all handed out");
    }

    function test_pay_revertsAfterDeadline() public {
        uint256 id = _create(FIFTH, 5 ether, TENTH);
        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert();
        TERMINAL.pay{value: 1 ether}(id, JBConstants.NATIVE_TOKEN, 1 ether, alice, 0, "", "");
    }

    function test_cashOut_sellsIntoThePoolOnceServed() public {
        uint256 id = _served(0, 0, 0);
        uint256 supply = TOKENS.totalSupplyOf(id);
        uint256 balance = _balance(id);

        // 10,000 tokens sell for just under 0.01 ETH after the 1% fee.
        assertApproxEqRel(_sell(id, alice, 10_000e18, _sellMetadata(0.0098 ether)), 0.0099 ether, 0.01e18, "sold");
        assertEq(TOKENS.totalSupplyOf(id), supply, "the pool holds them now");
        assertEq(_balance(id), balance, "the balance isn't touched");

        // A minimum the pool can't pay stops the sale.
        vm.expectRevert();
        vm.prank(alice);
        TERMINAL.cashOutTokensOf(
            alice, id, 10_000e18, JBConstants.NATIVE_TOKEN, 0, payable(alice), _sellMetadata(0.011 ether)
        );
        _assertHoldsNothing(id);
    }

    /// @notice A sale has to name the least it will take, however much price history the pool has. Left to the
    /// terminal it would burn the tokens for nothing, and the buyback hook's own price check is too loose to sell by.
    function test_cashOut_withoutAMinimumReverts() public {
        uint256 id = _served(0, 0, 0);
        _pay(id, bob, 1 ether);
        _trade(id);
        uint256 waiting = _balance(id);
        uint256 held = _token(id).balanceOf(alice);

        for (uint256 i; i < 2; i++) {
            vm.expectRevert(abi.encodeWithSelector(FairLunchDataHook.FairLunchDataHook_NoSale.selector, id));
            vm.prank(alice);
            TERMINAL.cashOutTokensOf(alice, id, 10_000e18, JBConstants.NATIVE_TOKEN, 0, payable(alice), "");
            vm.warp(_servedAt() + 60 minutes);
        }
        assertEq(_token(id).balanceOf(alice), held, "kept their tokens");
        assertEq(_balance(id), waiting, "and what waits is nobody's to cash out");
    }

    /// @notice Until the deadline a payer can take back what they paid, and no more than that.
    function test_refund_duringTheRaise() public {
        uint256 id = _create(0, 0, 0);
        _pay(id, alice, 2 ether);
        _pay(id, bob, 1 ether);

        // Money that reached the balance another way isn't a payer's to take.
        TERMINAL.addToBalanceOf{value: 5 ether}(id, JBConstants.NATIVE_TOKEN, 5 ether, false, "", "");

        vm.warp(deadline - 1);
        // Leaving that money out rounds down, by a wei at most.
        assertApproxEqAbs(_sell(id, alice, 500_000e18, ""), 0.5 ether, 1, "half a unit back");
        assertEq(_token(id).balanceOf(alice), 1_500_000e18, "tokens burned");
        assertApproxEqAbs(_sell(id, bob, 1_000_000e18, ""), 1 ether, 1, "all of it back");
        assertApproxEqAbs(_balance(id), 6.5 ether, 2, "the rest stays");

        // At the deadline the raise is settled.
        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(FairLunchDataHook.FairLunchDataHook_Closed.selector, id));
        vm.prank(alice);
        TERMINAL.cashOutTokensOf(alice, id, 500_000e18, JBConstants.NATIVE_TOKEN, 0, payable(alice), "");

        // What's left of the raise is served as usual.
        lunch.serve(id);
        assertEq(_token(id).balanceOf(alice), 1_500_000e18, "kept the rest");
    }

    /// @notice A chef can keep nearly all of the raise. What's left still opens the pool.
    function test_serve_withNearlyAllOfTheRaiseKept() public {
        uint256 id = _create(10 * TENTH - 1, type(uint104).max, TENTH);
        _pay(id, alice, 2 ether);
        vm.warp(deadline);
        uint256 before = creator.balance;
        lunch.serve(id);
        assertApproxEqAbs(creator.balance - before, 1.95 ether, 1e10, "the raise less the Juicebox fee");
        assertGt(lunch.servedAtOf(id), 0, "served");
    }

    function test_unlockCallback_onlyPoolManager() public {
        FairLunchPool pool = lunch.POOL();
        vm.expectRevert(abi.encodeWithSelector(FairLunchPool.FairLunchPool_Unauthorized.selector, address(this)));
        pool.unlockCallback("");
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
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_TooEarly.selector, id, uint256(deadline)));
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
        assertEq(lunch.servedAtOf(id), _servedAt());
        assertEq(
            IERC721Like(address(POSITION_MANAGER)).ownerOf(lunch.recordOf(id).positionId),
            address(lunch.POOL()),
            "the lunch's pool contract holds the position"
        );
        _assertHoldsNothing(id);
    }

    function test_serve_creatorTokensVest() public {
        uint256 id = _served(0, 0, TENTH);
        FairLunchClaims claims = lunch.CLAIMS();
        IERC20 token = _token(id);

        // A tenth of the total supply, held for the creator from the serve on.
        uint256 total = claims.creatorTokenCountOf(id);
        assertApproxEqAbs(total * 10, token.totalSupply(), 1e6, "10% of supply");
        assertEq(token.balanceOf(address(claims)), total, "held");
        assertEq(claims.creatorOf(id), creator);
        assertEq(claims.creatorVestingDurationOf(id), 52 weeks);

        // Nothing has vested in the block it's served in.
        vm.expectRevert(abi.encodeWithSelector(FairLunchClaims.FairLunchClaims_NothingToClaim.selector, id, creator));
        claims.release(id);

        // Anyone sends the creator what has vested.
        vm.warp(_servedAt() + 13 weeks);
        vm.prank(bob);
        assertEq(claims.release(id), total / 4, "a quarter after a quarter");
        assertEq(token.balanceOf(creator), total / 4, "to the creator");
        vm.expectRevert(abi.encodeWithSelector(FairLunchClaims.FairLunchClaims_NothingToClaim.selector, id, creator));
        claims.release(id);

        vm.warp(_servedAt() + 65 weeks);
        claims.release(id);
        assertEq(token.balanceOf(creator), total, "all of it at the end");
        assertEq(token.balanceOf(address(claims)), 0, "none left");
    }

    /// @notice A creator who set no vesting gets every token as soon as the lunch is served.
    function test_serve_creatorTokensRightAway() public {
        FairLunchConfig memory config = _config(creator, 0, 0, TENTH);
        config.vestingDuration = 0;
        uint256 id = lunch.createFor{value: PROJECTS.creationFee()}(config);
        _pay(id, alice, 1 ether);
        vm.warp(deadline);
        lunch.serve(id);

        FairLunchClaims claims = lunch.CLAIMS();
        assertEq(claims.release(id), claims.creatorTokenCountOf(id));
        assertApproxEqAbs(_token(id).balanceOf(creator) * 10, TOKENS.totalSupplyOf(id), 1e6, "10% of supply");
    }

    /// @notice The creator's tokens and the list's are held together and never pay for each other.
    function test_release_andClaimsKeepToTheirOwn() public {
        vm.deal(address(0xFEED), 10 ether);
        uint256 id = _servedWithClaims(TENTH, 6 * TENTH);
        FairLunchClaims claims = lunch.CLAIMS();
        uint256 creatorTokens = claims.creatorTokenCountOf(id);

        claims.claim(id, alice, 0.75e18, _proof(bob, 0.25e18));
        claims.claim(id, bob, 0.25e18, _proof(alice, 0.75e18));
        assertApproxEqAbs(_token(id).balanceOf(address(claims)), creatorTokens, 1, "the creator's are untouched");

        vm.warp(_servedAt() + 52 weeks);
        assertEq(claims.release(id), creatorTokens);
        vm.expectRevert(abi.encodeWithSelector(FairLunchClaims.FairLunchClaims_NothingToClaim.selector, id, creator));
        claims.release(id);
    }

    function test_serve_noCreatorShares() public {
        uint256 id = _served(0, 0, 0);
        assertEq(creator.balance, 0);
        assertEq(lunch.CLAIMS().creatorTokenCountOf(id), 0);
        // The whole raise less the fee is in the pool.
        assertEq(_sqrtPrice(id), RAISE_SQRT_PRICE_X96);
        _assertHoldsNothing(id);
    }

    function test_serve_creatorRejectsEth() public {
        Picky picky = new Picky();
        uint256 id = lunch.createFor{value: PROJECTS.creationFee()}(_config(address(picky), FIFTH, 5 ether, 0));
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
        _serveOverHostilePool(138_162 + 46_000, CHEAPEST_SQRT_PRICE_X96);
    }

    function test_serve_hostilePoolTooLow() public {
        _serveOverHostilePool(138_162 - 46_000, DEAREST_SQRT_PRICE_X96);
    }

    /// @notice A stranger creates the pool at a price about 100x off before the lunch is served. Serving moves it back
    /// for free, to the edge of the 1% beside the fundraise's price that it won't trade inside.
    function _serveOverHostilePool(int24 hostileTick, uint160 servedSqrtPriceX96) internal {
        uint256 id = _create(FIFTH, 5 ether, TENTH);
        _pay(id, alice, 10 ether);

        vm.prank(bob);
        POOL_MANAGER.initialize(lunch.poolKeyOf(id), TickMath.getSqrtPriceAtTick(hostileTick));

        vm.warp(deadline + 1);
        lunch.serve(id);

        assertEq(_sqrtPrice(id), servedSqrtPriceX96, "moved back beside the fundraise's price");
        assertLt(_balance(id), 0.1 ether, "all but the 1% the off price didn't take was pooled");
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
        params[0] =
            abi.encode(key, int24(130_000), int24(136_000), uint256(liquidity), uint128(1 ether), uint128(0), bob, "");
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, bob);
        POSITION_MANAGER.modifyLiquidities{value: 1 ether}(abi.encode(actions, params), block.timestamp);
        vm.stopPrank();

        uint256 supplyBefore = TOKENS.totalSupplyOf(id);
        vm.warp(deadline + 1);
        lunch.serve(id);

        assertEq(_sqrtPrice(id), DEAREST_SQRT_PRICE_X96, "ends beside the fundraise's price");
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

    /// @notice A payment that doesn't name a minimum never buys, however much price history the pool has. It waits for
    /// a burn.
    function test_pay_afterServe_withoutAMinimumWaitsForABurn() public {
        uint256 id = _served(0, 0, 0);
        uint256 supply = TOKENS.totalSupplyOf(id);

        assertEq(_buy(id, bob, 1 ether, ""), 0, "buys nothing");
        _trade(id);
        vm.warp(_servedAt() + 60 minutes);
        assertEq(_buy(id, bob, 1 ether, ""), 0, "nor with history");

        assertEq(TOKENS.totalSupplyOf(id), supply, "mints nothing");
        assertApproxEqAbs(_balance(id), 2 ether, 1e9, "the payments wait in the balance");
        _assertHoldsNothing(id);
    }

    function test_pay_afterServe_withAMinimumBuysRightAway() public {
        uint256 id = _served(0, 0, 0);
        uint256 supply = TOKENS.totalSupplyOf(id);
        uint256 balance = _balance(id);

        // 0.01 ETH buys just under 10,000 tokens after the 1% fee and a little slippage.
        assertApproxEqRel(_buy(id, bob, 0.01 ether, _payMetadata(9800e18)), 9900e18, 0.01e18, "bought");
        assertEq(TOKENS.totalSupplyOf(id), supply, "from the pool, not minted");
        assertEq(_balance(id), balance, "nothing waits");

        // A minimum the pool can't meet stops the payment.
        vm.expectRevert();
        vm.prank(bob);
        TERMINAL.pay{value: 0.01 ether}(id, JBConstants.NATIVE_TOKEN, 0.01 ether, bob, 0, "", _payMetadata(10_000e18));
    }

    function test_serve_registersThePoolWithTheBuybackHook() public {
        uint256 id = _served(0, 0, 0);
        IJBBuybackHook hook = IJBBuybackHook(address(BUYBACK.hookOf(id)));

        assertEq(
            PoolId.unwrap(hook.poolKeyOf(id, address(0)).toId()),
            PoolId.unwrap(lunch.poolKeyOf(id).toId()),
            "the lunch's pool"
        );
        assertEq(hook.twapWindowOf(id, address(0)), 30 minutes);

        // The hook, and nobody else, mints through the data hook.
        IJBController controller = lunch.CONTROLLER();
        (JBRuleset memory ruleset,) = controller.currentRulesetOf(id);
        assertTrue(lunch.DATA_HOOK().hasMintPermissionFor(id, ruleset, address(hook)));
        assertFalse(lunch.DATA_HOOK().hasMintPermissionFor(id, ruleset, creator));
        vm.expectRevert();
        vm.prank(creator);
        controller.mintTokensOf(id, 1e18, creator, "", false);
    }

    /// @notice A lunch whose buyback hook couldn't take its pool could never be served, so it's never made.
    function test_createFor_needsABuybackHookOnThePoolsOracle() public {
        vm.mockCall(address(BUYBACK.defaultHook()), abi.encodeWithSignature("oracleHook()"), abi.encode(address(0xBAD)));
        FairLunchConfig memory config = _config(creator, 0, 0, 0);
        uint256 fee = PROJECTS.creationFee();
        vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
        lunch.createFor{value: fee}(config);
    }

    /// @notice A payment that names its minimum and is sent with too little gas for its buy fails, so wallets estimate
    /// enough for it.
    function test_pay_withAMinimumRevertsRatherThanStarveTheBuy() public {
        uint256 id = _served(0, 0, 0);
        bytes memory metadata = _payMetadata(9800e18);

        // What a whole payment and buy use.
        uint256 snapshot = vm.snapshotState();
        uint256 gasBefore = gasleft();
        _buy(id, bob, 0.01 ether, metadata);
        uint256 used = gasBefore - gasleft();
        vm.revertToState(snapshot);

        vm.prank(bob);
        (bool ok,) = address(TERMINAL).call{value: 0.01 ether, gas: used * 6 / 10}(
            abi.encodeCall(TERMINAL.pay, (id, JBConstants.NATIVE_TOKEN, 0.01 ether, bob, 0, "", metadata))
        );
        assertFalse(ok, "starved payment reverts");
    }

    function test_pay_fromInsideAnotherLunchsCallWaits() public {
        ForwardingCreator forwarder = new ForwardingCreator(TERMINAL);
        uint256 a = _create(0, 0, 0);
        uint256 b = lunch.createFor{value: PROJECTS.creationFee()}(_config(address(forwarder), 200_000_000, 5 ether, 0));
        forwarder.setPayInto(a);
        _pay(a, alice, 10 ether);
        _pay(b, alice, 10 ether);
        vm.warp(_servedAt());
        lunch.serve(a);
        vm.warp(_servedAt() + 30 minutes);

        // Serving B pays its creator, who pays A while this contract is mid-call. The payment lands and waits.
        lunch.serve(b);

        assertEq(address(forwarder).balance, 0, "the creator's payment went through");
        assertGt(_balance(a), 1 ether, "it waits in A's balance");
        (uint256 spent,) = lunch.burn(a);
        assertGt(spent, 0, "the next burn uses it");
    }

    function test_burn_goesThroughWhileJbp6CreditTransfersArePaused() public {
        uint256 id = _served(0, 0, 0);
        _pay(id, bob, 0.01 ether);
        vm.warp(_servedAt() + 30 minutes);

        // Someone parks JBP6 credits on the contract, then JBP6 pauses credit transfers.
        uint256 credits = 5e18;
        stdstore.target(address(TOKENS)).sig("creditBalanceOf(address,uint256)").with_key(address(lunch))
            .with_key(uint256(1)).checked_write(credits);
        stdstore.target(address(TOKENS)).sig("totalCreditSupplyOf(uint256)").with_key(uint256(1))
            .checked_write(TOKENS.totalCreditSupplyOf(1) + credits);
        vm.mockCallRevert(
            address(lunch.DIRECTORY().controllerOf(1)),
            abi.encodeWithSignature("transferCreditsFrom(address,uint256,address,uint256)"),
            "paused"
        );

        IERC20 jbp6 = _token(1);
        uint256 before = jbp6.balanceOf(creator);
        lunch.burn(id);

        assertGe(jbp6.balanceOf(creator) - before, credits, "the credits reached the creator as JBP6");
        assertEq(TOKENS.totalBalanceOf(address(lunch), 1), 0, "lunch holds JBP6");
    }

    function test_burn_anyoneCanCall() public {
        uint256 id = _served(0, 0, 0);
        _pay(id, bob, 0.01 ether);
        vm.warp(_servedAt() + 30 minutes);

        uint256 supply = TOKENS.totalSupplyOf(id);
        vm.prank(address(0xDEAD0001));
        (uint256 spent, uint256 burned) = lunch.burn(id);

        assertApproxEqAbs(spent, 0.01 ether, 1e9);
        assertApproxEqRel(burned, 9900e18, 0.01e18);
        assertEq(supply - TOKENS.totalSupplyOf(id), burned);
        assertEq(_balance(id), 0, "all of it was spent");
        _assertHoldsNothing(id);
    }

    function test_collect_burnsTokensAndPaysJbp6() public {
        uint256 id = _served(0, 0, 0);
        PoolKey memory key = lunch.poolKeyOf(id);
        uint128 liquidity = POSITION_MANAGER.getPositionLiquidity(lunch.recordOf(id).positionId);
        vm.warp(_servedAt() + 30 minutes);

        // Trade both ways through the pool so it earns fees on both sides: a burn's buy pays ETH, a holder's sale pays
        // tokens.
        _pay(id, bob, 0.05 ether);
        lunch.burn(id);
        PoolProbe trader = new PoolProbe(POSITION_MANAGER, PERMIT2);
        IERC20 token = _token(id);
        vm.prank(alice);
        token.transfer(address(trader), 100_000e18);
        trader.swap(key, false, 100_000e18);

        uint256 jbp6Before = TOKENS.totalBalanceOf(creator, 1);
        uint256 supply = TOKENS.totalSupplyOf(id);
        (uint256 tokensBurned, uint256 ethPaid) = lunch.collect(id);

        // 1% of each trade, to the wei of rounding.
        assertApproxEqAbs(ethPaid, 0.0005 ether, 1e9, "ETH fees");
        assertApproxEqAbs(tokensBurned, 1000e18, 1e12, "token fees");
        assertGt(TOKENS.totalBalanceOf(creator, 1), jbp6Before, "creator earned JBP6");
        assertEq(supply - TOKENS.totalSupplyOf(id), tokensBurned, "token fees were burned");
        assertEq(POSITION_MANAGER.getPositionLiquidity(lunch.recordOf(id).positionId), liquidity, "liquidity untouched");
        _assertHoldsNothing(id);

        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_NotServed.selector, 1));
        lunch.collect(1);
    }

    /// @notice Trade both ways through a served lunch's pool so its position earns fees on both sides.
    function _earnPoolFees(uint256 id) internal {
        PoolKey memory key = lunch.poolKeyOf(id);
        vm.warp(_servedAt() + 30 minutes);
        _pay(id, bob, 0.05 ether);
        lunch.burn(id);
        PoolProbe trader = new PoolProbe(POSITION_MANAGER, PERMIT2);
        IERC20 token = _token(id);
        vm.prank(alice);
        token.transfer(address(trader), 100_000e18);
        trader.swap(key, false, 100_000e18);
    }

    /// @notice Make a lunch that sells tokens for a number of days from now, to stand in for a partner project.
    function _partner(uint48 daysOpen) internal returns (uint256) {
        FairLunchConfig memory config = _config(creator, 0, 0, 0);
        config.deadline = uint48(block.timestamp) + daysOpen * 1 days;
        config.salt = "partner";
        return lunch.createFor{value: PROJECTS.creationFee()}(config);
    }

    /// @notice Make an address JBP6's operator, as its revnet owner contract would report it.
    function _asJbp6Operator(address operator) internal {
        vm.mockCall(
            PROJECTS.ownerOf(1), abi.encodeWithSignature("isOperatorOf(uint256,address)", 1, operator), abi.encode(true)
        );
    }

    /// @notice Only JBP6's operator sets the project that shares pool fees, only once, and only to a real project.
    function test_setSplitProjectId_onlyJbp6OperatorOnce() public {
        uint256 partner = _create(0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_Unauthorized.selector, address(this)));
        lunch.setSplitProjectId(partner);

        address operator = address(0x09E7A702);
        _asJbp6Operator(operator);
        vm.startPrank(operator);
        uint256 beyond = PROJECTS.count() + 1;
        for (uint256 i; i < 3; i++) {
            vm.expectRevert(FairLunch.FairLunch_InvalidConfig.selector);
            lunch.setSplitProjectId(i == 2 ? beyond : i);
        }

        lunch.setSplitProjectId(partner);
        assertEq(lunch.splitProjectId(), partner);

        vm.expectRevert(FairLunch.FairLunch_AlreadyConfigured.selector);
        lunch.setSplitProjectId(partner + 1);
        vm.stopPrank();
    }

    /// @notice Once a project is set, it gets half of the money side of pool fees and JBP6 gets the other half. The
    /// creator gets the tokens both payments mint.
    function test_collect_splitsTheMoneyWithTheSetProject() public {
        uint256 id = _served(0, 0, 0);

        // The partner is a lunch that's still selling tokens, so it takes ETH in the same terminal.
        uint256 partner = _partner(60);
        address operator = address(0x09E7A702);
        _asJbp6Operator(operator);
        vm.prank(operator);
        lunch.setSplitProjectId(partner);

        _earnPoolFees(id);
        uint256 jbp6Before = TOKENS.totalBalanceOf(creator, 1);
        uint256 lunchBalance = _balance(id);
        (, uint256 ethPaid) = lunch.collect(id);

        assertApproxEqAbs(ethPaid, 0.0005 ether, 1e9, "ETH fees");
        assertEq(_balance(partner), ethPaid / 2, "half went to the partner");
        assertEq(TOKENS.totalBalanceOf(creator, partner), (ethPaid / 2) * 1_000_000, "creator got the partner's tokens");
        assertGt(TOKENS.totalBalanceOf(creator, 1), jbp6Before, "creator earned JBP6 on the rest");
        assertEq(_balance(id), lunchBalance, "nothing kept");
        _assertHoldsNothing(id);
    }

    /// @notice A set project whose terminals break the lookup doesn't block `collect`: the lunch keeps that half.
    function test_collect_survivesASetProjectWhoseLookupReverts() public {
        uint256 id = _served(0, 0, 0);
        uint256 partner = _partner(60);
        address operator = address(0x09E7A702);
        _asJbp6Operator(operator);
        vm.prank(operator);
        lunch.setSplitProjectId(partner);

        _earnPoolFees(id);
        vm.mockCallRevert(
            address(lunch.DIRECTORY()),
            abi.encodeWithSignature("primaryTerminalOf(uint256,address)", partner, JBConstants.NATIVE_TOKEN),
            "broken"
        );
        uint256 lunchBalance = _balance(id);
        (, uint256 ethPaid) = lunch.collect(id);

        assertEq(_balance(partner), 0, "partner took nothing");
        assertEq(_balance(id), lunchBalance + ethPaid / 2, "the lunch kept the partner's half");
        _assertHoldsNothing(id);
    }

    /// @notice If the set project won't take its half, the lunch's balance does, and JBP6 still gets its half.
    function test_collect_keepsTheHalfTheSetProjectRefuses() public {
        uint256 id = _served(0, 0, 0);

        // A lunch nobody funded stops taking payments at its deadline.
        uint256 partner = _partner(1);
        address operator = address(0x09E7A702);
        _asJbp6Operator(operator);
        vm.prank(operator);
        lunch.setSplitProjectId(partner);

        _earnPoolFees(id);
        vm.warp(block.timestamp + 30 days);
        uint256 jbp6Before = TOKENS.totalBalanceOf(creator, 1);
        uint256 lunchBalance = _balance(id);
        (, uint256 ethPaid) = lunch.collect(id);

        assertEq(_balance(partner), 0, "partner took nothing");
        assertEq(_balance(id), lunchBalance + ethPaid / 2, "the lunch kept the partner's half");
        assertGt(TOKENS.totalBalanceOf(creator, 1), jbp6Before, "creator earned JBP6 on the rest");
        _assertHoldsNothing(id);
    }

    //*********************************************************************//
    // --------------------------- adversaries --------------------------- //
    //*********************************************************************//

    /// @notice A copy of a lunch with any other terms gets other bridges, so it can't mint into this one.
    function test_createFor_bindsTermsIntoAddresses() public {
        FairLunchConfig memory config = _config(creator, FIFTH, 1 ether, TENTH);
        config.salt = "same";
        uint256 fee = PROJECTS.creationFee();
        address token = address(TOKENS.tokenOf(lunch.createFor{value: fee}(config)));

        // The token's address stands in for every address derived from the salt, the suckers' included.
        uint256 snapshot = vm.snapshotState();
        config.deadline += 1;
        assertNotEq(address(TOKENS.tokenOf(lunch.createFor{value: fee}(config))), token, "deadline");
        vm.revertToState(snapshot);
        config.deadline -= 1;
        config.tokenPercent = HALF;
        assertNotEq(address(TOKENS.tokenOf(lunch.createFor{value: fee}(config))), token, "token percent");
        vm.revertToState(snapshot);
        config.tokenPercent = TENTH;
        config.vestingDuration = 0;
        assertNotEq(address(TOKENS.tokenOf(lunch.createFor{value: fee}(config))), token, "vesting");
        vm.revertToState(snapshot);
        config.vestingDuration = 52 weeks;
        config.claimsPercent = TENTH;
        config.claimsRoot = bytes32(uint256(1));
        address withClaims = address(TOKENS.tokenOf(lunch.createFor{value: fee}(config)));
        vm.revertToState(snapshot);
        config.claimsVestingDuration = 52 weeks;
        assertNotEq(address(TOKENS.tokenOf(lunch.createFor{value: fee}(config))), withClaims, "claims vesting");
        vm.revertToState(snapshot);
        config.claimsPercent = 0;
        config.claimsRoot = 0;
        config.claimsVestingDuration = 0;
        config.creator = bob;
        assertNotEq(address(TOKENS.tokenOf(lunch.createFor{value: fee}(config))), token, "creator");

        // The same terms again collide, as the same lunch would.
        vm.revertToState(snapshot);
        config.creator = creator;
        vm.expectRevert();
        lunch.createFor{value: fee}(config);
    }

    /// @notice A stranger opens the pool long before the lunch is served, at a price where the token costs a hundred
    /// times the fundraise's. That history must not reach the buyback: it would let the buyback pay that price.
    function test_burn_ignoresPriceHistoryFromBeforeServing() public {
        uint256 id = _create(0, 0, 0);
        _pay(id, alice, 10 ether);
        vm.prank(bob);
        POOL_MANAGER.initialize(lunch.poolKeyOf(id), TickMath.getSqrtPriceAtTick(92_000));

        vm.warp(deadline + 1);
        lunch.serve(id);
        int24 servedTick = _tick(id);

        // Inside the first half hour the average still holds the stranger's price. Nothing is bought.
        vm.warp(_servedAt() + 30 minutes - 1);
        _pay(id, bob, 5 ether);
        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_TooEarly.selector, id, _servedAt() + 30 minutes));
        lunch.burn(id);
        assertEq(_tick(id), servedTick, "no buyback yet");
        assertApproxEqAbs(_balance(id), 5 ether, 1e9, "the payment waits");

        // After it, the average is the served price alone, and a buyback stops 200 ticks past it.
        vm.warp(_servedAt() + 30 minutes);
        (uint256 spent,) = lunch.burn(id);
        assertGt(spent, 0, "buys");
        assertApproxEqAbs(_tick(id), servedTick - 200, 1, "bounded by the served price, not the stranger's");
        _assertHoldsNothing(id);
    }

    function test_burn_oversized_stopsAtTheBound() public {
        uint256 id = _served(0, 0, 0);
        int24 servedTick = _tick(id);
        vm.warp(_servedAt() + 30 minutes);

        // A hundred times the pool's ETH.
        _pay(id, bob, 975 ether);
        lunch.burn(id);

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

    /// @notice Whatever the pool's price is when a buyback runs, it never ends past the bound.
    function testFuzz_burn_neverBuysPastTheBound(uint256 firstBuy, uint256 secondBuy) public {
        firstBuy = bound(firstBuy, 0.001 ether, 500 ether);
        secondBuy = bound(secondBuy, 0.001 ether, 500 ether);

        uint256 id = _served(0, 0, 0);
        int24 servedTick = _tick(id);

        vm.warp(_servedAt() + 30 minutes);
        _pay(id, bob, firstBuy);
        lunch.burn(id);
        assertGe(_tick(id), servedTick - 201, "first buy");

        // Fifteen minutes on, the average is at most halfway to wherever the first buy left the price.
        int24 afterFirst = _tick(id);
        vm.warp(_servedAt() + 45 minutes);
        _pay(id, bob, secondBuy);
        lunch.burn(id);
        assertGe(_tick(id), (servedTick + afterFirst) / 2 - 202, "second buy");
        _assertHoldsNothing(id);
    }

    /// @notice A buy slipped in ahead of a buyback in the same block gets nothing out of it.
    function test_burn_ignoresPriceMovedInItsOwnBlock() public {
        uint256 id = _served(0, 0, 0);
        PoolKey memory key = lunch.poolKeyOf(id);
        PoolProbe trader = new PoolProbe(POSITION_MANAGER, PERMIT2);
        vm.deal(address(trader), 10 ether);

        // A holder sells hard, and time passes with the price low: far under the average, a buyback has room.
        IERC20 token = _token(id);
        vm.prank(alice);
        token.transfer(address(trader), 4_000_000e18);
        vm.warp(_servedAt() + 30 minutes);
        trader.swap(key, false, 4_000_000e18);
        vm.warp(_servedAt() + 31 minutes);
        int24 lowTick = _tick(id);

        // Front-run: push the price up 5% just ahead of a 1 ETH payment.
        trader.swap(key, true, 0.15 ether);
        assertLt(_tick(id), lowTick - 400, "front-run moved the price");
        int24 frontRunTick = _tick(id);

        _pay(id, bob, 1 ether);
        (uint256 chased,) = lunch.burn(id);
        assertEq(chased, 0);
        assertEq(_tick(id), frontRunTick, "the buyback didn't chase it");
        assertApproxEqAbs(_balance(id), 1 ether, 1e9, "the payment waits");

        // A block later that price is the pool's last close, and a buyback moves it by the bound and no more: less
        // than the two swap fees a round trip costs.
        vm.warp(_servedAt() + 32 minutes);
        (uint256 spent,) = lunch.burn(id);
        assertGt(spent, 0, "buys the next block");
        assertApproxEqAbs(_tick(id), frontRunTick - 200, 1, "by the bound");
        _assertHoldsNothing(id);
    }

    /// @notice Buying ahead of a burn and selling after it loses money: the burn won't buy at the pushed price.
    function test_burn_sandwichLosesMoney() public {
        uint256 id = _served(0, 0, 0);
        PoolKey memory key = lunch.poolKeyOf(id);
        PoolProbe trader = new PoolProbe(POSITION_MANAGER, PERMIT2);
        vm.deal(address(trader), 4 ether);
        _pay(id, bob, 1 ether);
        _trade(id);
        vm.warp(_servedAt() + 31 minutes);

        // 4 ETH into a 10 ETH pool, a burn with 1 ETH waiting, then out again.
        (, bytes memory result) =
            trader.sandwich(key, true, 4 ether, address(lunch), 0, abi.encodeCall(lunch.burn, (id)));
        (uint256 spent,) = abi.decode(result, (uint256, uint256));

        assertEq(spent, 0, "the burn didn't buy at the pushed price");
        assertLt(address(trader).balance, 4 ether, "the round trip only paid fees");
        assertApproxEqAbs(_balance(id), 1 ether, 1e9, "the ETH still waits");
    }

    /// @notice Trading around a burn never pays, whichever way the push goes, however big it and the waiting balance
    /// are, in the burn's own block or with the push a block ahead.
    function testFuzz_burn_sandwichNeverProfits(uint256 push, uint256 waiting, bool ethFirst, bool blockAhead) public {
        uint256 id = _served(0, 0, 0);
        PoolKey memory key = lunch.poolKeyOf(id);
        PoolProbe probe = new PoolProbe(POSITION_MANAGER, PERMIT2);
        _pay(id, bob, bound(waiting, 0.001 ether, 5 ether));
        _trade(id);
        vm.warp(_servedAt() + 31 minutes);

        // Up to twice the pool's ETH, or most of its tokens.
        if (ethFirst) {
            push = bound(push, 0.0001 ether, 20 ether);
            vm.deal(address(probe), push);
        } else {
            push = bound(push, 100e18, 9_000_000e18);
            IERC20 token = _token(id);
            vm.prank(alice);
            token.transfer(address(probe), push);
        }

        uint256 back;
        if (blockAhead) {
            uint256 got = probe.swap(key, ethFirst, push);
            vm.warp(_servedAt() + 31 minutes + 2);
            lunch.burn(id);
            back = probe.swap(key, !ethFirst, got);
        } else {
            (back,) = probe.sandwich(key, ethFirst, push, address(lunch), 0, abi.encodeCall(lunch.burn, (id)));
        }
        assertLe(back, push, "the round trip paid");
    }

    /// @notice Liquidity added just ahead of a burn earns the pool's fee on it, and the burn buys more tokens per ETH
    /// for it, not fewer.
    function test_burn_liquidityAheadOnlyHelpsIt() public {
        uint256 start = vm.snapshotState();
        uint256 without = _tokensPerEthBurned(false);
        vm.revertToState(start);
        uint256 with = _tokensPerEthBurned(true);
        assertGt(with, without, "the burn bought fewer tokens per ETH");
    }

    /// @notice The tokens a 0.1 ETH burn buys per ETH it spends, with or without someone's liquidity put right around
    /// the price just ahead of it and taken out just after.
    function _tokensPerEthBurned(bool ahead) internal returns (uint256) {
        uint256 id = _served(0, 0, 0);
        PoolKey memory key = lunch.poolKeyOf(id);
        _pay(id, bob, 0.1 ether);
        _trade(id);
        vm.warp(_servedAt() + 31 minutes);

        PoolProbe probe = new PoolProbe(POSITION_MANAGER, PERMIT2);
        uint256 position;
        if (ahead) {
            vm.deal(address(probe), 50 ether);
            IERC20 token = _token(id);
            vm.prank(alice);
            token.transfer(address(probe), 5_000_000e18);
            int24 floor = _tick(id) / 200 * 200 - 200;
            position = probe.seed(key, 0, floor - 200, floor + 200, 50 ether, 5_000_000e18);
        }
        (uint256 spent, uint256 burned) = lunch.burn(id);
        if (ahead) probe.unseed(key, position);
        return burned * 1e18 / spent;
    }

    /// @notice Someone who makes the pool early with their own liquidity in the way, lets `serve` trade through it,
    /// and then sells everything, never ends with more ETH than they started with.
    /// @param dear Whether their pool prices the token above the fundraise's price (resting ETH bids) or below it
    /// (resting asks of tokens they bought while it cooked).
    function testFuzz_serve_earlyPoolNeverProfits(
        bool dear,
        uint256 size,
        uint256 stake,
        uint8 width,
        uint8 gap,
        bool straddle
    )
        public
    {
        uint256 id = _create(FIFTH, 5 ether, TENTH);
        _pay(id, alice, 10 ether);
        PoolKey memory key = lunch.poolKeyOf(id);
        PoolProbe probe = new PoolProbe(POSITION_MANAGER, PERMIT2);
        size = bound(size, 0.01 ether, 40 ether);
        stake = bound(stake, 0, 20 ether);
        vm.deal(address(probe), size + stake);

        // They can also hold tokens from the fundraise to sell into whatever price the pool opens at.
        if (stake != 0) {
            vm.prank(address(probe));
            TERMINAL.pay{value: stake}(id, JBConstants.NATIVE_TOKEN, stake, address(probe), 0, "", "");
        }

        // The fundraise's price is tick 138,162. A range ends beside it or straddles it.
        int24 span = 200 * int24(uint24(bound(width, 1, 20)));
        int24 away = 200 * int24(uint24(bound(gap, 0, 50)));
        if (dear) {
            int24 upper = straddle ? int24(138_200) : int24(138_000);
            probe.seed(key, TickMath.getSqrtPriceAtTick(upper - span - away), upper - span, upper, uint128(size), 0);
        } else {
            vm.prank(address(probe));
            uint256 tokens = TERMINAL.pay{value: size}(id, JBConstants.NATIVE_TOKEN, size, address(probe), 0, "", "");
            int24 lower = straddle ? int24(138_000) : int24(138_200);
            probe.seed(key, TickMath.getSqrtPriceAtTick(lower + span + away), lower, lower + span, 0, uint128(tokens));
        }
        uint256 positionId = POSITION_MANAGER.nextTokenId() - 1;

        vm.warp(deadline + 1);
        lunch.serve(id);

        probe.unseed(key, positionId);
        probe.swap(key, false, _token(id).balanceOf(address(probe)));
        assertLe(address(probe).balance, size + stake, "making the pool early paid");
    }

    /// @notice Liquidity left beside the fundraise's price never trades with `serve` at a better price than the
    /// fundraise gave, counting the pool fee `serve` pays it: tokens bought while cooking can't be sold to `serve` for
    /// more than they cost, and tokens can't be bought from `serve` for less.
    function test_serve_sellsNoTokenUnderTheRaisePrice() public {
        _serveThroughRange(true);
    }

    function test_serve_buysNoTokenOverTheRaisePrice() public {
        _serveThroughRange(false);
    }

    function _serveThroughRange(bool dear) internal {
        uint256 id = _create(FIFTH, 5 ether, TENTH);
        _pay(id, alice, 10 ether);
        PoolKey memory key = lunch.poolKeyOf(id);
        PoolProbe probe = new PoolProbe(POSITION_MANAGER, PERMIT2);
        vm.deal(address(probe), 40 ether);

        // A range beside the fundraise's price, tick 138,162, with the pool started at its far edge so `serve` trades
        // through it.
        if (dear) {
            probe.seed(key, TickMath.getSqrtPriceAtTick(138_000), 138_000, 138_200, 30 ether, 0);
        } else {
            vm.prank(address(probe));
            uint256 tokens =
                TERMINAL.pay{value: 30 ether}(id, JBConstants.NATIVE_TOKEN, 30 ether, address(probe), 0, "", "");
            probe.seed(key, TickMath.getSqrtPriceAtTick(138_400), 138_200, 138_400, 0, uint128(tokens));
        }
        uint256 positionId = POSITION_MANAGER.nextTokenId() - 1;
        uint256 ethBefore = address(probe).balance;
        uint256 tokensBefore = _token(id).balanceOf(address(probe));

        vm.warp(deadline + 1);
        lunch.serve(id);
        probe.unseed(key, positionId);

        // What the position ended up trading, against the fundraise's 1,000,000 tokens per ETH.
        if (dear) {
            uint256 paid = 30 ether - (address(probe).balance - ethBefore);
            assertLe(_token(id).balanceOf(address(probe)), paid * 1_000_000, "bought under the fundraise's price");
        } else {
            uint256 sold = 30_000_000e18 - (_token(id).balanceOf(address(probe)) - tokensBefore);
            assertLe((address(probe).balance - ethBefore) * 1_000_000, sold, "sold over the fundraise's price");
        }
    }

    /// @notice A pool started as far from the fundraise's price as `serve` will leave it gives nobody a trade that
    /// beats the fundraise: tokens bought while cooking don't sell for more than they cost, and the pool's tokens don't
    /// sell
    /// for less.
    function test_serve_openingBesideTheRaisePriceGivesNoFreeTrade_dear() public {
        (uint256 id, PoolProbe probe) = _servedFrom(DEAREST_SQRT_PRICE_X96);
        IERC20 token = _token(id);
        vm.prank(alice);
        token.transfer(address(probe), 1000e18);
        assertLe(probe.swap(lunch.poolKeyOf(id), false, 1000e18), 0.001 ether, "sold over the fundraise's price");
    }

    function test_serve_openingBesideTheRaisePriceGivesNoFreeTrade_cheap() public {
        (uint256 id, PoolProbe probe) = _servedFrom(CHEAPEST_SQRT_PRICE_X96);
        vm.deal(address(probe), 0.001 ether);
        assertLe(probe.swap(lunch.poolKeyOf(id), true, 0.001 ether), 1000e18, "bought under the fundraise's price");
    }

    function _servedFrom(uint160 sqrtPriceX96) internal returns (uint256 id, PoolProbe probe) {
        id = _create(0, 0, 0);
        _pay(id, alice, 10 ether);
        POOL_MANAGER.initialize(lunch.poolKeyOf(id), sqrtPriceX96);
        vm.warp(deadline + 1);
        lunch.serve(id);
        assertEq(_sqrtPrice(id), sqrtPriceX96, "opened where it was started");
        probe = new PoolProbe(POSITION_MANAGER, PERMIT2);
    }

    /// @notice Someone can buy a little, lend it to the pool as liquidity right where a burn is about to buy, and take
    /// it back after: they sell into the burn and earn its fee instead of paying one. That pays. Starting from a quiet
    /// price the burn's bound keeps it under 2% of what the burn spent. Tokens bought cheaply after someone else's
    /// large sale carry that gain on top: the bound limits what the burn pays, not what a seller paid.
    function test_burn_liquidityAddedAheadFromAQuietPriceTakesUnderTheBound() public {
        uint256 id = _served(0, 0, 0);
        PoolKey memory key = lunch.poolKeyOf(id);
        PoolProbe probe = new PoolProbe(POSITION_MANAGER, PERMIT2);
        _pay(id, bob, 1 ether);
        _trade(id);
        vm.warp(_servedAt() + 31 minutes);

        vm.deal(address(probe), 1 ether);
        uint256 bought = probe.swap(key, true, 0.05 ether);
        probe.seed(key, 0, 138_000, 138_200, 0.2 ether, uint128(bought));
        uint256 positionId = POSITION_MANAGER.nextTokenId() - 1;
        (uint256 spent,) = lunch.burn(id);
        probe.unseed(key, positionId);
        probe.swap(key, false, _token(id).balanceOf(address(probe)));

        assertGt(spent, 0, "the burn bought");
        assertLe(address(probe).balance, 1 ether + spent / 50, "took more than the bound allows");
    }

    /// @notice Deep liquidity parked just short of the fundraise's price can't keep a lunch from being served.
    function test_serve_deepStrangerLiquidityCantBlockIt() public {
        uint256 id = _create(0, 0, 0);
        _pay(id, alice, 10 ether);
        PoolKey memory key = lunch.poolKeyOf(id);

        // 15 ETH between ticks 138,000 and 138,200, with the price under the fundraise's 138,162: more than the
        // lunch's 9.75M tokens can sell through.
        vm.deal(bob, 100 ether);
        vm.startPrank(bob);
        POOL_MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(138_000));
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(138_000), TickMath.getSqrtPriceAtTick(138_200), 15 ether
        );
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(key, int24(138_000), int24(138_200), uint256(liquidity), uint128(16 ether), uint128(0), bob, "");
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, bob);
        POSITION_MANAGER.modifyLiquidities{value: 16 ether}(abi.encode(actions, params), block.timestamp);
        vm.stopPrank();

        vm.warp(deadline + 1);
        lunch.serve(id);

        // Served short of the fundraise's price, with a position, and the ETH it didn't use waiting for buybacks.
        assertLt(_sqrtPrice(id), RAISE_SQRT_PRICE_X96, "couldn't reach the price");
        assertGt(POSITION_MANAGER.getPositionLiquidity(lunch.recordOf(id).positionId), 0, "has a position");
        assertGt(_balance(id), 1 ether, "unused ETH waits");
        _assertHoldsNothing(id);
    }

    /// @notice Whatever happens in the pool before serving, the creator ends with exactly their share of the supply.
    function test_serve_creatorShareHoldsOverHostilePool() public {
        uint256 id = _create(0, 0, HALF);
        _pay(id, alice, 10 ether);
        vm.prank(bob);
        POOL_MANAGER.initialize(lunch.poolKeyOf(id), TickMath.getSqrtPriceAtTick(150_000));

        vm.warp(deadline + 1);
        lunch.serve(id);

        uint256 vested = lunch.CLAIMS().creatorTokenCountOf(id);
        assertApproxEqAbs(vested * 2, TOKENS.totalSupplyOf(id), 2, "half the supply");
    }

    function test_sendHome_revertsOnHost() public {
        uint256 id = _create(0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(FairLunch.FairLunch_NotRemote.selector, id));
        lunch.sendHome(id);
    }

    function test_setChainSpecificConstants_onlyDeployerOnce() public {
        assertEq(
            address(lunch.POOL().POOL_MANAGER()), address(POOL_MANAGER), "pool manager read from the position manager"
        );

        vm.expectRevert(FairLunch.FairLunch_AlreadyConfigured.selector);
        lunch.setChainSpecificConstants({positionManager: POSITION_MANAGER, oracleHook: ORACLE});

        FairLunch fresh = new FairLunch({
            omnichainDeployer: OMNI,
            buybackRegistry: BUYBACK,
            terminal: TERMINAL,
            routerTerminalRegistry: ROUTER_REGISTRY,
            suckerRegistry: REGISTRY,
            permit2: PERMIT2,
            deployer: bob
        });
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
}

interface IERC721Like {
    function ownerOf(uint256 tokenId) external view returns (address);
}
