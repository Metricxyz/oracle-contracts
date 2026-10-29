// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Codebook256} from "../utils/Codebook256.sol";
import {U64x32} from "../utils/U64x32.sol";

import {OracleBase} from "./OracleBase.sol";

import {TimeMs, toTimeMs} from "../utils/TimeMs.sol";
import {ICompressedOracleV1} from "../../interfaces/ICompressedOracleV1.sol";

contract CompressedOracleV1 is OracleBase, ICompressedOracleV1 {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeCast for uint256;

    mapping(address => RegistryInfo) private $;
    mapping(address => address) public namespaceRemapping;
    EnumerableSet.Bytes32Set private slotKeys;

    // Per-slot occupancy: bit 7 = explicitly set, bits 0-3 = position bitmap
    mapping(bytes32 => uint8) private _slotOccupancy;

    // COMPRESSED_DATA_SIZE_BITS = 32 + 8 + 8; // uint32 + uint8 + uint8
    // METADATA_LENGTH = 8 + 32; // uint8 + uint32
    uint256 private constant MAX_PER_SLOT = 4; // (256 - METADATA_LENGTH) // COMPRESSED_DATA_SIZE_BITS
    uint256 private constant MAX_SLOTS_PER_CREATOR = 255;

    uint256 private constant X8 = 0xFF;
    uint256 private constant X16 = 0xFFFF;
    uint256 private constant X32 = 0xFFFFFFFF;
    uint256 private constant X48 = 0xFFFFFFFFFFFF;
    uint256 private constant X56 = 0xFFFFFFFFFFFFFF;
    uint256 private constant X64 = 0xFFFFFFFFFFFFFFFF;

    uint48 private constant DEFAULT_ORACLE_DATA_VALUE = 0x00000000FFFF; // price = 0, spread = 10_000, volatility = 10_000
    uint32 private constant DEFAULT_TIMESTAMP = 0; // sentinel forces deadline checks to fail


    constructor(address _owner, uint256 maxTimeDrift) OracleBase(_owner, maxTimeDrift) {
    }

    /*
     *
     * Views
     * 
     */


    function getSlotLayout(bytes32 feedId) external view override returns (SlotLayout memory layout) {
        OracleInfo memory info = getOracleInfo(feedId);
        (address creator, uint8 slotIndex,) = _unpackMisc(info.misc);
        if (creator == address(0)) return layout; // deactivated feed
        layout = _loadSlotLayout(_oracleSlot(creator, slotIndex));
    }

    function getCompressedOracle(bytes32 feedId)
        external
        view
        override
        returns (CompressedOracleData memory data, TimeMs timestamp)
    {
        OracleInfo memory info = getOracleInfo(feedId);
        (address creator, uint8 slotIndex, uint8 positionIndex) = _unpackMisc(info.misc);
        if (creator == address(0)) return (data, timestamp); // deactivated feed
        SlotLayout memory layout = _loadSlotLayout(_oracleSlot(creator, slotIndex));

        data = _selectCompressedData(layout, positionIndex);
        timestamp = layout.timestampMs;
    }

    function _getOracleData(OracleInfo memory info) internal override view returns (OracleData memory data) {
        (address creator, uint8 slotIndex, uint8 positionIndex) = _unpackMisc(info.misc);

        // Deactivated feed: pointer was invalidated to address(0)
        if (creator == address(0)) {
            data.spread = BPS_BASE;
            data.volatility = BPS_BASE;
            return data;
        }

        SlotLayout memory layout = _loadSlotLayout(_oracleSlot(creator, slotIndex));
        CompressedOracleData memory compressed = _selectCompressedData(layout, positionIndex);

        if (compressed.v == 0xff && compressed.s == 0xff) {
            data.volatility = BPS_BASE;
            data.spread = BPS_BASE;
            return data;
        }

        data.price = U64x32.decode(compressed.p);
        data.spread = _decodeCodebookIndex(compressed.s);
        data.volatility = _decodeCodebookIndex(compressed.v);
        data.timestampMs = layout.timestampMs;
    }

    function _loadSlotLayout(bytes32 slotIndex) internal view returns (SlotLayout memory layout) {
        uint256 slotValue;
        assembly ("memory-safe") {
            slotValue := sload(slotIndex)
        }

        layout.timestampMs = toTimeMs(slotValue >> 8 & X56);

        layout.oracle0 = _decodeCompressedOracleData(uint48((slotValue >> 208) & X48));
        layout.oracle1 = _decodeCompressedOracleData(uint48((slotValue >> 160) & X48));
        layout.oracle2 = _decodeCompressedOracleData(uint48((slotValue >> 112) & X48));
        layout.oracle3 = _decodeCompressedOracleData(uint48((slotValue >> 64) & X48));
    }

    function _selectCompressedData(SlotLayout memory layout, uint8 index)
        internal
        pure
        returns (CompressedOracleData memory data)
    {
        if (index == 0) return layout.oracle0;
        if (index == 1) return layout.oracle1;
        if (index == 2) return layout.oracle2;
        if (index == 3) return layout.oracle3;
        revert InvalidPosition(index);
    }

    function _decodeCompressedOracleData(uint48 raw) internal pure returns (CompressedOracleData memory data) {
        data.p = uint32(raw >> 16);
        data.s = uint8((raw >> 8) & 0xFF);
        data.v = uint8(raw & 0xFF);
    }

    function _encodeCompressedOracleData(CompressedOracleData memory data) internal pure returns (uint48 raw) {
        raw = (uint48(data.p) << 16) | (uint48(data.s) << 8) | uint48(data.v);
    }

    function _decodeCodebookIndex(uint8 index) internal pure returns (uint16 value) {
        bool ok;
        (value, ok) = Codebook256.decode(index);
        if (!ok) revert CodebookDecodeFailed(index);
    }

    /// @notice Unified read path shared with the providers oracle. The compressed oracle is open, so
    ///         `pool` is unused (no in-swap binding) and reads are permissionless.
    function price(bytes32 feedId, address /* pool */)
        external
        view
        returns (uint256 mid, uint256 spread, uint16 volatility, uint256 refTime)
    {
        return _price(feedId);
    }

    function _price(bytes32 feedId)
        internal
        view
        feedExists(feedId)
        returns (uint256 mid, uint256 spread, uint16 volatility, uint256 refTime)
    {
        OracleInfo memory info = oracleInfo[feedId];
        OracleData memory data = _getOracleData(info);
        return (uint256(data.price), uint256(data.spread), data.volatility, data.timestampMs.toSeconds());
    }

    /*
     *
     * Main logic
     * 
     */

    /// @dev Caller must call `createOracles` first.
    /// @notice Pusher signature replay is acceptable by design — pushers are trusted
    ///         delegates under the creator's control, used to bypass nonce stacking.
    ///         A replayed signature simply re-registers an already-authorized pusher.
    ///         Creators can revoke pushers at any time via `removePushers()`.
    function allowPushers(uint256 deadline, address[] calldata pushers, bytes[] memory signatures) external {
        _ensureDeadline(deadline);

        uint256 l = pushers.length;
        require(l == signatures.length);
        for (uint256 i; i < l; i++) {
            address pusher = pushers[i];

            if (namespaceRemapping[pusher] == pusher) {
                revert CreatorCannotBeRemapped();
            }

            if (pusher == msg.sender) {
                revert NoSelfRemapping();
            }

            bytes32 hash = MessageHashUtils.toEthSignedMessageHash(
                keccak256(abi.encode(block.chainid, address(this), deadline, pusher, msg.sender))
            );
            require(pusher == ECDSA.recover(hash, signatures[i]));

            namespaceRemapping[pusher] = msg.sender;
            emit PusherAuthorized(pusher, msg.sender);
        }
    }

    /// @dev Caller must call `createOracles` first.
    /// @notice Pusher signature replay is acceptable by design — pushers are trusted
    ///         delegates under the creator's control, used to bypass nonce stacking.
    ///         A replayed signature simply re-registers an already-authorized pusher.
    ///         Creators can revoke pushers at any time via `removePushers()`.
    function allowContractPushers(uint256 deadline, address[] calldata pushers) external {
        _ensureDeadline(deadline);

        uint256 l = pushers.length;
        for (uint256 i; i < l; i++) {
            address pusher = pushers[i];

            if (namespaceRemapping[pusher] == pusher) {
                revert CreatorCannotBeRemapped();
            }

            if (pusher == msg.sender) {
                revert NoSelfRemapping();
            }

            (bool ok, bytes memory res) = pusher.staticcall(abi.encodeWithSignature("isPusher(address)", msg.sender));
            require(ok);
            bool allowed = abi.decode(res, (bool));
            require(allowed);

            namespaceRemapping[pusher] = msg.sender;
            emit PusherAuthorized(pusher, msg.sender);
        }
    }

    /// @notice Allows a pusher to self-revoke their delegation.
    ///         Note: if a creator still holds a valid signature from this pusher,
    ///         `allowPushers()` can re-register the mapping. This is by design —
    ///         pushers exist as trusted nonce-bypass delegates under creator control.
    function revokePusher() external {
        address creator = namespaceRemapping[msg.sender];
        if (creator == address(0) || creator == msg.sender) revert NoSelfRemapping();
        namespaceRemapping[msg.sender] = address(0);
        emit PusherRevoked(msg.sender, creator);
    }

    function removePushers(address[] calldata pushers) external {
        uint256 l = pushers.length;
        for (uint256 i; i < l; i++) {
            address pusher = pushers[i];
            if (pusher == msg.sender) {
                revert CreatorCannotBeRemapped();
            }

            if (namespaceRemapping[pusher] == msg.sender) {
                namespaceRemapping[pusher] = address(0);
                emit PusherRevoked(pusher, msg.sender);
            } else {
                revert InvalidManager(msg.sender);
            }
        }
    }

    function createOracles(CreationRequest[] calldata requests) external override returns (CreationResponse[] memory res) {
        uint256 length = requests.length;
        res = new CreationResponse[](length);
        if (length == 0) return res;

        address baseToken;
        address quoteToken;
        RegistryInfo memory r = $[msg.sender];
        uint256 namespace = uint256(uint160(msg.sender)) << 96;
        namespaceRemapping[msg.sender] = msg.sender;

        if (uint256(r.currentSlotIndex) >= MAX_SLOTS_PER_CREATOR) revert SlotLimitExceeded(msg.sender);

        uint256 slotKey = namespace | r.currentSlotIndex;

        for (uint256 i; i < length; i++) {
            if (uint256(r.currentSlotIndex) >= MAX_SLOTS_PER_CREATOR) revert SlotLimitExceeded(msg.sender);
            (baseToken, quoteToken) =
                (requests[i].baseToken, requests[i].quoteToken);
            if (baseToken == address(0) || quoteToken == address(0) || baseToken == quoteToken) {
                revert BadCreationRequest();
            }

            if (r.nextPositionIndex == 0) {
                // register new slotKey once per slot
                slotKeys.add(bytes32(slotKey));
            }

            bytes32 feedId = keccak256(abi.encodePacked(block.chainid, address(this), slotKey, r.nextPositionIndex));
            feedIds.add(feedId);

            if (requests[i].stateGuard != address(0)) {
                stateGuard[feedId] = requests[i].stateGuard;
            } else {
                stateGuard[feedId] = msg.sender;
            }

            require(requests[i].minPrice < requests[i].maxPrice);
            priceGuard[feedId] = PriceGuard({min: requests[i].minPrice, max: requests[i].maxPrice});

            oracleInfo[feedId] = OracleInfo({
                baseToken: baseToken,
                quoteToken: quoteToken,
                misc: abi.encodePacked(msg.sender, r.currentSlotIndex, r.nextPositionIndex)
            });

            _initializeOracleData(slotKey, r.nextPositionIndex, DEFAULT_ORACLE_DATA_VALUE);

            // Sync explicit occupancy bitmap if set by a prior reorg (deactivate/move/swap).
            // Without this, feeds created after a reorg become ghost entries invisible to
            // _getOccupancy, isFeedActive, and moveFeeds target-free checks.
            {
                bytes32 slotHash = bytes32(slotKey);
                uint8 storedOcc = _slotOccupancy[slotHash];
                if (storedOcc & 0x80 != 0) {
                    _slotOccupancy[slotHash] = storedOcc | uint8(1 << r.nextPositionIndex);
                }
            }

            res[i] = CreationResponse({
                feedId: feedId,
                misc: abi.encodePacked(msg.sender, r.currentSlotIndex, r.nextPositionIndex)
            });

            emit FeedRegistered(
                feedId, 
                baseToken, 
                quoteToken, 
                requests[i].stateGuard, 
                requests[i].minPrice, 
                requests[i].maxPrice, 
                abi.encodePacked(msg.sender, r.currentSlotIndex, r.nextPositionIndex)
            );

            unchecked {
                r.nextPositionIndex += 1;
            }

            if (r.nextPositionIndex == MAX_PER_SLOT) {
                r.nextPositionIndex = 0;
                unchecked {
                    r.currentSlotIndex += 1;
                }

                slotKey = namespace | r.currentSlotIndex;
            }
        }

        $[msg.sender] = r;
    }

    function updateBySignature(address feedCreator, uint256 deadline, uint256 newSlotValue, bytes calldata signature) external override returns (bool) {
        _ensureDeadline(deadline);
        require(feedCreator != address(0), InvalidNamespace());

        uint256 namespace;
        assembly ("memory-safe") {
            namespace := shl(96, feedCreator) // [creator:20][zeros:12]
        }

        uint8 slotId = uint8(newSlotValue); // LSB
        TimeMs timestampMs = toTimeMs(newSlotValue >> 8 & X56);
        timestampMs.revertIfAfterBlockTimeWithDrift(MAX_TIME_DRIFT);
        bytes32 key = bytes32(namespace | uint256(slotId));
        uint256 old = uint256(_loadStorage(key));
        TimeMs oldTimestampMs = toTimeMs(old >> 8 & X56);

        bool newer = timestampMs.isAfter(oldTimestampMs);
        if (!newer) {
            return false;
        }

        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(block.chainid, address(this), feedCreator, deadline, newSlotValue))
        );
        require(feedCreator == ECDSA.recover(hash, signature));

        RegistryInfo memory r = $[feedCreator];
        require(slotId <= r.currentSlotIndex, InvalidSlotIndex());
        require(_isDataValid(r, slotId, newSlotValue), UninializedPush());

        _writeStorage(key, bytes32(newSlotValue & ~uint256(0xff)));

        return true;
    }

    fallback() override external {
        uint256 end;
        uint256 deadline;
        uint256 namespace;

        address creator = namespaceRemapping[msg.sender];
        require(creator != address(0), InvalidNamespace());

        assembly ("memory-safe") {
            deadline := shr(224, calldataload(0)) // first 4 bytes
            end := calldatasize()
            namespace := shl(96, creator) // [creator:20][zeros:12]
        }
        _ensureDeadline(deadline);

        unchecked {
            // 4 * 6 + 7 + 1 = 32 bytes per slot
            if ((end <= 4) || (end - 4) % 32 != 0) revert BadCalldataLength();
        }

        RegistryInfo memory r = $[creator];

        for (uint256 ptr = 4; ptr < end; ptr += 32) {
            uint256 word;
            assembly ("memory-safe") {
                word := calldataload(ptr)
            }
            // casting to 'uint8' is safe we want LSB
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 slotId = uint8(word);
            require(slotId <= r.currentSlotIndex, InvalidSlotIndex());
            TimeMs timestampMs = toTimeMs(word >> 8 & X56);
            timestampMs.revertIfAfterBlockTimeWithDrift(MAX_TIME_DRIFT);
            bytes32 key = bytes32(namespace | uint256(slotId));
            uint256 old = uint256(_loadStorage(key));
            TimeMs oldTimestampMs = toTimeMs(old >> 8 & X56);

            bool newer = timestampMs.isAfter(oldTimestampMs);
            if (!newer) continue;

            require(_isDataValid(r, slotId, word), UninializedPush());

            _writeStorage(key, bytes32(bytes32(word & ~uint256(0xff))));
        }
    }

    /*
     *
     * Slot reorganization
     *
     */

    function deactivateFeeds(bytes32[] calldata feeds) external {
        for (uint256 i; i < feeds.length; i++) {
            bytes32 feedId = feeds[i];
            require(feedIds.contains(feedId), FeedNotFound(feedId));

            OracleInfo memory info = oracleInfo[feedId];
            (address creator, uint8 slotIndex, uint8 pos) = _unpackMisc(info.misc);
            require(msg.sender == creator || hasRole(ADMIN_ROLE, msg.sender), NotCreatorOrOwner());

            bytes32 slot = _oracleSlot(creator, slotIndex);
            uint8 occ = _getOccupancy(creator, slotIndex);
            require(occ & (1 << pos) != 0, PositionEmpty(slotIndex, pos));

            _initializeOracleData(uint256(slot), pos, DEFAULT_ORACLE_DATA_VALUE);
            _slotOccupancy[slot] = 0x80 | (occ & ~uint8(1 << pos));

            // Invalidate pointer so deactivated feed cannot resolve to another
            // feed's data after a subsequent moveFeeds reorg.
            oracleInfo[feedId].misc = abi.encodePacked(address(0), uint8(0), uint8(0));

            emit FeedDeactivated(feedId, slotIndex, pos);
        }
    }

    function moveFeeds(address creator, SlotMoveRequest[] calldata moves) external {
        require(msg.sender == creator || hasRole(ADMIN_ROLE, msg.sender), NotCreatorOrOwner());
        require(namespaceRemapping[creator] == creator, InvalidNamespace());

        RegistryInfo memory r = $[creator];

        for (uint256 i; i < moves.length; i++) {
            bytes32 feedId = moves[i].feedId;
            require(feedIds.contains(feedId), FeedNotFound(feedId));

            OracleInfo memory info = oracleInfo[feedId];
            (address feedCreator, uint8 oldSlotIdx, uint8 oldPos) = _unpackMisc(info.misc);
            require(feedCreator == creator, FeedNotOwnedByCreator(feedId));

            uint8 newSlotIdx = moves[i].targetSlotIndex;
            uint8 newPos = moves[i].targetPositionIndex;
            require(newPos < MAX_PER_SLOT, InvalidTargetPosition(newPos));
            require(newSlotIdx <= r.currentSlotIndex, InvalidSlotIndex());
            // Block moves into unallocated frontier positions — createOracles
            // would overwrite them, causing alias pointers and data loss.
            if (newSlotIdx == r.currentSlotIndex && newPos >= r.nextPositionIndex) {
                revert InvalidTargetPosition(newPos);
            }
            require(!(oldSlotIdx == newSlotIdx && oldPos == newPos), MoveToSamePosition(feedId));

            bytes32 oldSlot = _oracleSlot(creator, oldSlotIdx);
            bytes32 newSlot = _oracleSlot(creator, newSlotIdx);

            // Validate source occupied, target free
            uint8 srcOcc = _getOccupancy(creator, oldSlotIdx);
            uint8 dstOcc = _getOccupancy(creator, newSlotIdx);
            require(srcOcc & (1 << oldPos) != 0, PositionEmpty(oldSlotIdx, oldPos));
            require(dstOcc & (1 << newPos) == 0, PositionOccupied(newSlotIdx, newPos));

            // Copy 48-bit data from source to target
            uint48 data = _readOracleData(oldSlot, oldPos);
            _initializeOracleData(uint256(newSlot), newPos, data);
            _initializeOracleData(uint256(oldSlot), oldPos, DEFAULT_ORACLE_DATA_VALUE);

            // Update occupancy (with explicit flag)
            if (oldSlot == newSlot) {
                _slotOccupancy[oldSlot] = 0x80 | ((srcOcc & ~uint8(1 << oldPos)) | uint8(1 << newPos));
            } else {
                _slotOccupancy[oldSlot] = 0x80 | (srcOcc & ~uint8(1 << oldPos));
                _slotOccupancy[newSlot] = 0x80 | (dstOcc | uint8(1 << newPos));
            }

            // Update data location pointer
            oracleInfo[feedId].misc = abi.encodePacked(creator, newSlotIdx, newPos);

            // Ensure target slot is tracked
            if (!slotKeys.contains(newSlot)) {
                slotKeys.add(newSlot);
            }

            emit FeedMoved(feedId, oldSlotIdx, oldPos, newSlotIdx, newPos);
        }
    }

    function swapFeeds(address creator, SlotSwapRequest[] calldata swaps) external {
        require(msg.sender == creator || hasRole(ADMIN_ROLE, msg.sender), NotCreatorOrOwner());
        require(namespaceRemapping[creator] == creator, InvalidNamespace());

        for (uint256 i; i < swaps.length; i++) {
            bytes32 feedIdA = swaps[i].feedIdA;
            bytes32 feedIdB = swaps[i].feedIdB;
            require(feedIds.contains(feedIdA), FeedNotFound(feedIdA));
            require(feedIds.contains(feedIdB), FeedNotFound(feedIdB));

            OracleInfo memory infoA = oracleInfo[feedIdA];
            OracleInfo memory infoB = oracleInfo[feedIdB];
            (address creatorA, uint8 slotIdxA, uint8 posA) = _unpackMisc(infoA.misc);
            (address creatorB, uint8 slotIdxB, uint8 posB) = _unpackMisc(infoB.misc);
            require(creatorA == creator, FeedNotOwnedByCreator(feedIdA));
            require(creatorB == creator, FeedNotOwnedByCreator(feedIdB));

            bytes32 slotA = _oracleSlot(creator, slotIdxA);
            bytes32 slotB = _oracleSlot(creator, slotIdxB);

            // Verify both positions occupied
            uint8 occA = _getOccupancy(creator, slotIdxA);
            uint8 occB = (slotIdxA == slotIdxB) ? occA : _getOccupancy(creator, slotIdxB);
            require(occA & (1 << posA) != 0, PositionEmpty(slotIdxA, posA));
            require(occB & (1 << posB) != 0, PositionEmpty(slotIdxB, posB));

            // Read data from both positions
            uint48 dataA = _readOracleData(slotA, posA);
            uint48 dataB = _readOracleData(slotB, posB);

            // Write swapped data
            _initializeOracleData(uint256(slotA), posA, dataB);
            _initializeOracleData(uint256(slotB), posB, dataA);

            // Update pointers
            oracleInfo[feedIdA].misc = abi.encodePacked(creator, slotIdxB, posB);
            oracleInfo[feedIdB].misc = abi.encodePacked(creator, slotIdxA, posA);

            emit FeedSwapped(feedIdA, feedIdB, slotIdxA, posA, slotIdxB, posB);
        }
    }

    function getSlotOccupancy(address creator, uint8 slotIndex) external view returns (uint8) {
        return _getOccupancy(creator, slotIndex);
    }

    function isFeedActive(bytes32 feedId) external view feedExists(feedId) returns (bool) {
        OracleInfo memory info = oracleInfo[feedId];
        (address creator, uint8 slotIndex, uint8 pos) = _unpackMisc(info.misc);
        return (_getOccupancy(creator, slotIndex) & (1 << pos)) != 0;
    }

    /*
     *
     * Internals
     *
     */

    function _getOccupancy(address creator, uint8 slotIndex) internal view returns (uint8) {
        bytes32 slot = _oracleSlot(creator, slotIndex);
        uint8 stored = _slotOccupancy[slot];
        if (stored & 0x80 != 0) return stored & 0x0F;

        RegistryInfo memory r = $[creator];
        if (slotIndex < r.currentSlotIndex) return 0x0F;
        if (slotIndex == r.currentSlotIndex) return uint8((1 << r.nextPositionIndex) - 1);
        return 0;
    }

    function _readOracleData(bytes32 slot, uint8 index) internal view returns (uint48 data) {
        assembly ("memory-safe") {
            if gt(index, 3) { revert(0, 0) }
            let shift := add(16, mul(sub(4, index), 48))
            data := and(shr(shift, sload(slot)), 0xFFFFFFFFFFFF)
        }
    }

    function _loadStorage(bytes32 slot) internal view returns (bytes32 s) {
        assembly ("memory-safe") {
            s := sload(slot)
        }
    }

    function _writeStorage(bytes32 slot, bytes32 data) internal {
        assembly ("memory-safe") {
            sstore(slot, data)
        }
    }

    function _initializeOracleData(uint256 slot, uint8 index, uint48 data) internal {
        assembly ("memory-safe") {
            // bounds: index ∈ [0..3]
            if gt(index, 3) { revert(0, 0) }

            // shift: index=0 → [208..255], index=3 → [64..111]
            // 48 = data size, 16 = metadata LSB-padding
            let shift := add(16, mul(sub(4, index), 48))
            let fieldMask := shl(shift, X48)
            let cleared := and(sload(slot), not(fieldMask))
            sstore(slot, or(cleared, shl(shift, data)))
        }
    }

    function _isOracleSlot(bytes32 key) internal view returns (bool ok) {
        return slotKeys.contains(key);
    }

    function _oracleSlot(address creator, uint8 slotIndex) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            slot := or(shl(96, creator), slotIndex)
        }
    }

    function _isDataValid(RegistryInfo memory r, uint8 slotId, uint256 word) internal pure returns (bool ok) {
        if (slotId != r.currentSlotIndex) return true;

        uint256 nextPositionIndex = uint256(r.nextPositionIndex);
        if (nextPositionIndex >= MAX_PER_SLOT) return true;

        uint256 mask;
        if (r.nextPositionIndex == 0) { mask = type(uint256).max; }
        else {
            uint256 shift = (64 + (MAX_PER_SLOT - r.nextPositionIndex) * 48);
            mask = (1 << shift) - 1;
        } 
        uint256 remainder = word & mask & ~uint256(X64);

        return remainder == 0;
    }
    
    function _unpackMisc(bytes memory data) internal pure returns(address creator, uint8 slotIndex, uint8 positionIndex) {
        assembly ("memory-safe") {
            let packed := mload(add(data, 32))   // skip length prefix
            creator := shr(96, packed)           // high 20 bytes → address
            slotIndex := byte(20, packed)        // 21st byte
            positionIndex := byte(21, packed)    // 22nd byte
        }
    }
}