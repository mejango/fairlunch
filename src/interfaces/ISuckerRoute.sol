// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The words of a sucker's token mapping that Fair Lunch reads.
/// @dev `IJBSucker.remoteTokenFor` returns a `JBRemoteToken`, whose members are all static, so its returned words are
/// its members in order. Reading them as whole words, without the struct, keeps `FairLunch` under the contract size
/// limit.
interface ISuckerRoute {
    /// @notice A token's mapping to the sucker's remote chain.
    /// @param token The local terminal token.
    /// @return enabled 1 if the token is mapped and sending it is on, 0 if not.
    /// @return emergencyHatch 1 if the token's emergency hatch is open, 0 if not.
    /// @return minGas The gas the sucker reserves on the remote chain for a claim of the token.
    function remoteTokenFor(address token)
        external
        view
        returns (uint256 enabled, uint256 emergencyHatch, uint256 minGas);
}
