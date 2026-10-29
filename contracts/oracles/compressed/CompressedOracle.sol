// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Codebook256} from "../utils/Codebook256.sol";
import {U64x32} from "../utils/U64x32.sol";

import {OracleBase} from "./OracleBase.sol";

import {TimeMs, toTimeMs} from "../utils/TimeMs.sol";
import {ICompressedOracleV1} from "../../interfaces/ICompressedOracleV1.sol";

/// @notice Registrationless compressed oracle: a feed's LOCATION is its identity.
///         There is no feed registry — the feedId packs (creator, chainid, slotIndex,
///         positionIndex) and every read decodes its coordinates straight from the id:
///
///           feedId = creator << 96 | block.chainid << 16 | slotIndex << 8 | positionIndex
///
///         A creator owns 256 slots × 4 positions in their own namespace and simply
///         pushes into them (directly, or through pushers delegated via `allowPushers`).
///         A never-pushed position reads as price 0 / timestamp 0, which every consumer
///         already rejects as stale — no seeding or creation step is needed.
contract CompressedOracleV1 is OracleBase, ICompressedOracleV1 {
    /// @notice Oracle family discriminator for off-chain introspection (matches the
    ///         pusher/console `kind` vocabulary).
    string public constant kind = "compressed";

    mapping(address => address) public namespaceRemapping;

    uint256 private constant MAX_PER_SLOT = 4;

    uint256 private constant X48 = 0xFFFFFFFFFFFF;
    uint256 private constant X56 = 0xFFFFFFFFFFFFFF;
    uint256 private constant X80 = 0xFFFFFFFFFFFFFFFFFFFF;

    constructor(address _owner, uint256 maxTimeDrift) OracleBase(_owner, maxTimeDrift) {
        // feedIds reserve 80 bits for the chain id (EIP-2294 caps real ids well below).
        require(block.chainid <= X80);
    }

    /*
     *
     * feedId codec
     *
     */

    /// bits [255:96] creator, [95:16] chainid, [15:8] slotIndex, [7:0] positionIndex.
    function feedIdOf(address creator, uint8 slotIndex, uint8 positionIndex) public view returns (bytes32) {
        return bytes32(
            uint256(uint160(creator)) << 96 | block.chainid << 16 | uint256(slotIndex) << 8 | positionIndex
        );
    }

    /// Decodes and VALIDATES a feedId: a foreign-chain id or an out-of-range position
    /// does not exist on this oracle, exactly like an unregistered feed used to.
    function _unpackFeedId(bytes32 feedId)
        internal
        view
        returns (address creator, uint8 slotIndex, uint8 positionIndex)
    {
        uint256 raw = uint256(feedId);
        require((raw >> 16) & X80 == block.chainid, FeedNotFound(feedId));
        positionIndex = uint8(raw);
        require(positionIndex < MAX_PER_SLOT, FeedNotFound(feedId));
        slotIndex = uint8(raw >> 8);
        creator = address(uint160(raw >> 96));
        require(creator != address(0), FeedNotFound(feedId));
    }

    /// Guard authority before an explicit stateGuard is accepted = the feed's creator,
    /// decoded from the feedId itself.
    function _defaultGuard(bytes32 feedId) internal view override returns (address creator) {
        (creator,,) = _unpackFeedId(feedId);
    }

    /*
     *
     * Views
     *
     */

    function getSlotLayout(bytes32 feedId) external view override returns (SlotLayout memory _layout) {
        (address creator, uint8 slotIndex,) = _unpackFeedId(feedId);
        _layout = _loadSlotLayout(_oracleSlot(creator, slotIndex));
    }

    function getCompressedOracle(bytes32 feedId)
        external
        view
        override
        returns (CompressedOracleData memory data, TimeMs timestamp)
    {
        (address creator, uint8 slotIndex, uint8 positionIndex) = _unpackFeedId(feedId);
        SlotLayout memory _layout = _loadSlotLayout(_oracleSlot(creator, slotIndex));

        data = _selectCompressedData(_layout, positionIndex);
        timestamp = _layout.timestampMs;
    }

    function getOracleData(bytes32 feedId) public view override returns (OracleData memory data) {
        (address creator, uint8 slotIndex, uint8 positionIndex) = _unpackFeedId(feedId);

        SlotLayout memory _layout = _loadSlotLayout(_oracleSlot(creator, slotIndex));
        CompressedOracleData memory compressed = _selectCompressedData(_layout, positionIndex);

        if (compressed.s1 == 0xff && compressed.s0 == 0xff) {
            data.spread1 = BPS_BASE;
            data.spread0 = BPS_BASE;
            return data;
        }

        data.price = U64x32.decode(compressed.p);
        data.spread0 = _decodeCodebookIndex(compressed.s0);
        data.spread1 = _decodeCodebookIndex(compressed.s1);
        data.timestampMs = _layout.timestampMs;
    }

    function _loadSlotLayout(bytes32 slotIndex) internal view returns (SlotLayout memory _layout) {
        uint256 slotValue;
        assembly ("memory-safe") {
            slotValue := sload(slotIndex)
        }

        _layout.timestampMs = toTimeMs(slotValue >> 8 & X56);

        _layout.oracle0 = _decodeCompressedOracleData(uint48((slotValue >> 208) & X48));
        _layout.oracle1 = _decodeCompressedOracleData(uint48((slotValue >> 160) & X48));
        _layout.oracle2 = _decodeCompressedOracleData(uint48((slotValue >> 112) & X48));
        _layout.oracle3 = _decodeCompressedOracleData(uint48((slotValue >> 64) & X48));
    }

    function _selectCompressedData(SlotLayout memory _layout, uint8 index)
        internal
        pure
        returns (CompressedOracleData memory data)
    {
        if (index == 0) return _layout.oracle0;
        if (index == 1) return _layout.oracle1;
        if (index == 2) return _layout.oracle2;
        if (index == 3) return _layout.oracle3;
        revert InvalidPosition(index);
    }

    function _decodeCompressedOracleData(uint48 raw) internal pure returns (CompressedOracleData memory data) {
        data.p = uint32(raw >> 16);
        data.s0 = uint8((raw >> 8) & 0xFF);
        data.s1 = uint8(raw & 0xFF);
    }

    function _encodeCompressedOracleData(CompressedOracleData memory data) internal pure returns (uint48 raw) {
        raw = (uint48(data.p) << 16) | (uint48(data.s0) << 8) | uint48(data.s1);
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
        returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime)
    {
        return _price(feedId);
    }

    function _price(bytes32 feedId)
        internal
        view
        returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime)
    {
        OracleData memory data = getOracleData(feedId);
        return (uint256(data.price), uint256(data.spread0), data.spread1, data.timestampMs.toSeconds());
    }

    /*
     *
     * Pusher delegation
     *
     */

    /// @notice Delegates pusher wallets into the caller's namespace. The pusher's EIP-191
    ///         signature is REQUIRED — without it anyone could remap a foreign pusher
    ///         wallet into their own namespace and silently swallow its pushes. The
    ///         deadline is likewise required: the signed consent carries no timestamp of
    ///         its own, so an undated signature could re-establish a delegation AFTER the
    ///         pusher revoked it.
    function allowPushers(uint256 deadline, address[] calldata pushers, bytes[] memory signatures) external {
        _ensureDeadline(deadline);

        uint256 l = pushers.length;
        require(l == signatures.length);
        for (uint256 i; i < l; i++) {
            address pusher = pushers[i];

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

    /// @notice Contract-pusher variant: consent is proven by a LIVE `isPusher(creator)`
    ///         staticcall instead of a signature, so there is nothing to replay and no
    ///         deadline is needed.
    function allowContractPushers(address[] calldata pushers) external {
        uint256 l = pushers.length;
        for (uint256 i; i < l; i++) {
            address pusher = pushers[i];

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

    /// @notice Allows a pusher to self-revoke their delegation. After revocation the
    ///         wallet pushes into its OWN namespace again (the registrationless default).
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
                revert NoSelfRemapping();
            }

            if (namespaceRemapping[pusher] == msg.sender) {
                namespaceRemapping[pusher] = address(0);
                emit PusherRevoked(pusher, msg.sender);
            } else {
                revert InvalidManager(msg.sender);
            }
        }
    }

    /*
     *
     * Push paths
     *
     */

    /// @notice Single-slot update authorized by the creator's signature. The signed slot
    ///         word carries its own 56-bit timestamp, so replay is neutralized by the
    ///         monotonicity check below — no deadline is needed.
    function updateBySignature(address feedCreator, uint256 newSlotValue, bytes calldata signature)
        external
        override
        returns (bool)
    {
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
            keccak256(abi.encode(block.chainid, address(this), feedCreator, newSlotValue))
        );
        require(feedCreator == ECDSA.recover(hash, signature));

        _writeStorage(key, bytes32(newSlotValue & ~uint256(0xff)));

        return true;
    }

    /// @notice Push path. Calldata = N × 32-byte slot words:
    ///         [data0:6][data1:6][data2:6][data3:6][ts:7][slotId:1]
    ///         The sender pushes into `namespaceRemapping[msg.sender]`, falling back to
    ///         its OWN namespace — a creator needs zero setup transactions to start
    ///         pushing. Each word carries its own timestamp (monotonicity is the only
    ///         freshness gate), so there is no deadline prefix.
    fallback() override external {
        uint256 end;
        uint256 namespace;

        address creator = namespaceRemapping[msg.sender];
        if (creator == address(0)) creator = msg.sender;

        assembly ("memory-safe") {
            end := calldatasize()
            namespace := shl(96, creator) // [creator:20][zeros:12]
        }

        // 4 * 6 + 7 + 1 = 32 bytes per slot
        if (end == 0 || end % 32 != 0) revert BadCalldataLength();

        for (uint256 ptr = 0; ptr < end; ptr += 32) {
            uint256 word;
            assembly ("memory-safe") {
                word := calldataload(ptr)
            }
            // casting to 'uint8' is safe we want LSB
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 slotId = uint8(word);
            TimeMs timestampMs = toTimeMs(word >> 8 & X56);
            timestampMs.revertIfAfterBlockTimeWithDrift(MAX_TIME_DRIFT);
            bytes32 key = bytes32(namespace | uint256(slotId));
            uint256 old = uint256(_loadStorage(key));
            TimeMs oldTimestampMs = toTimeMs(old >> 8 & X56);

            bool newer = timestampMs.isAfter(oldTimestampMs);
            if (!newer) continue;

            _writeStorage(key, bytes32(bytes32(word & ~uint256(0xff))));
        }
    }

    /*
     *
     * Internals
     *
     */

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

    function _oracleSlot(address creator, uint8 slotIndex) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            slot := or(shl(96, creator), slotIndex)
        }
    }
}
