// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PriceProvider} from "../contracts/PriceProvider.sol";
import {IOffchainOracle} from "../contracts/interfaces/IOffchainOracle.sol";
import {TimeMs, toTimeMs} from "../contracts/oracles/utils/TimeMs.sol";

contract PriceProviderTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant BPS_BASE_U = 1e18;
    uint256 private constant STEP_DENOM = 1e8 * BPS_BASE_U;
    uint16  private constant ORACLE_BPS = 10_000;
    uint256 private constant CONFIDENCE_BASE = 1e10;

    bytes32 private constant FEED_ID = keccak256("feed-id");
    address private constant BASE_TOKEN = address(0xBEEF);
    address private constant QUOTE_TOKEN = address(0xCAFE);

    MockCompressedOracle private offchain;
    PriceProvider private provider;

    address private factory;
    int256  private constant CEX_STEP = 100_000_000_000_000; // 0.01% (1e14)
    uint256 private constant MAX_TIME_DELTA = 1 days;

    uint256 private immutable STEP_BID_FACTOR = BPS_BASE_U - uint256(CEX_STEP);
    uint256 private immutable STEP_ASK_FACTOR = BPS_BASE_U + uint256(CEX_STEP);

    function setUp() public {
        factory = address(this);
        offchain = new MockCompressedOracle();
        offchain.setOracleInfo(FEED_ID, BASE_TOKEN, QUOTE_TOKEN);
        provider = new PriceProvider(
            factory,
            address(offchain),
            FEED_ID,
            CEX_STEP,
            MAX_TIME_DELTA,
            type(uint16).max,
            address(0),
            address(0)
        );
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// @dev Compute bid from mid + adjustedSpread (same logic as PriceProvider._getBidAskFrom)
    function _bidFrom(uint64 mid, uint256 adjustedSpread) internal pure returns (uint256) {
        uint256 delta = uint256(mid) * adjustedSpread / CONFIDENCE_BASE;
        return delta >= mid ? 0 : uint256(mid) - delta;
    }

    function _askFrom(uint64 mid, uint256 adjustedSpread) internal pure returns (uint256) {
        return uint256(mid) + uint256(mid) * adjustedSpread / CONFIDENCE_BASE;
    }

    // ── Token getters ─────────────────────────────────────────────────────

    function testGetTokensReturnsConfiguredPair() public view {
        (address baseToken, address quoteToken) = provider.getTokens();
        assertEq(baseToken, BASE_TOKEN);
        assertEq(quoteToken, QUOTE_TOKEN);
    }

    // ── Bid / Ask adjustments ─────────────────────────────────────────────

    function testGetBidPriceAdjustsOffchainQuote() public {
        vm.warp(100);
        uint64 mid = 155_000_000;
        uint16 oracleSpread = 300;
        uint256 confidence = 100_000;
        offchain.setFeed(FEED_ID, mid, oracleSpread, 4321);
        provider.setConfidenceParam(confidence);

        uint256 bidPrice = provider.getBidPrice();

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

        uint256 askPrice = provider.getAskPrice();

        uint256 adjustedSpread = uint256(oracleSpread) * confidence;
        uint256 ask = _askFrom(mid, adjustedSpread);
        uint256 expected = Math.mulDiv(ask, Q64 * STEP_ASK_FACTOR, STEP_DENOM, Math.Rounding.Ceil);

        assertEq(askPrice, expected, "ask price should apply step to computed ask");
    }

    // ── Stalled feed ──────────────────────────────────────────────────────

    function testGetBidPriceRevertsWhenFeedInvalid() public {
        offchain.setFeed(FEED_ID, 0, 500, 1);

        vm.expectRevert(PriceProvider.FeedStalled.selector);
        provider.getBidPrice();
    }

    function testGetAskPriceRevertsWhenFeedInvalid() public {
        offchain.setFeed(FEED_ID, 0, 500, 1);

        vm.expectRevert(PriceProvider.FeedStalled.selector);
        provider.getAskPrice();
    }

    // ── Staleness (time-based) ────────────────────────────────────────────

    function testGetBidPriceUiReturnsZeroWhenStale() public {
        vm.warp(100);
        offchain.setFeed(FEED_ID, 120_000_000, 400, 1111);

        vm.warp(100 + MAX_TIME_DELTA + 1);
        uint256 bidPrice = provider.getBidPriceUi();

        assertEq(bidPrice, 0, "bid price should be zero once feed is stale");
    }

    function testGetAskPriceUiReturnsMaxWhenStale() public {
        vm.warp(200);
        offchain.setFeed(FEED_ID, 120_000_000, 400, 2222);

        vm.warp(200 + MAX_TIME_DELTA + 1);
        uint256 askPrice = provider.getAskPriceUi();

        assertEq(askPrice, type(uint128).max, "ask price should be max once feed is stale");
    }

    function testGetBidPriceRevertsWhenStale() public {
        vm.warp(100);
        offchain.setFeed(FEED_ID, 120_000_000, 400, 1111);

        vm.warp(100 + MAX_TIME_DELTA + 1);
        vm.expectRevert(PriceProvider.FeedStalled.selector);
        provider.getBidPrice();
    }

    function testGetAskPriceRevertsWhenStale() public {
        vm.warp(200);
        offchain.setFeed(FEED_ID, 120_000_000, 400, 2222);

        vm.warp(200 + MAX_TIME_DELTA + 1);
        vm.expectRevert(PriceProvider.FeedStalled.selector);
        provider.getAskPrice();
    }

    // ── Future refTime is always stale on L1 ─────────────────────────────

    function testFutureRefTimeIsAlwaysStale() public {
        vm.warp(1000);
        offchain.setFeed(FEED_ID, 150_000_000, 300, 100);

        // Even 1 second in the future should be stale on L1
        vm.warp(999);
        uint256 bidPrice = provider.getBidPriceUi();
        assertEq(bidPrice, 0, "future refTime should be stale on L1");
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

    function testGetBidAndAskPriceUiReturnsStalledDefaults() public {
        vm.warp(100);
        offchain.setFeed(FEED_ID, 120_000_000, 400, 1111);

        vm.warp(100 + MAX_TIME_DELTA + 1);
        (uint128 bid, uint128 ask) = provider.getBidAndAskPriceUi();

        assertEq(bid, 0, "staled bid should be 0");
        assertEq(ask, type(uint128).max, "staled ask should be max uint128");
    }

    function testGetBidAndAskPriceRevertsWhenStale() public {
        vm.warp(100);
        offchain.setFeed(FEED_ID, 120_000_000, 400, 1111);

        vm.warp(100 + MAX_TIME_DELTA + 1);
        vm.expectRevert(PriceProvider.FeedStalled.selector);
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
        vm.expectRevert(PriceProvider.OnlyFactory.selector);
        provider.setConfidenceParam(1);
    }

    function testSetConfidenceParamRevertsOutOfBounds() public {
        vm.expectRevert(PriceProvider.ConfidenceParamOutOfBounds.selector);
        provider.setConfidenceParam(BPS_BASE_U);
    }

    function testSetConfidenceParamRevertsCooldown() public {
        vm.warp(100);
        provider.setConfidenceParam(1);

        vm.expectRevert(PriceProvider.CooldownNotElapsed.selector);
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

        // confidenceParam = 0 (default) → adjustedSpread = 0 → only cexStep
        (uint128 bid, uint128 ask) = provider.getBidAndAskPrice();
        assertGt(bid, 0, "bid should be non-zero (cexStep provides separation)");
        assertLt(bid, ask, "bid < ask from cexStep alone");

        // Verify spread is minimal (only cexStep)
        uint256 expectedBid = Math.mulDiv(uint256(100_000_000), Q64 * STEP_BID_FACTOR, STEP_DENOM);
        uint256 expectedAsk = Math.mulDiv(uint256(100_000_000), Q64 * STEP_ASK_FACTOR, STEP_DENOM, Math.Rounding.Ceil);
        assertEq(bid, expectedBid, "bid should be mid with only cexStep applied");
        assertEq(ask, expectedAsk, "ask should be mid with only cexStep applied");
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

        uint256 bidPrice = provider.getBidPrice();

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

    // ── CexStep bounds ────────────────────────────────────────────────────

    function testCexStepOutOfBoundsReverts() public {
        vm.expectRevert(PriceProvider.CexStepOutOfBounds.selector);
        new PriceProvider(
            factory,
            address(offchain),
            FEED_ID,
            int256(BPS_BASE_U), // == BPS_BASE, out of bounds
            MAX_TIME_DELTA,
            type(uint16).max,
            address(0),
            address(0)
        );
    }

    // ── setCexStep (debug) ──────────────────────────────────────────────────

    function testSetCexStepFromFactory() public {
        int256 newStep = 200_000_000_000_000; // 0.02%
        provider.setCexStep(newStep);
        assertEq(provider.cexStep(), newStep);
    }

    function testSetCexStepRevertsNonFactory() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(PriceProvider.OnlyFactory.selector);
        provider.setCexStep(1);
    }

    function testSetCexStepRevertsOutOfBounds() public {
        vm.expectRevert(PriceProvider.CexStepOutOfBounds.selector);
        provider.setCexStep(int256(BPS_BASE_U));
    }

    function testSetCexStepAffectsPrices() public {
        vm.warp(100);
        offchain.setFeed(FEED_ID, 100_000_000, 300, 100);
        provider.setConfidenceParam(100_000);

        (uint128 bidBefore,) = provider.getBidAndAskPrice();

        // Increase cexStep → bid moves further from mid
        provider.setCexStep(1e16); // 1%
        (uint128 bidAfter,) = provider.getBidAndAskPrice();

        assertLt(bidAfter, bidBefore, "larger cexStep should decrease bid");
    }

    // ── Negative CEX_STEP & inversion guard ──────────────────────────────

    function testNegCexStepInversionReturnsStalledUi() public {
        vm.warp(100);
        PriceProvider negProvider = new PriceProvider(
            factory, address(offchain), FEED_ID,
            -5e14, MAX_TIME_DELTA, type(uint16).max,
            address(0), address(0)
        );

        offchain.setFeed(FEED_ID, 100_000_000, 200, 100);
        // confidence 1x → adjustedSpread = 200*10_000 = 2_000_000 → 2 bps < 5 bps step
        negProvider.setConfidenceParam(10_000);

        (uint128 bid, uint128 ask) = negProvider.getBidAndAskPriceUi();
        assertEq(bid, 0, "should return stalled bid on inversion");
        assertEq(ask, type(uint128).max, "should return stalled ask on inversion");
    }

    function testNegCexStepInversionRevertsStrict() public {
        vm.warp(100);
        PriceProvider negProvider = new PriceProvider(
            factory, address(offchain), FEED_ID,
            -5e14, MAX_TIME_DELTA, type(uint16).max,
            address(0), address(0)
        );

        offchain.setFeed(FEED_ID, 100_000_000, 200, 100);
        negProvider.setConfidenceParam(10_000);

        vm.expectRevert(PriceProvider.FeedStalled.selector);
        negProvider.getBidAndAskPrice();
    }

    function testNegCexStepWithSufficientConfidence() public {
        vm.warp(100);
        PriceProvider negProvider = new PriceProvider(
            factory, address(offchain), FEED_ID,
            -5e14, MAX_TIME_DELTA, type(uint16).max,
            address(0), address(0)
        );

        offchain.setFeed(FEED_ID, 100_000_000, 200, 100);
        // adjustedSpread = 200*250_000 = 50_000_000 → 50 bps > 5 bps step
        negProvider.setConfidenceParam(250_000);

        (uint128 bid, uint128 ask) = negProvider.getBidAndAskPrice();
        assertGt(bid, 0, "bid should be valid");
        assertLt(bid, ask, "bid < ask with sufficient confidence");
    }

    function testNegCexStepWithConfidenceWorks() public {
        vm.warp(100);
        PriceProvider negProvider = new PriceProvider(
            factory, address(offchain), FEED_ID,
            -5e14, MAX_TIME_DELTA, type(uint16).max,
            address(0), address(0)
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

        (uint128 bid, uint128 ask) = provider.getBidAndAskPriceUi();
        assertEq(bid, 0, "bid should be 0 when price below guard min");
        assertEq(ask, type(uint128).max, "ask should be max when price below guard min");
    }

    function testPriceGuardRejectsAbove() public {
        offchain.setFeed(FEED_ID, 250_000_000, 300, 100);
        offchain.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);

        (uint128 bid, uint128 ask) = provider.getBidAndAskPriceUi();
        assertEq(bid, 0, "bid should be 0 when price above guard max");
        assertEq(ask, type(uint128).max, "ask should be max when price above guard max");
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

    function testSpreadAtBpsBaseReturnsStalledUi() public {
        // spread == ORACLE_BPS (10000) is treated as stalled marker
        offchain.setFeed(FEED_ID, 100_000_000, ORACLE_BPS, 100);

        (uint128 bid, uint128 ask) = provider.getBidAndAskPriceUi();
        assertEq(bid, 0);
        assertEq(ask, type(uint128).max);
    }
}

contract MockCompressedOracle is IOffchainOracle {
    uint16 private constant BPS = 10_000;

    struct Feed {
        uint64  midPrice;
        uint16  spread;
        uint16  volatility;
        uint256 refTime;
    }

    error FeedNotSet();

    mapping(bytes32 => Feed) private feeds;
    mapping(bytes32 => OracleInfo) private oracleInfoByFeedId;
    mapping(bytes32 => PriceGuard) private priceGuards;

    function setFeed(bytes32 feedId, uint64 midPrice, uint16 spread, uint16 volatility) external {
        feeds[feedId] = Feed({midPrice: midPrice, spread: spread, volatility: volatility, refTime: block.timestamp});
    }

    function setOracleInfo(bytes32 feedId, address baseToken, address quoteToken) external {
        oracleInfoByFeedId[feedId] =
            OracleInfo({baseToken: baseToken, quoteToken: quoteToken, misc: ""});
    }

    function setPriceGuard(bytes32 feedId, uint128 minPrice, uint128 maxPrice) external {
        priceGuards[feedId] = PriceGuard({min: minPrice, max: maxPrice});
    }

    // --- IOffchainOracle ---

    function getOracleCount() external pure override returns (uint256) { return 0; }
    function getOracleIds(uint256, uint256) external pure override returns (bytes32[] memory ids) { ids = new bytes32[](0); }
    function getOracleInfo(bytes32 feedId) external view override returns (OracleInfo memory) { return oracleInfoByFeedId[feedId]; }
    function getOracleDataBulk(bytes32[] calldata) external pure override returns (OracleData[] memory) { return new OracleData[](0); }

    function getOracleData(bytes32 feedId) external view override returns (OracleData memory data) {
        Feed memory f = feeds[feedId];
        data.price = f.midPrice;
        data.spread = f.spread;
        data.volatility = f.volatility;
        data.timestampMs = toTimeMs(f.refTime * 1000);
    }

    function priceGuard(bytes32 feedId) external view override returns (uint128, uint128) {
        PriceGuard memory g = priceGuards[feedId];
        return (g.min, g.max);
    }

    function price(bytes32 feedId)
        external view override
        returns (uint256 mid, uint256 spread, uint16 volatility, uint256 refTime)
    {
        Feed memory f = feeds[feedId];
        if (f.refTime == 0) revert FeedNotSet();
        return (uint256(f.midPrice), uint256(f.spread), f.volatility, f.refTime);
    }

}
