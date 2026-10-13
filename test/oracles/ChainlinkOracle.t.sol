// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ChainlinkOracle} from "../../contracts/oracles/providers/ChainlinkOracle.sol";
import {IOffchainOracle} from "../../contracts/interfaces/IOffchainOracle.sol";
import {ReportV3, ReportV4, ReportHFS} from "../../contracts/interfaces/IDataStreams.sol";
import {FutureTimestamp, ZeroTimestamp} from "../../contracts/oracles/utils/TimeMs.sol";
import {MockVerifierProxy} from "../mocks/MockVerifierProxy.sol";
import {MockPoolFactory} from "../mocks/MockPoolFactory.sol";
import {IPool} from "../../contracts/interfaces/IPoolFactory.sol";

/// @notice ChainlinkOracle is REGISTRATIONLESS: any DON-verified report is stored (the
///         VerifierProxy signature is the trust anchor). A feed "exists" for readers once
///         its first verified report lands.
contract ChainlinkOracleTest is Test {
    uint256 private constant MAX_DRIFT = 60;
    uint256 private constant T0 = 1_000_000;

    // 18-dec inputs → 8-dec mid; bid/ask chosen so spread = 20 bps = 2000 in 0.01-bps units.
    int192 private constant PRICE = 150e18;
    int192 private constant BID = 1497e17; // 149.7e18
    int192 private constant ASK = 1503e17; // 150.3e18
    uint64 private constant MID8 = 15_000_000_000; // 150e8
    uint16 private constant SPREAD_UNITS = 2000; // 20 bps in 0.01-bps units

    // Version tags (mirror ChainlinkOracle.TAG_V050 / TAG_V051). Reports are prefixed with a tag
    // byte that routes them to the matching VerifierProxy. Builders default to the v0.5.0 (payable)
    // path; the v0.5.1 (verifyView) path is exercised explicitly.
    uint8 private constant TAG_V050 = 0x50;
    uint8 private constant TAG_V051 = 0x51;

    ChainlinkOracle private oracle;
    MockVerifierProxy private verifier; // v0.5.0-style: payable verify
    MockVerifierProxy private verifierView; // v0.5.1-style: fee-free verifyView
    MockPoolFactory private factory;
    address private pool;
    uint16 private spreadCase;

    function setUp() public {
        verifier = new MockVerifierProxy();
        verifierView = new MockVerifierProxy();

        ChainlinkOracle.VerifierRoute[] memory routes = new ChainlinkOracle.VerifierRoute[](2);
        routes[0] = ChainlinkOracle.VerifierRoute(TAG_V050, address(verifier), false);
        routes[1] = ChainlinkOracle.VerifierRoute(TAG_V051, address(verifierView), true);
        oracle = new ChainlinkOracle(address(this), MAX_DRIFT, routes, makeAddr("feeToken"));
        vm.deal(address(oracle), 1 ether); // fund verification-fee pool

        factory = new MockPoolFactory();
        oracle.addApprovedFactory(address(factory));
        pool = makeAddr("pool");
        factory.setPool(pool, true);
        vm.deal(address(this), 1 ether); // pool registration fee

        vm.warp(T0);
    }

    // ── feedId builders (byte0 high nibble = resolution; standard version in high 2 bytes) ──
    function _v3Feed(uint16 idx) internal pure returns (bytes32) {
        return bytes32((uint256(3) << 240) | uint256(idx)); // byte0=0x00 (sec), version 3
    }

    function _v4Feed(uint16 idx) internal pure returns (bytes32) {
        return bytes32((uint256(4) << 240) | uint256(idx)); // byte0=0x00 (sec), version 4
    }

    function _hfsFeed(uint16 idx) internal pure returns (bytes32) {
        return bytes32((uint256(0x1003) << 240) | uint256(idx)); // 0x1003: ms nibble (1) + base schema v3
    }

    // ── report blob builders (prefixed with the default v0.5.0 version tag) ──
    // MockVerifierProxy echoes the payload it receives, so the report blob doubles as the
    // "verified" reportData. The leading tag byte routes the payload; _verifyReport strips it.
    function _v3(bytes32 feedId, int192 price, int192 bid, int192 ask, uint32 obsSec)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            TAG_V050, abi.encode(ReportV3(feedId, obsSec, obsSec, 0, 0, obsSec + 3600, price, bid, ask))
        );
    }

    function _v4(bytes32 feedId, int192 price, uint32 marketStatus, uint32 obsSec)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            TAG_V050, abi.encode(ReportV4(feedId, obsSec, obsSec, 0, 0, obsSec + 3600, price, marketStatus))
        );
    }

    function _hfs(bytes32 feedId, int192 price, int192 bid, int192 ask, uint64 obsMs)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            TAG_V050, abi.encode(ReportHFS(feedId, obsMs, obsMs, 0, 0, obsMs + 3_600_000, price, bid, ask))
        );
    }

    /// @dev Re-tag an already-tagged payload to route it to a different VerifierProxy version.
    function _retag(uint8 tag, bytes memory tagged) internal pure returns (bytes memory) {
        bytes memory raw = new bytes(tagged.length - 1);
        for (uint256 i; i < raw.length; ++i) {
            raw[i] = tagged[i + 1];
        }
        return abi.encodePacked(tag, raw);
    }

    // ── attributed read (public getters disabled in OracleBase) ──
    function _read(bytes32 feedId) internal returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) {
        if (!oracle.registeredPool(feedId, pool)) oracle.register{value: 1}(feedId, pool, address(factory));
        vm.mockCall(pool, abi.encodeWithSelector(IPool.inSwap.selector), abi.encode(address(this)));
        return oracle.price(feedId, pool);
    }

    function test_kindAndVersion() public view {
        assertEq(oracle.kind(), "chainlink-datastreams");
        assertEq(oracle.version(), "1.1.0");
    }

    // ── v3 (Crypto, seconds) ────────────────────────────────────────────

    function test_v3_storesAndReads() public {
        bytes32 feedId = _v3Feed(1);
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));

        (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) = _read(feedId);
        assertEq(mid, MID8, "mid = price/1e10");
        assertEq(spread, SPREAD_UNITS, "spread = ceil(SPREAD_SCALE*max(ask-price,price-bid) / price)");
        assertEq(spread1, 0xFFFF);
        assertEq(refTime, T0, "refTime = observationsTimestamp (sec)");
    }

    /// @notice spread0 is emitted in 0.01-bps units (fraction × 1e6), matching the compressed
    ///         lane / codebook and the provider math (× confidenceParam / 1e10, so 10_000 = 1×).
    ///         The 20-bps bid/ask must store as 2000, NOT 20. This is the confidence-scaling fix.
    function test_v3_spreadInHundredthsOfBps() public {
        bytes32 feedId = _v3Feed(2);
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));

        (, uint256 spread,,) = _read(feedId);
        assertEq(spread, 2000, "20 bps real spread => 2000 in 0.01-bps units");
    }

    /// @notice A genuine wide bid/ask spread is reported as-is (widens the band), NOT clamped to
    ///         the stall sentinel — a real 2% spread must be distinguishable from a stalled feed.
    function test_v3_wideSpreadWidensBand() public {
        bytes32 feedId = _v3Feed(3);
        // ±2% band around 150e18 => 2% half-spread → 20_000 in 0.01-bps units, reported verbatim.
        oracle.updateReport(_v3(feedId, PRICE, 147e18, 153e18, uint32(T0)));

        (, uint256 spread,,) = _read(feedId);
        assertEq(spread, 20_000, "2% real spread reported as 20_000, not the stall sentinel");
    }

    /// @notice Saturated oracle reads retain the ceiling; providers must halt on this ambiguity.
    function test_v3_hugeSpreadSaturatesBelowSentinel() public {
        bytes32 feedId = _v3Feed(4);
        // ±10% band → 10% half-spread = 100_000 units, above MAX_REAL_SPREAD → saturates to 65534.
        oracle.updateReport(_v3(feedId, PRICE, 135e18, 165e18, uint32(T0)));

        (, uint256 spread,,) = _read(feedId);
        assertEq(spread, uint256(type(uint16).max) - 1, "saturates to MAX_REAL_SPREAD, below sentinel");
    }

    /// @dev Exercise both schemas through their real decode/normalize path, using the echo verifier.
    function _assertSpreadBothSchemas(int192 price, int192 bid, int192 ask, uint256 expected) internal {
        // Fresh feed IDs keep each case independent of the monotonic timestamp gate.
        bytes32 v3 = _v3Feed(++spreadCase);
        bytes32 hfs = _hfsFeed(spreadCase);
        oracle.updateReport(_v3(v3, price, bid, ask, uint32(T0)));
        oracle.updateReport(_hfs(hfs, price, bid, ask, uint64(T0 * 1000)));
        (, uint256 v3Spread,,) = _read(v3);
        (, uint256 hfsSpread,,) = _read(hfs);
        assertEq(v3Spread, expected, "v3 spread");
        assertEq(hfsSpread, expected, "hfs spread");
    }

    function test_asymmetricSpreadCoversBothDirections() public {
        _assertSpreadBothSchemas(100e18, 99e18, 103e18, 30_000);
        _assertSpreadBothSchemas(100e18, 97e18, 101e18, 30_000);
    }

    function test_benchmarkOutsideBidAskRemainsValid() public {
        _assertSpreadBothSchemas(100e18, 101e18, 103e18, 30_000);
        _assertSpreadBothSchemas(100e18, 97e18, 99e18, 30_000);
    }

    function test_spreadRoundsUpAndSaturatesAtBoundary() public {
        _assertSpreadBothSchemas(100e18, 100e18, 100e18 + 1, 1);
        _assertSpreadBothSchemas(100e18, 100e18, 100e18 + 1e14, 1);
        _assertSpreadBothSchemas(100e18, 100e18, 100e18 + 1e14 + 1, 2);
        _assertSpreadBothSchemas(100e18, 100e18, 1065533e14, 65_533);
        _assertSpreadBothSchemas(100e18, 100e18, 1065534e14, 65_534);
        _assertSpreadBothSchemas(100e18, 100e18, 1065534e14 + 1, 65_534);
        // Half-width was 4% and representable; maximum deviation is 7% and must saturate.
        _assertSpreadBothSchemas(100e18, 99e18, 107e18, 65_534);
    }

    function test_signedDeviationDoesNotOverflowOrRequirePositiveBid() public {
        _assertSpreadBothSchemas(100e18, type(int192).min, type(int192).max, 65_534);
        _assertSpreadBothSchemas(100e18, -2e18, -1e18, 65_534);
    }

    function testFuzz_spreadCoversBothReportedEdges(uint64 rawPrice, uint32 rawUp, uint32 rawDown, bool hfs) public {
        int192 price = int192(int256(bound(rawPrice, 1e10, type(uint64).max)));
        uint256 upUnits = bound(rawUp, 0, 65_533);
        uint256 downUnits = bound(rawDown, 0, 65_533);
        int192 ask = price + int192(int256(uint256(int256(price)) * upUnits / 1e6));
        int192 bid = price - int192(int256(uint256(int256(price)) * downUnits / 1e6));
        bytes32 feed = hfs ? _hfsFeed(101) : _v3Feed(101);
        oracle.updateReport(
            hfs ? _hfs(feed, price, bid, ask, uint64(T0 * 1000)) : _v3(feed, price, bid, ask, uint32(T0))
        );
        (, uint256 spread,,) = _read(feed);
        uint256 width = uint256(int256(price)) * spread;
        // Cross-products check containment without copying the implementation's division/rounding.
        assertGe(width, uint256(int256(ask) - int256(price)) * 1e6);
        assertGe(width, uint256(int256(price) - int256(bid)) * 1e6);
        if (spread > 0) {
            uint256 previousWidth = uint256(int256(price)) * (spread - 1);
            assertTrue(
                previousWidth < uint256(int256(ask) - int256(price)) * 1e6
                    || previousWidth < uint256(int256(price) - int256(bid)) * 1e6,
                "the previous spread unit cannot cover both edges"
            );
        }
    }

    function test_updateReports_batch() public {
        bytes32 f1 = _v3Feed(1);
        bytes32 f2 = _v3Feed(2);

        bytes[] memory reports = new bytes[](2);
        reports[0] = _v3(f1, PRICE, BID, ASK, uint32(T0));
        reports[1] = _v3(f2, 200e18, 200e18, 200e18, uint32(T0));
        oracle.updateReports(reports);

        (uint256 mid1,,,) = _read(f1);
        (uint256 mid2,,,) = _read(f2);
        assertEq(mid1, MID8);
        assertEq(mid2, 20_000_000_000);
    }

    // ── registrationless storage / existence ────────────────────────────

    /// Any verified report is stored, even for a feed id never seen before.
    function test_unseenFeed_verifiedReportStores() public {
        bytes32 feedId = _v3Feed(9); // valid schema, never pushed before

        // Does not exist yet → read path reverts FeedNotFound
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, feedId));
        oracle.price(feedId, pool);

        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));

        (uint256 mid,,,) = _read(feedId);
        assertEq(mid, MID8, "unseen feed stored on first verified report");
    }

    /// A feed id that never received a verified report reads FeedNotFound.
    function test_neverPushedFeed_read_reverts() public {
        bytes32 feedId = _v3Feed(77);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, feedId));
        oracle.price(feedId, pool);
    }

    // ── v4 (RWA, seconds, marketStatus) ─────────────────────────────────

    function test_v4_openMarket_zeroSpread() public {
        bytes32 feedId = _v4Feed(1);
        oracle.updateReport(
            _v4(
                feedId,
                PRICE,
                2,
                /* OPEN */
                uint32(T0)
            )
        );

        (uint256 mid, uint256 spread,,) = _read(feedId);
        assertEq(mid, MID8);
        assertEq(spread, 0, "open market -> no spread");
    }

    function test_v4_closedMarket_stalledSpread() public {
        bytes32 feedId = _v4Feed(2);
        oracle.updateReport(
            _v4(
                feedId,
                PRICE,
                1,
                /* CLOSED */
                uint32(T0)
            )
        );

        (, uint256 spread,,) = _read(feedId);
        assertEq(spread, type(uint16).max, "closed market -> stall sentinel");
    }

    // ── HFS (milliseconds) ──────────────────────────────────────────────

    function test_hfs_storesAndReads_msTimestamp() public {
        bytes32 feedId = _hfsFeed(1);
        // observationsTimestamp is in MILLISECONDS for HFS feeds.
        oracle.updateReport(_hfs(feedId, PRICE, BID, ASK, uint64(T0 * 1000)));

        (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) = _read(feedId);
        assertEq(mid, MID8);
        assertEq(spread, SPREAD_UNITS);
        assertEq(spread1, 0xFFFF);
        assertEq(refTime, T0, "ms timestamp converted to seconds once (not double-scaled)");
    }

    // ── schema dispatch / decode failures ───────────────────────────────

    function test_unsupportedSchema_reverts() public {
        bytes32 feedId = bytes32(uint256(5) << 240); // sec resolution, version 5
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.UnsupportedReportSchema.selector, uint16(5)));
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));
    }

    /// An ms-resolution feed whose BASE schema is not v3 (here v4: 0x1004) fails closed — routing
    /// checks the base schema, not just the resolution nibble, so a well-formed HFS-shaped blob is
    /// still rejected rather than misdecoded.
    function test_hfsNonV3BaseSchema_reverts() public {
        bytes32 feedId = bytes32((uint256(0x1004) << 240) | uint256(1)); // ms nibble + base v4
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.UnsupportedReportSchema.selector, uint16(0x1004)));
        oracle.updateReport(_hfs(feedId, PRICE, BID, ASK, uint64(T0 * 1000)));
    }

    /// An ms-nibble feed with base schema 0 (0x1000)
    /// reverts instead of silently routing to the HFS decoder.
    function test_hfsBaseSchemaZero_reverts() public {
        bytes32 feedId = bytes32((uint256(0x1000) << 240) | uint256(1)); // ms nibble + base 0
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.UnsupportedReportSchema.selector, uint16(0x1000)));
        oracle.updateReport(_hfs(feedId, PRICE, BID, ASK, uint64(T0 * 1000)));
    }

    /// An UNKNOWN resolution nibble must fail closed. Schema matching goes off the
    /// masked base schema so the ms lane can reuse the v3 id — which leaves the seconds lane
    /// matching on `baseSchema` alone, ignoring the nibble entirely: without the resolution check a
    /// feedId like 0x2003 (nibble
    /// 2, base v3) would decode as SECONDS and have its observationsTimestamp multiplied by 1000.
    /// Only nibbles 0
    /// (seconds) and 1 (milliseconds) have a defined meaning; everything else must revert, not be
    /// assumed to be seconds.
    function test_unknownResolutionNibble_reverts() public {
        bytes32 feedId = bytes32((uint256(0x2003) << 240) | uint256(1)); // nibble 2 + base v3
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.UnsupportedReportSchema.selector, uint16(0x2003)));
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));
    }

    /// The top nibble is 4 bits, so 0xF is the widest unknown value — same requirement.
    function test_maxResolutionNibble_reverts() public {
        bytes32 feedId = bytes32((uint256(0xF003) << 240) | uint256(2)); // nibble 15 + base v3
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.UnsupportedReportSchema.selector, uint16(0xF003)));
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));
    }

    function test_invalidPrice_reverts() public {
        bytes32 feedId = _v3Feed(1);
        vm.expectRevert(ChainlinkOracle.InvalidReportPrice.selector);
        oracle.updateReport(_v3(feedId, 0, 0, 0, uint32(T0)));
    }

    // ── verification fee (constant, from balance) ───────────────────────

    /// @notice `VERIFICATION_FEE` is zero and the whole Chainlink lane depends on it staying zero —
    ///         ingestion is not payable, `feeToken` is immutable, and there is no LINK approve path
    ///         anywhere, so a nonzero effective fee is unpayable and would brick that route until the
    ///         tag is rerouted to a fee-free verifier serving that feed, or the oracle is redeployed.
    ///
    ///         Pin the ZERO, not a tautology. Asserting
    ///         `balBefore - balance == verifier.received()` would hold for ANY fee value — the mock
    ///         simply banks whatever it is sent — and would stay green after the constant
    ///         was raised, which is exactly the change this test guards.
    function test_verify_spendsExactlyZeroFee() public {
        bytes32 feedId = _v3Feed(1);

        uint256 balBefore = address(oracle).balance;
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));

        assertEq(address(oracle).balance, balBefore, "no native value may leave the oracle");
        assertEq(verifier.received(), 0, "and the verifier must be paid nothing");
    }

    /// @notice The failure mode the zero-fee assumption is protecting against, made explicit: point
    ///         the lane at a verifier whose FeeManager quotes a real fee, and ingestion reverts
    ///         permanently — the oracle cannot pay it, however much native it is holding. This is why
    ///         `VERIFICATION_FEE` must not be "fixed by" raising the constant, and why the v0.5.1
    ///         `verifyView` route (fee-free) is the intended escape hatch.
    function test_verify_nonzeroFeeBricksIngestion() public {
        verifier.setRequiredFee(1 wei);
        assertGt(address(oracle).balance, 0, "oracle is funded, and it still cannot pay");

        bytes32 feedId = _v3Feed(1);
        vm.expectRevert(
            abi.encodeWithSelector(MockVerifierProxy.InsufficientVerificationFee.selector, uint256(0), uint256(1))
        );
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));

        // The fee-free v0.5.1 route is unaffected — the documented way out.
        verifierView.setRequiredFee(1 wei); // irrelevant: verifyView takes no value
        oracle.updateReport(_retag(TAG_V051, _v3(_v3Feed(9), PRICE, BID, ASK, uint32(T0))));
        (uint256 mid,,,) = _read(_v3Feed(9));
        assertEq(mid, MID8, "verifyView path still ingests");
    }

    // ── v0.5.1 fee-free verifyView routing ───────────────────────────────

    /// @notice A report tagged for the v0.5.1 proxy is verified through `verifyView`: it stores and
    ///         reads back identically to the payable path, and takes no fee from either verifier.
    function test_v051_verifyViewPath_storesAndTakesNoFee() public {
        bytes32 feedId = _v3Feed(5);
        bytes memory report = _retag(TAG_V051, _v3(feedId, PRICE, BID, ASK, uint32(T0)));

        uint256 balBefore = address(oracle).balance;
        oracle.updateReport(report);
        uint256 balAfter = address(oracle).balance; // before _read (which registers, +1 wei)

        (uint256 mid,,,) = _read(feedId);
        assertEq(mid, MID8, "v0.5.1 verifyView path stores the report");
        assertEq(balAfter, balBefore, "verifyView path takes no fee from balance");
        assertEq(verifier.received(), 0, "payable verifier untouched");
        assertEq(verifierView.received(), 0, "view verifier is not payable");
    }

    function test_unknownTag_reverts() public {
        bytes memory report = _retag(0x99, _v3(_v3Feed(1), PRICE, BID, ASK, uint32(T0)));
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.UnknownVerifierTag.selector, uint8(0x99)));
        oracle.updateReport(report);
    }

    function test_emptyPayload_reverts() public {
        vm.expectRevert(ChainlinkOracle.EmptyPayload.selector);
        oracle.updateReport("");
    }

    // ── staleness / freshness ───────────────────────────────────────────

    function test_futureTimestamp_reverts() public {
        bytes32 feedId = _v3Feed(1);
        vm.expectRevert(FutureTimestamp.selector);
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0 + MAX_DRIFT + 100)));
    }

    function test_zeroTimestamp_reverts() public {
        bytes32 feedId = _v3Feed(1);
        vm.expectRevert(ZeroTimestamp.selector);
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, 0));
    }

    function test_olderReport_notOverwritten() public {
        bytes32 feedId = _v3Feed(1);
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));

        // Older observation with a different price must NOT overwrite.
        oracle.updateReport(_v3(feedId, 999e18, 999e18, 999e18, uint32(T0 - 10)));

        (uint256 mid,,,) = _read(feedId);
        assertEq(mid, MID8, "stale (older) report ignored");
    }

    // ── sub-scale price (floors to 0) is skipped, not stored ────────────

    /// @notice A strictly-positive 18-dec price below PRICE_SCALE (1e10) floors to 0. Such a report
    ///         must be SKIPPED, never overwriting the last good value or advancing the timestamp.
    function test_subScalePrice_skippedNotOverwriting() public {
        bytes32 feedId = _v3Feed(1);
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));

        // Newer report whose 18-dec price (5e9) is below 1e10 → 5e9 / 1e10 = 0.
        oracle.updateReport(_v3(feedId, 5e9, 5e9, 5e9, uint32(T0 + 10)));

        (uint256 mid,,, uint256 refTime) = _read(feedId);
        assertEq(mid, MID8, "floored-to-zero report must not overwrite last good value");
        assertEq(refTime, T0, "timestamp must not advance on a skipped zero-price report");
    }

    /// @notice A first-ever report that floors to 0 creates no feed (nothing stored → FeedNotFound).
    function test_subScalePrice_unseenFeed_notCreated() public {
        bytes32 feedId = _v3Feed(42);
        oracle.updateReport(_v3(feedId, 5e9, 5e9, 5e9, uint32(T0)));

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, feedId));
        oracle.price(feedId, pool);
    }

    // ── FeedUpdated notarization (quote-side (oracle, feed) join key) ─────

    bytes32 private constant FEED_UPDATED_SIG = keccak256("FeedUpdated(bytes32)");

    function _countFeedUpdated(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(oracle) && logs[i].topics[0] == FEED_UPDATED_SIG) n++;
        }
    }

    /// @notice An accepted store emits FeedUpdated keyed by the feed id (the indexed topic) — the
    ///         builder's quote-side join key. The event carries no other fields.
    function test_feedUpdated_emittedOnAcceptedStore() public {
        bytes32 feedId = _v3Feed(1);
        vm.expectEmit(true, false, false, false, address(oracle));
        emit IOffchainOracle.FeedUpdated(feedId);
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));
    }

    /// @notice A rejected (older-timestamp) report writes nothing, so it must emit no FeedUpdated —
    ///         the monotonic gate that guards the write also guards the event.
    function test_feedUpdated_notEmittedOnOlderReport() public {
        bytes32 feedId = _v3Feed(1);
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));

        vm.recordLogs();
        oracle.updateReport(_v3(feedId, 999e18, 999e18, 999e18, uint32(T0 - 10)));
        assertEq(_countFeedUpdated(vm.getRecordedLogs()), 0, "older report must not emit FeedUpdated");
    }

    /// @notice A batch of accepted reports emits one FeedUpdated per stored feed.
    function test_feedUpdated_oncePerFeedInBatch() public {
        bytes[] memory reports = new bytes[](2);
        reports[0] = _v3(_v3Feed(1), PRICE, BID, ASK, uint32(T0));
        reports[1] = _v3(_v3Feed(2), 200e18, 200e18, 200e18, uint32(T0));

        vm.recordLogs();
        oracle.updateReports(reports);
        assertEq(_countFeedUpdated(vm.getRecordedLogs()), 2, "one FeedUpdated per stored feed");
    }
}
