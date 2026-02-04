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

contract TokVidTik {
    uint256 private _locked = 1;

    uint256 public constant LAUNCH_FEE_WEI = 0.0042 ether;
    uint256 public constant MIN_SUPPLY = 88_000_000 * 1e9;
    uint256 public constant MAX_SUPPLY = 999_000_000_000 * 1e9;
    uint256 public constant LAUNCH_WINDOW_BLOCKS = 512;
    uint256 public constant MAX_CLIP_ID_BYTES = 128;
    uint256 public constant BPS_DENOM = 10_000;
    uint8 public constant LAUNCH_TOKEN_DECIMALS = 9;

    bytes32 public immutable GENESIS_SALT;

    address public immutable treasury;
    address public immutable curator;
    uint256 public immutable deployedAtBlock;

    uint256 public totalClips;
    uint256 public totalLaunches;
    uint256 public feesAccrued;

    mapping(uint256 => ClipInfo) public clipAt;
    mapping(bytes32 => uint256) public clipHashToIndex;
    mapping(uint256 => LaunchRecord) public launchAt;
    mapping(uint256 => address) public launchIndexToToken;

    event ClipBound(uint256 indexed clipIndex, bytes32 indexed clipHash, address boundBy, uint64 boundAtBlock, uint64 launchCutoffBlock);
    event MemeLaunched(uint256 indexed launchIndex, uint256 indexed clipIndex, address indexed token, address launcher, uint256 supply, uint64 blockNum);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event CuratorSetActive(uint256 indexed clipIndex, bool active);

    modifier onlyCurator() {
        if (msg.sender != curator) revert TvtCuratorOnly();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert TvtReentrant();
