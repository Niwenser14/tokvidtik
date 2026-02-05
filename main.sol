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
    }

    /// @notice Toggle whether new launches are allowed for a clip (curator only).
    function setClipActive(uint256 clipIndex_, bool active_) external onlyCurator {
        ClipInfo storage c = clipAt[clipIndex_];
        if (c.boundAtBlock == 0) revert TvtClipNotFound();
        c.active = active_;
        emit CuratorSetActive(clipIndex_, active_);
    }

    /// @notice Launch a meme token tied to a previously bound clip. Caller pays LAUNCH_FEE_WEI.
    function launchMeme(
        uint256 clipIndex_,
        string calldata name_,
        string calldata symbol_,
        uint256 supply_
    ) external payable nonReentrant returns (address token, uint256 launchIndex) {
        if (msg.value < LAUNCH_FEE_WEI) revert TvtBelowMinPayment();
        if (supply_ < MIN_SUPPLY || supply_ > MAX_SUPPLY) revert TvtSupplyOutOfBounds();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert TvtNameOrSymbolEmpty();
        ClipInfo storage c = clipAt[clipIndex_];
        if (c.boundAtBlock == 0) revert TvtClipNotFound();
        if (!c.active) revert TvtClipNotYetActive();
        if (block.number > c.launchCutoffBlock) revert TvtLaunchWindowClosed();

        feesAccrued += LAUNCH_FEE_WEI;
        launchIndex = ++totalLaunches;

        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, msg.sender, totalLaunches, GENESIS_SALT));
        token = address(
            new MemeToken{salt: salt}(
                name_,
                symbol_,
                supply_,
                LAUNCH_TOKEN_DECIMALS,
                msg.sender
            )
        );

        launchAt[launchIndex] = LaunchRecord({
            clipIndex: uint128(clipIndex_),
            token: token,
            launcher: msg.sender,
            supply: supply_,
            launchedAtBlock: uint64(block.number)
        });
        launchIndexToToken[launchIndex] = token;

        emit MemeLaunched(launchIndex, clipIndex_, token, msg.sender, supply_, uint64(block.number));

        uint256 refund = msg.value - LAUNCH_FEE_WEI;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "Tvt: refund failed");
        }
    }

    /// @notice Pull accrued launch fees to the treasury.
    function withdrawFees() external nonReentrant {
        if (msg.sender != treasury) revert TvtTreasuryOnly();
        uint256 amount = feesAccrued;
        if (amount == 0) revert TvtNoFeesToPull();
        feesAccrued = 0;
        (bool ok,) = treasury.call{value: amount}("");
        require(ok, "Tvt: transfer failed");
        emit FeesWithdrawn(treasury, amount);
    }

    /// @notice Check if a clip is still open for new launches (active and before cutoff block).
    function isClipOpenForLaunch(uint256 clipIndex_) external view returns (bool) {
        ClipInfo storage c = clipAt[clipIndex_];
        return c.boundAtBlock != 0 && c.active && block.number <= c.launchCutoffBlock;
    }

    /// @notice Get clip metadata by index.
    function getClip(uint256 clipIndex_) external view returns (ClipInfo memory) {
        return clipAt[clipIndex_];
    }

    /// @notice Get launch metadata by index.
    function getLaunch(uint256 launchIndex_) external view returns (LaunchRecord memory) {
        return launchAt[launchIndex_];
    }

    /// @notice Resolve token address for a launch index.
    function tokenByLaunch(uint256 launchIndex_) external view returns (address) {
        return launchIndexToToken[launchIndex_];
    }

    /// @notice Number of launches tied to a given clip.
    function launchCountForClip(uint256 clipIndex_) external view returns (uint256 count) {
        for (uint256 i = 1; i <= totalLaunches; ) {
            if (launchAt[i].clipIndex == clipIndex_) count++;
            unchecked { ++i; }
        }
    }

    /// @notice Fetch launch indices for a clip (bounded by maxReturn).
    function launchIndicesForClip(uint256 clipIndex_, uint256 maxReturn) external view returns (uint256[] memory indices) {
        uint256 n = 0;
        for (uint256 i = 1; i <= totalLaunches && n < maxReturn; ) {
            if (launchAt[i].clipIndex == clipIndex_) n++;
            unchecked { ++i; }
        }
        indices = new uint256[](n);
        uint256 j = 0;
        for (uint256 i = 1; i <= totalLaunches && j < n; ) {
            if (launchAt[i].clipIndex == clipIndex_) {
                indices[j] = i;
                j++;
            }
            unchecked { ++i; }
        }
    }

    /// @notice Batch-fetch clip info for a range of indices (inclusive start, exclusive end; cap at 64).
    function getClipsBatch(uint256 startIndex_, uint256 endIndex_) external view returns (ClipInfo[] memory out) {
        if (endIndex_ > totalClips) endIndex_ = totalClips + 1;
        if (startIndex_ >= endIndex_) return out;
        uint256 cap = endIndex_ - startIndex_;
        if (cap > 64) cap = 64;
        out = new ClipInfo[](cap);
        for (uint256 i = 0; i < cap; ) {
            out[i] = clipAt[startIndex_ + i];
            unchecked { ++i; }
        }
    }

    /// @notice Batch-fetch launch records for a range of indices (inclusive start, exclusive end; cap at 32).
    function getLaunchesBatch(uint256 startIndex_, uint256 endIndex_) external view returns (LaunchRecord[] memory out) {
        if (endIndex_ > totalLaunches) endIndex_ = totalLaunches + 1;
        if (startIndex_ >= endIndex_) return out;
        uint256 cap = endIndex_ - startIndex_;
        if (cap > 32) cap = 32;
        out = new LaunchRecord[](cap);
        for (uint256 i = 0; i < cap; ) {
            out[i] = launchAt[startIndex_ + i];
            unchecked { ++i; }
        }
    }

    /// @notice Returns config constants for frontends.
    function getConfig() external pure returns (
        uint256 launchFeeWei,
        uint256 minSupply,
        uint256 maxSupply,
        uint256 launchWindowBlocks,
        uint256 maxClipIdBytes
    ) {
        return (
            LAUNCH_FEE_WEI,
            MIN_SUPPLY,
            MAX_SUPPLY,
            LAUNCH_WINDOW_BLOCKS,
            MAX_CLIP_ID_BYTES
        );
    }

    receive() external payable {
        revert TvtBelowMinPayment();
    }
}

contract MemeToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

