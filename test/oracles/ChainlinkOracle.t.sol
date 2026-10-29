// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

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
    uint16  private constant ORACLE_BPS = 10_000;
    uint256 private constant MAX_DRIFT = 60;
    uint256 private constant T0 = 1_000_000;

    // 18-dec inputs → 8-dec mid; bid/ask chosen so spread = 20 bps.
    int192  private constant PRICE = 150e18;
    int192  private constant BID = 1497e17; // 149.7e18
    int192  private constant ASK = 1503e17; // 150.3e18
    uint64  private constant MID8 = 15_000_000_000; // 150e8
    uint16  private constant SPREAD_BPS = 20;

    ChainlinkOracle private oracle;
    MockVerifierProxy private verifier;
    MockPoolFactory private factory;
    address private pool;

    function setUp() public {
        verifier = new MockVerifierProxy();
        oracle = new ChainlinkOracle(address(this), MAX_DRIFT, address(verifier), makeAddr("feeToken"));
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
        return bytes32((uint256(0x10) << 248) | uint256(idx)); // byte0=0x10 → resolution nibble 1 (ms)
    }

    // ── report blob builders ──
    function _v3(bytes32 feedId, int192 price, int192 bid, int192 ask, uint32 obsSec) internal pure returns (bytes memory) {
        return abi.encode(ReportV3(feedId, obsSec, obsSec, 0, 0, obsSec + 3600, price, bid, ask));
    }
    function _v4(bytes32 feedId, int192 price, uint32 marketStatus, uint32 obsSec) internal pure returns (bytes memory) {
        return abi.encode(ReportV4(feedId, obsSec, obsSec, 0, 0, obsSec + 3600, price, marketStatus));
    }
    function _hfs(bytes32 feedId, int192 price, int192 bid, int192 ask, uint64 obsMs) internal pure returns (bytes memory) {
        return abi.encode(ReportHFS(feedId, obsMs, obsMs, 0, 0, obsMs + 3_600_000, price, bid, ask));
    }

    // ── attributed read (public getters disabled in OracleBase) ──
    function _read(bytes32 feedId) internal returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) {
        if (!oracle.registeredPool(feedId, pool)) oracle.register{value: 1}(feedId, pool, address(factory));
        vm.mockCall(pool, abi.encodeWithSelector(IPool.inSwap.selector), abi.encode(address(this)));
        return oracle.price(feedId, pool);
    }

    function test_kindAndVersion() public view {
        assertEq(oracle.kind(), "chainlink-datastreams");
        assertEq(oracle.version(), "0.2.1");
    }

    // ── v3 (Crypto, seconds) ────────────────────────────────────────────

    function test_v3_storesAndReads() public {
        bytes32 feedId = _v3Feed(1);
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));

        (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) = _read(feedId);
        assertEq(mid, MID8, "mid = price/1e10");
        assertEq(spread, SPREAD_BPS, "spread = ceil(BPS*(ask-bid)/2 / price)");
        assertEq(spread1, 0xFFFF);
        assertEq(refTime, T0, "refTime = observationsTimestamp (sec)");
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
        oracle.updateReport(_v4(feedId, PRICE, 2 /* OPEN */, uint32(T0)));

        (uint256 mid, uint256 spread,,) = _read(feedId);
        assertEq(mid, MID8);
        assertEq(spread, 0, "open market -> no spread");
    }

    function test_v4_closedMarket_stalledSpread() public {
        bytes32 feedId = _v4Feed(2);
        oracle.updateReport(_v4(feedId, PRICE, 1 /* CLOSED */, uint32(T0)));

        (, uint256 spread,,) = _read(feedId);
        assertEq(spread, ORACLE_BPS, "closed market -> stalled marker");
    }

    // ── HFS (milliseconds) ──────────────────────────────────────────────

    function test_hfs_storesAndReads_msTimestamp() public {
        bytes32 feedId = _hfsFeed(1);
        // observationsTimestamp is in MILLISECONDS for HFS feeds.
        oracle.updateReport(_hfs(feedId, PRICE, BID, ASK, uint64(T0 * 1000)));

        (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) = _read(feedId);
        assertEq(mid, MID8);
        assertEq(spread, SPREAD_BPS);
        assertEq(spread1, 0xFFFF);
        assertEq(refTime, T0, "ms timestamp converted to seconds once (not double-scaled)");
    }

    // ── schema dispatch / decode failures ───────────────────────────────

    function test_unsupportedSchema_reverts() public {
        bytes32 feedId = bytes32(uint256(5) << 240); // sec resolution, version 5
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.UnsupportedReportSchema.selector, uint16(5)));
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));
    }

    function test_invalidPrice_reverts() public {
        bytes32 feedId = _v3Feed(1);
        vm.expectRevert(ChainlinkOracle.InvalidReportPrice.selector);
        oracle.updateReport(_v3(feedId, 0, 0, 0, uint32(T0)));
    }

    // ── verification fee (constant, from balance) ───────────────────────

    function test_verify_feeFromBalance() public {
        bytes32 feedId = _v3Feed(1);

        uint256 balBefore = address(oracle).balance;
        oracle.updateReport(_v3(feedId, PRICE, BID, ASK, uint32(T0)));
        // Whatever VERIFICATION_FEE is configured (0 on testnet, where DS verification is free),
        // exactly that amount leaves the contract balance and lands at the verifier.
        assertEq(balBefore - address(oracle).balance, verifier.received(), "fee from balance == verifier received");
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
}
