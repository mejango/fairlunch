// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The one function of a revnet's owner contract that Fair Lunch reads.
/// @dev JBP6 is a revnet. Its project is owned by a contract that knows who its operator is.
interface IRevnetOperator {
    /// @notice Whether an address holds a revnet's operator permissions.
    /// @param revnetId The ID of the revnet.
    /// @param addr The address to check.
    /// @return A flag indicating whether the address is the revnet's operator.
    function isOperatorOf(uint256 revnetId, address addr) external view returns (bool);
}
