// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The one word of a sucker's token mapping that Fair Lunch reads.
/// @dev `IJBSucker.remoteTokenFor` returns a `JBRemoteToken`, whose members are all static, so its first returned word
/// is `enabled`. Reading only that word keeps `FairLunch` under the contract size limit.
interface ISuckerRoute {
    /// @notice Whether the sucker will bridge a token.
    /// @param token The local terminal token.
    /// @return enabled Whether the token is mapped and sending it is on.
    function remoteTokenFor(address token) external view returns (bool enabled);
}
