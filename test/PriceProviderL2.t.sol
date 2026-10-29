// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PriceProviderL2} from "../contracts/PriceProviderL2.sol";
import {IOffchainOracle} from "../contracts/interfaces/IOffchainOracle.sol";
import {TimeMs, toTimeMs} from "../contracts/oracles/utils/TimeMs.sol";

contract PriceProviderL2Test is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant BPS_BASE_U = 1e18;
    uint256 private constant STEP_DENOM = 1e8 * BPS_BASE_U;
    uint16  private constant ORACLE_BPS = 10_000;
    uint256 private constant CONFIDENCE_BASE = 1e10;

    bytes32 private constant FEED_ID = keccak256("feed-id");
    address private constant BASE_TOKEN = address(0xBEEF);
    address private constant QUOTE_TOKEN = address(0xCAFE);

    MockCompressedOracleL2 private offchain;
    PriceProviderL2 private provider;

    address private factory;
    int256  private constant CEX_STEP = 100_000_000_000_000; // 0.01% (1e14)
    uint256 private constant MAX_TIME_DELTA = 1 days;
    uint256 private constant FUTURE_TOLERANCE = 10;

    uint256 private immutable STEP_BID_FACTOR = BPS_BASE_U - uint256(CEX_STEP);
    uint256 private immutable STEP_ASK_FACTOR = BPS_BASE_U + uint256(CEX_STEP);

    function setUp() public {
        factory = address(this);
        offchain = new MockCompressedOracleL2();
        provider = new PriceProviderL2(
            factory,
            address(offchain),
            FEED_ID,
            CEX_STEP,
            MAX_TIME_DELTA,
            FUTURE_TOLERANCE,
            BASE_TOKEN,
            QUOTE_TOKEN
        );
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// @dev Compute bid from mid + adjustedSpread (same logic as PriceProviderL2._getBidAskFrom)
    function _bidFrom(uint64 mid, uint256 adjustedSpread) internal pure returns (uint256) {
        uint256 delta = uint256(mid) * adjustedSpread / CONFIDENCE_BASE;
        return delta >= mid ? 0 : uint256(mid) - delta;
    }

    function _askFrom(uint64 mid, uint256 adjustedSpread) internal pure returns (uint256) {
        return uint256(mid) + uint256(mid) * adjustedSpread / CONFIDENCE_BASE;
    }

    // ── Token getters / constructor token validation ──────────────────────

    function testTokenGettersReturnConfiguredPair() public view {
        assertEq(provider.token0(), BASE_TOKEN);
        assertEq(provider.token1(), QUOTE_TOKEN);
    }

    function testConstructorZeroBaseTokenReverts() public {
        vm.expectRevert();
        new PriceProviderL2(
            factory, address(offchain), FEED_ID, CEX_STEP, MAX_TIME_DELTA, FUTURE_TOLERANCE,
            address(0), QUOTE_TOKEN
        );
    }

    function testConstructorZeroQuoteTokenReverts() public {
        vm.expectRevert();
        new PriceProviderL2(
            factory, address(offchain), FEED_ID, CEX_STEP, MAX_TIME_DELTA, FUTURE_TOLERANCE,
            BASE_TOKEN, address(0)
        );
    }

    function testConstructorEqualTokensReverts() public {
        vm.expectRevert();
        new PriceProviderL2(
            factory, address(offchain), FEED_ID, CEX_STEP, MAX_TIME_DELTA, FUTURE_TOLERANCE,
            BASE_TOKEN, BASE_TOKEN
        );
    }

    function testConstructorExplicitTokensLandInGetters() public {
        PriceProviderL2 p = new PriceProviderL2(
            factory, address(offchain), FEED_ID, CEX_STEP, MAX_TIME_DELTA, FUTURE_TOLERANCE,
            address(0xA11CE), address(0xB0B)
        );
        assertEq(p.token0(), address(0xA11CE));
        assertEq(p.token1(), address(0xB0B));
    }

    // ── Bid / Ask adjustments ─────────────────────────────────────────────

    function testGetBidPriceAdjustsOffchainQuote() public {
        vm.warp(100);
        uint64 mid = 155_000_000;
        uint16 oracleSpread = 300;
        uint256 confidence = 100_000;
        offchain.setFeed(FEED_ID, mid, oracleSpread, 4321);
        provider.setConfidenceParam(confidence);

        (uint128 bidPrice,) = provider.getBidAndAskPrice();

        uint256 adjustedSpread = uint256(oracleSpread) * confidence;
        uint256 bid = _bidFrom(mid, adjustedSpread);
        uint256 expected = Math.mulDiv(bid, Q64 * STEP_BID_FACTOR, STEP_DENOM);

        assertEq(bidPrice, expected, "bid price should apply step to computed bid");
    }

    function testGetAskPriceAdjustsOffchainQuote() public {
        vm.warp(100);
        uint64 mid = 155_000_000;
        uint16 oracleSpread = 300;
        uint256 confidence = 100_000;
        offchain.setFeed(FEED_ID, mid, oracleSpread, 3210);
        provider.setConfidenceParam(confidence);

        (, uint128 askPrice) = provider.getBidAndAskPrice();

        uint256 adjustedSpread = uint256(oracleSpread) * confidence;
        uint256 ask = _askFrom(mid, adjustedSpread);
        uint256 expected = Math.mulDiv(ask, Q64 * STEP_ASK_FACTOR, STEP_DENOM, Math.Rounding.Ceil);

        assertEq(askPrice, expected, "ask price should apply step to computed ask");
    }

    // ── Stalled feed ──────────────────────────────────────────────────────

    function testGetBidAndAskPriceRevertsWhenFeedInvalid() public {
        offchain.setFeed(FEED_ID, 0, 500, 1);

        vm.expectRevert(PriceProviderL2.FeedStalled.selector);
        provider.getBidAndAskPrice();
    }

    // ── Future tolerance (L2 sequencer skew) ──────────────────────────────

    function testBidAcceptsFutureRefTimeWithinTolerance() public {
        vm.warp(1000);
        offchain.setFeed(FEED_ID, 150_000_000, 300, 100);

        vm.warp(1000 - FUTURE_TOLERANCE);
        (uint128 bidPrice,) = provider.getBidAndAskPrice();
        assertGt(bidPrice, 0, "should accept refTime within future tolerance");
    }

    function testBidRejectsFutureRefTimeBeyondTolerance() public {
        vm.warp(1000);
        offchain.setFeed(FEED_ID, 150_000_000, 300, 100);

        vm.warp(1000 - FUTURE_TOLERANCE - 1);
        vm.expectRevert(PriceProviderL2.FeedStalled.selector);
        provider.getBidAndAskPrice();
    }

    // ── Combined bid & ask ────────────────────────────────────────────────

    function testGetBidAndAskPriceReturnsBothAdjustedQuotes() public {
        vm.warp(100);
        uint64 mid = 185_000_000;
        uint16 oracleSpread = 250;
        uint256 confidence = 100_000;
        offchain.setFeed(FEED_ID, mid, oracleSpread, 9876);
        provider.setConfidenceParam(confidence);

        (uint128 bid, uint128 ask) = provider.getBidAndAskPrice();

        uint256 adjustedSpread = uint256(oracleSpread) * confidence;
        uint256 expectedBid = Math.mulDiv(_bidFrom(mid, adjustedSpread), Q64 * STEP_BID_FACTOR, STEP_DENOM);
        uint256 expectedAsk = Math.mulDiv(_askFrom(mid, adjustedSpread), Q64 * STEP_ASK_FACTOR, STEP_DENOM, Math.Rounding.Ceil);

        assertEq(bid, expectedBid, "bid should match adjusted offchain quote");
        assertEq(ask, expectedAsk, "ask should match adjusted offchain quote");
    }

    function testGetBidAndAskPriceRevertsWhenStale() public {
        vm.warp(100);
        offchain.setFeed(FEED_ID, 120_000_000, 400, 1111);

        vm.warp(100 + MAX_TIME_DELTA + 1);
        vm.expectRevert(PriceProviderL2.FeedStalled.selector);
        provider.getBidAndAskPrice();
    }

    // ── Confidence param ──────────────────────────────────────────────────

    function testSetConfidenceParamFromFactory() public {
        vm.warp(100);
        uint256 confidence = 500_000;
        provider.setConfidenceParam(confidence);
        assertEq(provider.confidenceParam(), confidence);
    }

    function testSetConfidenceParamRevertsNonFactory() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(PriceProviderL2.OnlyFactory.selector);
        provider.setConfidenceParam(1);
    }

    function testSetConfidenceParamRevertsOutOfBounds() public {
        vm.expectRevert(PriceProviderL2.ConfidenceParamOutOfBounds.selector);
        provider.setConfidenceParam(BPS_BASE_U);
    }

    function testSetConfidenceParamRevertsCooldown() public {
        vm.warp(100);
        provider.setConfidenceParam(1);

        vm.expectRevert(PriceProviderL2.CooldownNotElapsed.selector);
        provider.setConfidenceParam(2);
    }

    function testSetConfidenceParamAfterCooldown() public {
        vm.warp(100);
        provider.setConfidenceParam(1);

        vm.warp(block.timestamp + provider.CONFIDENCE_COOLDOWN());
        provider.setConfidenceParam(2);
        assertEq(provider.confidenceParam(), 2);
    }

    // ── Confidence e2e ────────────────────────────────────────────────────

    function testConfidenceMultipliesOracleSpreadE2E() public {
        vm.warp(100);
        uint64 mid = 100_000_000;
        uint16 oracleSpread = 500;
        offchain.setFeed(FEED_ID, mid, oracleSpread, 100);

        // confidenceParam = 10_000 (1x) → adjustedSpread = 500*10_000 = 5_000_000 (5 bps passthrough)
        provider.setConfidenceParam(10_000);
        (uint128 bidSmall, uint128 askSmall) = provider.getBidAndAskPrice();
        uint256 spreadSmall = askSmall - bidSmall;

        // confidenceParam = 100_000 (10x) → adjustedSpread = 500*100_000 = 50_000_000 (50 bps)
        vm.warp(block.timestamp + provider.CONFIDENCE_COOLDOWN());
        provider.setConfidenceParam(100_000);
        (uint128 bidLarge, uint128 askLarge) = provider.getBidAndAskPrice();
        uint256 spreadLarge = askLarge - bidLarge;

        assertGt(spreadLarge, spreadSmall, "higher confidence should widen spread");
        assertLt(bidLarge, bidSmall, "bid should decrease with higher confidence");
        assertGt(askLarge, askSmall, "ask should increase with higher confidence");
    }

    function testConfidenceZeroMeansNoSpread() public {
        vm.warp(100);
        offchain.setFeed(FEED_ID, 100_000_000, 500, 100);

        // confidenceParam = 0 (default) → adjustedSpread = 0 → only marginStep
        (uint128 bid, uint128 ask) = provider.getBidAndAskPrice();
        assertGt(bid, 0, "bid should be non-zero (marginStep provides separation)");
        assertLt(bid, ask, "bid < ask from marginStep alone");

        uint256 expectedBid = Math.mulDiv(uint256(100_000_000), Q64 * STEP_BID_FACTOR, STEP_DENOM);
        uint256 expectedAsk = Math.mulDiv(uint256(100_000_000), Q64 * STEP_ASK_FACTOR, STEP_DENOM, Math.Rounding.Ceil);
        assertEq(bid, expectedBid, "bid should be mid with only marginStep applied");
        assertEq(ask, expectedAsk, "ask should be mid with only marginStep applied");
    }

    function testConfidencePreciseValues() public {
        vm.warp(100);
        uint64 mid = 100_000_000;
        uint16 oracleSpread = 500;
        uint256 confidence = 100_000;
        offchain.setFeed(FEED_ID, mid, oracleSpread, 100);

        // adjustedSpread = 500 * 100_000 = 50_000_000
        // delta = 100_000_000 * 50_000_000 / 1e10 = 500_000
        // bid = 100_000_000 - 500_000 = 99_500_000
        provider.setConfidenceParam(confidence);

        (uint128 bidPrice,) = provider.getBidAndAskPrice();

        uint256 adjustedSpread = uint256(oracleSpread) * confidence;
        uint256 expectedBid = _bidFrom(mid, adjustedSpread);
        uint256 expected = Math.mulDiv(expectedBid, Q64 * STEP_BID_FACTOR, STEP_DENOM);

        assertEq(bidPrice, expected, "bid should match confidence-adjusted computation");
    }

    function testConfidenceMaxValue() public {
        vm.warp(100);
        uint64 mid = 100_000_000;
        uint16 oracleSpread = 50;
        offchain.setFeed(FEED_ID, mid, oracleSpread, 100);

        // confidence = 1_000_000 (100x), adjustedSpread = 50 * 1_000_000 = 50_000_000
        // delta = 100_000_000 * 50_000_000 / 1e10 = 500_000 (50 bps)
        provider.setConfidenceParam(1_000_000);
        (uint128 bid, uint128 ask) = provider.getBidAndAskPrice();
        assertGt(bid, 0, "bid should still be positive");
        assertLt(bid, ask, "bid < ask");
    }

    // ── MarginStep bounds ────────────────────────────────────────────────────

    function testMarginStepOutOfBoundsReverts() public {
        vm.expectRevert(PriceProviderL2.MarginStepOutOfBounds.selector);
        new PriceProviderL2(
            factory,
            address(offchain),
            FEED_ID,
            int256(BPS_BASE_U), // == BPS_BASE, out of bounds
            MAX_TIME_DELTA,
            FUTURE_TOLERANCE,
            BASE_TOKEN,
            QUOTE_TOKEN
        );
    }


    // ── Negative CEX_STEP & inversion guard ──────────────────────────────

    function testNegMarginStepInversionRevertsStrict() public {
        vm.warp(100);
        PriceProviderL2 negProvider = new PriceProviderL2(
            factory, address(offchain), FEED_ID,
            -5e14, MAX_TIME_DELTA, FUTURE_TOLERANCE,
            BASE_TOKEN, QUOTE_TOKEN
        );

        offchain.setFeed(FEED_ID, 100_000_000, 200, 100);
        negProvider.setConfidenceParam(10_000);

        vm.expectRevert(PriceProviderL2.FeedStalled.selector);
        negProvider.getBidAndAskPrice();
    }

    function testNegMarginStepWithSufficientConfidence() public {
        vm.warp(100);
        PriceProviderL2 negProvider = new PriceProviderL2(
            factory, address(offchain), FEED_ID,
            -5e14, MAX_TIME_DELTA, FUTURE_TOLERANCE,
            BASE_TOKEN, QUOTE_TOKEN
        );

        offchain.setFeed(FEED_ID, 100_000_000, 200, 100);
        // adjustedSpread = 200*250_000 = 50_000_000 → 50 bps > 5 bps step
        negProvider.setConfidenceParam(250_000);

        (uint128 bid, uint128 ask) = negProvider.getBidAndAskPrice();
        assertGt(bid, 0, "bid should be valid");
        assertLt(bid, ask, "bid < ask with sufficient confidence");
    }

    function testNegMarginStepWithConfidenceWorks() public {
        vm.warp(100);
        PriceProviderL2 negProvider = new PriceProviderL2(
            factory, address(offchain), FEED_ID,
            -5e14, MAX_TIME_DELTA, FUTURE_TOLERANCE,
            BASE_TOKEN, QUOTE_TOKEN
        );

        offchain.setFeed(FEED_ID, 100_000_000, 200, 100);
        // adjustedSpread = 200*100_000 = 20_000_000 → 20 bps > 5 bps step
        negProvider.setConfidenceParam(100_000);

        (uint128 bid, uint128 ask) = negProvider.getBidAndAskPrice();
        assertGt(bid, 0, "bid should be valid with confidence");
        assertLt(bid, ask, "bid < ask with confidence");
    }

    // ── Price guard ──────────────────────────────────────────────────────

    function testPriceGuardRejectsBelow() public {
        offchain.setFeed(FEED_ID, 50_000_000, 300, 100);
        offchain.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);

        vm.expectRevert(PriceProviderL2.FeedStalled.selector);
        provider.getBidAndAskPrice();
    }

    function testPriceGuardRejectsAbove() public {
        offchain.setFeed(FEED_ID, 250_000_000, 300, 100);
        offchain.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);

        vm.expectRevert(PriceProviderL2.FeedStalled.selector);
        provider.getBidAndAskPrice();
    }

    function testPriceGuardAcceptsWithinRange() public {
        vm.warp(100);
        offchain.setFeed(FEED_ID, 150_000_000, 300, 100);
        offchain.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);
        provider.setConfidenceParam(100_000);

        (uint128 bid, uint128 ask) = provider.getBidAndAskPrice();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    function testPriceGuardZeroMaxTreatedAsUnlimited() public {
        offchain.setFeed(FEED_ID, 150_000_000, 300, 100);
        // guardMax = 0 means unlimited
        offchain.setPriceGuard(FEED_ID, 0, 0);

        (uint128 bid, uint128 ask) = provider.getBidAndAskPrice();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    // ── Spread validity ─────────────────────────────────────────────────

    function testSpreadAtBpsBaseReverts() public {
        // spread == ORACLE_BPS (10000) is treated as stalled marker
        offchain.setFeed(FEED_ID, 100_000_000, ORACLE_BPS, 100);

        vm.expectRevert(PriceProviderL2.FeedStalled.selector);
        provider.getBidAndAskPrice();
    }
}

contract MockCompressedOracleL2 is IOffchainOracle {
    uint16 private constant BPS = 10_000;

    struct Feed {
        uint64  midPrice;
        uint16  spread0;
        uint16  spread1;
        uint256 refTime;
    }

    error FeedNotSet();

    mapping(bytes32 => Feed) private feeds;
    mapping(bytes32 => PriceGuard) private priceGuards;

    function setFeed(bytes32 feedId, uint64 midPrice, uint16 spread0, uint16 spread1) external {
        feeds[feedId] = Feed({midPrice: midPrice, spread0: spread0, spread1: spread1, refTime: block.timestamp});
    }

    function setPriceGuard(bytes32 feedId, uint128 minPrice, uint128 maxPrice) external {
        priceGuards[feedId] = PriceGuard({min: minPrice, max: maxPrice});
    }

    // --- IOffchainOracle ---

    function getOracleDataBulk(bytes32[] calldata) external pure override returns (OracleData[] memory) { return new OracleData[](0); }

    function getOracleData(bytes32 feedId) external view override returns (OracleData memory data) {
        Feed memory f = feeds[feedId];
        data.price = f.midPrice;
        data.spread0 = f.spread0;
        data.spread1 = f.spread1;
        data.timestampMs = toTimeMs(f.refTime * 1000);
    }

    function priceGuard(bytes32 feedId) external view override returns (uint128, uint128) {
        PriceGuard memory g = priceGuards[feedId];
        return (g.min, g.max);
    }

    // Unified read path (open compressed oracle: `pool` unused). Mirrors getOracleData — returns
    // zeros for an unset feed rather than reverting, so the provider sees the stale/zero sentinel.
    function price(bytes32 feedId, address)
        external view
        returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime)
    {
        Feed memory f = feeds[feedId];
        return (uint256(f.midPrice), uint256(f.spread0), f.spread1, f.refTime);
    }

}
