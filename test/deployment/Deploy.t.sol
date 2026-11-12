// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {FairLunch} from "../../src/FairLunch.sol";

/// @notice Runs the deploy script's own deployment code, with this harness standing in for the Sphinx Safe.
contract DeployHarness is Deploy {
    function rehearse() external returns (FairLunch) {
        return _deploy({configurator: address(this)});
    }
}

/// @notice The deploy script lands Fair Lunch on the same address on Base and Optimism, configured for each.
contract DeployTest is Test {
    /// @notice One harness for both forks, since Sphinx's constructor can only run once per test.
    DeployHarness internal _harness;

    function setUp() public {
        _harness = new DeployHarness();
        vm.makePersistent(address(_harness));
    }

    function _rehearseOn(string memory rpc, uint256 blockNumber) internal returns (FairLunch) {
        vm.createSelectFork(rpc, blockNumber);
        return _harness.rehearse();
    }

    function test_deploy_sameAddressConfiguredPerChain() public {
        FairLunch onBase = _rehearseOn("https://mainnet.base.org", 56_216_000);
        assertEq(address(onBase.POOL().POSITION_MANAGER()), 0x7C5f5A4bBd8fD63184577525326123B519429bDc);
        assertEq(address(onBase.POOL().POOL_MANAGER()), 0x498581fF718922c3f8e6A244956aF099B2652b2b);
        assertEq(address(onBase.ORACLE_HOOK()), 0xB436Cedbee8F191A3860719b4B0f474434F315c8);
        assertEq(address(onBase.TERMINAL()), 0x130f5Dd2bD8805443Cf41755253D778a75a67f53);
        assertGt(address(onBase.VESTING_DEPLOYER()).code.length, 0);

        FairLunch onOptimism = _rehearseOn("https://mainnet.optimism.io", 159_417_000);
        assertEq(address(onOptimism), address(onBase), "same address on both chains");
        assertEq(address(onOptimism.POOL().POSITION_MANAGER()), 0x3C3Ea4B57a46241e54610e5f022E5c45859A1017);
        assertEq(address(onOptimism.ORACLE_HOOK()), 0x850eC1a2aDcB2126d823632e60441De2926fD5C8);
    }
}
