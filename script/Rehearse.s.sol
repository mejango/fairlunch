// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBMultiTerminal} from "@bananapus/core-v6/src/interfaces/IJBMultiTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {FairLunch} from "../src/FairLunch.sol";
import {FairLunchConfig} from "../src/structs/FairLunchConfig.sol";
import {Deploy} from "./Deploy.s.sol";

/// @notice Puts Fair Lunch and two lunches on a local fork, for looking at the website with real state.
/// @dev `forge script script/Rehearse.s.sol --rpc-url <fork> --broadcast --unlocked --sender <account>`. Never run
/// against a live chain: the broadcaster becomes the one-shot configurator.
contract Rehearse is Deploy {
    /// @notice Puts Fair Lunch alone on a second fork, at the same address, for a lunch with a copy there.
    function deployOnly() external {
        vm.startBroadcast();
        _deploy({configurator: msg.sender});
        vm.stopBroadcast();
    }

    function rehearse() external {
        vm.startBroadcast();
        FairLunch lunch = _deploy({configurator: msg.sender});
        IJBMultiTerminal terminal = lunch.TERMINAL();
        uint256 fee = lunch.DIRECTORY().PROJECTS().creationFee();

        // One that's served soon, one that keeps cooking.
        uint256[2] memory raises = [uint256(3 ether), 1.25 ether];
        uint48[2] memory deadlines = [uint48(block.timestamp + 10 minutes), uint48(block.timestamp + 7 days)];
        string[2] memory names = ["Sandwich", "Bagel"];
        string[2] memory symbols = ["SAND", "BAGEL"];
        for (uint256 i; i < 2; i++) {
            FairLunchConfig memory config;
            config.name = names[i];
            config.symbol = symbols[i];
            config.token = JBConstants.NATIVE_TOKEN;
            config.hostChainId = uint64(block.chainid);
            config.deadline = deadlines[i];
            config.creator = msg.sender;
            config.keepPercent = JBConstants.SPLITS_TOTAL_PERCENT / 5;
            config.keepCap = 0.5 ether;
            config.tokenPercent = JBConstants.SPLITS_TOTAL_PERCENT / 10;
            config.vestingDuration = 52 weeks;
            uint256 id = lunch.createFor{value: fee}(config);
            terminal.pay{value: raises[i]}(id, JBConstants.NATIVE_TOKEN, raises[i], msg.sender, 0, "", "");
        }

        // And one that raises USDC, left for the caller to pay.
        FairLunchConfig memory usdc;
        usdc.name = "Taco";
        usdc.symbol = "TACO";
        usdc.token = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        usdc.hostChainId = uint64(block.chainid);
        usdc.deadline = uint48(block.timestamp + 7 days);
        usdc.creator = msg.sender;
        usdc.keepPercent = JBConstants.SPLITS_TOTAL_PERCENT / 5;
        usdc.keepCap = 2000e6;
        usdc.tokenPercent = JBConstants.SPLITS_TOTAL_PERCENT / 10;
        usdc.vestingDuration = 52 weeks;
        lunch.createFor{value: fee}(usdc);
        vm.stopBroadcast();
    }
}
