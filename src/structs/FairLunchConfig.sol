// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBSuckerDeploymentConfig} from "@bananapus/omnichain-deployers-v6/src/structs/JBSuckerDeploymentConfig.sol";

/// @notice Everything a creator chooses when making a Fair Lunch. The same values are used on every chain.
/// @custom:member name The name of the lunch's token.
/// @custom:member symbol The symbol of the lunch's token.
/// @custom:member projectUri The metadata URI of the lunch's Juicebox project.
/// @custom:member hostChainId The ID of the chain the lunch takes place on: where the fundraise happens, where the
/// pool lives, and where every buyback and burn happens. Every other chain only collects revenue to send home.
/// @custom:member token The money the lunch raises in on its host chain: `JBConstants.NATIVE_TOKEN` for ETH, or an
/// ERC-20. The same on every chain's copy of the configuration. A copy collects whatever its first sucker maps to it.
/// @custom:member deadline The timestamp after which the fundraise stops accepting payments and the lunch can be
/// served.
/// @custom:member creator The address that receives the kept money, the JBP6 minted by fees, and the vested tokens.
/// @custom:member keepPercent The share of the raise the creator keeps, out of `JBConstants.SPLITS_TOTAL_PERCENT`.
/// @custom:member keepCap The most the creator can keep, in the money's smallest unit, whatever the raise ends up
/// being.
/// @custom:member tokenPercent The creator's share of the total token supply at launch, out of
/// `JBConstants.SPLITS_TOTAL_PERCENT`.
/// @custom:member vestingDuration The number of seconds over which the creator's tokens vest linearly, starting when
/// the lunch is served.
/// @custom:member claimsPercent The share of the total token supply at launch that goes to a list of addresses, out
/// of `JBConstants.SPLITS_TOTAL_PERCENT`. Zero for none.
/// @custom:member claimsRoot The merkle root of that list, as `FairLunchClaims` reads it. Zero for none.
/// @custom:member claimsVestingDuration The number of seconds over which the list's tokens vest linearly, starting
/// when the lunch is served. Zero if they're claimable at once, and zero for no list.
/// @custom:member salt A salt for the token's and suckers' deterministic addresses. It is scoped to the caller, so the
/// same caller using the same salt on each chain gets matching deployments.
/// @custom:member suckerDeploymentConfiguration The suckers connecting this chain's copy of the lunch to the others.
/// The host chain's configuration must not map any tokens; the host maps the native token itself once served.
struct FairLunchConfig {
    string name;
    string symbol;
    string projectUri;
    uint64 hostChainId;
    address token;
    uint48 deadline;
    address creator;
    uint32 keepPercent;
    uint104 keepCap;
    uint32 tokenPercent;
    uint32 vestingDuration;
    uint32 claimsPercent;
    bytes32 claimsRoot;
    uint32 claimsVestingDuration;
    bytes32 salt;
    JBSuckerDeploymentConfig suckerDeploymentConfiguration;
}
