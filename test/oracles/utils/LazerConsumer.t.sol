// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {PythLazerStructs} from "pyth-lazer-sdk/PythLazerStructs.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

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
    using EnumerableSet for EnumerableSet.Bytes32Set;

    EnumerableSet.Bytes32Set internal _feedIds;
    mapping(bytes32 => IOffchainOracle.OracleData) internal store;

    constructor(address pythLazerAddress, uint32 usdConversionFeedId)
        LazerConsumer(pythLazerAddress, 60, usdConversionFeedId, _defaultExpectedProps())
    {}

    function _defaultExpectedProps() internal pure returns (uint8[] memory props) {
        props = new uint8[](3);
        props[0] = 0; // Price
        props[1] = 4; // Exponent
        props[2] = 5; // Confidence
    }

    function verifyAndStore(uint32[] memory feedIds, bytes memory priceUpdate) external {
        for (uint256 i; i < feedIds.length; ++i) {
            _feedIds.add(bytes32(uint256(feedIds[i])));
        }
        _verifyAndStore(_feedIds, store, feedIds, priceUpdate);
    }

    function get(uint32 feedId) external view returns (IOffchainOracle.OracleData memory) {
        return store[bytes32(uint256(feedId))];
    }
}

contract LazerConsumerTest is Test {

    bytes4 internal constant FORMAT_MAGIC = 0x93c7d375;
    uint32 internal constant USDT_ID = 8;

    MockPythLazer internal mock;
    LazerConsumerHarness internal consumer;
    uint64 internal tsMicros;

    function setUp() public {
        vm.warp(1_700_000_000); // fixed timestamp for deterministic tsPart

        mock = new MockPythLazer();
        consumer = new LazerConsumerHarness(address(mock), USDT_ID);

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
        int64 usdtPrice,
        int16 usdtExpo,
        int64 price1,
        int16 expo1,
        uint64 conf1,
        uint32 feed1,
        uint64 tsMicros_,
        uint8 channel
    ) internal pure returns (bytes memory payload, uint32[] memory feedIds) {
        // USDT feed now gets 3 properties (same schema as all feeds)
        bytes[] memory usdtProps = new bytes[](3);
        usdtProps[0] = _priceProp(usdtPrice);
        usdtProps[1] = _expoProp(usdtExpo);
        usdtProps[2] = _confProp(0); // confidence parsed but unused for USDT

        bytes[] memory feedProps = new bytes[](3);
        feedProps[0] = _priceProp(price1);
        feedProps[1] = _expoProp(expo1);
        feedProps[2] = _confProp(conf1);

        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(USDT_ID, usdtProps);
        feeds[1] = _feed(feed1, feedProps);

        payload = _payload(tsMicros_, channel, feeds);

        feedIds = new uint32[](2);
        feedIds[0] = USDT_ID;
        feedIds[1] = feed1;
    }

    // ─── Happy path ───────────────────────────────────────────────────

    function test_verifyAndStream_normalizesPrice() public {
        (bytes memory payload, uint32[] memory feedIds) = _buildTwoFeedPayload(
            int64(100_000_000), // 1.0 USDT with expo -8
            int16(-8),
            int64(20 * 1e8),
            int16(-8),
            uint64(200_000),
            1,
            tsMicros,
            uint8(PythLazerStructs.Channel.RealTime)
        );

        mock.setPayload(payload);

        uint256[] memory values = consumer.verifyAndStream(feedIds, "");
        assertEq(values.length, 1);

        (uint32 feedId, uint64 price, uint16 spread, uint64 ts) = consumer.unpack(values[0]);
        assertEq(feedId, 1);
        assertEq(price, 6_294_967_296); // includes feedId<<32 due to packing
        assertEq(spread, 1); // ceilDiv(1e4 * 200k / 2e9) = 1
        assertEq(ts, tsMicros / 1000);
    }

    function test_verifyAndStream_handlesNegativeTotalExpo() public {
        (bytes memory payload, uint32[] memory feedIds) = _buildTwoFeedPayload(
            int64(100_000_000), // USDT 1e8, expo -8
            int16(-8),
            int64(5_000_000_000_000), // large price to exercise negative branch but keep pack within 32 bits
            int16(-20),
            uint64(1_000_000),
            1,
            tsMicros,
            uint8(PythLazerStructs.Channel.RealTime)
        );

        mock.setPayload(payload);

        uint256[] memory values = consumer.verifyAndStream(feedIds, "");
        (,, uint16 spread, uint64 ts) = consumer.unpack(values[0]);

        // expo=-20, usdtExpo=-8 → totalExpo=-4 ⇒ scale=10^4, rawPrice=5_000_000_000_000 / 1e12 = 5
        (, uint64 price,,) = consumer.unpack(values[0]);
        assertEq(price, 4_294_967_301); // 5 + feedId<<32
        assertEq(spread, 1);
        assertEq(ts, tsMicros / 1000);
    }

    function test_verifyAndStream_defaultsWhenPriceNonPositive() public {
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

        uint256[] memory values = consumer.verifyAndStream(feedIds, "");
        (uint32 feedId, uint64 price, uint16 spread, uint64 ts) = consumer.unpack(values[0]);

        assertEq(feedId, 1);
        assertEq(price, 4_294_967_296); // feedId<<32, normPrice=0
        assertEq(spread, 10_000);
        assertEq(ts, tsMicros / 1000);
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
        assertEq(d.spread, 1);
        assertEq(d.volatility, 0xFFFF);
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
        feedIds[0] = USDT_ID;

        mock.setPayload(payload);

        vm.expectRevert(abi.encodeWithSelector(LazerConsumer.FeedsLengthMismatch.selector, 2, 1));
        consumer.verifyAndStream(feedIds, "");
    }

    function test_wrongUsdtFeedId_reverts() public {
        bytes[] memory usdtProps = new bytes[](3);
        usdtProps[0] = _priceProp(int64(100_000_000));
        usdtProps[1] = _expoProp(int16(-8));
        usdtProps[2] = _confProp(0);

        bytes[] memory feeds = new bytes[](1);
        feeds[0] = _feed(uint32(9), usdtProps);

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);
        uint32[] memory feedIds = new uint32[](1);
        feedIds[0] = USDT_ID;

        mock.setPayload(payload);

        vm.expectRevert();
        consumer.verifyAndStream(feedIds, "");
    }

    function test_missingRequiredFields_usdt_reverts() public {
        // USDT feed with only 1 property (expects 3)
        bytes[] memory usdtProps = new bytes[](1);
        usdtProps[0] = _expoProp(int16(-8));

        bytes[] memory feeds = new bytes[](1);
        feeds[0] = _feed(USDT_ID, usdtProps);

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);
        uint32[] memory feedIds = new uint32[](1);
        feedIds[0] = USDT_ID;

        mock.setPayload(payload);

        vm.expectRevert();
        consumer.verifyAndStream(feedIds, "");
    }

    function test_missingRequiredFields_feed_reverts() public {
        bytes[] memory usdtProps = new bytes[](3);
        usdtProps[0] = _priceProp(int64(100_000_000));
        usdtProps[1] = _expoProp(int16(-8));
        usdtProps[2] = _confProp(0);

        bytes[] memory feedProps = new bytes[](2); // missing confidence
        feedProps[0] = _priceProp(int64(20 * 1e8));
        feedProps[1] = _expoProp(int16(-8));

        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(USDT_ID, usdtProps);
        feeds[1] = _feed(1, feedProps);

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);

        uint32[] memory feedIds = new uint32[](2);
        feedIds[0] = USDT_ID;
        feedIds[1] = 1;

        mock.setPayload(payload);

        vm.expectRevert();
        consumer.verifyAndStream(feedIds, "");
    }

    function test_feedIdMismatch_reverts() public {
        bytes[] memory usdtProps = new bytes[](3);
        usdtProps[0] = _priceProp(int64(100_000_000));
        usdtProps[1] = _expoProp(int16(-8));
        usdtProps[2] = _confProp(0);

        bytes[] memory feedProps = new bytes[](3);
        feedProps[0] = _priceProp(int64(20 * 1e8));
        feedProps[1] = _expoProp(int16(-8));
        feedProps[2] = _confProp(uint64(1_000_000));

        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(USDT_ID, usdtProps);
        feeds[1] = _feed(2, feedProps); // actual id 2

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);

        uint32[] memory feedIds = new uint32[](2);
        feedIds[0] = USDT_ID;
        feedIds[1] = 1; // expected id 1

        mock.setPayload(payload);

        vm.expectRevert();
        consumer.verifyAndStream(feedIds, "");
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

        vm.expectRevert();
        consumer.verifyAndStream(feedIds, "");
    }

    function test_invalidMagic_reverts() public {
        bytes[] memory usdtProps = new bytes[](3);
        usdtProps[0] = _priceProp(int64(100_000_000));
        usdtProps[1] = _expoProp(int16(-8));
        usdtProps[2] = _confProp(0);

        bytes[] memory feeds = new bytes[](1);
        feeds[0] = _feed(USDT_ID, usdtProps);

        bytes memory payload = abi.encodePacked(bytes4(0xDEADBEEF), tsMicros, uint8(1), uint8(1), feeds[0]);

        uint32[] memory feedIds = new uint32[](1);
        feedIds[0] = USDT_ID;

        mock.setPayload(payload);

        vm.expectRevert();
        consumer.verifyAndStream(feedIds, "");
    }

    function test_invalidUsdtPrice_reverts() public {
        bytes[] memory usdtProps = new bytes[](3);
        usdtProps[0] = _priceProp(int64(0)); // invalid price
        usdtProps[1] = _expoProp(int16(-8));
        usdtProps[2] = _confProp(0);

        bytes[] memory feeds = new bytes[](1);
        feeds[0] = _feed(USDT_ID, usdtProps);

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);

        uint32[] memory feedIds = new uint32[](1);
        feedIds[0] = USDT_ID;

        mock.setPayload(payload);

        vm.expectRevert();
        consumer.verifyAndStream(feedIds, "");
    }

    // ─── Strict validation (reverts on unexpected properties) ────────

    function test_verifyAndStream_revertsOnUnexpectedProperty() public {
        // USDT feed: 3 expected properties
        bytes[] memory usdtProps = new bytes[](3);
        usdtProps[0] = _priceProp(int64(100_000_000));
        usdtProps[1] = _expoProp(int16(-8));
        usdtProps[2] = _confProp(0);

        // Feed with 6 properties including unexpected ones (ema price, ema conf, feed update ts)
        bytes[] memory feedProps = new bytes[](6);
        feedProps[0] = _priceProp(int64(20 * 1e8));
        feedProps[1] = _expoProp(int16(-8));
        feedProps[2] = _confProp(uint64(200_000));
        feedProps[3] = _emaPriceProp(int64(19 * 1e8));
        feedProps[4] = _emaConfProp(uint64(150_000));
        feedProps[5] = _feedUpdateTsProp(uint64(1_700_000_000_000));

        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(USDT_ID, usdtProps);
        feeds[1] = _feed(1, feedProps);

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);

        uint32[] memory feedIds = new uint32[](2);
        feedIds[0] = USDT_ID;
        feedIds[1] = 1;

        mock.setPayload(payload);

        // numProps (6) != expected (3), reverts with UnexpectedPropsCount
        vm.expectRevert();
        consumer.verifyAndStream(feedIds, "");
    }

    function test_verifyAndStream_revertsOnEmptyFeedUpdateTs() public {
        // USDT feed: 3 expected properties
        bytes[] memory usdtProps = new bytes[](3);
        usdtProps[0] = _priceProp(int64(100_000_000));
        usdtProps[1] = _expoProp(int16(-8));
        usdtProps[2] = _confProp(0);

        // Feed with price, expo, conf + empty FeedUpdateTimestamp (4 props, expects 3)
        bytes[] memory feedProps = new bytes[](4);
        feedProps[0] = _priceProp(int64(20 * 1e8));
        feedProps[1] = _expoProp(int16(-8));
        feedProps[2] = _confProp(uint64(200_000));
        feedProps[3] = _feedUpdateTsPropEmpty();

        bytes[] memory feeds = new bytes[](2);
        feeds[0] = _feed(USDT_ID, usdtProps);
        feeds[1] = _feed(1, feedProps);

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);

        uint32[] memory feedIds = new uint32[](2);
        feedIds[0] = USDT_ID;
        feedIds[1] = 1;

        mock.setPayload(payload);

        // numProps (4) != expected (3), reverts
        vm.expectRevert();
        consumer.verifyAndStream(feedIds, "");
    }

    function test_noFeeds_reverts() public {
        bytes[] memory usdtProps = new bytes[](3);
        usdtProps[0] = _priceProp(int64(100_000_000));
        usdtProps[1] = _expoProp(int16(-8));
        usdtProps[2] = _confProp(0);

        bytes[] memory feeds = new bytes[](1);
        feeds[0] = _feed(USDT_ID, usdtProps);

        // feedsLen set to 0 in header, but payload still includes USDT section; contract will revert with NoFeeds()
        bytes memory payload = abi.encodePacked(FORMAT_MAGIC, tsMicros, uint8(1), uint8(0), feeds[0]);

        uint32[] memory feedIds = new uint32[](0);

        mock.setPayload(payload);

        vm.expectRevert(LazerConsumer.NoFeeds.selector);
        consumer.verifyAndStream(feedIds, "");
    }

    // ─── New validation tests ─────────────────────────────────────────

    function test_revertsWhenWrongPropsCount() public {
        // USDT feed with only 2 properties instead of expected 3
        bytes[] memory usdtProps = new bytes[](2);
        usdtProps[0] = _priceProp(int64(100_000_000));
        usdtProps[1] = _expoProp(int16(-8));

        bytes[] memory feeds = new bytes[](1);
        feeds[0] = _feed(USDT_ID, usdtProps);

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);

        uint32[] memory feedIds = new uint32[](1);
        feedIds[0] = USDT_ID;

        mock.setPayload(payload);

        vm.expectRevert();
        consumer.verifyAndStream(feedIds, "");
    }

    function test_revertsOnUnexpectedProperty() public {
        // Feed with 3 properties but one is unexpected (emaPrice instead of confidence)
        bytes[] memory usdtProps = new bytes[](3);
        usdtProps[0] = _priceProp(int64(100_000_000));
        usdtProps[1] = _expoProp(int16(-8));
        usdtProps[2] = _emaPriceProp(int64(99_000_000)); // pid 10 not in config

        bytes[] memory feeds = new bytes[](1);
        feeds[0] = _feed(USDT_ID, usdtProps);

        bytes memory payload = _payload(tsMicros, uint8(PythLazerStructs.Channel.RealTime), feeds);

        uint32[] memory feedIds = new uint32[](1);
        feedIds[0] = USDT_ID;

        mock.setPayload(payload);

        vm.expectRevert();
        consumer.verifyAndStream(feedIds, "");
    }
}
