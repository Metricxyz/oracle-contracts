// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {PythLazerStructs} from "pyth-lazer-sdk/PythLazerStructs.sol";

import {LazerConsumer} from "../../../contracts/oracles/utils/LazerConsumer.sol";
import {IOffchainOracle} from "../../../contracts/interfaces/IOffchainOracle.sol";
import {TimeMs, FutureTimestamp} from "../../../contracts/oracles/utils/TimeMs.sol";

contract MockPythLazer {
    bytes public payload;
    address public signer;

    function setPayload(bytes memory newPayload) external {
        payload = newPayload;
    }

    function verifyUpdate(bytes calldata) external payable returns (bytes memory, address) {
        return (payload, signer);
    }
}

contract LazerConsumerHarness is LazerConsumer {
    mapping(bytes32 => IOffchainOracle.OracleData) internal store;

    constructor(address pythLazerAddress)
        LazerConsumer(pythLazerAddress, 60, _defaultExpectedProps())
    {}

    function _defaultExpectedProps() internal pure returns (uint8[] memory props) {
        props = new uint8[](4);
        props[0] = 0;  // Price
        props[1] = 4;  // Exponent
        props[2] = 5;  // Confidence
        props[3] = 12; // FeedUpdateTimestamp
    }

    // Registrationless: every feed id in the verified payload is stored, no registry set.
    function verifyAndStore(uint32[] memory feedIds, bytes memory priceUpdate) external {
        _verifyAndStore(store, feedIds, priceUpdate);
    }

    function get(uint32 feedId) external view returns (IOffchainOracle.OracleData memory) {
        return store[bytes32(uint256(feedId))];
    }
}

contract LazerConsumerTest is Test {

    bytes4 internal constant FORMAT_MAGIC = 0x93c7d375;
    uint32 internal constant FEED0_ID = 8;

    MockPythLazer internal mock;
    LazerConsumerHarness internal consumer;
    uint64 internal tsMicros;

    function setUp() public {
        vm.warp(1_700_000_000); // fixed timestamp for deterministic feed timestamps

        mock = new MockPythLazer();
        consumer = new LazerConsumerHarness(address(mock));

        // LazerConsumer sends 1 wei with verifyUpdate; pre-fund to avoid underflow
        vm.deal(address(consumer), 1 ether);

        tsMicros = uint64(block.timestamp * 1000 * 1000); // microseconds
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _header(uint8 feedsLen, uint8 channel, uint64 tsMicros_) internal pure returns (bytes memory) {
        return abi.encodePacked(FORMAT_MAGIC, tsMicros_, channel, feedsLen);
    }

    function _priceProp(int64 price) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), bytes8(uint64(price)));
    }

    function _expoProp(int16 expo) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(4), bytes2(uint16(expo)));
    }

    function _confProp(uint64 conf) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(5), bytes8(conf));
    }

    function _emaPriceProp(int64 emaPrice) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(10), bytes8(uint64(emaPrice)));
    }

    function _emaConfProp(uint64 emaConf) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(11), bytes8(emaConf));
    }

    function _feedUpdateTsProp(uint64 ts) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(12), uint8(1), bytes8(ts));
    }

    function _feedUpdateTsPropEmpty() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(12), uint8(0));
    }

    /// @dev Standard 4-prop feed body matching the harness config [0, 4, 5, 12].
    function _props4(int64 price, int16 expo, uint64 conf, bytes memory tsProp)
        internal
        pure
        returns (bytes[] memory props)
    {
        props = new bytes[](4);
        props[0] = _priceProp(price);
        props[1] = _expoProp(expo);
        props[2] = _confProp(conf);
        props[3] = tsProp;
    }

    function _feed(uint32 feedId, bytes[] memory props) internal pure returns (bytes memory out) {
        out = abi.encodePacked(feedId, uint8(props.length));
        for (uint256 i; i < props.length; ++i) {
            out = bytes.concat(out, props[i]);
        }
    }

    function _payload(uint64 tsMicros_, uint8 channel, bytes[] memory feeds)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory body;
        for (uint256 i; i < feeds.length; ++i) {
            body = bytes.concat(body, feeds[i]);
        }
        return bytes.concat(_header(uint8(feeds.length), channel, tsMicros_), body);
    }

    function _buildTwoFeedPayload(
        int64 feed0Price,
        int16 feed0Expo,
        int64 price1,
        int16 expo1,
        uint64 conf1,
        uint32 feed1,
        uint64 tsMicros_,
        uint8 channel
    ) internal pure returns (bytes memory payload, uint32[] memory feedIds) {
        // every feed carries the full 4-prop schema;
        // both FeedUpdateTimestamps equal the header timestamp here
        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(FEED0_ID, _props4(feed0Price, feed0Expo, 0, _feedUpdateTsProp(tsMicros_)));
        feeds[1] = _feed(feed1, _props4(price1, expo1, conf1, _feedUpdateTsProp(tsMicros_)));

        payload = _payload(tsMicros_, channel, feeds);

        feedIds = new uint32[](2);
        feedIds[0] = FEED0_ID;
        feedIds[1] = feed1;
    }

    function _twoFeedIds(uint32 feed1) internal pure returns (uint32[] memory feedIds) {
        feedIds = new uint32[](2);
        feedIds[0] = FEED0_ID;
        feedIds[1] = feed1;
    }

    // ─── Happy path ───────────────────────────────────────────────────

    function test_verifyAndStore_handlesNegativeTotalExpo() public {
        (bytes memory payload, uint32[] memory feedIds) = _buildTwoFeedPayload(
            int64(100_000_000), // feed-0 1.0 (1e8 @ -8)
            int16(-8),
            int64(5_000_000_000_000), // large price to exercise the negative-scale branch
            int16(-20),
            uint64(1_000_000),
            1,
            tsMicros,
            uint8(PythLazerStructs.Channel.RealTime)
        );

        mock.setPayload(payload);
        consumer.verifyAndStore(feedIds, "");

        // expo=-20 -> totalExpo=-12 -> rawPrice = 5_000_000_000_000 / 1e12 = 5
        IOffchainOracle.OracleData memory d = consumer.get(1);
        assertEq(d.price, 5);
        assertEq(d.spread0, 1);
        assertEq(TimeMs.unwrap(d.timestampMs), tsMicros / 1000);
    }

    function test_verifyAndStore_storesInvalidMarkerWhenPriceNonPositive() public {
        (bytes memory payload, uint32[] memory feedIds) = _buildTwoFeedPayload(
            int64(100_000_000),
            int16(-8),
            int64(-1),
            int16(-8),
            uint64(1_000_000),
            1,
            tsMicros,
            uint8(PythLazerStructs.Channel.RealTime)
        );

        mock.setPayload(payload);
        consumer.verifyAndStore(feedIds, "");

        // fresh ts but non-positive price → "no price" marker persisted
        IOffchainOracle.OracleData memory d = consumer.get(1);
        assertEq(d.price, 0);
        assertEq(d.spread0, 0xFFFF);
        assertEq(TimeMs.unwrap(d.timestampMs), tsMicros / 1000);
    }

    // ─── Per-feed FeedUpdateTimestamp ─────────────────────────────────

    function test_verifyAndStore_usesPerFeedTimestamp() public {
        uint64 feedTsMicros = tsMicros - 5_000_000;

        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(FEED0_ID, _props4(int64(100_000_000), int16(-8), 0, _feedUpdateTsProp(tsMicros)));
        feeds[1] = _feed(1, _props4(int64(20 * 1e8), int16(-8), uint64(200_000), _feedUpdateTsProp(feedTsMicros)));

        mock.setPayload(_payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds));
        consumer.verifyAndStore(_twoFeedIds(1), "");

        assertEq(TimeMs.unwrap(consumer.get(1).timestampMs), feedTsMicros / 1000);
    }

    function test_verifyAndStore_skipsFeedWithMissingTs_othersPersist() public {
        // First push: feed 1 gets data
        (bytes memory first, uint32[] memory feedIds) = _buildTwoFeedPayload(
            int64(100_000_000),
            int16(-8),
            int64(20 * 1e8),
            int16(-8),
            uint64(200_000),
            1,
            tsMicros,
            uint8(PythLazerStructs.Channel.RealTime)
        );
        mock.setPayload(first);
        consumer.verifyAndStore(feedIds, "");

        IOffchainOracle.OracleData memory stored = consumer.get(1);
        assertEq(stored.price, 2_000_000_000);

        // Second, newer push: feed 1 has no FeedUpdateTimestamp, feed 2 is valid
        uint64 newer = tsMicros + 1_000_000;
        bytes[] memory feeds = new bytes[](3);
        feeds[0] = _feed(FEED0_ID, _props4(int64(100_000_000), int16(-8), 0, _feedUpdateTsProp(newer)));
        feeds[1] = _feed(1, _props4(int64(21 * 1e8), int16(-8), uint64(200_000), _feedUpdateTsPropEmpty()));
        feeds[2] = _feed(2, _props4(int64(30 * 1e8), int16(-8), uint64(200_000), _feedUpdateTsProp(newer)));

        uint32[] memory threeIds = new uint32[](3);
        threeIds[0] = FEED0_ID;
        threeIds[1] = 1;
        threeIds[2] = 2;

        mock.setPayload(_payload(newer, uint8(PythLazerStructs.Channel.RealTime), feeds));
        consumer.verifyAndStore(threeIds, "");

        // feed 1 untouched (skipped), feed 2 stored
        assertEq(consumer.get(1).price, stored.price);
        assertEq(TimeMs.unwrap(consumer.get(1).timestampMs), tsMicros / 1000);
        assertEq(consumer.get(2).price, 3_000_000_000);
        assertEq(TimeMs.unwrap(consumer.get(2).timestampMs), newer / 1000);
    }

    function test_verifyAndStore_revertsFutureFeedTimestamp() public {
        uint64 futureMicros = uint64((block.timestamp + 600) * 1_000_000);

        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(FEED0_ID, _props4(int64(100_000_000), int16(-8), 0, _feedUpdateTsProp(tsMicros)));
        feeds[1] = _feed(1, _props4(int64(20 * 1e8), int16(-8), uint64(200_000), _feedUpdateTsProp(futureMicros)));

        mock.setPayload(_payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds));

        vm.expectRevert(FutureTimestamp.selector);
        consumer.verifyAndStore(_twoFeedIds(1), "");
    }

    function test_verifyAndStore_olderOrEqualTsDoesNotOverwrite() public {
        (bytes memory first, uint32[] memory feedIds) = _buildTwoFeedPayload(
            int64(100_000_000),
            int16(-8),
            int64(20 * 1e8),
            int16(-8),
            uint64(200_000),
            1,
            tsMicros,
            uint8(PythLazerStructs.Channel.RealTime)
        );
        mock.setPayload(first);
        consumer.verifyAndStore(feedIds, "");
        assertEq(consumer.get(1).price, 2_000_000_000);

        // older feed ts → ignored
        (bytes memory older,) = _buildTwoFeedPayload(
            int64(100_000_000),
            int16(-8),
            int64(30 * 1e8),
            int16(-8),
            uint64(200_000),
            1,
            tsMicros - 1_000_000,
            uint8(PythLazerStructs.Channel.RealTime)
        );
        mock.setPayload(older);
        consumer.verifyAndStore(feedIds, "");
        assertEq(consumer.get(1).price, 2_000_000_000);

        // equal feed ts (carried-forward re-push) → ignored as well
        (bytes memory same,) = _buildTwoFeedPayload(
            int64(100_000_000),
            int16(-8),
            int64(40 * 1e8),
            int16(-8),
            uint64(200_000),
            1,
            tsMicros,
            uint8(PythLazerStructs.Channel.RealTime)
        );
        mock.setPayload(same);
        consumer.verifyAndStore(feedIds, "");
        assertEq(consumer.get(1).price, 2_000_000_000);
    }

    function test_verifyAndStore_oversizedTsSkipped() public {
        // µs value whose ms form exceeds the 48-bit packed field → same as absent: skipped on store
        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(FEED0_ID, _props4(int64(100_000_000), int16(-8), 0, _feedUpdateTsProp(tsMicros)));
        feeds[1] = _feed(1, _props4(int64(20 * 1e8), int16(-8), uint64(200_000), _feedUpdateTsProp(type(uint64).max)));

        mock.setPayload(_payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds));
        consumer.verifyAndStore(_twoFeedIds(1), "");

        assertEq(TimeMs.unwrap(consumer.get(1).timestampMs), 0); // nothing stored
    }

    function test_verifyAndStore_oddTsOnInvalidFeed_noPanic() public {
        // Regression: an odd packed ts must never flip the marker bit. Previously the
        // header ts landed in bit 0 of default entries and an odd value sent them
        // through _normalize (division by zero panic).
        uint64 oddTsMicros = tsMicros + 1_001_000; // ms component becomes odd
        assertEq((oddTsMicros / 1000) % 2, 1);

        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(FEED0_ID, _props4(int64(100_000_000), int16(-8), 0, _feedUpdateTsProp(tsMicros)));
        feeds[1] = _feed(1, _props4(int64(-1), int16(-8), uint64(200_000), _feedUpdateTsProp(oddTsMicros)));

        mock.setPayload(_payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds));
        consumer.verifyAndStore(_twoFeedIds(1), "");

        IOffchainOracle.OracleData memory d = consumer.get(1);
        assertEq(d.price, 0);
        assertEq(d.spread0, 0xFFFF);
        assertEq(TimeMs.unwrap(d.timestampMs), oddTsMicros / 1000);
    }

    function test_verifyAndStore_oddTsHappyPath() public {
        uint64 oddTsMicros = tsMicros + 1_001_000;

        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(FEED0_ID, _props4(int64(100_000_000), int16(-8), 0, _feedUpdateTsProp(tsMicros)));
        feeds[1] = _feed(1, _props4(int64(20 * 1e8), int16(-8), uint64(200_000), _feedUpdateTsProp(oddTsMicros)));

        mock.setPayload(_payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds));
        consumer.verifyAndStore(_twoFeedIds(1), "");

        IOffchainOracle.OracleData memory d = consumer.get(1);
        assertEq(d.price, 2_000_000_000);
        assertEq(d.spread0, 1);
        assertEq(TimeMs.unwrap(d.timestampMs), oddTsMicros / 1000);
    }

    function test_constructor_revertsWithoutFeedUpdateTsProp() public {
        uint8[] memory props = new uint8[](3);
        props[0] = 0;
        props[1] = 4;
        props[2] = 5;

        vm.expectRevert(bytes("FeedUpdateTimestamp property required"));
        new LazerConsumer(address(mock), 60, props);
    }

    // ─── verifyAndStore ───────────────────────────────────────────────

    function test_verifyAndStore_persistsData() public {
        (bytes memory payload, uint32[] memory feedIds) = _buildTwoFeedPayload(
            int64(100_000_000),
            int16(-8),
            int64(20 * 1e8),
            int16(-8),
            uint64(200_000),
            1,
            tsMicros,
            uint8(PythLazerStructs.Channel.RealTime)
        );

        mock.setPayload(payload);
        consumer.verifyAndStore(feedIds, "");

        IOffchainOracle.OracleData memory d = consumer.get(1);
        assertEq(d.price, 2_000_000_000);
        assertEq(d.spread0, 1);
        assertEq(d.spread1, 0xFFFF);
        assertEq(TimeMs.unwrap(d.timestampMs), tsMicros / 1000);
    }

    function test_verifyAndStore_revertsFutureTimestamp() public {
        uint64 futureMicros = uint64((block.timestamp + 600) * 1_000_000);

        (bytes memory payload, uint32[] memory feedIds) = _buildTwoFeedPayload(
            int64(100_000_000),
            int16(-8),
            int64(20 * 1e8),
            int16(-8),
            uint64(200_000),
            1,
            futureMicros,
            uint8(PythLazerStructs.Channel.RealTime)
        );

        mock.setPayload(payload);

        // the first feed.s future ts is rejected by the per-feed check in the loop
        vm.expectRevert(FutureTimestamp.selector);
        consumer.verifyAndStore(feedIds, "");
    }

    // ─── Input validation / reverts ───────────────────────────────────

    function test_feedsLengthMismatch_reverts() public {
        (bytes memory payload,) = _buildTwoFeedPayload(
            int64(100_000_000),
            int16(-8),
            int64(20 * 1e8),
            int16(-8),
            uint64(200_000),
            1,
            tsMicros,
            uint8(PythLazerStructs.Channel.RealTime)
        );

        uint32[] memory feedIds = new uint32[](1);
        feedIds[0] = FEED0_ID;

        mock.setPayload(payload);

        vm.expectRevert(abi.encodeWithSelector(LazerConsumer.FeedsLengthMismatch.selector, 2, 1));
        consumer.verifyAndStore(feedIds, "");
    }

    function test_missingRequiredFields_singleFeed_reverts() public {
        // feed with only 1 property (expects 4)
        bytes[] memory feedProps = new bytes[](1);
        feedProps[0] = _expoProp(int16(-8));

        bytes[] memory feeds = new bytes[](1);
        feeds[0] = _feed(FEED0_ID, feedProps);

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);
        uint32[] memory feedIds = new uint32[](1);
        feedIds[0] = FEED0_ID;

        mock.setPayload(payload);

        vm.expectRevert(abi.encodeWithSelector(LazerConsumer.UnexpectedPropsCount.selector, 4, 1));
        consumer.verifyAndStore(feedIds, "");
    }

    function test_missingRequiredFields_feed_reverts() public {
        // right prop count but a duplicated pid → foundMask misses Confidence
        bytes[] memory feedProps = new bytes[](4);
        feedProps[0] = _priceProp(int64(20 * 1e8));
        feedProps[1] = _expoProp(int16(-8));
        feedProps[2] = _expoProp(int16(-8)); // duplicate instead of confidence
        feedProps[3] = _feedUpdateTsProp(tsMicros);

        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(FEED0_ID, _props4(int64(100_000_000), int16(-8), 0, _feedUpdateTsProp(tsMicros)));
        feeds[1] = _feed(1, feedProps);

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);

        mock.setPayload(payload);

        // expected mask [0,4,5,12] = 0x1031, found [0,4,12] = 0x1011
        vm.expectRevert(abi.encodeWithSelector(LazerConsumer.UnexpectedPropsCount.selector, 0x1031, 0x1011));
        consumer.verifyAndStore(_twoFeedIds(1), "");
    }

    function test_feedIdMismatch_reverts() public {
        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(FEED0_ID, _props4(int64(100_000_000), int16(-8), 0, _feedUpdateTsProp(tsMicros)));
        feeds[1] = _feed(2, _props4(int64(20 * 1e8), int16(-8), uint64(1_000_000), _feedUpdateTsProp(tsMicros))); // actual id 2

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);

        uint32[] memory feedIds = new uint32[](2);
        feedIds[0] = FEED0_ID;
        feedIds[1] = 1; // expected id 1

        mock.setPayload(payload);

        vm.expectRevert(abi.encodeWithSelector(LazerConsumer.FeedIdMismatch.selector, 1, 1, 2));
        consumer.verifyAndStore(feedIds, "");
    }

    function test_payloadLengthMismatch_reverts() public {
        (bytes memory payload, uint32[] memory feedIds) = _buildTwoFeedPayload(
            int64(100_000_000),
            int16(-8),
            int64(20 * 1e8),
            int16(-8),
            uint64(200_000),
            1,
            tsMicros,
            uint8(PythLazerStructs.Channel.RealTime)
        );

        bytes memory padded = bytes.concat(payload, hex"ff");

        mock.setPayload(padded);

        vm.expectRevert(
            abi.encodeWithSelector(LazerConsumer.PayloadLengthMismatch.selector, payload.length, padded.length)
        );
        consumer.verifyAndStore(feedIds, "");
    }

    function test_invalidMagic_reverts() public {
        bytes memory feed = _feed(FEED0_ID, _props4(int64(100_000_000), int16(-8), 0, _feedUpdateTsProp(tsMicros)));
        bytes memory payload = abi.encodePacked(bytes4(0xDEADBEEF), tsMicros, uint8(1), uint8(1), feed);

        uint32[] memory feedIds = new uint32[](1);
        feedIds[0] = FEED0_ID;

        mock.setPayload(payload);

        vm.expectRevert(LazerConsumer.InvalidMagic.selector);
        consumer.verifyAndStore(feedIds, "");
    }

    // ─── Strict validation (reverts on unexpected properties) ────────

    function test_verifyAndStore_revertsOnUnexpectedProperty() public {
        // Feed with 6 properties including unexpected ones (ema price, ema conf)
        bytes[] memory feedProps = new bytes[](6);
        feedProps[0] = _priceProp(int64(20 * 1e8));
        feedProps[1] = _expoProp(int16(-8));
        feedProps[2] = _confProp(uint64(200_000));
        feedProps[3] = _emaPriceProp(int64(19 * 1e8));
        feedProps[4] = _emaConfProp(uint64(150_000));
        feedProps[5] = _feedUpdateTsProp(uint64(1_700_000_000_000_000));

        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(FEED0_ID, _props4(int64(100_000_000), int16(-8), 0, _feedUpdateTsProp(tsMicros)));
        feeds[1] = _feed(1, feedProps);

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);

        mock.setPayload(payload);

        vm.expectRevert(abi.encodeWithSelector(LazerConsumer.UnexpectedPropsCount.selector, 4, 6));
        consumer.verifyAndStore(_twoFeedIds(1), "");
    }

    function test_noFeeds_reverts() public {
        bytes memory feed = _feed(FEED0_ID, _props4(int64(100_000_000), int16(-8), 0, _feedUpdateTsProp(tsMicros)));

        // feedsLen set to 0 in header, but payload still includes a feed section; contract will revert with NoFeeds()
        bytes memory payload = abi.encodePacked(FORMAT_MAGIC, tsMicros, uint8(1), uint8(0), feed);

        uint32[] memory feedIds = new uint32[](0);

        mock.setPayload(payload);

        vm.expectRevert(LazerConsumer.NoFeeds.selector);
        consumer.verifyAndStore(feedIds, "");
    }

    // ─── New validation tests ─────────────────────────────────────────

    function test_revertsWhenWrongPropsCount() public {
        // feed with only 3 properties instead of expected 4
        bytes[] memory feedProps = new bytes[](3);
        feedProps[0] = _priceProp(int64(100_000_000));
        feedProps[1] = _expoProp(int16(-8));
        feedProps[2] = _confProp(0);

        bytes[] memory feeds = new bytes[](1);
        feeds[0] = _feed(FEED0_ID, feedProps);

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);

        uint32[] memory feedIds = new uint32[](1);
        feedIds[0] = FEED0_ID;

        mock.setPayload(payload);

        vm.expectRevert(abi.encodeWithSelector(LazerConsumer.UnexpectedPropsCount.selector, 4, 3));
        consumer.verifyAndStore(feedIds, "");
    }

    function test_revertsOnUnexpectedProperty() public {
        // Feed with 4 properties but one is unexpected (emaPrice instead of confidence)
        bytes[] memory feedProps = new bytes[](4);
        feedProps[0] = _priceProp(int64(100_000_000));
        feedProps[1] = _expoProp(int16(-8));
        feedProps[2] = _emaPriceProp(int64(99_000_000)); // pid 10 not in config
        feedProps[3] = _feedUpdateTsProp(tsMicros);

        bytes[] memory feeds = new bytes[](1);
        feeds[0] = _feed(FEED0_ID, feedProps);

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);

        uint32[] memory feedIds = new uint32[](1);
        feedIds[0] = FEED0_ID;

        mock.setPayload(payload);

        vm.expectRevert(abi.encodeWithSelector(LazerConsumer.UnknownProperty.selector, 10));
        consumer.verifyAndStore(feedIds, "");
    }

    // ─── _normalize exponent bounds (overflow-safe ±57) ───────────────

    function _expoPayload(int16 feedExpo) internal pure returns (bytes memory payload, uint32[] memory feedIds) {
        // no USD conversion: totalExpo = feedExpo + 8
        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(FEED0_ID, _props4(int64(100_000_000), int16(-8), 0, _feedUpdateTsProp(1_700_000_000_000_000)));
        feeds[1] = _feed(1, _props4(int64(20 * 1e8), feedExpo, uint64(200_000), _feedUpdateTsProp(1_700_000_000_000_000)));
        payload = _payload(1_700_000_000_000_000, uint8(PythLazerStructs.Channel.RealTime), feeds);
        feedIds = new uint32[](2);
        feedIds[0] = FEED0_ID;
        feedIds[1] = 1;
    }

    function test_normalize_totalExpoAbove57_reverts() public {
        (bytes memory payload, uint32[] memory feedIds) = _expoPayload(int16(50)); // totalExpo = 58
        mock.setPayload(payload);
        vm.expectRevert(); // bare require in _normalize
        consumer.verifyAndStore(feedIds, "");
    }

    function test_normalize_totalExpoBelowMinus57_reverts() public {
        (bytes memory payload, uint32[] memory feedIds) = _expoPayload(int16(-66)); // totalExpo = -58
        mock.setPayload(payload);
        vm.expectRevert();
        consumer.verifyAndStore(feedIds, "");
    }

    function test_normalize_totalExpoAtMinus57_storesZeroPrice() public {
        // boundary passes the require; the scale crushes the price to 0 without any wrap
        (bytes memory payload, uint32[] memory feedIds) = _expoPayload(int16(-65)); // totalExpo = -57
        mock.setPayload(payload);
        consumer.verifyAndStore(feedIds, "");

        IOffchainOracle.OracleData memory d = consumer.get(1);
        assertEq(d.price, 0); // 2e9 / (1e8 · 10^57) = 0, no overflow
        assertEq(d.spread0, 1);
        assertEq(TimeMs.unwrap(d.timestampMs), 1_700_000_000_000);
    }
}
