// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

/// @notice Deploys the wallets that vest creators' tokens.
/// @dev This exists only to keep `VestingWallet`'s creation code out of `FairLunch`, which would otherwise exceed the
/// contract size limit. Anyone can call it; a vesting wallet has no powers over anything but what it's sent.
contract FairLunchVestingDeployer {
    /// @notice Deploy a wallet that releases what it holds to a beneficiary linearly over time.
    /// @param beneficiary The address the wallet releases to.
    /// @param startTimestamp The timestamp vesting starts at.
    /// @param durationSeconds The number of seconds vesting lasts.
    /// @return wallet The wallet.
    function deployFor(
        address beneficiary,
        uint64 startTimestamp,
        uint64 durationSeconds
    )
        external
        returns (address wallet)
    {
        return address(
            new VestingWallet({
                beneficiary: beneficiary, startTimestamp: startTimestamp, durationSeconds: durationSeconds
            })
        );
    }
}
