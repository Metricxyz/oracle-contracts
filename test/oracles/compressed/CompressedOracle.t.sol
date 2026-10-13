// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {CompressedOracleV1, ICompressedOracleV1} from "../../../contracts/oracles/compressed/CompressedOracle.sol";
import {IOffchainOracle} from "../../../contracts/interfaces/IOffchainOracle.sol";
import {Codebook256} from "../../../contracts/oracles/utils/Codebook256.sol";
import {U64x32} from "../../../contracts/oracles/utils/U64x32.sol";
import {TimeMs, toTimeMs, FutureTimestamp} from "../../../contracts/oracles/utils/TimeMs.sol";

/// @dev Tests for the registrationless CompressedOracleV1: feeds need no creation step,
///      feed ids are derived via feedIdOf(creator, slotIndex, positionIndex) and push
///      calldata is a leading zero byte + N x 32-byte slot words (no deadline prefix; the
///      zero byte keeps the calldata from ever matching a function selector).
contract CompressedOracleTest is Test {
    CompressedOracleV1 private oracle;

    uint8 private constant MAX_PER_SLOT = 4;
    uint256 private constant X56 = 0xFFFFFFFFFFFFFF;
    bytes32 private constant FEED_UPDATED_SIG = keccak256("FeedUpdated(bytes32)");
    bytes32 private constant PRICE_READ_SIG = keccak256("PriceRead(address,bytes32)");

    uint256 private constant CREATOR_KEY = 0xC0FFEE;
    uint256 private constant PUSHER_KEY = 0xBEEF;
    address private creator;
    address private pusher;

    function setUp() public {
        oracle = new CompressedOracleV1(address(this), 0);
        creator = vm.addr(CREATOR_KEY);
        pusher = vm.addr(PUSHER_KEY);
        vm.warp(1_700_000_000);
    }

    /*
     *
     * Push + read roundtrip
     *
     */

    function testKindDiscriminator() public view {
        assertEq(oracle.kind(), "compressed");
    }

    function testPushReadRoundtripAllPositions() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48[4] memory raws = [
            _packRaw(1_000_000, 3, 5), _packRaw(2_000_000, 7, 0), _packRaw(3_000_000, 1, 2), _packRaw(4_000_000, 9, 9)
        ];

        uint8 slotId = 17;
        bytes memory payload = _slotWord(slotId, raws[0], raws[1], raws[2], raws[3], tsMs);

        vm.prank(creator);
        (bool ok,) = address(oracle).call(payload);
        assertTrue(ok, "push failed");

        for (uint8 pos; pos < MAX_PER_SLOT; pos++) {
            bytes32 feedId = oracle.feedIdOf(creator, slotId, pos);
            IOffchainOracle.OracleData memory data = oracle.getOracleData(feedId);

            assertEq(data.price, U64x32.decode(uint32(raws[pos] >> 16)), "price mismatch");
            assertEq(data.spread0, _decodeCodebook(uint8(raws[pos] >> 8)), "spread0 mismatch");
            assertEq(data.spread1, _decodeCodebook(uint8(raws[pos])), "spread1 mismatch");
            assertEq(TimeMs.unwrap(data.timestampMs), uint256(tsMs), "timestamp mismatch");
        }

        // slot layout view agrees with the per-position reads
        ICompressedOracleV1.SlotLayout memory layout = oracle.getSlotLayout(oracle.feedIdOf(creator, slotId, 0));
        assertEq(uint256(layout.oracle0.p), uint256(raws[0] >> 16), "layout oracle0 price mismatch");
        assertEq(uint256(layout.oracle3.p), uint256(raws[3] >> 16), "layout oracle3 price mismatch");
        assertEq(TimeMs.unwrap(layout.timestampMs), uint256(tsMs), "layout timestamp mismatch");

        // compressed view exposes the raw lane
        (ICompressedOracleV1.CompressedOracleData memory compressed, TimeMs ts) =
            oracle.getCompressedOracle(oracle.feedIdOf(creator, slotId, 2));
        assertEq(uint256(compressed.p), uint256(raws[2] >> 16), "compressed price mismatch");
        assertEq(uint256(compressed.s0), uint256(uint8(raws[2] >> 8)), "compressed s0 mismatch");
        assertEq(uint256(compressed.s1), uint256(uint8(raws[2])), "compressed s1 mismatch");
        assertEq(TimeMs.unwrap(ts), uint256(tsMs), "compressed timestamp mismatch");
    }

    function testPushMultipleWordsInOneCall() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 rawA = _packRaw(500_000, 2, 2);
        uint48 rawB = _packRaw(600_000, 4, 4);

        // Multi-word push: ONE leading zero byte, then the two raw 32-byte words (not two prefixed
        // _wordAt payloads, which would embed a stray zero byte between the words).
        bytes memory payload = abi.encodePacked(bytes1(0), _slotValue(0, 0, rawA, tsMs), _slotValue(1, 3, rawB, tsMs));
        assertEq(payload.length, 65, "payload length mismatch");

        vm.prank(creator);
        (bool ok,) = address(oracle).call(payload);
        assertTrue(ok, "multi-word push failed");

        IOffchainOracle.OracleData memory dataA = oracle.getOracleData(oracle.feedIdOf(creator, 0, 0));
        IOffchainOracle.OracleData memory dataB = oracle.getOracleData(oracle.feedIdOf(creator, 1, 3));
        assertEq(dataA.price, U64x32.decode(uint32(rawA >> 16)), "word A price mismatch");
        assertEq(dataB.price, U64x32.decode(uint32(rawB >> 16)), "word B price mismatch");
    }

    /// @notice Regression: a push whose first slot word's leading 4 bytes (the pos-0 price) equal a
    ///         real function selector must still hit the fallback and STORE — not dispatch to that
    ///         function. Without the leading zero byte, `kind()` (0x04baa00b, zero-arg) would execute
    ///         and the push would silently no-op (and `revokePusher()` would self-revoke a delegation).
    function testPushWithSelectorLeadingBytesHitsFallback() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        // price = kind() selector; at pos 0 it forms the raw calldata's leading 4 bytes.
        uint32 collidingPrice = 0x04baa00b;
        uint48 raw = _packRaw(collidingPrice, 3, 5);

        vm.prank(creator);
        (bool ok,) = address(oracle).call(_wordAt(2, 0, raw, tsMs));
        assertTrue(ok, "colliding-selector push failed");

        IOffchainOracle.OracleData memory data = oracle.getOracleData(oracle.feedIdOf(creator, 2, 0));
        assertEq(data.price, U64x32.decode(collidingPrice), "must store via fallback, not dispatch to kind()");
        assertEq(TimeMs.unwrap(data.timestampMs), uint256(tsMs), "timestamp stored");
    }

    function testPriceViewMatchesOracleData() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 raw = _packRaw(1_234_567, 6, 3);

        vm.prank(creator);
        (bool ok,) = address(oracle).call(_wordAt(5, 1, raw, tsMs));
        assertTrue(ok, "push failed");

        bytes32 feedId = oracle.feedIdOf(creator, 5, 1);
        (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) = oracle.price(feedId, address(0));

        IOffchainOracle.OracleData memory data = oracle.getOracleData(feedId);
        assertEq(mid, uint256(data.price), "mid mismatch");
        assertEq(spread, uint256(data.spread0), "spread mismatch");
        assertEq(spread1, data.spread1, "spread1 mismatch");
        assertEq(refTime, uint256(tsMs) / 1000, "refTime should be in seconds");
    }

    function testNeverPushedFeedReadsZeros() public {
        bytes32 feedId = oracle.feedIdOf(creator, 42, 1);
        IOffchainOracle.OracleData memory data = oracle.getOracleData(feedId);

        assertEq(data.price, 0, "price should be zero");
        assertEq(data.spread0, 0, "spread0 should be zero");
        assertEq(data.spread1, 0, "spread1 should be zero");
        assertEq(TimeMs.unwrap(data.timestampMs), 0, "timestamp should be zero");
    }

    function testStalledSentinelReadsFullSpread() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 raw = _packRaw(1_000_000, 0xff, 0xff); // 0xff/0xff spread combo = stalled marker

        vm.prank(creator);
        (bool ok,) = address(oracle).call(_wordAt(3, 0, raw, tsMs));
        assertTrue(ok, "push failed");

        IOffchainOracle.OracleData memory data = oracle.getOracleData(oracle.feedIdOf(creator, 3, 0));
        assertEq(data.spread0, type(uint16).max, "stalled spread0 should be the stall sentinel");
        assertEq(data.spread1, type(uint16).max, "stalled spread1 should be the stall sentinel");
        assertEq(data.price, 0, "stalled price should be zero");
        assertEq(TimeMs.unwrap(data.timestampMs), 0, "stalled timestamp should be zero");
    }

    function testGetOracleDataBulk() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 raw = _packRaw(700_000, 5, 5);

        vm.prank(creator);
        (bool ok,) = address(oracle).call(_wordAt(9, 2, raw, tsMs));
        assertTrue(ok, "push failed");

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = oracle.feedIdOf(creator, 9, 2);
        ids[1] = oracle.feedIdOf(creator, 9, 3); // never pushed

        IOffchainOracle.OracleData[] memory res = oracle.getOracleDataBulk(ids);
        assertEq(res.length, 2, "bulk length mismatch");
        assertEq(res[0].price, U64x32.decode(uint32(raw >> 16)), "bulk[0] price mismatch");
        assertEq(res[1].price, 0, "bulk[1] should be empty");
    }

    /*
     *
     * Timestamp monotonicity + drift
     *
     */

    function testNonNewerWordsSkippedSilently() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 first = _packRaw(1_000_000, 3, 3);

        vm.prank(creator);
        (bool ok,) = address(oracle).call(_wordAt(0, 0, first, tsMs));
        assertTrue(ok, "first push failed");

        // same timestamp: skipped, no revert
        vm.prank(creator);
        (ok,) = address(oracle).call(_wordAt(0, 0, _packRaw(9_999_999, 8, 8), tsMs));
        assertTrue(ok, "equal-ts push should not revert");

        // older timestamp: skipped, no revert
        vm.prank(creator);
        (ok,) = address(oracle).call(_wordAt(0, 0, _packRaw(8_888_888, 8, 8), tsMs - 1));
        assertTrue(ok, "older-ts push should not revert");

        IOffchainOracle.OracleData memory data = oracle.getOracleData(oracle.feedIdOf(creator, 0, 0));
        assertEq(data.price, U64x32.decode(uint32(first >> 16)), "stale word must not overwrite");
        assertEq(TimeMs.unwrap(data.timestampMs), uint256(tsMs), "timestamp must stay");
    }

    function testNewerWordOverwrites() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 first = _packRaw(1_000_000, 3, 3);
        uint48 second = _packRaw(2_000_000, 4, 4);

        vm.prank(creator);
        (bool ok,) = address(oracle).call(_wordAt(0, 1, first, tsMs));
        assertTrue(ok, "first push failed");

        vm.prank(creator);
        (ok,) = address(oracle).call(_wordAt(0, 1, second, tsMs + 1));
        assertTrue(ok, "second push failed");

        IOffchainOracle.OracleData memory data = oracle.getOracleData(oracle.feedIdOf(creator, 0, 1));
        assertEq(data.price, U64x32.decode(uint32(second >> 16)), "newer word should overwrite");
        assertEq(TimeMs.unwrap(data.timestampMs), uint256(tsMs) + 1, "timestamp should advance");
    }

    function testFutureTimestampReverts() public {
        // MAX_TIME_DRIFT = 0: a timestamp whose whole second is past block.timestamp reverts
        uint56 tsMs = uint56((block.timestamp + 1) * 1000);
        bytes memory payload = _wordAt(0, 0, _packRaw(1_000_000, 3, 3), tsMs);

        vm.prank(creator);
        vm.expectRevert(FutureTimestamp.selector);
        (bool ok,) = address(oracle).call(payload);
        assertTrue(ok, "expectRevert did not fire");
    }

    function testDriftAllowsBoundedFuture() public {
        CompressedOracleV1 drifty = new CompressedOracleV1(address(this), 5);

        uint56 within = uint56((block.timestamp + 5) * 1000);
        vm.prank(creator);
        (bool ok,) = address(drifty).call(_wordAt(0, 0, _packRaw(1_000_000, 3, 3), within));
        assertTrue(ok, "within-drift push should succeed");
        IOffchainOracle.OracleData memory data = drifty.getOracleData(drifty.feedIdOf(creator, 0, 0));
        assertEq(TimeMs.unwrap(data.timestampMs), uint256(within), "within-drift ts mismatch");

        uint56 beyond = uint56((block.timestamp + 6) * 1000);
        bytes memory payload = _wordAt(0, 0, _packRaw(1_000_000, 3, 3), beyond);
        vm.prank(creator);
        vm.expectRevert(FutureTimestamp.selector);
        (ok,) = address(drifty).call(payload);
        assertTrue(ok, "expectRevert did not fire");
    }

    /*
     *
     * Calldata shape
     *
     */

    function testEmptyCalldataReverts() public {
        vm.prank(creator);
        vm.expectRevert(IOffchainOracle.BadCalldataLength.selector);
        (bool ok,) = address(oracle).call("");
        assertTrue(ok, "expectRevert did not fire");
    }

    function testNonWordAlignedCalldataReverts() public {
        vm.prank(creator);
        vm.expectRevert(IOffchainOracle.BadCalldataLength.selector);
        (bool ok,) = address(oracle).call(hex"aa");
        assertTrue(ok, "expectRevert did not fire");

        // With the 1-byte prefix, a valid push is 1 + 32·N bytes. 34 = 1 + 33 is non-word-aligned
        // (33 % 32 != 0) and must revert.
        bytes memory almostTwoWords = new bytes(34);
        vm.prank(creator);
        vm.expectRevert(IOffchainOracle.BadCalldataLength.selector);
        (ok,) = address(oracle).call(almostTwoWords);
        assertTrue(ok, "expectRevert did not fire");
    }

    /*
     *
     * updateBySignature
     *
     */

    function testUpdateBySignatureHappyPath() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 raw = _packRaw(1_500_000, 4, 2);
        uint256 slotValue = _slotValue(11, 0, raw, tsMs);

        bytes memory sig = _signSlotValue(CREATOR_KEY, creator, slotValue);
        bool updated = oracle.updateBySignature(creator, slotValue, sig);
        assertTrue(updated, "update should report success");

        IOffchainOracle.OracleData memory data = oracle.getOracleData(oracle.feedIdOf(creator, 11, 0));
        assertEq(data.price, U64x32.decode(uint32(raw >> 16)), "signed update price mismatch");
        assertEq(TimeMs.unwrap(data.timestampMs), uint256(tsMs), "signed update timestamp mismatch");
    }

    function testUpdateBySignatureNonNewerReturnsFalse() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint256 first = _slotValue(11, 0, _packRaw(1_500_000, 4, 2), tsMs);
        assertTrue(oracle.updateBySignature(creator, first, _signSlotValue(CREATOR_KEY, creator, first)));

        // same timestamp: returns false, keeps old state
        uint256 second = _slotValue(11, 1, _packRaw(2_500_000, 5, 5), tsMs);
        bool updated = oracle.updateBySignature(creator, second, _signSlotValue(CREATOR_KEY, creator, second));
        assertFalse(updated, "non-newer update should return false");

        IOffchainOracle.OracleData memory data = oracle.getOracleData(oracle.feedIdOf(creator, 11, 0));
        assertEq(data.price, U64x32.decode(uint32(_packRaw(1_500_000, 4, 2) >> 16)), "state must not change");
    }

    function testUpdateBySignatureWrongSignerReverts() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint256 slotValue = _slotValue(11, 0, _packRaw(1_500_000, 4, 2), tsMs);

        // signed by the pusher key, claimed as the creator's namespace
        bytes memory sig = _signSlotValue(PUSHER_KEY, creator, slotValue);
        vm.expectRevert();
        oracle.updateBySignature(creator, slotValue, sig);
    }

    function testUpdateBySignatureSignatureBindsSlotValue() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint256 signedValue = _slotValue(11, 0, _packRaw(1_500_000, 4, 2), tsMs);
        uint256 forgedValue = _slotValue(11, 0, _packRaw(9_000_000, 4, 2), tsMs);

        bytes memory sig = _signSlotValue(CREATOR_KEY, creator, signedValue);
        vm.expectRevert();
        oracle.updateBySignature(creator, forgedValue, sig);
    }

    function testUpdateBySignatureZeroCreatorReverts() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint256 slotValue = _slotValue(11, 0, _packRaw(1_500_000, 4, 2), tsMs);

        vm.expectRevert(ICompressedOracleV1.InvalidNamespace.selector);
        oracle.updateBySignature(address(0), slotValue, "");
    }

    function testUpdateBySignatureFutureTimestampReverts() public {
        uint56 tsMs = uint56((block.timestamp + 1) * 1000);
        uint256 slotValue = _slotValue(11, 0, _packRaw(1_500_000, 4, 2), tsMs);

        bytes memory sig = _signSlotValue(CREATOR_KEY, creator, slotValue);
        vm.expectRevert(FutureTimestamp.selector);
        oracle.updateBySignature(creator, slotValue, sig);
    }

    /*
     *
     * Pusher delegation (EOA pushers)
     *
     */

    function testAllowPushersDelegatesNamespace() public {
        uint256 deadline = block.timestamp + 1 days;
        _allowPusher(deadline);
        assertEq(oracle.namespaceRemapping(pusher), creator, "pusher should map to creator");

        // delegated push lands in the CREATOR namespace, not the pusher's own
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 raw = _packRaw(900_000, 5, 0);
        vm.prank(pusher);
        (bool ok,) = address(oracle).call(_wordAt(2, 3, raw, tsMs));
        assertTrue(ok, "delegated push failed");

        IOffchainOracle.OracleData memory data = oracle.getOracleData(oracle.feedIdOf(creator, 2, 3));
        assertEq(data.price, U64x32.decode(uint32(raw >> 16)), "delegated push should land in creator namespace");

        IOffchainOracle.OracleData memory own = oracle.getOracleData(oracle.feedIdOf(pusher, 2, 3));
        assertEq(own.price, 0, "pusher's own namespace must stay empty");
    }

    function testAllowPushersExpiredDeadlineReverts() public {
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signConsent(PUSHER_KEY, deadline, pusher, creator);

        address[] memory pushers = new address[](1);
        pushers[0] = pusher;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        vm.prank(creator);
        vm.expectRevert(IOffchainOracle.DeadlineExceeded.selector);
        oracle.allowPushers(deadline, pushers, sigs);
    }

    function testAllowPushersSelfRemappingReverts() public {
        uint256 deadline = block.timestamp + 1 days;
        address[] memory pushers = new address[](1);
        pushers[0] = creator;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signConsent(CREATOR_KEY, deadline, creator, creator);

        vm.prank(creator);
        vm.expectRevert(ICompressedOracleV1.NoSelfRemapping.selector);
        oracle.allowPushers(deadline, pushers, sigs);
    }

    function testAllowPushersBadSignatureReverts() public {
        uint256 deadline = block.timestamp + 1 days;
        address[] memory pushers = new address[](1);
        pushers[0] = pusher;
        bytes[] memory sigs = new bytes[](1);
        // valid signature over a DIFFERENT deadline
        sigs[0] = _signConsent(PUSHER_KEY, deadline + 1, pusher, creator);

        vm.prank(creator);
        vm.expectRevert();
        oracle.allowPushers(deadline, pushers, sigs);
    }

    function testRevokePusherRestoresOwnNamespace() public {
        _allowPusher(block.timestamp + 1 days);
        assertEq(oracle.namespaceRemapping(pusher), creator, "precondition: mapped");

        vm.prank(pusher);
        oracle.revokePusher();
        assertEq(oracle.namespaceRemapping(pusher), address(0), "mapping should clear");

        // after revocation the wallet pushes into its OWN namespace again
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 raw = _packRaw(750_000, 2, 2);
        vm.prank(pusher);
        (bool ok,) = address(oracle).call(_wordAt(1, 1, raw, tsMs));
        assertTrue(ok, "self push after revoke failed");

        assertEq(
            oracle.getOracleData(oracle.feedIdOf(pusher, 1, 1)).price,
            U64x32.decode(uint32(raw >> 16)),
            "post-revoke push should land in own namespace"
        );
        assertEq(oracle.getOracleData(oracle.feedIdOf(creator, 1, 1)).price, 0, "creator namespace must stay empty");
    }

    function testRevokePusherWithoutMappingReverts() public {
        vm.prank(pusher);
        vm.expectRevert(ICompressedOracleV1.NoSelfRemapping.selector);
        oracle.revokePusher();
    }

    /// @notice A spent consent cannot be replayed to re-establish a delegation after the pusher
    ///         revoked it — the deadline is a monotonic nonce (usedPusherDeadline).
    function testAllowPushersReplayAfterRevokeReverts() public {
        uint256 deadline = block.timestamp + 30 days;
        _allowPusher(deadline);
        assertEq(oracle.usedPusherDeadline(pusher, creator), deadline, "deadline consumed");

        // Pusher revokes.
        vm.prank(pusher);
        oracle.revokePusher();
        assertEq(oracle.namespaceRemapping(pusher), address(0), "revoked");

        // Creator replays the EXACT same (still-unexpired) signature — must revert, not re-map.
        address[] memory pushers = new address[](1);
        pushers[0] = pusher;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signConsent(PUSHER_KEY, deadline, pusher, creator);

        vm.prank(creator);
        vm.expectRevert(ICompressedOracleV1.StaleConsent.selector);
        oracle.allowPushers(deadline, pushers, sigs);
        assertEq(oracle.namespaceRemapping(pusher), address(0), "delegation must stay revoked");
    }

    /// @notice Re-authorization is still possible, but only with a FRESH consent whose deadline is
    ///         strictly newer than the last one consumed (the pusher must sign again).
    function testAllowPushersReauthorizeRequiresFreshDeadline() public {
        uint256 first = block.timestamp + 10 days;
        _allowPusher(first);

        vm.prank(pusher);
        oracle.revokePusher();

        // A new consent with a strictly greater deadline re-establishes the delegation.
        uint256 second = first + 1;
        address[] memory pushers = new address[](1);
        pushers[0] = pusher;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signConsent(PUSHER_KEY, second, pusher, creator);

        vm.prank(creator);
        oracle.allowPushers(second, pushers, sigs);
        assertEq(oracle.namespaceRemapping(pusher), creator, "fresh consent re-maps");
        assertEq(oracle.usedPusherDeadline(pusher, creator), second, "high-water advanced");
    }

    function testRemovePushersRevokesDelegation() public {
        _allowPusher(block.timestamp + 1 days);

        address[] memory pushers = new address[](1);
        pushers[0] = pusher;
        vm.prank(creator);
        oracle.removePushers(pushers);
        assertEq(oracle.namespaceRemapping(pusher), address(0), "pusher should be revoked");
    }

    function testRemovePushersByStrangerReverts() public {
        _allowPusher(block.timestamp + 1 days);

        address stranger = address(0xD00D);
        address[] memory pushers = new address[](1);
        pushers[0] = pusher;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.InvalidManager.selector, stranger));
        oracle.removePushers(pushers);
    }

    function testRemovePushersSelfReverts() public {
        address[] memory pushers = new address[](1);
        pushers[0] = creator;

        vm.prank(creator);
        vm.expectRevert(ICompressedOracleV1.NoSelfRemapping.selector);
        oracle.removePushers(pushers);
    }

    /*
     *
     * Price guards
     *
     */

    function testSetPriceGuardByCreator() public {
        bytes32 feedId = oracle.feedIdOf(creator, 0, 0);

        vm.prank(creator);
        oracle.setPriceGuard(feedId, 1, 100);

        (uint128 min, uint128 max) = oracle.priceGuard(feedId);
        assertEq(min, 1, "min mismatch");
        assertEq(max, 100, "max mismatch");
    }

    function testSetPriceGuardByStrangerReverts() public {
        bytes32 feedId = oracle.feedIdOf(creator, 0, 0);
        address stranger = address(0xDEAD);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.InvalidGuard.selector, stranger));
        oracle.setPriceGuard(feedId, 1, 100);
    }

    function testSetPriceGuardRejectsInvertedBounds() public {
        bytes32 feedId = oracle.feedIdOf(creator, 0, 0);

        vm.prank(creator);
        vm.expectRevert();
        oracle.setPriceGuard(feedId, 100, 100);
    }

    /*
     *
     * FeedUpdated notarization (quote-side (oracle, feed) join key)
     *
     */

    /// @notice A push writes a whole slot word (up to 4 packed positions) under one monotonic
    ///         timestamp; each non-empty position is a feed that was written → one FeedUpdated each.
    function testFeedUpdatedOncePerNonEmptyPosition() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        bytes memory payload = _slotWord(
            17,
            _packRaw(1_000_000, 3, 5),
            _packRaw(2_000_000, 7, 0),
            _packRaw(3_000_000, 1, 2),
            _packRaw(4_000_000, 9, 9),
            tsMs
        );

        vm.recordLogs();
        vm.prank(creator);
        (bool ok,) = address(oracle).call(payload);
        assertTrue(ok, "push failed");
        assertEq(_countFeedUpdated(vm.getRecordedLogs()), 4, "one FeedUpdated per non-empty position");
    }

    /// @notice Empty (never-set) positions in a written slot emit nothing — only live feeds notarize.
    function testFeedUpdatedSkipsEmptyPositions() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        // Only position 0 carries data; positions 1..3 are zero.
        bytes memory payload = _slotWord(8, _packRaw(1_000_000, 3, 5), 0, 0, 0, tsMs);

        vm.recordLogs();
        vm.prank(creator);
        (bool ok,) = address(oracle).call(payload);
        assertTrue(ok, "push failed");
        assertEq(_countFeedUpdated(vm.getRecordedLogs()), 1, "only the non-empty position notarizes");
    }

    /// @notice The emitted FeedUpdated is keyed by the position's feed id (the indexed topic) and
    ///         carries no other fields.
    function testFeedUpdatedIndexedFeedIdTopic() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        bytes32 feedId = oracle.feedIdOf(creator, 5, 1);

        vm.expectEmit(true, false, false, false, address(oracle));
        emit IOffchainOracle.FeedUpdated(feedId);

        vm.prank(creator);
        (bool ok,) = address(oracle).call(_wordAt(5, 1, _packRaw(1_234_567, 6, 3), tsMs));
        assertTrue(ok, "push failed");
    }

    /// @notice A reserved 0xff/0xff stall-marker position is NOT a live quote, so _notarizeSlot skips it
    ///         (the empty check excludes the stall sentinel 0x…ffff, not just the never-set 0). A live
    ///         position in the same slot still notarizes, so exactly one FeedUpdated fires.
    function testFeedUpdatedSkipsStallPosition() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        // pos0 live, pos1 stalled (0xff/0xff), pos2..3 never-set.
        bytes memory payload = _slotWord(9, _packRaw(1_000_000, 3, 5), _packRaw(2_000_000, 0xff, 0xff), 0, 0, tsMs);

        vm.recordLogs();
        vm.prank(creator);
        (bool ok,) = address(oracle).call(payload);
        assertTrue(ok, "push failed");
        assertEq(
            _countFeedUpdated(vm.getRecordedLogs()), 1, "only the live position notarizes; stall marker is skipped"
        );
    }

    /// @notice A non-newer (equal/older ts) word is skipped by the monotonic gate, so it re-emits no
    ///         FeedUpdated — the event tracks the accepted write exactly.
    function testFeedUpdatedNotEmittedOnNonNewerWord() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        vm.prank(creator);
        (bool ok,) = address(oracle).call(_wordAt(0, 0, _packRaw(1_000_000, 3, 3), tsMs));
        assertTrue(ok, "first push failed");

        vm.recordLogs();
        vm.prank(creator);
        (ok,) = address(oracle).call(_wordAt(0, 0, _packRaw(9_999_999, 8, 8), tsMs)); // equal ts → skipped
        assertTrue(ok, "equal-ts push should not revert");
        assertEq(_countFeedUpdated(vm.getRecordedLogs()), 0, "skipped word must not emit FeedUpdated");
    }

    /// @notice updateBySignature notarizes exactly like the fallback push path.
    function testFeedUpdatedFromUpdateBySignature() public {
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint256 slotValue = _slotValue(11, 0, _packRaw(1_500_000, 4, 2), tsMs);
        bytes memory sig = _signSlotValue(CREATOR_KEY, creator, slotValue);
        bytes32 feedId = oracle.feedIdOf(creator, 11, 0);

        vm.expectEmit(true, false, false, false, address(oracle));
        emit IOffchainOracle.FeedUpdated(feedId);
        assertTrue(oracle.updateBySignature(creator, slotValue, sig), "update should succeed");
    }

    /*
     *
     * PriceRead — the read half of the (oracle, feed) join
     *
     */

    /// @notice `price()` is the compressed lane's half of the off-chain builder's join: FeedUpdated
    ///         sequences the maker write, PriceRead(pool, feedId) the matching read. Exactly ONE per
    ///         call — `price()` reads through the internal `_price`, so adding an emit to
    ///         `getOracleData` later would silently double it and this pins that.
    function testPriceEmitsPriceReadExactlyOnce() public {
        bytes32 feedId = _seedFeed();
        address pool = makeAddr("pool");

        vm.recordLogs();
        oracle.price(feedId, pool);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countPriceRead(logs), 1, "exactly one PriceRead per price() call");
        (address reader, bytes32 loggedFeed) = _firstPriceRead(logs);
        assertEq(reader, pool, "reader is the pool argument");
        assertEq(loggedFeed, feedId, "feedId is the one read");
    }

    /// @notice The oracle logs `pool` AS PASSED. It is permissionless — there is no `inSwap()`
    ///         binding the way the providers oracle has — so the address is the caller's CLAIM, and a
    ///         direct caller can name any pool it likes. Pinned deliberately: a consumer treating this
    ///         event as proof that a given pool read the feed would be wrong, and that has to be a
    ///         decision on record rather than an accident.
    function testPriceReadLogsPoolAsClaimedByAnyCaller() public {
        bytes32 feedId = _seedFeed();
        address notReallyAPool = makeAddr("someoneElsesPool");

        vm.prank(makeAddr("randomCaller"));
        vm.recordLogs();
        oracle.price(feedId, notReallyAPool);

        (address reader,) = _firstPriceRead(vm.getRecordedLogs());
        assertEq(reader, notReallyAPool, "unverified pool claim is logged verbatim");
    }

    /// @notice The view read paths stay silent, so the event covers `price()` and not "every read".
    ///         This contract is deliberately open (it inherits Extsload), so a complete read log is
    ///         not achievable anyway — pinning the boundary keeps it an explicit choice.
    function testViewReadsEmitNothing() public {
        bytes32 feedId = _seedFeed();
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = feedId;

        vm.recordLogs();
        oracle.getOracleData(feedId);
        oracle.getOracleDataBulk(ids);

        assertEq(_countPriceRead(vm.getRecordedLogs()), 0, "view reads must not emit PriceRead");
    }

    /*
     *
     * Helpers
     *
     */

    function _countPriceRead(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(oracle) && logs[i].topics[0] == PRICE_READ_SIG) n++;
        }
    }

    /// @dev Both PriceRead arguments are indexed, so they arrive as topics 1 and 2, not as data.
    function _firstPriceRead(Vm.Log[] memory logs) internal view returns (address reader, bytes32 feedId) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(oracle) && logs[i].topics[0] == PRICE_READ_SIG) {
                return (address(uint160(uint256(logs[i].topics[1]))), logs[i].topics[2]);
            }
        }
        revert("no PriceRead emitted");
    }

    /// @dev A pushed feed to read back; the push path itself is covered elsewhere.
    function _seedFeed() internal returns (bytes32 feedId) {
        vm.prank(creator);
        (bool ok,) = address(oracle).call(_wordAt(5, 1, _packRaw(1_234_567, 6, 3), uint56(block.timestamp * 1000)));
        assertTrue(ok, "seed push failed");
        return oracle.feedIdOf(creator, 5, 1);
    }

    function _countFeedUpdated(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(oracle) && logs[i].topics[0] == FEED_UPDATED_SIG) n++;
        }
    }

    function _allowPusher(uint256 deadline) internal {
        address[] memory pushers = new address[](1);
        pushers[0] = pusher;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _signConsent(PUSHER_KEY, deadline, pusher, creator);

        vm.prank(creator);
        oracle.allowPushers(deadline, pushers, sigs);
    }

    function _signConsent(uint256 pk, uint256 deadline, address _pusher, address _creator)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(block.chainid, address(oracle), deadline, _pusher, _creator))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signSlotValue(uint256 pk, address feedCreator, uint256 slotValue) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(block.chainid, address(oracle), feedCreator, slotValue))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Slot word layout: [data0:6][data1:6][data2:6][data3:6][ts:7][slotId:1]
    function _slotValue(uint8 slotId, uint8 pos, uint48 raw, uint56 tsMs) internal pure returns (uint256 word) {
        require(pos < MAX_PER_SLOT, "invalid position");
        word = (uint256(tsMs) << 8) | uint256(slotId);
        word |= uint256(raw) << (208 - uint256(pos) * 48);
    }

    // Push calldata carries a leading zero byte: its first 4 bytes are then 0x00...., which matches no
    // function selector (none start with 0x00), so the fallback (push path) always wins over dispatch.
    function _wordAt(uint8 slotId, uint8 pos, uint48 raw, uint56 tsMs) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0), _slotValue(slotId, pos, raw, tsMs));
    }

    function _slotWord(uint8 slotId, uint48 d0, uint48 d1, uint48 d2, uint48 d3, uint56 tsMs)
        internal
        pure
        returns (bytes memory)
    {
        uint256 word = (uint256(d0) << 208) | (uint256(d1) << 160) | (uint256(d2) << 112) | (uint256(d3) << 64)
            | (uint256(tsMs) << 8) | uint256(slotId);
        return abi.encodePacked(bytes1(0), word);
    }

    function _packRaw(uint32 price, uint8 s0, uint8 s1) internal pure returns (uint48) {
        return (uint48(price) << 16) | (uint48(s0) << 8) | uint48(s1);
    }

    function _decodeCodebook(uint8 index) internal pure returns (uint16 value) {
        bool ok;
        (value, ok) = Codebook256.decode(index);
        require(ok, "codebook decode failed");
    }
}
