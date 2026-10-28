// SPDX-License-Identifier: MIT
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
    uint16 private constant ORACLE_BPS = 10_000;
    uint256 private constant CONFIDENCE_BASE = 1e10;

    bytes32 private constant FEED_ID = keccak256("feed-id");
    address private constant BASE_TOKEN = address(0xBEEF);
    address private constant QUOTE_TOKEN = address(0xCAFE);

    MockCompressedOracle private offchain;
    PriceProvider private provider;

    address private factory;
    int256 private constant CEX_STEP = 100_000_000_000_000; // 0.01% (1e14)
    uint256 private constant MAX_TIME_DELTA = 1 days;

    uint256 private immutable STEP_BID_FACTOR = BPS_BASE_U - uint256(CEX_STEP);
    uint256 private immutable STEP_ASK_FACTOR = BPS_BASE_U + uint256(CEX_STEP);

    function setUp() public {
        factory = address(this);
        offchain = new MockCompressedOracle();
        provider =
            new PriceProvider(factory, address(offchain), FEED_ID, CEX_STEP, MAX_TIME_DELTA, BASE_TOKEN, QUOTE_TOKEN);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /// @dev Compute bid from mid + adjustedSpread (same bid math as PriceProvider._getQuote)
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
        new PriceProvider(factory, address(offchain), FEED_ID, CEX_STEP, MAX_TIME_DELTA, address(0), QUOTE_TOKEN);
    }

    function testConstructorZeroQuoteTokenReverts() public {
        vm.expectRevert();
        new PriceProvider(factory, address(offchain), FEED_ID, CEX_STEP, MAX_TIME_DELTA, BASE_TOKEN, address(0));
    }

    function testConstructorEqualTokensReverts() public {
        vm.expectRevert();
        new PriceProvider(factory, address(offchain), FEED_ID, CEX_STEP, MAX_TIME_DELTA, BASE_TOKEN, BASE_TOKEN);
    }

    function testConstructorExplicitTokensLandInGetters() public {
        PriceProvider p = new PriceProvider(
            factory, address(offchain), FEED_ID, CEX_STEP, MAX_TIME_DELTA, address(0xA11CE), address(0xB0B)
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

        (uint128 bidPrice,,) = provider.getQuote();

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

        (, uint128 askPrice,) = provider.getQuote();

        uint256 adjustedSpread = uint256(oracleSpread) * confidence;
        uint256 ask = _askFrom(mid, adjustedSpread);
        uint256 expected = Math.mulDiv(ask, Q64 * STEP_ASK_FACTOR, STEP_DENOM, Math.Rounding.Ceil);

        assertEq(askPrice, expected, "ask price should apply step to computed ask");
    }

    // ── Stalled feed ──────────────────────────────────────────────────────

    function testGetBidAndAskPriceRevertsWhenFeedInvalid() public {
        offchain.setFeed(FEED_ID, 0, 500, 1);

        vm.expectRevert(PriceProvider.FeedStalled.selector);
        provider.getQuote();
    }

    // ── Future refTime is always stale ───────────────────────────────────

    function testFutureRefTimeIsAlwaysStale() public {
        vm.warp(1000);
        offchain.setFeed(FEED_ID, 150_000_000, 300, 100);

        // Even 1 second in the future is stale
        vm.warp(999);
        vm.expectRevert(PriceProvider.FeedStalled.selector);
        provider.getQuote();
    }

    // ── Combined bid & ask ────────────────────────────────────────────────

    function testGetBidAndAskPriceReturnsBothAdjustedQuotes() public {
        vm.warp(100);
        uint64 mid = 185_000_000;
        uint16 oracleSpread = 250;
        uint256 confidence = 100_000;
        offchain.setFeed(FEED_ID, mid, oracleSpread, 9876);
        provider.setConfidenceParam(confidence);

        (uint128 bid, uint128 ask,) = provider.getQuote();

        uint256 adjustedSpread = uint256(oracleSpread) * confidence;
        uint256 expectedBid = Math.mulDiv(_bidFrom(mid, adjustedSpread), Q64 * STEP_BID_FACTOR, STEP_DENOM);
        uint256 expectedAsk =
            Math.mulDiv(_askFrom(mid, adjustedSpread), Q64 * STEP_ASK_FACTOR, STEP_DENOM, Math.Rounding.Ceil);

        assertEq(bid, expectedBid, "bid should match adjusted offchain quote");
        assertEq(ask, expectedAsk, "ask should match adjusted offchain quote");
    }

    function testGetBidAndAskPriceRevertsWhenStale() public {
        vm.warp(100);
        offchain.setFeed(FEED_ID, 120_000_000, 400, 1111);

        vm.warp(100 + MAX_TIME_DELTA + 1);
        vm.expectRevert(PriceProvider.FeedStalled.selector);
        provider.getQuote();
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
        (uint128 bidSmall, uint128 askSmall,) = provider.getQuote();
        uint256 spreadSmall = askSmall - bidSmall;

        // confidenceParam = 100_000 (10x) → adjustedSpread = 500*100_000 = 50_000_000 (50 bps)
        vm.warp(block.timestamp + provider.CONFIDENCE_COOLDOWN());
        provider.setConfidenceParam(100_000);
        (uint128 bidLarge, uint128 askLarge,) = provider.getQuote();
        uint256 spreadLarge = askLarge - bidLarge;

        assertGt(spreadLarge, spreadSmall, "higher confidence should widen spread");
        assertLt(bidLarge, bidSmall, "bid should decrease with higher confidence");
        assertGt(askLarge, askSmall, "ask should increase with higher confidence");
    }

    function testConfidenceZeroMeansNoSpread() public {
        vm.warp(100);
        offchain.setFeed(FEED_ID, 100_000_000, 500, 100);

        // confidenceParam = 0 (default) → adjustedSpread = 0 → delta = 0. The bid stays at the mid
        // (with marginStep); the ask gets the 1-quantum truncation floor (mid+1) so ASK >= true price.
        (uint128 bid, uint128 ask,) = provider.getQuote();
        assertGt(bid, 0, "bid should be non-zero (marginStep provides separation)");
        assertLt(bid, ask, "bid < ask");

        // bid = mid; ask = mid + 1 quantum (the downward-truncation cover), each with marginStep.
        uint256 expectedBid = Math.mulDiv(uint256(100_000_000), Q64 * STEP_BID_FACTOR, STEP_DENOM);
        uint256 expectedAsk = Math.mulDiv(uint256(100_000_001), Q64 * STEP_ASK_FACTOR, STEP_DENOM, Math.Rounding.Ceil);
        assertEq(bid, expectedBid, "bid = mid (floored-conservative) with marginStep");
        assertEq(ask, expectedAsk, "ask = mid + 1 quantum (covers the hidden truncation)");
    }

    /// @notice On a low-priced feed the mid is floored onto the 8-dec grid, so a zero-band quote
    ///         (delta==0) must lift the ASK by one quantum (mid+1) to stay >= the true price; the BID
    ///         stays at the floored mid (conservative), never above true.
    function testAskQuantumFloorCoversTruncationLowPrice() public {
        vm.warp(100);
        offchain.setFeed(FEED_ID, 60, 0, 100); // mid8 = 60 (~$6e-7), no report spread → delta == 0

        (uint128 bid, uint128 ask,) = provider.getQuote();
        assertEq(bid, Math.mulDiv(uint256(60), Q64 * STEP_BID_FACTOR, STEP_DENOM), "bid = floored mid (60)");
        assertEq(
            ask,
            Math.mulDiv(uint256(61), Q64 * STEP_ASK_FACTOR, STEP_DENOM, Math.Rounding.Ceil),
            "ask = mid + 1 quantum (61), covering the <1-quantum downward truncation"
        );
    }

    /// @notice Regression: when the band already spans >= 1 quantum (delta >= 1), the quantum floor
    ///         is a no-op — the ask is exactly mid + delta, unchanged by the fix.
    function testAskQuantumFloorNoOpWhenBandNonZero() public {
        vm.warp(100);
        uint64 mid = 100_000_000;
        offchain.setFeed(FEED_ID, mid, 500, 100);
        provider.setConfidenceParam(100_000); // delta = mid*500*100_000/1e10 = 500_000 >= 1

        (, uint128 ask,) = provider.getQuote();
        // ask = mid + delta = 100_500_000 (NOT bumped to mid+delta+1)
        assertEq(
            ask,
            Math.mulDiv(uint256(100_500_000), Q64 * STEP_ASK_FACTOR, STEP_DENOM, Math.Rounding.Ceil),
            "ask unchanged: mid + delta, no extra quantum"
        );
    }

    /// @notice On a low-priced feed the confidence-derived fee must NOT be floored away. The old
    ///         `delta = mid * confidence / CONFIDENCE_BASE` collapses to 0 when mid is small (here
    ///         mid = 299, PEPE-scale, 5 bps confidence: 299*5e6/1e10 = 0.149 -> floor 0), silently
    ///         dropping the whole spread and pinning bid == mid. The full-precision quote keeps the fee.
    function testConfidenceFeeSurvivesLowPriceMid() public {
        vm.warp(100);
        uint64 mid = 299; // ~$2.99e-6
        uint16 spread = 500; // 5 bps (0.01-bps units)
        offchain.setFeed(FEED_ID, mid, spread, 100);
        provider.setConfidenceParam(10_000); // 1x -> n = 500 * 10_000 = 5e6; mid*n < 1e10, so old delta -> 0

        (uint128 bid, uint128 ask,) = provider.getQuote();

        uint256 n = uint256(spread) * 10_000;
        uint256 shapedDenom = STEP_DENOM * CONFIDENCE_BASE;

        // Full-precision bid keeps the confidence fee: bid = mid*(CB - n)/CB, marginStep-scaled.
        uint256 expectedBid =
            Math.mulDiv(uint256(mid) * (CONFIDENCE_BASE - n), Q64 * STEP_BID_FACTOR, shapedDenom, Math.Rounding.Floor);
        assertEq(bid, expectedBid, "bid = full-precision confidence bid (fee not floored away)");

        // Delta-floored math would pin bid to the mid-only bid (delta == 0). Confirm the fee
        // actually moved the bid strictly below that — i.e. the fee does not collapse to zero.
        uint256 midOnlyBid = Math.mulDiv(uint256(mid), Q64 * STEP_BID_FACTOR, STEP_DENOM, Math.Rounding.Floor);
        assertLt(bid, midOnlyBid, "confidence fee survives: bid strictly below the mid-only bid");

        // Ask still carries the quantum cover (the sub-quantum confidence is dominated by mid+1).
        assertEq(
            ask,
            Math.mulDiv(uint256(mid + 1), Q64 * STEP_ASK_FACTOR, STEP_DENOM, Math.Rounding.Ceil),
            "ask = (mid+1) honest upper (quantum cover preserved)"
        );
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

        (uint128 bidPrice,,) = provider.getQuote();

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
        (uint128 bid, uint128 ask,) = provider.getQuote();
        assertGt(bid, 0, "bid should still be positive");
        assertLt(bid, ask, "bid < ask");
    }

    // ── MarginStep bounds ────────────────────────────────────────────────────

    function testMarginStepOutOfBoundsReverts() public {
        vm.expectRevert(PriceProvider.MarginStepOutOfBounds.selector);
        new PriceProvider(
            factory,
            address(offchain),
            FEED_ID,
            int256(BPS_BASE_U), // == BPS_BASE, out of bounds
            MAX_TIME_DELTA,
            BASE_TOKEN,
            QUOTE_TOKEN
        );
    }

    // ── Negative CEX_STEP & inversion guard ──────────────────────────────

    function testNegMarginStepInversionRevertsStrict() public {
        vm.warp(100);
        PriceProvider negProvider =
            new PriceProvider(factory, address(offchain), FEED_ID, -5e14, MAX_TIME_DELTA, BASE_TOKEN, QUOTE_TOKEN);

        offchain.setFeed(FEED_ID, 100_000_000, 200, 100);
        negProvider.setConfidenceParam(10_000);

        vm.expectRevert(PriceProvider.FeedStalled.selector);
        negProvider.getQuote();
    }

    function testNegMarginStepWithSufficientConfidence() public {
        vm.warp(100);
        PriceProvider negProvider =
            new PriceProvider(factory, address(offchain), FEED_ID, -5e14, MAX_TIME_DELTA, BASE_TOKEN, QUOTE_TOKEN);

        offchain.setFeed(FEED_ID, 100_000_000, 200, 100);
        // adjustedSpread = 200*250_000 = 50_000_000 → 50 bps > 5 bps step
        negProvider.setConfidenceParam(250_000);

        (uint128 bid, uint128 ask,) = negProvider.getQuote();
        assertGt(bid, 0, "bid should be valid");
        assertLt(bid, ask, "bid < ask with sufficient confidence");
    }

    function testNegMarginStepWithConfidenceWorks() public {
        vm.warp(100);
        PriceProvider negProvider =
            new PriceProvider(factory, address(offchain), FEED_ID, -5e14, MAX_TIME_DELTA, BASE_TOKEN, QUOTE_TOKEN);

        offchain.setFeed(FEED_ID, 100_000_000, 200, 100);
        // adjustedSpread = 200*100_000 = 20_000_000 → 20 bps > 5 bps step
        negProvider.setConfidenceParam(100_000);

        (uint128 bid, uint128 ask,) = negProvider.getQuote();
        assertGt(bid, 0, "bid should be valid with confidence");
        assertLt(bid, ask, "bid < ask with confidence");
    }

    /// @notice With a NEGATIVE marginStep the E8 quantum cover must still bracket the true price. The
    ///         cover lifts the ask to the honest upper bound `mid + 1`; an unfloored
    ///         `stepAskFactor = BPS_BASE_U + marginStep` — which is BELOW 1e18 when
    ///         marginStep < 0 — would drag the "honest" bound under `mid + 1`: `ASK >= T` would fail
    ///         exactly where the cover exists to hold, and the pool would buy token0 out of LP
    ///         inventory above the true price. The factor is therefore floored at 1e18.
    ///
    ///         Chosen so the quantum matters: mid = 33 (3.3e-7 at 8 decimals) with confidence 0, so
    ///         nothing but the cover stands between the ask and the truncated mid. `testNegMarginStep…`
    ///         above cannot catch this — it asserts only `bid < ask`, at mid = 1e8 where one quantum
    ///         is negligible.
    function testNegMarginStepStillCoversTheQuantum() public {
        vm.warp(100);
        int256 ms = -235e12; // −0.0235%, comfortably inside |marginStep| < 1e18
        PriceProvider negProvider =
            new PriceProvider(factory, address(offchain), FEED_ID, ms, MAX_TIME_DELTA, BASE_TOKEN, QUOTE_TOKEN);

        // Confidence must out-weigh |marginStep|, or the quote inverts and correctly halts before the
        // covers run: rel = spread·conf/CONFIDENCE_BASE = 300·10_000/1e10 = 3 bps > 2.35 bps = |ms|.
        uint64 mid = 33;
        offchain.setFeed(FEED_ID, mid, 300, 100);
        negProvider.setConfidenceParam(10_000);

        (uint128 bid, uint128 ask,) = negProvider.getQuote();

        // T is anywhere in [mid, mid+1) on the 8-dec grid; the honest bounds are mid/1e8 and
        // (mid+1)/1e8 in Q64 — deliberately UNSCALED by any marginStep factor.
        uint256 honestUpper = Math.mulDiv(uint256(mid) + 1, Q64 * BPS_BASE_U, STEP_DENOM, Math.Rounding.Ceil);
        uint256 honestLower = Math.mulDiv(uint256(mid), Q64 * BPS_BASE_U, STEP_DENOM, Math.Rounding.Floor);

        assertGe(ask, honestUpper, "ASK must cover the whole quantum even for marginStep < 0");
        assertLe(bid, honestLower, "BID stays floored-conservative");
        assertLt(bid, ask, "band still ordered");
    }

    // ── referencePrice ────────────────────────────────────────────────────

    /// @notice The reported reference is the oracle mid on the Q64 scale — the value both edges are
    ///         shaped around, before the confidence spread and the marginStep bias.
    function testReferenceIsOracleMid() public {
        vm.warp(100);
        uint64 mid = 155_000_000;
        offchain.setFeed(FEED_ID, mid, 300, 4321);
        provider.setConfidenceParam(100_000);

        (uint128 bid, uint128 ask, uint128 refPrice) = provider.getQuote();

        assertEq(refPrice, uint128(Math.mulDiv(uint256(mid), Q64, 1e8)), "reference = oracle mid in Q64");
        assertLe(bid, refPrice, "bid <= reference");
        assertLe(refPrice, ask, "reference <= ask");
    }

    /// @notice Widening the quote (more confidence) must not move the fee base.
    function testReferenceUnmovedByConfidence() public {
        vm.warp(100);
        uint64 mid = 155_000_000;
        offchain.setFeed(FEED_ID, mid, 300, 4321);

        (uint128 tightBid, uint128 tightAsk, uint128 refTight) = provider.getQuote();

        provider.setConfidenceParam(500_000);
        (uint128 wideBid, uint128 wideAsk, uint128 refWide) = provider.getQuote();

        assertLt(wideBid, tightBid, "confidence widened the bid side");
        assertGt(wideAsk, tightAsk, "confidence widened the ask side");
        assertEq(refWide, refTight, "reference unchanged");
    }

    /// @notice A nonzero marginStep is a symmetric widening of both edges, so it does not skew the
    ///         reference off the oracle mid either — the fee each side pays simply grows by the bias.
    function testReferenceWithNegativeMarginStepStaysInQuote() public {
        vm.warp(100);
        PriceProvider negProvider =
            new PriceProvider(factory, address(offchain), FEED_ID, -5e14, MAX_TIME_DELTA, BASE_TOKEN, QUOTE_TOKEN);
        offchain.setFeed(FEED_ID, 100_000_000, 200, 100);
        negProvider.setConfidenceParam(100_000);

        (uint128 bid, uint128 ask, uint128 refPrice) = negProvider.getQuote();

        assertEq(refPrice, uint128(Math.mulDiv(uint256(100_000_000), Q64, 1e8)));
        assertLe(bid, refPrice, "bid <= reference even when marginStep scales the bid up");
        assertLe(refPrice, ask, "reference <= ask");
    }

    /// @notice The invariant the consumer enforces, over the whole live surface: any mid, any spread
    ///         under the circuit breaker, any confidence, either sign of marginStep.
    function testFuzzReferenceWithinQuote(uint64 mid, uint16 spread, uint256 confidence, int256 marginStep) public {
        vm.warp(100);
        mid = uint64(bound(mid, 1, 1e18));
        spread = uint16(bound(spread, 0, 50_000)); // MAX_SPREAD_BPS; above it the feed halts
        confidence = bound(confidence, 0, 1_000_000); // CONFIDENCE_MAX
        marginStep = bound(marginStep, -1e17, 1e17);

        PriceProvider p =
            new PriceProvider(factory, address(offchain), FEED_ID, marginStep, MAX_TIME_DELTA, BASE_TOKEN, QUOTE_TOKEN);
        offchain.setFeed(FEED_ID, mid, spread, 0);
        p.setConfidenceParam(confidence);

        // A halt is a valid outcome (inverted quote, confidence eating the bid); when a quote IS
        // produced, the reference must sit inside it.
        try p.getQuote() returns (uint128 bid, uint128 ask, uint128 refPrice) {
            assertEq(refPrice, uint128(Math.mulDiv(uint256(mid), Q64, 1e8)), "reference = oracle mid");
            assertLe(bid, refPrice, "bid <= reference");
            assertLe(refPrice, ask, "reference <= ask");
        } catch {}
    }

    // ── Price guard ──────────────────────────────────────────────────────

    function testPriceGuardRejectsBelow() public {
        offchain.setFeed(FEED_ID, 50_000_000, 300, 100);
        offchain.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);

        vm.expectRevert(PriceProvider.FeedStalled.selector);
        provider.getQuote();
    }

    function testPriceGuardRejectsAbove() public {
        offchain.setFeed(FEED_ID, 250_000_000, 300, 100);
        offchain.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);

        vm.expectRevert(PriceProvider.FeedStalled.selector);
        provider.getQuote();
    }

    function testPriceGuardAcceptsWithinRange() public {
        vm.warp(100);
        offchain.setFeed(FEED_ID, 150_000_000, 300, 100);
        offchain.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);
        provider.setConfidenceParam(100_000);

        (uint128 bid, uint128 ask,) = provider.getQuote();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    function testPriceGuardZeroMaxTreatedAsUnlimited() public {
        offchain.setFeed(FEED_ID, 150_000_000, 300, 100);
        // guardMax = 0 means unlimited
        offchain.setPriceGuard(FEED_ID, 0, 0);

        (uint128 bid, uint128 ask,) = provider.getQuote();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    // ── Spread validity ─────────────────────────────────────────────────

    function testStallSentinelReverts() public {
        // Only the reserved stall sentinel (type(uint16).max) halts as "feed inactive".
        offchain.setFeed(FEED_ID, 100_000_000, type(uint16).max, 100);

        vm.expectRevert(PriceProvider.FeedStalled.selector);
        provider.getQuote();
    }

    function testSpreadAboveCircuitBreakerReverts() public {
        // A genuine spread wider than the 5% circuit breaker (MAX_SPREAD_BPS = 50_000) halts.
        offchain.setFeed(FEED_ID, 100_000_000, 60_000, 100);

        vm.expectRevert(PriceProvider.FeedStalled.selector);
        provider.getQuote();
    }

    function testWideSpreadBelowCeilingQuotes() public {
        vm.warp(100); // clear the confidence-param cooldown
        // A 3% spread (30_000) — above the old 1% halt but below the circuit breaker — now WIDENS
        // the band instead of halting.
        offchain.setFeed(FEED_ID, 100_000_000, 30_000, 100);
        provider.setConfidenceParam(ORACLE_BPS); // 1×

        (uint128 bid, uint128 ask,) = provider.getQuote();
        assertGt(bid, 0, "wide spread should still quote");
        assertLt(bid, ask, "band widened, not halted");
    }
}

contract MockCompressedOracle is IOffchainOracle {
    uint16 private constant BPS = 10_000;

    struct Feed {
        uint64 midPrice;
        uint16 spread0;
        uint16 spread1;
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

    function getOracleDataBulk(bytes32[] calldata) external pure override returns (OracleData[] memory) {
        return new OracleData[](0);
    }

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
        external
        view
        returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime)
    {
        Feed memory f = feeds[feedId];
        return (uint256(f.midPrice), uint256(f.spread0), f.spread1, f.refTime);
    }
}
