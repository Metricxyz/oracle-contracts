// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CompressedOracleV1, ICompressedOracleV1} from "../../../contracts/oracles/compressed/CompressedOracle.sol";
import {IOffchainOracle} from "../../../contracts/interfaces/IOffchainOracle.sol";
import {Codebook256} from "../../../contracts/oracles/utils/Codebook256.sol";
import {U64x32} from "../../../contracts/oracles/utils/U64x32.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {TimeMs, toTimeMs} from "../../../contracts/oracles/utils/TimeMs.sol";


contract CompressedOracleExposed is CompressedOracleV1 {
    constructor(address _owner) CompressedOracleV1(_owner, 0) {}

    function unpackMisc(bytes memory data)
        external
        pure
        returns (address creator, uint8 slotIndex, uint8 positionIndex)
    {
        return _unpackMisc(data);
    }
}

library unpacker {
    function _unpackResponse(IOffchainOracle.CreationResponse memory data) internal pure returns(uint8 _slotIndex, uint8 _positionIndex) {
        assembly ("memory-safe") {
            // Memory layout of struct:
            // res + 0x00: feedId (bytes32)
            // res + 0x20: pointer to misc bytes
            
            let miscPtr := mload(add(data, 0x20))    // pointer to misc
            let packed := mload(add(miscPtr, 0x20)) // skip length, load data
            
            // misc format: [address(20)][uint8][uint8]
            _slotIndex := byte(20, packed)
            _positionIndex := byte(21, packed)
        }
    }

    function _unpackInfo(IOffchainOracle.OracleInfo memory info) internal pure returns(uint8 _slotIndex, uint8 _positionIndex) {
        assembly ("memory-safe") {
            let miscPtr := mload(add(info, 0x40))  // struct misc pointer
            let packed := mload(add(miscPtr, 0x20)) // skip length, load data
            // misc format: [address(20)][uint8][uint8]
            _slotIndex := byte(20, packed)
            _positionIndex := byte(21, packed)
        }
    }

    function slotIndex(IOffchainOracle.CreationResponse memory data) internal view returns (uint8) {
        (uint8 _slotIndex, ) = _unpackResponse(data);
        return _slotIndex;
    }

    function positionIndex(IOffchainOracle.CreationResponse memory data) internal view returns (uint8) {
        (, uint8 _positionIndex) = _unpackResponse(data);
        return _positionIndex;
    }

    function slotIndex(IOffchainOracle.OracleInfo memory info) internal view returns (uint8) {
        (uint8 _slotIndex, ) = _unpackInfo(info);
        return _slotIndex;
    }

    function positionIndex(IOffchainOracle.OracleInfo memory info) internal view returns (uint8) {
        (, uint8 _positionIndex) = _unpackInfo(info);
        return _positionIndex;
    }
}

contract CompressedOracleTest is Test {
    using unpacker for IOffchainOracle.CreationResponse;
    using unpacker for IOffchainOracle.OracleInfo;

    CompressedOracleExposed private oracle;
    uint256 private constant BPS_BASE = 10_000;
    uint8 private constant MAX_PER_SLOT = 4;
    uint256 private constant X8 = 0xFF;
    uint256 private constant X32 = 0xFFFFFFFF;
    uint256 private constant X48 = 0xFFFFFFFFFFFF;
    uint256 private constant X56 = 0xFFFFFFFFFFFFFF;
    uint32 private constant DEFAULT_TIMESTAMP = 0;
    uint48 constant DEFAULT_ORACLE_DATA_VALUE = 0x00000000FFFF;

    function setUp() public {
        oracle = new CompressedOracleExposed(address(this));
    }



    function testCreationInitializesDefaultTimestamp(uint64 ts) public {
        vm.assume(ts > 0xffff && ts < type(uint32).max);
        vm.warp(ts);

        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](1);
        requests[0] = _mkRequest(address(1), address(2));

        for (uint256 i; i < 25; i++) {
            vm.warp(++ts);
            IOffchainOracle.CreationResponse[] memory responses = oracle.createOracles(requests);
            
            bytes32 slotKey = _slotKey(responses[0].slotIndex());
            ICompressedOracleV1.SlotLayout memory layout = _decodeSlotLayout(_loadSlot(slotKey));
            ICompressedOracleV1.CompressedOracleData memory expected =
                _dataFromLayout(layout, responses[0].positionIndex());
            ICompressedOracleV1.CompressedOracleData memory defaultCompressed = _toCompressed(DEFAULT_ORACLE_DATA_VALUE);

            _assertCompressedEq(expected, defaultCompressed, "default compressed mismatch");
            assertEq(uint256(TimeMs.unwrap(layout.timestampMs)), uint256(0), "layout timestamp should default to sentinel");

            IOffchainOracle.OracleData memory expanded = _expandCompressed(expected, TimeMs.unwrap(layout.timestampMs));
            assertEq(expanded.price, U64x32.decode(defaultCompressed.p), "expanded price mismatch");
            assertEq(expanded.spread, _decodeCodebook(defaultCompressed.s), "expanded spread mismatch");
            assertEq(expanded.volatility, _decodeCodebook(defaultCompressed.v), "expanded volatility mismatch");
            assertEq(uint256(TimeMs.unwrap(expanded.timestampMs)), uint256(TimeMs.unwrap(layout.timestampMs)), "expanded timestamp mismatch");
        }
    }

    function testViewMetadataAfterCreation() public {
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](3);
        for (uint256 i; i < requests.length; i++) {
            address tokenA = address(uint160(100 + i * 10));
            address tokenB = address(uint160(50 + i * 10));
            requests[i] = _mkRequest(tokenA, tokenB);
        }

        IOffchainOracle.CreationResponse[] memory responses = oracle.createOracles(requests);

        assertEq(oracle.getOracleCount(), responses.length, "oracle count mismatch");

        bytes32[] memory ids = oracle.getOracleIds(0, type(uint256).max);
        assertEq(ids.length, responses.length, "id set length mismatch");

        bool[] memory seen = new bool[](responses.length);
        for (uint256 i; i < ids.length; i++) {
            for (uint256 j; j < responses.length; j++) {
                if (ids[i] == responses[j].feedId) {
                    seen[j] = true;
                    break;
                }
            }
        }

        for (uint256 j; j < seen.length; j++) {
            assertTrue(seen[j], "missing feed id");
        }

        for (uint256 i; i < responses.length; i++) {
            IOffchainOracle.OracleInfo memory info = oracle.getOracleInfo(responses[i].feedId);

            assertEq(info.slotIndex(), responses[i].slotIndex(), "slot index mismatch");
            assertEq(uint256(info.positionIndex()), uint256(responses[i].positionIndex()), "position mismatch");

            assertEq(info.baseToken, requests[i].baseToken, "baseToken mismatch");
            assertEq(info.quoteToken, requests[i].quoteToken, "quoteToken mismatch");
        }
    }

    function testSlotLayoutExposesPackedState() public {
        uint256 feedsPerSlot = 4;
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](feedsPerSlot);

        for (uint256 i; i < feedsPerSlot; i++) {
            address tokenA = address(uint160(200 + i * 10));
            address tokenB = address(uint160(150 + i * 10));
            requests[i] = _mkRequest(tokenA, tokenB);
        }

        IOffchainOracle.CreationResponse[] memory responses = oracle.createOracles(requests);

        bytes32 slotKey = _slotKey(responses[0].slotIndex());
        ICompressedOracleV1.SlotLayout memory layout = _loadLayout(slotKey);
        assertEq(TimeMs.unwrap(layout.timestampMs), uint256(0), "layout timestamp mismatch");

        for (uint256 i; i < responses.length; i++) {
            ICompressedOracleV1.CompressedOracleData memory expected =
                _dataFromLayout(layout, responses[i].positionIndex());

            _assertCompressedEq(expected, _toCompressed(DEFAULT_ORACLE_DATA_VALUE), "compressed feed mismatch");
        }
    }

    function testViewsRevertForUnknownFeed() public {
        bytes32 fakeId = keccak256("missing-feed");

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, fakeId));
        oracle.getOracleInfo(fakeId);

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, fakeId));
        oracle.getSlotLayout(fakeId);

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, fakeId));
        oracle.getCompressedOracle(fakeId);

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, fakeId));
        oracle.getOracleData(fakeId);
    }

    function testFallbackRevertsWhenDeadlineExpired() public {
        vm.warp(1_000);
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](1);
        requests[0] = _mkRequest(address(0xAB10), address(0xAB20));
        IOffchainOracle.CreationResponse memory response = oracle.createOracles(requests)[0];

        uint32 expiredDeadline = uint32(block.timestamp);
        uint56 tsMs = uint56(block.timestamp * 1000);
        bytes memory entry = _encodeFallbackEntry(response.slotIndex(), tsMs, 0x010203040506);
        bytes memory payload = _encodeFallbackPayload(expiredDeadline, entry);

        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.DeadlineExceeded.selector));
        (bool ok,) = address(oracle).call(payload);
        assertTrue(ok, "expectRevert did not fire");
    }

    function testFallbackRevertsOnBadCalldataLength() public {
        vm.warp(1);
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](1);
        requests[0] = _mkRequest(address(0xAC10), address(0xAC20));
        oracle.createOracles(requests);

        uint32 deadline = uint32(block.timestamp + 10);
        bytes memory payload = bytes.concat(abi.encodePacked(deadline), hex"aa");

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.BadCalldataLength.selector));
        (bool ok,) = address(oracle).call(payload);
        assertTrue(ok, "expectRevert did not fire");
    }

    function testFallbackHigherSequenceStillNoWrite() public {
        vm.warp(42);

        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](1);
        requests[0] = _mkRequest(address(0xAAA1), address(0xAAA2));

        IOffchainOracle.CreationResponse memory response = oracle.createOracles(requests)[0];
        bytes32 slotKey = _slotKey(response.slotIndex());
        bytes32 initial = _loadSlot(slotKey);

        uint32 deadline = uint32(block.timestamp + 10);
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 compressed = 0x010203040506;
        bytes memory firstEntry =
            _encodeFallbackEntryWithIndex(response.slotIndex(), response.positionIndex(), tsMs, compressed);
        bytes memory firstPayload = _encodeFallbackPayload(deadline, firstEntry);
        (bool okFirst,) = address(oracle).call(firstPayload);
        assertTrue(okFirst, "initial fallback should succeed");

        bytes32 afterFirst = _loadSlot(slotKey);
        assertTrue(afterFirst != initial, "first fallback update should mutate slot");

        ICompressedOracleV1.SlotLayout memory layoutAfterFirst = _loadLayout(slotKey);
        ICompressedOracleV1.CompressedOracleData memory zeroCompressed = _toCompressed(0);
        for (uint256 i; i < MAX_PER_SLOT; i++) {
            ICompressedOracleV1.CompressedOracleData memory expected =
                i == response.positionIndex() ? _toCompressed(compressed) : zeroCompressed;
            _assertCompressedEq(
                _dataFromLayout(layoutAfterFirst, uint8(i)),
                expected,
                string(abi.encodePacked("lane ", vm.toString(i), " mismatch"))
            );
        }
        assertEq(uint256(TimeMs.unwrap(layoutAfterFirst.timestampMs)), uint256(tsMs), "timestamp mismatch after first update");

        bytes memory secondEntry =
            _encodeFallbackEntryWithIndex(response.slotIndex(), response.positionIndex(), tsMs, 0x999999999999);
        bytes memory secondPayload = _encodeFallbackPayload(uint32(block.timestamp + 10), secondEntry);
        (bool okSecond,) = address(oracle).call(secondPayload);
        assertTrue(okSecond, "second fallback should succeed");

        bytes32 afterSecond = _loadSlot(slotKey);
        assertEq(afterSecond, afterFirst, "slot mutated after repeated call");
    }

    function testFallbackHigherSequenceDoesNotChangeLayout() public {
        vm.warp(500);

        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](1);
        requests[0] = _mkRequest(address(0xBBAA), address(0xBBAF));

        IOffchainOracle.CreationResponse memory response = oracle.createOracles(requests)[0];

        bytes32 slotKey = _slotKey(response.slotIndex());
        bytes32 slotBefore = _loadSlot(slotKey);
        ICompressedOracleV1.SlotLayout memory layoutBefore = _loadLayout(slotKey);
        assertEq(uint256(TimeMs.unwrap(layoutBefore.timestampMs)), uint256(0), "precondition timestamp mismatch");

        uint32 deadline = uint32(block.timestamp + 30);
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 compressed = 0x010203040506;
        bytes memory entry =
            _encodeFallbackEntryWithIndex(response.slotIndex(), response.positionIndex(), tsMs, compressed);
        bytes memory payload = _encodeFallbackPayload(deadline, entry);

        (bool ok,) = address(oracle).call(payload);
        assertTrue(ok, "fallback call failed");

        bytes32 slotAfter = _loadSlot(slotKey);
        assertTrue(slotAfter != slotBefore, "slot should update with newer sequence");

        ICompressedOracleV1.SlotLayout memory layoutAfter = _loadLayout(slotKey);
        ICompressedOracleV1.CompressedOracleData memory zeroCompressed = _toCompressed(0);
        for (uint256 i; i < MAX_PER_SLOT; i++) {
            ICompressedOracleV1.CompressedOracleData memory expected =
                i == response.positionIndex() ? _toCompressed(compressed) : zeroCompressed;
            _assertCompressedEq(
                _dataFromLayout(layoutAfter, uint8(i)),
                expected,
                string(abi.encodePacked("lane ", vm.toString(i), " mismatch"))
            );
        }
        assertEq(uint256(TimeMs.unwrap(layoutAfter.timestampMs)), uint256(tsMs), "timestamp mismatch after update");
    }

    function testFallbackSequenceWrapStillUpdatesSlot() public {
        vm.warp(750);

        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](4);
        for (uint256 i; i < requests.length; i++) {
            requests[i] = _mkRequest(address(uint160(0xCBCB + i * 2)), address(uint160(0xCBC1 + i * 2)));
        }

        IOffchainOracle.CreationResponse[] memory responses = oracle.createOracles(requests);
        IOffchainOracle.CreationResponse memory target = responses[responses.length - 1];
        assertEq(uint256(target.positionIndex()), MAX_PER_SLOT - 1, "target feed should occupy lane 3");
        bytes32 slotKey = _slotKey(target.slotIndex());

        (uint8 spreadIdx,) = _findSpreadIndex(5);
        uint32 firstDeadline = uint32(block.timestamp + 10);
        uint56 firstTsMs = uint56(block.timestamp);
        uint48 firstRaw = _packRaw(1_000_000, spreadIdx, 0);
        bytes memory firstEntry = _encodeFallbackEntry(target.slotIndex(), firstTsMs, firstRaw);
        bytes memory firstPayload = _encodeFallbackPayload(firstDeadline, firstEntry);
        (bool okFirst,) = address(oracle).call(firstPayload);
        assertTrue(okFirst, "initial wrap payload failed");

        vm.warp(block.timestamp + 1);
        uint32 secondDeadline = uint32(block.timestamp + 10);
        uint56 secondTsMs = firstTsMs + 1;
        uint48 secondRaw = _packRaw(1_000_200, spreadIdx, 0);
        bytes memory secondEntry = _encodeFallbackEntry(target.slotIndex(), secondTsMs, secondRaw);
        bytes memory secondPayload = _encodeFallbackPayload(secondDeadline, secondEntry);
        (bool okSecond,) = address(oracle).call(secondPayload);
        assertTrue(okSecond, "wrapped sequence payload rejected");

        ICompressedOracleV1.SlotLayout memory layout = _loadLayout(slotKey);
        emit log_uint(TimeMs.unwrap(layout.timestampMs));
        emit log_uint(secondTsMs);
        ICompressedOracleV1.CompressedOracleData memory finalData = _dataFromLayout(layout, target.positionIndex());
        _assertCompressedEq(finalData, _toCompressed(secondRaw), "wrapped update should overwrite lane");
        assertEq(uint256(TimeMs.unwrap(layout.timestampMs)), uint256(secondTsMs), "layout timestamp should include wrapped seq");
    }

    function testFallbackSequenceResetNoEffect() public {
        vm.warp(900);

        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](1);
        requests[0] = _mkRequest(address(0xCC01), address(0xCC02));

        IOffchainOracle.CreationResponse memory response = oracle.createOracles(requests)[0];
        bytes32 slotKey = _slotKey(response.slotIndex());
        bytes32 initial = _loadSlot(slotKey);

        uint32 deadline = uint32(block.timestamp + 30);
        uint56 firstTsMs = uint56(block.timestamp * 1000);
        bytes memory firstEntry =
            _encodeFallbackEntryWithIndex(response.slotIndex(), response.positionIndex(), firstTsMs, 0x0A0B0C0D0E0F);
        bytes memory firstPayload = _encodeFallbackPayload(deadline, firstEntry);
        (bool okFirst,) = address(oracle).call(firstPayload);
        assertTrue(okFirst, "initial fallback call failed");

        bytes32 afterFirst = _loadSlot(slotKey);
        assertTrue(afterFirst != initial, "first fallback call should mutate slot");

        ICompressedOracleV1.SlotLayout memory layoutAfterFirst = _loadLayout(slotKey);
        ICompressedOracleV1.CompressedOracleData memory zeroCompressed = _toCompressed(0);
        for (uint256 i; i < MAX_PER_SLOT; i++) {
            ICompressedOracleV1.CompressedOracleData memory expected =
                i == response.positionIndex() ? _toCompressed(0x0A0B0C0D0E0F) : zeroCompressed;
            _assertCompressedEq(
                _dataFromLayout(layoutAfterFirst, uint8(i)),
                expected,
                string(abi.encodePacked("lane ", vm.toString(i), " mismatch after first call"))
            );
        }
        assertEq(uint256(TimeMs.unwrap(layoutAfterFirst.timestampMs)), uint256(firstTsMs), "timestamp mismatch after first call");

        vm.warp(960);
        uint56 secondTsMs = firstTsMs - 1;
        bytes memory secondEntry =
            _encodeFallbackEntryWithIndex(response.slotIndex(), response.positionIndex(), secondTsMs, 0x010203040506);
        bytes memory secondPayload = _encodeFallbackPayload(uint32(block.timestamp + 10), secondEntry);

        (bool okSecond,) = address(oracle).call(secondPayload);
        assertTrue(okSecond, "reset fallback call failed");

        bytes32 afterReset = _loadSlot(slotKey);
        assertEq(afterReset, afterFirst, "slot mutated after reset attempt");

        ICompressedOracleV1.SlotLayout memory layoutAfter = _loadLayout(slotKey);
        _assertCompressedEq(
            _dataFromLayout(layoutAfter, response.positionIndex()),
            _toCompressed(0x0A0B0C0D0E0F),
            "oracle mismatch after reset attempt"
        );
        assertEq(uint256(TimeMs.unwrap(layoutAfter.timestampMs)), uint256(firstTsMs), "timestamp should remain from first update");
    }

    function testCreateOraclesNotWrapsSlotIndexAfterCapacity() public {
        try vm.envBool("COVERAGE_MODE") returns (bool) {
            // it fails during coverage generation; works well with regilar tests
            vm.skip(true);
            return;
        } catch {}

        uint256 feedsPerSlot = 4;
        IOffchainOracle.CreationRequest[] memory batch = new IOffchainOracle.CreationRequest[](feedsPerSlot);

        for (uint256 slot; slot < 0xff; slot++) {
            for (uint256 i; i < feedsPerSlot; i++) {
                address baseToken = address(uint160(0x1000 + slot * 16 + i * 2));
                address quoteToken = address(uint160(0x1000 + slot * 16 + i * 2 + 1));
                batch[i] = _mkRequest(baseToken, quoteToken);
            }
            oracle.createOracles(batch);
        }

        IOffchainOracle.CreationRequest[] memory extra = new IOffchainOracle.CreationRequest[](1);
        extra[0] = _mkRequest(address(0xDEAD), address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.SlotLimitExceeded.selector, address(this)));
        oracle.createOracles(extra);
    }

    function testNamespaceRemappingAllowsDelegatedFallback() public {
        uint256 creatorKey = 0xC0FFEE;
        address creator = vm.addr(creatorKey);
        uint256 pusherKey = 0xBEEF;
        address pusher = vm.addr(pusherKey);

        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](4);
        for (uint256 i; i < requests.length; i++) {
            requests[i] = _mkRequest(address(uint160(0xAA01 + i * 2)), address(uint160(0xAA02 + i * 2)));
        }
        vm.prank(creator);
        IOffchainOracle.CreationResponse[] memory responses = oracle.createOracles(requests);
        IOffchainOracle.CreationResponse memory response = responses[responses.length - 1];
        bytes32 feedId = response.feedId;

        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(block.chainid, address(oracle), deadline, pusher, creator))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pusherKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        address[] memory pushers = new address[](1);
        pushers[0] = pusher;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = sig;

        vm.prank(creator);
        oracle.allowPushers(deadline, pushers, signatures);
        assertEq(oracle.namespaceRemapping(pusher), creator, "pusher should map to creator namespace");
        assertEq(oracle.namespaceRemapping(creator), creator, "creator namespace should be initialized");

        (uint8 spreadIdx,) = _findSpreadIndex(5);
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 raw = _packRaw(900_000, spreadIdx, 0);
        bytes memory entry = _encodeFallbackEntry(response.slotIndex(), tsMs, raw);
        bytes memory payload = _encodeFallbackPayload(uint32(block.timestamp + 10), entry);
        assertEq(payload.length, 36, "delegated payload length mismatch");
        emit log_uint(payload.length);
        emit log_uint(block.timestamp);

        vm.prank(pusher);
        (bool ok, bytes memory revertData) = address(oracle).call(payload);
        if (!ok) emit log_bytes(revertData);
        assertTrue(ok, "delegated fallback call failed");

        ICompressedOracleV1.SlotLayout memory layout = oracle.getSlotLayout(feedId);
        ICompressedOracleV1.CompressedOracleData memory stored = _dataFromLayout(layout, response.positionIndex());
        _assertCompressedEq(stored, _toCompressed(raw), "delegated update mismatch");
        assertGt(uint256(TimeMs.unwrap(layout.timestampMs)), 0, "timestamp should be recorded");
    }

    function testRemovePushersRevokesDelegation() public {
        uint256 creatorKey = 0xCAFEBABE;
        address creator = vm.addr(creatorKey);
        uint256 pusherKey = 0xFEED;
        address pusher = vm.addr(pusherKey);

        vm.prank(creator);
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](1);
        requests[0] = _mkRequest(address(0xBA01), address(0xBA02));
        oracle.createOracles(requests);

        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest =
            MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(block.chainid, address(oracle), deadline, pusher, creator)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pusherKey, digest);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);
        address[] memory pushers = new address[](1);
        pushers[0] = pusher;

        vm.prank(creator);
        oracle.allowPushers(deadline, pushers, sigs);
        assertEq(oracle.namespaceRemapping(pusher), creator, "pusher should be mapped");

        vm.prank(creator);
        oracle.removePushers(pushers);
        assertEq(oracle.namespaceRemapping(pusher), address(0), "pusher should be revoked");

        (uint8 spreadIdx,) = _findSpreadIndex(5);
        bytes memory entry = _encodeFallbackEntry(0, 1, _packRaw(800_000, spreadIdx, 0));
        bytes memory payload = _encodeFallbackPayload(uint32(block.timestamp + 10), entry);

        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.InvalidNamespace.selector));
        (bool ok,) = address(oracle).call(payload);
        assertTrue(ok, "expectRevert did not fire");
    }

    function _sortTokens(address a, address b) internal pure returns (address, address) {
        return uint160(a) < uint160(b) ? (a, b) : (b, a);
    }

    function _dataFromLayout(ICompressedOracleV1.SlotLayout memory layout, uint8 index)
        internal
        pure
        returns (ICompressedOracleV1.CompressedOracleData memory)
    {
        if (index == 0) return layout.oracle0;
        if (index == 1) return layout.oracle1;
        if (index == 2) return layout.oracle2;
        if (index == 3) return layout.oracle3;
        revert("invalid index");
    }

    function _decodeCodebook(uint8 index) internal pure returns (uint16 value) {
        bool ok;
        (value, ok) = Codebook256.decode(index);
        require(ok, "codebook decode failed");
    }

    function _loadSlot(bytes32 slotKey) internal view returns (bytes32) {
        return vm.load(address(oracle), slotKey);
    }

    function _slotKey(uint8 slotIndex) internal view returns (bytes32) {
        uint256 namespace = uint256(uint160(address(this))) << 96;
        return bytes32(namespace | uint256(slotIndex));
    }

    function _decodeSlotLayout(bytes32 slotValue)
        internal
        pure
        returns (ICompressedOracleV1.SlotLayout memory layout)
    {
        uint256 value = uint256(slotValue);
        layout.timestampMs = toTimeMs(value >> 8 & X56);
        layout.oracle0 = _toCompressed(uint48((value >> 208) & X48));
        layout.oracle1 = _toCompressed(uint48((value >> 160) & X48));
        layout.oracle2 = _toCompressed(uint48((value >> 112) & X48));
        layout.oracle3 = _toCompressed(uint48((value >> 64) & X48));
    }

    function _expandCompressed(ICompressedOracleV1.CompressedOracleData memory compressed, uint256 timestampMs)
        internal
        pure
        returns (IOffchainOracle.OracleData memory data)
    {
        data.price = U64x32.decode(compressed.p);
        data.spread = _decodeCodebook(compressed.s);
        data.volatility = _decodeCodebook(compressed.v);
        data.timestampMs = toTimeMs(timestampMs);
    }

    function _loadLayout(bytes32 slotKey) internal view returns (ICompressedOracleV1.SlotLayout memory) {
        return _decodeSlotLayout(_loadSlot(slotKey));
    }

    function testFallbackAllFeedsRemainDefault() public {
        vm.warp(1000);

        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](4);
        for (uint256 i; i < 4; i++) {
            address baseToken = address(uint160(0x2200 + i * 2));
            address quoteToken = address(uint160(0x2200 + i * 2 + 1));
            requests[i] = _mkRequest(baseToken, quoteToken);
        }

        IOffchainOracle.CreationResponse[] memory responses = oracle.createOracles(requests);
        bytes32 slotKey = _slotKey(responses[0].slotIndex());

        bytes32 initial = _loadSlot(slotKey);
        uint32 deadline = uint32(block.timestamp + 20);
        uint56 tsMs = uint56(block.timestamp * 1000);
        bytes memory slotEntry = _encodeFallbackEntry(responses[0].slotIndex(), tsMs, 0xAA0102030405);
        bytes memory payload = _encodeFallbackPayload(deadline, slotEntry);
        assertEq(payload.length, 36, "payload length mismatch");

        (bool ok,) = address(oracle).call(payload);
        assertTrue(ok, "fallback slot update failed");

        bytes32 post = _loadSlot(slotKey);
        assertTrue(post != initial, "slot should be rewritten by fallback");

        ICompressedOracleV1.SlotLayout memory layout = _loadLayout(slotKey);
        ICompressedOracleV1.CompressedOracleData memory zeroCompressed = _toCompressed(0);
        _assertCompressedEq(layout.oracle0, zeroCompressed, "oracle0 mismatch after fallback");
        _assertCompressedEq(layout.oracle1, zeroCompressed, "oracle1 mismatch after fallback");
        _assertCompressedEq(layout.oracle2, zeroCompressed, "oracle2 mismatch after fallback");
        _assertCompressedEq(layout.oracle3, _toCompressed(0xAA0102030405), "oracle3 mismatch after fallback");
        assertEq(TimeMs.unwrap(layout.timestampMs), uint256(tsMs), "timestamp should reflect update time");

        bytes32 rawSlot = _loadSlot(slotKey);
        assertTrue(rawSlot != bytes32(0), "slot should contain data");
    }

    function testFallbackRejectsFullSlotPayload() public {
        vm.warp(2000);

        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](4);
        for (uint256 i; i < 4; i++) {
            address baseToken = address(uint160(0x3300 + i * 2));
            address quoteToken = address(uint160(0x3300 + i * 2 + 1));
            requests[i] = _mkRequest(baseToken, quoteToken);
        }

        IOffchainOracle.CreationResponse[] memory responses = oracle.createOracles(requests);

        uint48[4] memory newData =
            [uint48(0xAA0102030405), uint48(0xBB1112131415), uint48(0xCC2122232425), uint48(0xDD3132333435)];

        bytes memory slotEntry = abi.encodePacked(
            bytes6(newData[0]),
            bytes6(newData[1]),
            bytes6(newData[2]),
            bytes6(newData[3]),
            bytes1(uint8(9)),
            bytes1(uint8(block.timestamp & 0xFF)),
            bytes1(uint8(uint256(responses[0].slotIndex())))
        );

        uint32 deadline = uint32(block.timestamp + 20);
        bytes memory payload = bytes.concat(abi.encodePacked(deadline), slotEntry);

        (bool ok, bytes memory revertData) = address(oracle).call(payload);
        assertFalse(ok, "full slot payload should revert");
        assertEq(
            revertData, abi.encodeWithSelector(IOffchainOracle.BadCalldataLength.selector), "unexpected revert data"
        );
    }

    function _encodeFallbackPayload(uint32 deadline, bytes memory entry) internal pure returns (bytes memory) {
        require(entry.length == 32, "entry length mismatch");
        return bytes.concat(abi.encodePacked(deadline), entry);
    }

    function _encodeFallbackEntry(uint8 slotId, uint56 timestampMs, uint48 rawData)
        internal
        pure
        returns (bytes memory)
    {
        return _encodeFallbackEntryWithIndex(slotId, 3, timestampMs, rawData);
    }

    function _encodeFallbackEntryWithIndex(uint8 slotId, uint8 oracleIndex, uint56 timestampMs, uint48 rawData)
        internal
        pure
        returns (bytes memory)
    {
        require(oracleIndex < MAX_PER_SLOT, "invalid oracle index");
        uint256 word = uint256(timestampMs) << 8;
        word |= uint256(slotId);
        uint256 shift = 16 + (MAX_PER_SLOT - oracleIndex) * 48;
        word |= uint256(rawData) << shift;
        return abi.encodePacked(word);
    }

    function _mkRequest(address base, address quote)
        internal
        pure
        returns (IOffchainOracle.CreationRequest memory req)
    {
        req.baseToken = base;
        req.quoteToken = quote;
        req.minPrice = 0;
        req.maxPrice = type(uint128).max;
        req.stateGuard = address(0);
    }

    function testStateGuardDefaultsToCreator() public {
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](1);
        requests[0] = _mkRequest(address(0xAA10), address(0xAA20));

        IOffchainOracle.CreationResponse memory response = oracle.createOracles(requests)[0];
        bytes32 feedId = response.feedId;

        assertEq(oracle.stateGuard(feedId), address(this), "default state guard should be creator");

        oracle.setPriceGuard(feedId, 1, 100);

        address outsider = address(0xDEAD);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.InvalidGuard.selector, outsider));
        oracle.setPriceGuard(feedId, 2, 200);
    }

    function testStateGuardRoleTransferFlow() public {
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](1);
        requests[0] = _mkRequest(address(0xAB10), address(0xAB20));

        IOffchainOracle.CreationResponse memory response = oracle.createOracles(requests)[0];
        bytes32 feedId = response.feedId;

        address newGuard = address(0xBEEF);
        oracle.setPendingStateGuardRole(feedId, newGuard);
        assertEq(oracle.pendingStateGuard(feedId), newGuard, "pending guard mismatch");

        address stranger = address(0xCAFE);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.InvalidGuard.selector, stranger));
        oracle.acceptStateGuardRole(feedId);

        vm.prank(newGuard);
        oracle.acceptStateGuardRole(feedId);
        assertEq(oracle.stateGuard(feedId), newGuard, "state guard mismatch after accept");

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.InvalidGuard.selector, address(this)));
        oracle.setPriceGuard(feedId, 5, 50);

        vm.prank(newGuard);
        oracle.setPriceGuard(feedId, 5, 50);
    }

    function testStateGuardPendingCanBePurged() public {
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](1);
        requests[0] = _mkRequest(address(0xAC10), address(0xAC20));

        IOffchainOracle.CreationResponse memory response = oracle.createOracles(requests)[0];
        bytes32 feedId = response.feedId;

        address newGuard = address(0xB0B0);
        oracle.setPendingStateGuardRole(feedId, newGuard);
        assertEq(oracle.pendingStateGuard(feedId), newGuard, "pending guard should set");

        oracle.purgePendingStateGuardRole(feedId);
        assertEq(oracle.pendingStateGuard(feedId), address(0), "pending guard should clear");

        vm.prank(newGuard);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.InvalidGuard.selector, newGuard));
        oracle.acceptStateGuardRole(feedId);
    }

    function _packRaw(uint32 price, uint8 spreadIndex, uint8 volIndex) internal pure returns (uint48) {
        return (uint48(price) << 16) | (uint48(spreadIndex) << 8) | uint48(volIndex);
    }

    function _findSpreadIndex(uint16 minBps) internal pure returns (uint8 idx, uint16 value) {
        for (uint256 i; i <= type(uint8).max; i++) {
            uint16 decoded = _decodeCodebook(uint8(i));
            if (decoded >= minBps) {
                return (uint8(i), decoded);
            }
        }
        revert("spread index not found");
    }

    function _toCompressed(uint48 raw) internal pure returns (ICompressedOracleV1.CompressedOracleData memory data) {
        data.p = uint32(raw >> 16);
        data.s = uint8((raw >> 8) & 0xFF);
        data.v = uint8(raw & 0xFF);
    }

    function _assertCompressedEq(
        ICompressedOracleV1.CompressedOracleData memory actual,
        ICompressedOracleV1.CompressedOracleData memory expected,
        string memory context
    ) internal pure {
        assertEq(uint256(actual.p), uint256(expected.p), string(abi.encodePacked(context, ": price mismatch")));
        assertEq(uint256(actual.s), uint256(expected.s), string(abi.encodePacked(context, ": spread mismatch")));
        assertEq(uint256(actual.v), uint256(expected.v), string(abi.encodePacked(context, ": volatility mismatch")));
    }
}
