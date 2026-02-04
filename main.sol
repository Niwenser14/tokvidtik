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
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor() {
        treasury = 0x5dA9c8E7f2B4a1D6C9e3F0b8A2d5E7c9F1a4B6D8;
        curator = 0x2F7b4E9aC1d6F3A8e0B5c9D2f7A4e1B8C6d3F0a;
        deployedAtBlock = block.number;
        GENESIS_SALT = keccak256(
            abi.encodePacked(
                block.chainid,
                block.timestamp,
                block.prevrandao,
                address(this),
                "TokVidTik_ClipPad_v1"
            )
        );
    }

    /// @notice Bind a short-form video clip (e.g. TikTok ID) so meme launches can reference it.
    /// @param clipIdUtf8 UTF-8 bytes for the clip identifier (video ID or content hash reference).
    function bindClip(bytes calldata clipIdUtf8) external onlyCurator nonReentrant returns (uint256 clipIndex) {
        if (clipIdUtf8.length == 0) revert TvtClipIdEmpty();
        if (clipIdUtf8.length > MAX_CLIP_ID_BYTES) revert TvtClipIdTooLong();
        bytes32 h = keccak256(abi.encodePacked(clipIdUtf8, GENESIS_SALT));
        if (clipHashToIndex[h] != 0) revert TvtClipAlreadyBound();
        clipIndex = ++totalClips;
        clipHashToIndex[h] = clipIndex;
        uint64 cutoff = uint64(block.number + LAUNCH_WINDOW_BLOCKS);
        clipAt[clipIndex] = ClipInfo({
            clipHash: h,
            boundBy: msg.sender,
            boundAtBlock: uint64(block.number),
            launchCutoffBlock: cutoff,
            active: true
        });
        emit ClipBound(clipIndex, h, msg.sender, uint64(block.number), cutoff);
