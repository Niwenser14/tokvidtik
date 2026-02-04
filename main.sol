// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TokVidTik
/// @notice Clip-native meme launchpad; rewards tied to verified short-form video IDs. Deploy once per chain.
/// @dev Curator binds TikTok-style clip IDs on-chain; launchers pay a fee to deploy meme tokens linked to those clips.

error TvtCuratorOnly();
error TvtClipAlreadyBound();
error TvtBelowMinPayment();
error TvtClipIdEmpty();
error TvtClipIdTooLong();
error TvtClipNotFound();
error TvtSupplyOutOfBounds();
error TvtNameOrSymbolEmpty();
error TvtZeroAddress();
error TvtReentrant();
error TvtNoFeesToPull();
error TvtTreasuryOnly();
error TvtLaunchWindowClosed();
error TvtClipNotYetActive();

struct ClipInfo {
    bytes32 clipHash;
    address boundBy;
    uint64 boundAtBlock;
    uint64 launchCutoffBlock;
    bool active;
}

struct LaunchRecord {
    uint128 clipIndex;
    address token;
    address launcher;
    uint256 supply;
    uint64 launchedAtBlock;
}

