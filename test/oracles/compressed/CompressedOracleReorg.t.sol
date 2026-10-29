// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CompressedOracleV1, ICompressedOracleV1} from "../../../contracts/oracles/compressed/CompressedOracle.sol";
import {IOffchainOracle} from "../../../contracts/interfaces/IOffchainOracle.sol";
import {Codebook256} from "../../../contracts/oracles/utils/Codebook256.sol";
import {U64x32} from "../../../contracts/oracles/utils/U64x32.sol";
import {TimeMs, toTimeMs} from "../../../contracts/oracles/utils/TimeMs.sol";

contract CompressedOracleReorgTest is Test {
    CompressedOracleV1 private oracle;

    uint8 private constant MAX_PER_SLOT = 4;
    uint256 private constant X48 = 0xFFFFFFFFFFFF;
    uint256 private constant X56 = 0xFFFFFFFFFFFFFF;
    uint48 private constant DEFAULT_ORACLE_DATA_VALUE = 0x00000000FFFF;

    address private constant CREATOR = address(0xC0FFEE);
    address private constant OTHER = address(0xDEAD);

    function setUp() public {
        oracle = new CompressedOracleV1(address(this), 0);
        vm.warp(1000);
    }

    // ───────────────────────── helpers ─────────────────────────

    function _mkRequest(address base, address quote)
        internal
        pure
        returns (IOffchainOracle.CreationRequest memory req)
    {
        req.baseToken = base;
        req.quoteToken = quote;
        req.minPrice = 0;
        req.maxPrice = type(uint128).max;
    }

    function _createFeeds(address creator, uint256 count) internal returns (IOffchainOracle.CreationResponse[] memory) {
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](count);
        for (uint256 i; i < count; i++) {
            requests[i] = _mkRequest(
                address(uint160(0x1000 + i * 2)),
                address(uint160(0x1001 + i * 2))
            );
        }
        vm.prank(creator);
        return oracle.createOracles(requests);
    }

    function _slotKey(address creator, uint8 slotIndex) internal pure returns (bytes32) {
        uint256 namespace = uint256(uint160(creator)) << 96;
        return bytes32(namespace | uint256(slotIndex));
    }

    function _loadSlot(bytes32 key) internal view returns (bytes32) {
        return vm.load(address(oracle), key);
    }

    function _readRaw48(bytes32 slotKey, uint8 pos) internal view returns (uint48) {
        uint256 word = uint256(_loadSlot(slotKey));
        uint256 shift = 16 + (MAX_PER_SLOT - pos) * 48;
        return uint48((word >> shift) & X48);
    }

    function _unpackMisc(bytes memory data) internal pure returns (address creator, uint8 slotIndex, uint8 positionIndex) {
        assembly ("memory-safe") {
            let packed := mload(add(data, 32))
            creator := shr(96, packed)
            slotIndex := byte(20, packed)
            positionIndex := byte(21, packed)
        }
    }

    function _pushData(address creator, uint8 slotIndex, uint48[4] memory data48) internal {
        uint256 namespace = uint256(uint160(creator)) << 96;

        uint56 tsMs = uint56(block.timestamp * 1000);
        uint256 word = uint256(tsMs) << 8;
        word |= uint256(slotIndex);
        for (uint256 i; i < 4; i++) {
            uint256 shift = 16 + (MAX_PER_SLOT - i) * 48;
            word |= uint256(data48[i]) << shift;
        }

        uint32 deadline = uint32(block.timestamp + 10);
        bytes memory payload = bytes.concat(abi.encodePacked(deadline), abi.encodePacked(word));

        vm.prank(creator);
        (bool ok,) = address(oracle).call(payload);
        require(ok, "push failed");
    }

    function _packRaw(uint32 price, uint8 spreadIdx, uint8 volIdx) internal pure returns (uint48) {
        return (uint48(price) << 16) | (uint48(spreadIdx) << 8) | uint48(volIdx);
    }

    function _findSpreadIndex(uint16 minBps) internal pure returns (uint8 idx) {
        for (uint256 i; i <= type(uint8).max; i++) {
            (uint16 v, bool ok) = Codebook256.decode(uint8(i));
            if (ok && v >= minBps) return uint8(i);
        }
        revert("spread index not found");
    }

    // ═══════════════════════════════════════════════════════════
    //  getSlotOccupancy — default derivation
    // ═══════════════════════════════════════════════════════════

    function testOccupancyDefaultFullSlot() public {
        // Create 5 feeds → slot 0 full (4), slot 1 has 1
        _createFeeds(CREATOR, 5);

        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x0F, "full slot should be 0x0F");
        assertEq(oracle.getSlotOccupancy(CREATOR, 1), 0x01, "current slot with 1 feed should be 0x01");
        assertEq(oracle.getSlotOccupancy(CREATOR, 2), 0x00, "beyond frontier should be 0x00");
    }

    function testOccupancyDefaultPartialSlot() public {
        _createFeeds(CREATOR, 3);

        // 3 feeds in slot 0 (current), positions 0,1,2
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x07, "3 feeds should be 0x07");
    }

    function testOccupancyNoFeeds() public {
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x00);
    }

    // ═══════════════════════════════════════════════════════════
    //  isFeedActive
    // ═══════════════════════════════════════════════════════════

    function testIsFeedActiveTrue() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 1);
        assertTrue(oracle.isFeedActive(res[0].feedId));
    }

    function testIsFeedActiveRevertsUnknownFeed() public {
        bytes32 fake = keccak256("nope");
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, fake));
        oracle.isFeedActive(fake);
    }

    // ═══════════════════════════════════════════════════════════
    //  deactivateFeeds
    // ═══════════════════════════════════════════════════════════

    function testDeactivateClearsDataAndOccupancy() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 4);
        bytes32 feedId = res[1].feedId; // position 1

        vm.prank(CREATOR);
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = feedId;
        oracle.deactivateFeeds(feeds);

        // occupancy
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x0D, "bit 1 should be cleared"); // 1111 & ~0010 = 1101
        assertFalse(oracle.isFeedActive(feedId), "feed should be inactive");

        // raw data should be default
        uint48 raw = _readRaw48(_slotKey(CREATOR, 0), 1);
        assertEq(raw, DEFAULT_ORACLE_DATA_VALUE, "position data should be default");
    }

    function testDeactivateEmitsEvent() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 2);
        bytes32 feedId = res[0].feedId;

        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = feedId;

        vm.expectEmit(true, false, false, true);
        emit ICompressedOracleV1.FeedDeactivated(feedId, 0, 0);

        vm.prank(CREATOR);
        oracle.deactivateFeeds(feeds);
    }

    function testDeactivatePriceReturnsInvalid() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 4);

        // push real data first
        uint8 sIdx = _findSpreadIndex(5);
        uint48 realData = _packRaw(1_000_000, sIdx, sIdx);
        uint48[4] memory data48 = [realData, realData, realData, realData];
        _pushData(CREATOR, 0, data48);

        bytes32 feedId = res[2].feedId;
        // before deactivation, price should return valid
        (uint256 bidBefore,,,) = oracle.price(feedId, address(0));
        assertGt(bidBefore, 0, "should have valid price before deactivation");

        // deactivate
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(feeds);

        // after deactivation, pointer is invalidated — returns stall sentinel
        (uint256 mid, uint256 spread, uint16 vol,) = oracle.price(feedId, address(0));
        assertEq(mid, 0, "mid should be 0");
        assertEq(spread, 10_000, "spread should be BPS_BASE (deactivated sentinel)");
        assertEq(vol, 10_000, "vol should be BPS_BASE (deactivated sentinel)");
    }

    function testDeactivateMultipleFeeds() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 4);

        bytes32[] memory feeds = new bytes32[](3);
        feeds[0] = res[0].feedId;
        feeds[1] = res[2].feedId;
        feeds[2] = res[3].feedId;

        vm.prank(CREATOR);
        oracle.deactivateFeeds(feeds);

        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x02, "only position 1 active"); // 0010
        assertFalse(oracle.isFeedActive(res[0].feedId));
        assertTrue(oracle.isFeedActive(res[1].feedId));
        assertFalse(oracle.isFeedActive(res[2].feedId));
        assertFalse(oracle.isFeedActive(res[3].feedId));
    }

    function testDeactivateByOwner() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 1);

        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = res[0].feedId;

        // owner (address(this)) can deactivate
        oracle.deactivateFeeds(feeds);
        assertFalse(oracle.isFeedActive(res[0].feedId));
    }

    function testDeactivateRevertsNotCreatorOrOwner() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 1);

        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = res[0].feedId;

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.NotCreatorOrOwner.selector));
        oracle.deactivateFeeds(feeds);
    }

    function testDeactivateRevertsUnknownFeed() public {
        bytes32 fake = keccak256("missing");
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = fake;

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, fake));
        oracle.deactivateFeeds(feeds);
    }

    function testDeactivateRevertsAlreadyDeactivated() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 1);

        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = res[0].feedId;

        vm.prank(CREATOR);
        oracle.deactivateFeeds(feeds);

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.NotCreatorOrOwner.selector));
        oracle.deactivateFeeds(feeds);
    }

    // ═══════════════════════════════════════════════════════════
    //  moveFeeds
    // ═══════════════════════════════════════════════════════════

    function testMoveUpdatesPointerAndOccupancy() public {
        // Create 5 feeds: slot 0 full [0,1,2,3], slot 1 has [0]
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 5);

        // Push data to slot 0 so position 2 has real data
        uint8 sIdx = _findSpreadIndex(5);
        uint48 realData = _packRaw(500_000, sIdx, sIdx);
        uint48[4] memory data48 = [realData, realData, realData, realData];
        _pushData(CREATOR, 0, data48);

        // Deactivate feed at slot 1 pos 0 to free it
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[4].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Deactivate feed at slot 0 pos 3 to free a position
        deactFeeds[0] = res[3].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Move feed[2] (slot 0, pos 2) → (slot 0, pos 3)
        bytes32 feedId = res[2].feedId;
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 3
        });

        vm.prank(CREATOR);
        oracle.moveFeeds(CREATOR, moves);

        // Verify misc pointer updated
        IOffchainOracle.OracleInfo memory info = oracle.getOracleInfo(feedId);
        (, uint8 newSlot, uint8 newPos) = _unpackMisc(info.misc);
        assertEq(newSlot, 0, "should be in slot 0");
        assertEq(newPos, 3, "should be at position 3");

        // Verify occupancy: slot 0 had 0x0F, deactivated pos 3 → 0x07, moved pos 2→3 → 0x0B (1011)
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x0B);

        // Verify data at new position
        uint48 raw = _readRaw48(_slotKey(CREATOR, 0), 3);
        assertEq(raw, realData, "data should be at new position");

        // Verify old position cleared
        uint48 oldRaw = _readRaw48(_slotKey(CREATOR, 0), 2);
        assertEq(oldRaw, DEFAULT_ORACLE_DATA_VALUE, "old position should be default");
    }

    function testMoveEmitsEvent() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 5);

        // Deactivate slot 1 pos 0
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[4].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Move feed[0] (slot 0, pos 0) → (slot 1, pos 0)
        bytes32 feedId = res[0].feedId;
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: feedId,
            targetSlotIndex: 1,
            targetPositionIndex: 0
        });

        vm.expectEmit(true, false, false, true);
        emit ICompressedOracleV1.FeedMoved(feedId, 0, 0, 1, 0);

        vm.prank(CREATOR);
        oracle.moveFeeds(CREATOR, moves);
    }

    function testMovePriceReadsFromNewPosition() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 5);

        // Push distinct data to slot 0
        uint8 sIdx = _findSpreadIndex(5);
        uint48 dataA = _packRaw(1_000_000, sIdx, sIdx);
        uint48 dataB = _packRaw(2_000_000, sIdx, sIdx);
        uint48[4] memory slot0Data = [dataA, dataB, dataA, dataA];
        _pushData(CREATOR, 0, slot0Data);

        // Deactivate feed at slot 1 pos 0
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[4].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Move feed[1] (slot 0, pos 1, has dataB) → (slot 1, pos 0)
        bytes32 feedId = res[1].feedId;
        (uint256 bidBefore,,,) = oracle.price(feedId, address(0));
        assertGt(bidBefore, 0, "should have valid price before move");

        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: feedId,
            targetSlotIndex: 1,
            targetPositionIndex: 0
        });

        vm.prank(CREATOR);
        oracle.moveFeeds(CREATOR, moves);

        // The data (dataB) should have been copied to slot 1 pos 0
        // But slot 1 timestamp is 0 (no push yet), so price returns refTime=0 but data is there
        ICompressedOracleV1.CompressedOracleData memory compressed;
        TimeMs ts;
        (compressed, ts) = oracle.getCompressedOracle(feedId);
        assertEq(compressed.p, uint32(dataB >> 16), "price data should match moved data");
    }

    function testMoveRevertsOccupiedTarget() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 4);

        // Move feed[0] → (slot 0, pos 1) which is occupied
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[0].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 1
        });

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.PositionOccupied.selector, 0, 1));
        oracle.moveFeeds(CREATOR, moves);
    }

    function testMoveRevertsBeyondFrontier() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 4);

        // Deactivate one to have a free position
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[3].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // slot 0 is currentSlotIndex (it was filled but nextPositionIndex wrapped → currentSlotIndex=1)
        // Actually with 4 feeds: currentSlotIndex=1, nextPositionIndex=0
        // Try to move to slot 5 which is beyond frontier
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[0].feedId,
            targetSlotIndex: 5,
            targetPositionIndex: 0
        });

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.InvalidSlotIndex.selector));
        oracle.moveFeeds(CREATOR, moves);
    }

    function testMoveRevertsUnknownFeed() public {
        _createFeeds(CREATOR, 1);

        bytes32 fake = keccak256("ghost");
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: fake,
            targetSlotIndex: 0,
            targetPositionIndex: 0
        });

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, fake));
        oracle.moveFeeds(CREATOR, moves);
    }

    function testMoveRevertsFeedNotOwnedByCreator() public {
        IOffchainOracle.CreationResponse[] memory resA = _createFeeds(CREATOR, 1);
        _createFeeds(OTHER, 1);

        // Try to move CREATOR's feed but specify OTHER as creator
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: resA[0].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 0
        });

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.FeedNotOwnedByCreator.selector, resA[0].feedId));
        oracle.moveFeeds(OTHER, moves);
    }

    function testMoveRevertsSamePosition() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 1);

        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[0].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 0
        });

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.MoveToSamePosition.selector, res[0].feedId));
        oracle.moveFeeds(CREATOR, moves);
    }

    function testMoveRevertsInvalidPosition() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 1);

        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[0].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 4 // MAX_PER_SLOT = 4, so 4 is invalid
        });

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.InvalidTargetPosition.selector, 4));
        oracle.moveFeeds(CREATOR, moves);
    }

    function testMoveRevertsNotCreatorOrOwner() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 2);

        // Deactivate pos 1
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[1].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[0].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 1
        });

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.NotCreatorOrOwner.selector));
        oracle.moveFeeds(CREATOR, moves);
    }

    function testMoveByOwner() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 2);

        // Deactivate pos 1
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[1].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[0].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 1
        });

        // Owner (address(this)) moves
        oracle.moveFeeds(CREATOR, moves);

        assertTrue(oracle.isFeedActive(res[0].feedId));
        IOffchainOracle.OracleInfo memory info = oracle.getOracleInfo(res[0].feedId);
        (, uint8 s, uint8 p) = _unpackMisc(info.misc);
        assertEq(s, 0);
        assertEq(p, 1);
    }

    function testMoveRevertsSourceDeactivated() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 2);

        // Deactivate feed[0]
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[0].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Also deactivate feed[1] so pos 1 is free
        deactFeeds[0] = res[1].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Try to move deactivated feed[0] (pos 0) → pos 1
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[0].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 1
        });

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.FeedNotOwnedByCreator.selector, res[0].feedId));
        oracle.moveFeeds(CREATOR, moves);
    }

    // ═══════════════════════════════════════════════════════════
    //  Sequential moves — compaction scenario
    // ═══════════════════════════════════════════════════════════

    function testSequentialCompaction() public {
        // Create 8 feeds: slot 0 [0,1,2,3], slot 1 [0,1,2,3]
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 8);

        // Push distinct data
        uint8 sIdx = _findSpreadIndex(5);
        uint48[4] memory slot0Data = [
            _packRaw(100_000, sIdx, sIdx),
            _packRaw(200_000, sIdx, sIdx),
            _packRaw(300_000, sIdx, sIdx),
            _packRaw(400_000, sIdx, sIdx)
        ];
        uint48[4] memory slot1Data = [
            _packRaw(500_000, sIdx, sIdx),
            _packRaw(600_000, sIdx, sIdx),
            _packRaw(700_000, sIdx, sIdx),
            _packRaw(800_000, sIdx, sIdx)
        ];
        _pushData(CREATOR, 0, slot0Data);
        _pushData(CREATOR, 1, slot1Data);

        // Deactivate feeds 1,2,3 in slot 0 (keep only feed[0])
        bytes32[] memory deactFeeds = new bytes32[](3);
        deactFeeds[0] = res[1].feedId;
        deactFeeds[1] = res[2].feedId;
        deactFeeds[2] = res[3].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Deactivate feeds 5,6 in slot 1 (keep 4 and 7)
        bytes32[] memory deactFeeds2 = new bytes32[](2);
        deactFeeds2[0] = res[5].feedId;
        deactFeeds2[1] = res[6].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds2);

        // Current state:
        // slot 0: [feed0, -, -, -]      occupancy 0x01
        // slot 1: [feed4, -, -, feed7]   occupancy 0x09

        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x01);
        assertEq(oracle.getSlotOccupancy(CREATOR, 1), 0x09);

        // Compact: move feed4 (slot1,pos0) → slot0,pos1; move feed7 (slot1,pos3) → slot0,pos2
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](2);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[4].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 1
        });
        moves[1] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[7].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 2
        });

        vm.prank(CREATOR);
        oracle.moveFeeds(CREATOR, moves);

        // slot 0: [feed0, feed4, feed7, -]  occupancy 0x07
        // slot 1: [-, -, -, -]              occupancy 0x00
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x07);
        assertEq(oracle.getSlotOccupancy(CREATOR, 1), 0x00);

        // Verify data integrity
        uint48 raw4 = _readRaw48(_slotKey(CREATOR, 0), 1);
        assertEq(raw4, slot1Data[0], "feed4 data should be at slot0 pos1");

        uint48 raw7 = _readRaw48(_slotKey(CREATOR, 0), 2);
        assertEq(raw7, slot1Data[3], "feed7 data should be at slot0 pos2");

        // Verify pointers
        IOffchainOracle.OracleInfo memory info4 = oracle.getOracleInfo(res[4].feedId);
        (, uint8 s4, uint8 p4) = _unpackMisc(info4.misc);
        assertEq(s4, 0);
        assertEq(p4, 1);

        IOffchainOracle.OracleInfo memory info7 = oracle.getOracleInfo(res[7].feedId);
        (, uint8 s7, uint8 p7) = _unpackMisc(info7.misc);
        assertEq(s7, 0);
        assertEq(p7, 2);

        // feed0 should still be readable and unchanged
        assertTrue(oracle.isFeedActive(res[0].feedId));
        uint48 raw0 = _readRaw48(_slotKey(CREATOR, 0), 0);
        assertEq(raw0, slot0Data[0], "feed0 data should remain unchanged");
    }

    // ═══════════════════════════════════════════════════════════
    //  Move into deactivated position
    // ═══════════════════════════════════════════════════════════

    function testMoveIntoDeactivatedPosition() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 4);

        uint8 sIdx = _findSpreadIndex(10);
        uint48 dataX = _packRaw(999_999, sIdx, sIdx);
        uint48[4] memory data48 = [dataX, DEFAULT_ORACLE_DATA_VALUE, DEFAULT_ORACLE_DATA_VALUE, DEFAULT_ORACLE_DATA_VALUE];
        _pushData(CREATOR, 0, data48);

        // Deactivate feed[1] at pos 1
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[1].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Move feed[0] (pos 0) → pos 1 (now free)
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[0].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 1
        });

        vm.prank(CREATOR);
        oracle.moveFeeds(CREATOR, moves);

        // Verify data at new position
        uint48 raw = _readRaw48(_slotKey(CREATOR, 0), 1);
        assertEq(raw, dataX, "moved data should match");

        // Verify old position is default
        uint48 oldRaw = _readRaw48(_slotKey(CREATOR, 0), 0);
        assertEq(oldRaw, DEFAULT_ORACLE_DATA_VALUE, "old position should be default");

        // Verify occupancy: was [1,0,1,1]=0x0D after deact, after move [0,1,1,1]=0x0E
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x0E);
    }

    // ═══════════════════════════════════════════════════════════
    //  Cross-creator isolation
    // ═══════════════════════════════════════════════════════════

    function testMoveCrossCreatorIsolation() public {
        IOffchainOracle.CreationResponse[] memory resA = _createFeeds(CREATOR, 2);
        IOffchainOracle.CreationResponse[] memory resB = _createFeeds(OTHER, 2);

        // Deactivate OTHER's feed[1]
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = resB[1].feedId;
        vm.prank(OTHER);
        oracle.deactivateFeeds(deactFeeds);

        // CREATOR tries to move their feed into OTHER's namespace
        // This should revert because feedCreator != creator check
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: resA[0].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 1
        });

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.FeedNotOwnedByCreator.selector, resA[0].feedId));
        oracle.moveFeeds(OTHER, moves);
    }

    // ═══════════════════════════════════════════════════════════
    //  Move with namespace remapping restriction
    // ═══════════════════════════════════════════════════════════

    function testMoveRevertsInvalidNamespace() public {
        // Address that never called createOracles has no namespace
        address nobody = address(0xABCD);

        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](0);

        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.InvalidNamespace.selector));
        oracle.moveFeeds(nobody, moves);
    }

    // ═══════════════════════════════════════════════════════════
    //  Occupancy after explicit set persists through moves
    // ═══════════════════════════════════════════════════════════

    function testOccupancyExplicitFlagPersists() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 4);

        // Deactivate pos 3 → explicit flag set
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[3].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Occupancy should be explicit now
        uint8 occ = oracle.getSlotOccupancy(CREATOR, 0);
        assertEq(occ, 0x07, "should be 0111 after deactivating pos 3");

        // Move feed[2] (pos 2) → pos 3 (freed)
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[2].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 3
        });

        vm.prank(CREATOR);
        oracle.moveFeeds(CREATOR, moves);

        // Occupancy: was 0111, move clears bit 2 and sets bit 3 → 1011
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x0B);

        // Active feeds
        assertTrue(oracle.isFeedActive(res[0].feedId));
        assertTrue(oracle.isFeedActive(res[1].feedId));
        assertTrue(oracle.isFeedActive(res[2].feedId)); // moved to pos 3

        // res[3] was deactivated — its misc pointer was invalidated to address(0),
        // so isFeedActive correctly returns false even though pos 3 is now occupied.
        assertFalse(oracle.isFeedActive(res[3].feedId), "deactivated feed pointer invalidated");
    }

    // ═══════════════════════════════════════════════════════════
    //  Move across slots
    // ═══════════════════════════════════════════════════════════

    function testMoveAcrossSlots() public {
        // Create 8 feeds: slot 0 full, slot 1 full
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 8);

        uint8 sIdx = _findSpreadIndex(5);
        uint48 targetData = _packRaw(777_777, sIdx, sIdx);
        uint48[4] memory slot1Data = [targetData, DEFAULT_ORACLE_DATA_VALUE, DEFAULT_ORACLE_DATA_VALUE, DEFAULT_ORACLE_DATA_VALUE];
        _pushData(CREATOR, 1, slot1Data);

        // Deactivate feed at slot 0 pos 0
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[0].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Move feed[4] (slot 1, pos 0) → (slot 0, pos 0)
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[4].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 0
        });

        vm.prank(CREATOR);
        oracle.moveFeeds(CREATOR, moves);

        // Verify data moved
        uint48 raw = _readRaw48(_slotKey(CREATOR, 0), 0);
        assertEq(raw, targetData, "data should be at slot 0 pos 0");

        // Verify pointer
        IOffchainOracle.OracleInfo memory info = oracle.getOracleInfo(res[4].feedId);
        (, uint8 s, uint8 p) = _unpackMisc(info.misc);
        assertEq(s, 0);
        assertEq(p, 0);

        // Verify occupancies
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x0F, "slot 0 should be full again");
        assertEq(oracle.getSlotOccupancy(CREATOR, 1), 0x0E, "slot 1 should lose pos 0");
    }

    // ═══════════════════════════════════════════════════════════
    //  swapFeeds — atomic swap
    // ═══════════════════════════════════════════════════════════

    function testSwapFeedsBasic() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 4);

        uint8 sIdx = _findSpreadIndex(5);
        uint48 dataA = _packRaw(111_111, sIdx, sIdx);
        uint48 dataB = _packRaw(222_222, sIdx, sIdx);
        uint48[4] memory slot0Data = [dataA, dataB, DEFAULT_ORACLE_DATA_VALUE, DEFAULT_ORACLE_DATA_VALUE];
        _pushData(CREATOR, 0, slot0Data);

        ICompressedOracleV1.SlotSwapRequest[] memory swaps = new ICompressedOracleV1.SlotSwapRequest[](1);
        swaps[0] = ICompressedOracleV1.SlotSwapRequest({
            feedIdA: res[0].feedId,
            feedIdB: res[1].feedId
        });

        vm.prank(CREATOR);
        oracle.swapFeeds(CREATOR, swaps);

        // Data should be swapped
        uint48 rawPos0 = _readRaw48(_slotKey(CREATOR, 0), 0);
        uint48 rawPos1 = _readRaw48(_slotKey(CREATOR, 0), 1);
        assertEq(rawPos0, dataB, "pos 0 should have feed1's data");
        assertEq(rawPos1, dataA, "pos 1 should have feed0's data");

        // Pointers should be swapped
        IOffchainOracle.OracleInfo memory info0 = oracle.getOracleInfo(res[0].feedId);
        (, uint8 s0, uint8 p0) = _unpackMisc(info0.misc);
        assertEq(s0, 0);
        assertEq(p0, 1, "feed0 should be at pos 1");

        IOffchainOracle.OracleInfo memory info1 = oracle.getOracleInfo(res[1].feedId);
        (, uint8 s1, uint8 p1) = _unpackMisc(info1.misc);
        assertEq(s1, 0);
        assertEq(p1, 0, "feed1 should be at pos 0");

        // Occupancy unchanged
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x0F);
    }

    function testSwapFeedsAcrossSlots() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 8);

        uint8 sIdx = _findSpreadIndex(5);
        uint48 dataA = _packRaw(333_333, sIdx, sIdx);
        uint48 dataB = _packRaw(444_444, sIdx, sIdx);
        uint48[4] memory slot0Data = [dataA, DEFAULT_ORACLE_DATA_VALUE, DEFAULT_ORACLE_DATA_VALUE, DEFAULT_ORACLE_DATA_VALUE];
        uint48[4] memory slot1Data = [dataB, DEFAULT_ORACLE_DATA_VALUE, DEFAULT_ORACLE_DATA_VALUE, DEFAULT_ORACLE_DATA_VALUE];
        _pushData(CREATOR, 0, slot0Data);
        _pushData(CREATOR, 1, slot1Data);

        // Swap feed[0] (slot 0 pos 0) with feed[4] (slot 1 pos 0)
        ICompressedOracleV1.SlotSwapRequest[] memory swaps = new ICompressedOracleV1.SlotSwapRequest[](1);
        swaps[0] = ICompressedOracleV1.SlotSwapRequest({
            feedIdA: res[0].feedId,
            feedIdB: res[4].feedId
        });

        vm.prank(CREATOR);
        oracle.swapFeeds(CREATOR, swaps);

        // feed[0] now at slot 1 pos 0 with dataA; feed[4] now at slot 0 pos 0 with dataB
        uint48 rawSlot0 = _readRaw48(_slotKey(CREATOR, 0), 0);
        uint48 rawSlot1 = _readRaw48(_slotKey(CREATOR, 1), 0);
        assertEq(rawSlot0, dataB, "slot0 pos0 should have feed4's data");
        assertEq(rawSlot1, dataA, "slot1 pos0 should have feed0's data");

        IOffchainOracle.OracleInfo memory info0 = oracle.getOracleInfo(res[0].feedId);
        (, uint8 s0, uint8 p0) = _unpackMisc(info0.misc);
        assertEq(s0, 1);
        assertEq(p0, 0);

        IOffchainOracle.OracleInfo memory info4 = oracle.getOracleInfo(res[4].feedId);
        (, uint8 s4, uint8 p4) = _unpackMisc(info4.misc);
        assertEq(s4, 0);
        assertEq(p4, 0);
    }

    function testSwapFeedsEmitsEvent() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 2);

        ICompressedOracleV1.SlotSwapRequest[] memory swaps = new ICompressedOracleV1.SlotSwapRequest[](1);
        swaps[0] = ICompressedOracleV1.SlotSwapRequest({
            feedIdA: res[0].feedId,
            feedIdB: res[1].feedId
        });

        vm.expectEmit(true, true, false, true);
        emit ICompressedOracleV1.FeedSwapped(res[0].feedId, res[1].feedId, 0, 0, 0, 1);

        vm.prank(CREATOR);
        oracle.swapFeeds(CREATOR, swaps);
    }

    function testSwapFeedsMultiple() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 4);

        uint8 sIdx = _findSpreadIndex(5);
        uint48[4] memory data48 = [
            _packRaw(100_000, sIdx, sIdx),
            _packRaw(200_000, sIdx, sIdx),
            _packRaw(300_000, sIdx, sIdx),
            _packRaw(400_000, sIdx, sIdx)
        ];
        _pushData(CREATOR, 0, data48);

        // Swap (0,1) and (2,3) in one call
        ICompressedOracleV1.SlotSwapRequest[] memory swaps = new ICompressedOracleV1.SlotSwapRequest[](2);
        swaps[0] = ICompressedOracleV1.SlotSwapRequest({ feedIdA: res[0].feedId, feedIdB: res[1].feedId });
        swaps[1] = ICompressedOracleV1.SlotSwapRequest({ feedIdA: res[2].feedId, feedIdB: res[3].feedId });

        vm.prank(CREATOR);
        oracle.swapFeeds(CREATOR, swaps);

        assertEq(_readRaw48(_slotKey(CREATOR, 0), 0), data48[1]);
        assertEq(_readRaw48(_slotKey(CREATOR, 0), 1), data48[0]);
        assertEq(_readRaw48(_slotKey(CREATOR, 0), 2), data48[3]);
        assertEq(_readRaw48(_slotKey(CREATOR, 0), 3), data48[2]);
    }

    function testSwapFeedsRevertsNotCreatorOrOwner() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 2);

        ICompressedOracleV1.SlotSwapRequest[] memory swaps = new ICompressedOracleV1.SlotSwapRequest[](1);
        swaps[0] = ICompressedOracleV1.SlotSwapRequest({
            feedIdA: res[0].feedId,
            feedIdB: res[1].feedId
        });

        vm.prank(OTHER);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.NotCreatorOrOwner.selector));
        oracle.swapFeeds(CREATOR, swaps);
    }

    function testSwapFeedsRevertsFeedNotOwnedByCreator() public {
        IOffchainOracle.CreationResponse[] memory resA = _createFeeds(CREATOR, 1);
        IOffchainOracle.CreationResponse[] memory resB = _createFeeds(OTHER, 1);

        ICompressedOracleV1.SlotSwapRequest[] memory swaps = new ICompressedOracleV1.SlotSwapRequest[](1);
        swaps[0] = ICompressedOracleV1.SlotSwapRequest({
            feedIdA: resA[0].feedId,
            feedIdB: resB[0].feedId
        });

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.FeedNotOwnedByCreator.selector, resB[0].feedId));
        oracle.swapFeeds(CREATOR, swaps);
    }

    function testSwapFeedsRevertsDeactivatedFeed() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 2);

        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[0].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        ICompressedOracleV1.SlotSwapRequest[] memory swaps = new ICompressedOracleV1.SlotSwapRequest[](1);
        swaps[0] = ICompressedOracleV1.SlotSwapRequest({
            feedIdA: res[0].feedId,
            feedIdB: res[1].feedId
        });

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.FeedNotOwnedByCreator.selector, res[0].feedId));
        oracle.swapFeeds(CREATOR, swaps);
    }

    function testSwapFeedsByOwner() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 2);

        ICompressedOracleV1.SlotSwapRequest[] memory swaps = new ICompressedOracleV1.SlotSwapRequest[](1);
        swaps[0] = ICompressedOracleV1.SlotSwapRequest({
            feedIdA: res[0].feedId,
            feedIdB: res[1].feedId
        });

        // Owner (address(this)) swaps
        oracle.swapFeeds(CREATOR, swaps);

        IOffchainOracle.OracleInfo memory info0 = oracle.getOracleInfo(res[0].feedId);
        (, , uint8 p0) = _unpackMisc(info0.misc);
        assertEq(p0, 1, "feed0 should be at pos 1");

        IOffchainOracle.OracleInfo memory info1 = oracle.getOracleInfo(res[1].feedId);
        (, , uint8 p1) = _unpackMisc(info1.misc);
        assertEq(p1, 0, "feed1 should be at pos 0");
    }

    function testSwapFeedsPriceReadsCorrectly() public {
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 4);

        uint8 sIdx = _findSpreadIndex(5);
        uint48 dataA = _packRaw(1_000_000, sIdx, sIdx);
        uint48 dataB = _packRaw(2_000_000, sIdx, sIdx);
        uint48[4] memory data48 = [dataA, dataB, dataA, dataA];
        _pushData(CREATOR, 0, data48);

        // Get prices before swap
        (uint256 bidA_before,,,) = oracle.price(res[0].feedId, address(0));
        (uint256 bidB_before,,,) = oracle.price(res[1].feedId, address(0));
        assertGt(bidA_before, 0);
        assertGt(bidB_before, 0);

        ICompressedOracleV1.SlotSwapRequest[] memory swaps = new ICompressedOracleV1.SlotSwapRequest[](1);
        swaps[0] = ICompressedOracleV1.SlotSwapRequest({
            feedIdA: res[0].feedId,
            feedIdB: res[1].feedId
        });

        vm.prank(CREATOR);
        oracle.swapFeeds(CREATOR, swaps);

        // Prices should follow feeds, not positions
        (uint256 bidA_after,,,) = oracle.price(res[0].feedId, address(0));
        (uint256 bidB_after,,,) = oracle.price(res[1].feedId, address(0));
        assertEq(bidA_after, bidA_before, "feed0 price should be same after swap");
        assertEq(bidB_after, bidB_before, "feed1 price should be same after swap");
    }

    // ═══════════════════════════════════════════════════════════
    //  Swap via temp position (moveFeeds — legacy approach)
    // ═══════════════════════════════════════════════════════════

    function testSwapViaTemporaryPosition() public {
        // Create 5 feeds: slot 0 [0,1,2,3], slot 1 [0]
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 5);

        uint8 sIdx = _findSpreadIndex(5);
        uint48 dataA = _packRaw(111_111, sIdx, sIdx);
        uint48 dataB = _packRaw(222_222, sIdx, sIdx);
        uint48[4] memory slot0Data = [dataA, dataB, DEFAULT_ORACLE_DATA_VALUE, DEFAULT_ORACLE_DATA_VALUE];
        _pushData(CREATOR, 0, slot0Data);

        // Deactivate feed at slot 1 pos 0 (temp)
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[4].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Swap feed[0] (pos 0) and feed[1] (pos 1) using slot 1 pos 0 as temp:
        // 1) Move feed[0] → slot 1 pos 0
        // 2) Move feed[1] → slot 0 pos 0
        // 3) Move feed[0] → slot 0 pos 1
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](3);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[0].feedId,
            targetSlotIndex: 1,
            targetPositionIndex: 0
        });
        moves[1] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[1].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 0
        });
        moves[2] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[0].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 1
        });

        vm.prank(CREATOR);
        oracle.moveFeeds(CREATOR, moves);

        // Verify: feed[0] now at pos 1 with dataA, feed[1] at pos 0 with dataB
        uint48 rawPos0 = _readRaw48(_slotKey(CREATOR, 0), 0);
        uint48 rawPos1 = _readRaw48(_slotKey(CREATOR, 0), 1);
        assertEq(rawPos0, dataB, "pos 0 should have feed1's data (dataB)");
        assertEq(rawPos1, dataA, "pos 1 should have feed0's data (dataA)");

        // Verify pointers
        IOffchainOracle.OracleInfo memory info0 = oracle.getOracleInfo(res[0].feedId);
        (, uint8 s0, uint8 p0) = _unpackMisc(info0.misc);
        assertEq(s0, 0);
        assertEq(p0, 1, "feed0 should be at pos 1");

        IOffchainOracle.OracleInfo memory info1 = oracle.getOracleInfo(res[1].feedId);
        (, uint8 s1, uint8 p1) = _unpackMisc(info1.misc);
        assertEq(s1, 0);
        assertEq(p1, 0, "feed1 should be at pos 0");
    }
}
