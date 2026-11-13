// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IFairLunch} from "./IFairLunch.sol";

/// @notice Holds the parts of each lunch's token supply that go to its creator and to a list of addresses, and hands
/// them out.
interface IFairLunchClaims {
    /// @notice Emitted when a listed address is sent tokens from a lunch's claims.
    /// @param projectId The ID of the lunch's project.
    /// @param account The listed address.
    /// @param shares The address's share of the claims, out of `SHARES_TOTAL`.
    /// @param tokenCount The number of tokens sent.
    /// @param caller The address that called the function.
    event Claim(uint256 indexed projectId, address indexed account, uint256 shares, uint256 tokenCount, address caller);

    /// @notice Emitted when a lunch's claims and its creator's tokens are funded.
    /// @param projectId The ID of the lunch's project.
    /// @param token The lunch's token.
    /// @param tokenCount The number of tokens held for the claims.
    /// @param creator The address the creator's tokens go to.
    /// @param creatorTokenCount The number of tokens held for the creator.
    /// @param creatorVestingDuration The number of seconds over which the creator's tokens vest.
    /// @param caller The address that called the function.
    event Fund(
        uint256 indexed projectId,
        IERC20 token,
        uint256 tokenCount,
        address indexed creator,
        uint256 creatorTokenCount,
        uint32 creatorVestingDuration,
        address caller
    );

    /// @notice Emitted when a lunch's creator is sent tokens that have vested.
    /// @param projectId The ID of the lunch's project.
    /// @param creator The address the tokens were sent to.
    /// @param tokenCount The number of tokens sent.
    /// @param caller The address that called the function.
    event Release(uint256 indexed projectId, address indexed creator, uint256 tokenCount, address caller);

    /// @notice Emitted when a lunch's claims are fixed at its creation.
    /// @param projectId The ID of the lunch's project.
    /// @param percent The share of the lunch's total token supply its claims get.
    /// @param root The merkle root of the list.
    /// @param vestingDuration The number of seconds over which the claims vest once the lunch is served.
    /// @param caller The address that called the function.
    event SetTerms(uint256 indexed projectId, uint32 percent, bytes32 root, uint32 vestingDuration, address caller);

    /// @notice The `FairLunch` that made this contract, the only address that can set terms and fund them.
    function FAIR_LUNCH() external view returns (IFairLunch);

    /// @notice What a list's shares are out of.
    function SHARES_TOTAL() external view returns (uint256);

    /// @notice The number of a lunch's tokens an address has been sent from its claims.
    /// @param projectId The ID of the lunch's project.
    /// @param account The address.
    function claimedOf(uint256 projectId, address account) external view returns (uint256);

    /// @notice The number of a lunch's tokens its creator has been sent.
    /// @param projectId The ID of the lunch's project.
    function creatorClaimedOf(uint256 projectId) external view returns (uint256);

    /// @notice The address a lunch's creator tokens go to. Fixed when the lunch is served.
    /// @param projectId The ID of the lunch's project.
    function creatorOf(uint256 projectId) external view returns (address);

    /// @notice The number of tokens minted for a lunch's creator when it was served.
    /// @param projectId The ID of the lunch's project.
    function creatorTokenCountOf(uint256 projectId) external view returns (uint256);

    /// @notice The number of seconds over which a lunch's creator tokens vest. Zero if they're all sent at once.
    /// @param projectId The ID of the lunch's project.
    function creatorVestingDurationOf(uint256 projectId) external view returns (uint32);

    /// @notice The share of a lunch's total token supply its claims get, out of `JBConstants.SPLITS_TOTAL_PERCENT`.
    /// @param projectId The ID of the lunch's project.
    function percentOf(uint256 projectId) external view returns (uint32);

    /// @notice The merkle root of a lunch's list.
    /// @param projectId The ID of the lunch's project.
    function rootOf(uint256 projectId) external view returns (bytes32);

    /// @notice The number of tokens minted for a lunch's claims when it was served.
    /// @param projectId The ID of the lunch's project.
    function tokenCountOf(uint256 projectId) external view returns (uint256);

    /// @notice A lunch's token. Zero until the lunch is served.
    /// @param projectId The ID of the lunch's project.
    function tokenOf(uint256 projectId) external view returns (IERC20);

    /// @notice The number of tokens a lunch's claims have sent out so far.
    /// @param projectId The ID of the lunch's project.
    function totalClaimedOf(uint256 projectId) external view returns (uint256);

    /// @notice The number of seconds over which a lunch's claims vest. Zero if they're all claimable at once.
    /// @param projectId The ID of the lunch's project.
    function vestingDurationOf(uint256 projectId) external view returns (uint32);

    /// @notice Send a listed address the part of a served lunch's claims that has vested for it.
    /// @param projectId The ID of the lunch's project.
    /// @param account The listed address.
    /// @param shares The address's share of the claims, out of `SHARES_TOTAL`, as listed.
    /// @param proof The merkle proof of the entry.
    /// @return tokenCount The number of tokens sent.
    function claim(
        uint256 projectId,
        address account,
        uint256 shares,
        bytes32[] calldata proof
    )
        external
        returns (uint256 tokenCount);

    /// @notice Record the tokens `FAIR_LUNCH` minted here for a lunch's claims and its creator, which opens both.
    /// @param projectId The ID of the lunch's project.
    /// @param token The lunch's token.
    /// @param tokenCount The number of tokens minted here for the claims.
    /// @param creator The address the creator's tokens go to.
    /// @param creatorTokenCount The number of tokens minted here for the creator.
    /// @param creatorVestingDuration The number of seconds over which the creator's tokens vest from now.
    function fund(
        uint256 projectId,
        IERC20 token,
        uint256 tokenCount,
        address creator,
        uint256 creatorTokenCount,
        uint32 creatorVestingDuration
    )
        external;

    /// @notice Send a served lunch's creator the part of their tokens that has vested.
    /// @param projectId The ID of the lunch's project.
    /// @return tokenCount The number of tokens sent.
    function release(uint256 projectId) external returns (uint256 tokenCount);

    /// @notice Fix a lunch's claims at its creation.
    /// @param projectId The ID of the lunch's project.
    /// @param percent The share of the lunch's total token supply its claims get.
    /// @param root The merkle root of the list.
    /// @param vestingDuration The number of seconds over which the claims vest once the lunch is served.
    function setTermsOf(uint256 projectId, uint32 percent, bytes32 root, uint32 vestingDuration) external;
}
