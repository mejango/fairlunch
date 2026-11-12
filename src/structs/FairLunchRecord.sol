// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice What Fair Lunch remembers about a lunch. The first seven members are written once at creation and the last
/// three once when the lunch is served. Nothing can change them afterwards.
/// @custom:member hostChainId The ID of the chain the lunch takes place on.
/// @custom:member token The money this chain's project takes: `JBConstants.NATIVE_TOKEN` for ETH, or an ERC-20.
/// @custom:member deadline The timestamp after which the fundraise stops and the lunch can be served.
/// @custom:member servedAt The timestamp at which the lunch was served. Zero until then, and always zero on chains
/// other than the host.
/// @custom:member creator The address that receives the kept money, the JBP6 minted by fees, and the vested tokens.
/// @custom:member keepPercent The share of the raise the creator keeps, out of `JBConstants.SPLITS_TOTAL_PERCENT`.
/// @custom:member keepCap The most the creator can keep, in the money's smallest unit.
/// @custom:member tokenPercent The creator's share of the total token supply at launch, out of
/// `JBConstants.SPLITS_TOTAL_PERCENT`.
/// @custom:member vestingDuration The number of seconds over which the creator's tokens vest.
/// @custom:member vestingWallet The wallet holding the creator's vesting tokens. Zero if there are none.
/// @custom:member positionId The ID of the lunch's Uniswap V4 liquidity position, which `FairLunchPool` holds forever.
struct FairLunchRecord {
    uint64 hostChainId;
    address token;
    uint48 deadline;
    uint48 servedAt;
    address creator;
    uint32 keepPercent;
    uint104 keepCap;
    uint32 tokenPercent;
    uint32 vestingDuration;
    address vestingWallet;
    uint256 positionId;
}
