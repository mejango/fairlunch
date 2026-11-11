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
    function rehearse() external {
        vm.startBroadcast();
        FairLunch lunch = _deploy({configurator: msg.sender});
        IJBMultiTerminal terminal = lunch.TERMINAL();
        uint256 fee = lunch.DIRECTORY().PROJECTS().creationFee();

        // One that's served soon, one that keeps cooking.
        uint256[2] memory raises = [uint256(3 ether), 1.25 ether];
        uint48[2] memory deadlines = [uint48(block.timestamp + 10 minutes), uint48(block.timestamp + 7 days)];
        string[2] memory names = ["Sandwich", "Dumpling"];
        string[2] memory symbols = ["SAND", "DUMP"];
        for (uint256 i; i < 2; i++) {
            FairLunchConfig memory config;
            config.name = names[i];
            config.symbol = symbols[i];
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
        vm.stopBroadcast();
    }
}
