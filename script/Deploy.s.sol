// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBBuybackHookRegistry} from "@bananapus/buyback-hook-v6/src/interfaces/IJBBuybackHookRegistry.sol";
import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBOmnichainDeployer} from "@bananapus/omnichain-deployers-v6/src/interfaces/IJBOmnichainDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IGeomeanOracle} from "@bananapus/univ4-router-v6/src/interfaces/IGeomeanOracle.sol";
import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Script} from "forge-std/Script.sol";

import {FairLunch} from "../src/FairLunch.sol";

/// @notice Proposes Fair Lunch through the Juicebox V6 Sphinx workflow.
/// @dev Every constructor argument is the same on each chain of a network class, so `FairLunch` lands on the same
/// address on each of them. The Uniswap V4 addresses differ per chain and are set right after, in the same proposal,
/// by the Sphinx Safe.
contract Deploy is Script, Sphinx {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the connected chain isn't one Fair Lunch supports.
    error Deploy_UnsupportedChain(uint256 chainId);

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice The canonical Permit2, at the same address on every chain.
    IAllowanceTransfer internal constant _PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    /// @notice The router terminal registry, at the same address on every chain.
    IJBTerminal internal constant _ROUTER_TERMINAL_REGISTRY = IJBTerminal(0xe0427F250fdb0379c8E98e884Ee4570521208CbC);

    /// @notice The salt Fair Lunch is deployed with.
    bytes32 internal constant _SALT = "FairLunch";

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Configures the Sphinx project and supported RPC aliases.
    function configureSphinx() public override {
        sphinxConfig.projectName = "fair-lunch";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    /// @notice Deploys and configures Fair Lunch on the connected chain, as the Sphinx Safe.
    function run() public sphinx {
        _deploy({configurator: safeAddress()});
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Deploys Fair Lunch, which deploys its data hook, pool and claims, and sets the connected chain's Uniswap
    /// V4 addresses. @param configurator The address allowed to set the chain-specific constants. It must be the
    /// caller.
    /// @return lunch The deployed Fair Lunch.
    function _deploy(address configurator) internal returns (FairLunch lunch) {
        string memory chain = _chainName();

        lunch = new FairLunch{salt: _SALT}({
            omnichainDeployer: IJBOmnichainDeployer(
                _deployed({package: "omnichain-deployers-v6", chain: chain, name: "JBOmnichainDeployer"})
            ),
            buybackRegistry: IJBBuybackHookRegistry(
                _deployed({package: "buyback-hook-v6", chain: chain, name: "JBBuybackHookRegistry"})
            ),
            terminal: IJBMultiTerminal(_deployed({package: "core-v6", chain: chain, name: "JBMultiTerminal"})),
            routerTerminalRegistry: _ROUTER_TERMINAL_REGISTRY,
            suckerRegistry: IJBSuckerRegistry(
                _deployed({package: "suckers-v6", chain: chain, name: "JBSuckerRegistry"})
            ),
            permit2: _PERMIT2,
            deployer: configurator
        });

        lunch.setChainSpecificConstants({
            newPositionManager: _positionManager(),
            newOracleHook: IGeomeanOracle(
                _deployed({package: "univ4-router-v6", chain: chain, name: "JBUniswapV4Hook"})
            )
        });
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice The name the Juicebox packages file the connected chain's deployments under.
    /// @return name The chain's name.
    function _chainName() internal view returns (string memory name) {
        if (block.chainid == 1) return "ethereum";
        if (block.chainid == 10) return "optimism";
        if (block.chainid == 8453) return "base";
        if (block.chainid == 42_161) return "arbitrum";
        if (block.chainid == 11_155_111) return "sepolia";
        if (block.chainid == 84_532) return "base_sepolia";
        if (block.chainid == 421_614) return "arbitrum_sepolia";
        revert Deploy_UnsupportedChain(block.chainid);
    }

    /// @notice A Juicebox contract's address on a chain, read from the installed package's deployment record.
    /// @param package The package's name under `@bananapus`.
    /// @param chain The chain's name.
    /// @param name The contract's name.
    /// @return deployed The contract's address.
    function _deployed(
        string memory package,
        string memory chain,
        string memory name
    )
        internal
        view
        returns (address deployed)
    {
        return vm.parseJsonAddress({
            json: vm.readFile(
                string.concat("node_modules/@bananapus/", package, "/deployments/", chain, "/", name, ".json")
            ),
            key: ".address"
        });
    }

    /// @notice The Uniswap V4 position manager on the connected chain.
    /// @return positionManager The position manager.
    function _positionManager() internal view returns (IPositionManager positionManager) {
        if (block.chainid == 1) return IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
        if (block.chainid == 10) return IPositionManager(0x3C3Ea4B57a46241e54610e5f022E5c45859A1017);
        if (block.chainid == 8453) return IPositionManager(0x7C5f5A4bBd8fD63184577525326123B519429bDc);
        if (block.chainid == 42_161) return IPositionManager(0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869);
        if (block.chainid == 11_155_111) return IPositionManager(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4);
        if (block.chainid == 84_532) return IPositionManager(0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80);
        if (block.chainid == 421_614) return IPositionManager(0xAc631556d3d4019C95769033B5E719dD77124BAc);
        revert Deploy_UnsupportedChain(block.chainid);
    }
}
