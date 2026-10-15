// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AnchoredPriceProvider} from "../contracts/AnchoredPriceProvider.sol";
import {IAnchoredProviderFactory} from "../contracts/interfaces/IAnchoredProviderFactory.sol";
import {IOffchainOracle} from "../contracts/interfaces/IOffchainOracle.sol";
import {OracleBase} from "../contracts/oracles/providers/OracleBase.sol";
import {toTimeMs} from "../contracts/oracles/utils/TimeMs.sol";

import {TestOracle} from "./utils/TestOracle.sol";
import {MockPoolFactory} from "./mocks/MockPoolFactory.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockAnchorSource} from "./mocks/MockAnchorSource.sol";

// Spread-multiplier test constants (BPS_BASE_U scale): 1.0x default + a 4x envelope ceiling.
uint256 constant MULT = 1e18;
uint256 constant MULT_MAX = 4e18;

// Default InitialConfig for a provider: no source, per-leg staleness = the provider's cap,
// 1.0x per-leg multipliers (the plain single-bound default).
function _initFor(uint256 staleness) pure returns (IAnchoredProviderFactory.InitialConfig memory) {
    return IAnchoredProviderFactory.InitialConfig({
        source: address(0),
        baseMaxStaleness: staleness,
        quoteMaxStaleness: staleness,
        baseSpreadMult: MULT,
        quoteSpreadMult: MULT
    });
}

// Expected synthetic endpoints for exact quote assertions. Independent containment properties live
// in QuoteSafety.t.sol and compare cross-products against sampled unrounded input intervals.
function _expectedSyntheticBand(uint256 mid1, uint256 mid2, uint256 baseHalf, uint256 quoteHalf, uint256 margin)
    pure
    returns (uint128 bid, uint128 ask)
{
    uint256 scale = 1e18;
    uint256 q64 = 1 << 64;
    uint256 marginQ64 = Math.mulDiv(mid1, q64 * margin, mid2 * scale, Math.Rounding.Ceil);
    bid = uint128(Math.mulDiv(mid1, q64 * (scale - baseHalf), (mid2 + 1) * (scale + quoteHalf)) - marginQ64);
    ask = uint128(
        Math.mulDiv(mid1 + 1, q64 * (scale + baseHalf), mid2 * (scale - quoteHalf), Math.Rounding.Ceil) + marginQ64
    );
}

contract AnchoredPriceProviderTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant BPS_BASE_U = 1e18;
    uint256 private constant STEP_DENOM = 1e8 * BPS_BASE_U;
    uint16 private constant ORACLE_BPS = 10_000;
    uint256 private constant ONE_SPREAD_UNIT_E18 = 1e12; // 0.01-bps unit in 1e18 scale

    bytes32 private constant FEED_ID = keccak256("anchored-feed");
    address private constant BASE_TOKEN = address(0xBEEF);
    address private constant QUOTE_TOKEN = address(0xCAFE);

    // Majors-class parameters (floor 0.5 bps/side, uMax 150 spread units = 1.5 bps).
    uint256 private constant FLOOR = 5e13;
    uint256 private constant MAX_REF_STALENESS = 60;
    uint16 private constant U_MAX = 150;
    uint256 private constant T0 = 1_000_000;

    TestOracle private oracle;
    MockPoolFactory private poolFactory; // AMM pool factory (oracle-approved)
    AnchoredPriceProvider private provider;
    MockAnchorSource private src;

    address private anchorFactory; // provider's immutable factory (governs setSource)
    address private pool; // == address(this): this contract acts as the pool
    address private _inSwapPP; // IPool.inSwap() backing

    /// @dev IPool surface: the oracle queries this to bind the read to the calling provider.
    function inSwap() external view returns (address) {
        return _inSwapPP;
    }

    function setUp() public {
        anchorFactory = address(this);
        vm.deal(address(this), 1 ether);
        vm.warp(T0);

        oracle = new TestOracle(address(this), 60);

        poolFactory = new MockPoolFactory();
        oracle.addApprovedFactory(address(poolFactory));

        provider = _deployProvider(FLOOR, MAX_REF_STALENESS, BASE_TOKEN, QUOTE_TOKEN);
        src = new MockAnchorSource();

        // This test contract is the registered pool (it calls the provider directly).
        pool = address(this);
        poolFactory.setPool(pool, true);
        oracle.register{value: 1}(FEED_ID, pool, address(poolFactory));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _deployProvider(uint256 floor_, uint256 staleness, address base, address quote)
        internal
        returns (AnchoredPriceProvider)
    {
        return new AnchoredPriceProvider(
            anchorFactory,
            address(oracle),
            FEED_ID,
            bytes32(0),
            floor_,
            staleness,
            MULT,
            false,
            int256(0),
            base,
            quote,
            _initFor(staleness)
        );
    }

    function _deployMutableProvider() internal returns (AnchoredPriceProvider) {
        return new AnchoredPriceProvider(
            anchorFactory,
            address(oracle),
            FEED_ID,
            bytes32(0),
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            true,
            int256(0),
            BASE_TOKEN,
            QUOTE_TOKEN,
            _initFor(MAX_REF_STALENESS)
        );
    }

    /// @dev Expected reference band, mirroring the contract math.
    function _refBand(uint64 mid, uint16 u, uint256 floor_) internal pure returns (uint128 refBid, uint128 refAsk) {
        uint256 half = uint256(u) * ONE_SPREAD_UNIT_E18 + floor_;
        refBid = uint128(Math.mulDiv(mid, Q64 * (BPS_BASE_U - half), STEP_DENOM));
        // The ask carries the half-width on the honest upper bound `mid + 1` of the E8 quantum:
        // quantization and uncertainty compound (single-feed cover in `_computeBidAsk`).
        refAsk = uint128(Math.mulDiv(uint256(mid) + 1, Q64 * (BPS_BASE_U + half), STEP_DENOM, Math.Rounding.Ceil));
    }

    function _read() internal returns (uint128 bid, uint128 ask, uint128 refPrice) {
        _inSwapPP = address(provider); // mark this pool in-swap with the provider, then read (no args)
        return provider.getQuote();
    }

    function _expectStalled() internal {
        _inSwapPP = address(provider);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        provider.getQuote();
    }

    // ── Construction / tokens ─────────────────────────────────────────────

    function testGetTokensReturnsConfiguredPair() public view {
        address base = provider.token0();
        address quote = provider.token1();
        assertEq(base, BASE_TOKEN);
        assertEq(quote, QUOTE_TOKEN);
    }

    function testConstructorSetsExplicitTokens() public {
        AnchoredPriceProvider p = _deployProvider(FLOOR, MAX_REF_STALENESS, address(0xA11CE), address(0xB0B));
        address base = p.token0();
        address quote = p.token1();
        assertEq(base, address(0xA11CE));
        assertEq(quote, address(0xB0B));
    }

    function testConstructorZeroBaseTokenReverts() public {
        vm.expectRevert();
        _deployProvider(FLOOR, MAX_REF_STALENESS, address(0), QUOTE_TOKEN);
    }

    function testConstructorZeroQuoteTokenReverts() public {
        vm.expectRevert();
        _deployProvider(FLOOR, MAX_REF_STALENESS, BASE_TOKEN, address(0));
    }

    function testConstructorEqualTokensReverts() public {
        vm.expectRevert();
        _deployProvider(FLOOR, MAX_REF_STALENESS, BASE_TOKEN, BASE_TOKEN);
    }

    function testConstructorStoresClampParams() public view {
        assertEq(provider.minMargin(), FLOOR);
        assertEq(provider.MAX_REF_STALENESS(), MAX_REF_STALENESS);
        assertEq(provider.factory(), anchorFactory);
        assertEq(address(provider.offchainOracle()), address(oracle));
        assertEq(provider.baseFeedId(), FEED_ID);
        assertEq(provider.source(), address(0));
    }

    function testConstructorStoresMarginStep() public {
        AnchoredPriceProvider pPos = new AnchoredPriceProvider(
            anchorFactory,
            address(oracle),
            FEED_ID,
            bytes32(0),
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            true,
            int256(5e16),
            BASE_TOKEN,
            QUOTE_TOKEN,
            _initFor(MAX_REF_STALENESS)
        );
        assertEq(pPos.marginStep(), int256(5e16), "positive marginStep stored");
        AnchoredPriceProvider pNeg = new AnchoredPriceProvider(
            anchorFactory,
            address(oracle),
            FEED_ID,
            bytes32(0),
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            true,
            -int256(5e16),
            BASE_TOKEN,
            QUOTE_TOKEN,
            _initFor(MAX_REF_STALENESS)
        );
        assertEq(pNeg.marginStep(), -int256(5e16), "negative marginStep stored");
    }

    function testConstructorZeroFactoryReverts() public {
        vm.expectRevert();
        new AnchoredPriceProvider(
            address(0),
            address(oracle),
            FEED_ID,
            bytes32(0),
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            false,
            int256(0),
            BASE_TOKEN,
            QUOTE_TOKEN,
            _initFor(MAX_REF_STALENESS)
        );
    }

    function testConstructorStalenessZeroAllowed() public {
        AnchoredPriceProvider p = _deployProvider(FLOOR, 0, BASE_TOKEN, QUOTE_TOKEN);
        assertEq(p.MAX_REF_STALENESS(), 0, "staleness 0 allowed = refTime must equal block.timestamp");
    }

    function testConstructorStalenessTooLargeReverts() public {
        vm.expectRevert(AnchoredPriceProvider.MaxRefStalenessOutOfBounds.selector);
        _deployProvider(FLOOR, 7 days + 1, BASE_TOKEN, QUOTE_TOKEN);
    }

    /// @notice minMargin must be strictly positive. The refBid >= refAsk halt is not a sufficient
    ///         safety net on its own —
    ///         that halt only fires on an EXACTLY collapsed band, so minMargin 0 with a spread of 1
    ///         unit yields a ~0.0001%-per-side band that passes every guard while the provider still
    ///         advertises the "never tighter than the band" floor.
    function testConstructorMinMarginZeroRejected() public {
        vm.expectRevert(AnchoredPriceProvider.MinMarginZero.selector);
        _deployProvider(0, MAX_REF_STALENESS, BASE_TOKEN, QUOTE_TOKEN);
    }

    /// @notice With minMargin 0 the band would rely entirely on the oracle spread, and a spread of ONE
    ///         unit (not zero — zero is the only case the halt catches) would still produce a live,
    ///         near-zero-width quote. The constructor rejects minMargin 0, so assert the smallest
    ///         permitted minMargin still yields a band strictly wider than the degenerate one.
    function testMinimalMinMarginStillGivesPositiveBand() public {
        AnchoredPriceProvider p = _deployProvider(1, MAX_REF_STALENESS, BASE_TOKEN, QUOTE_TOKEN);
        oracle.setData(FEED_ID, 100_000_000, 1, 0, block.timestamp); // mid = 1.0 (round), spread = 1 unit
        _inSwapPP = address(p);
        (uint128 bid, uint128 ask,) = p.getQuote();
        assertLt(bid, ask, "band must be strictly positive");
    }

    // ── E8 quantization cover ───────────────────────────────────────────────

    /// @notice On a low-priced feed the mid is floored onto the 8-dec grid, so the true price sits in
    ///         [mid, mid+1)/1e8. When the band half-width is below one quantum (1/mid) the plain
    ///         reference ask lands below the true price. The cover must apply the half-width to the
    ///         honest upper bound (mid+1)/1e8 so ASK >= true·(1 + u + floor); the bid stays at the
    ///         floored band edge (conservative).
    function testAskCoversE8TruncationLowPriceSingleFeed() public {
        oracle.setData(FEED_ID, 60, 0, 0, block.timestamp); // mid8 = 60 (~$6e-7), u = 0 → thin band

        (uint128 bid, uint128 ask,) = _read();

        (uint128 refBid, uint128 refAsk) = _refBand(60, 0, FLOOR);
        uint256 plainAsk = Math.mulDiv(uint256(60), Q64 * (BPS_BASE_U + FLOOR), STEP_DENOM, Math.Rounding.Ceil);
        assertEq(bid, refBid, "bid = floored band edge (conservative, cover is a no-op on the bid)");
        assertGt(ask, plainAsk, "ask lifted above the plain floored-mid band by the E8 quantum cover");
        assertEq(ask, refAsk, "ask = (mid+1)*(1 + floor) honest upper bound");
        assertEq(
            ask,
            uint128(Math.mulDiv(uint256(61), Q64 * (BPS_BASE_U + FLOOR), STEP_DENOM, Math.Rounding.Ceil)),
            "ask = 61e-8 * (1 + 0.5 bps)"
        );
    }

    /// @notice On a normally-priced feed (majors) the cover is negligible rather than a no-op: the ask
    ///         still compounds the E8 quantum with the half-width, but one quantum (1/mid = 1e-8 here)
    ///         is orders of magnitude below FLOOR. The band is the plain reference band widened by
    ///         exactly one scaled quantum on the ask side and untouched on the bid side.
    function testAskQuantumCoverNegligibleWhenBandWide() public {
        oracle.setData(FEED_ID, 100_000_000, 0, 0, block.timestamp); // mid = 1.0, 1/mid ≪ FLOOR

        (uint128 bid, uint128 ask,) = _read();
        (uint128 refBid, uint128 refAsk) = _refBand(100_000_000, 0, FLOOR);
        assertEq(bid, refBid, "wide-band bid = plain floored band edge");
        assertEq(ask, refAsk, "wide-band ask = (mid+1)*(1 + floor)");

        uint256 plainAsk = Math.mulDiv(100_000_000, Q64 * (BPS_BASE_U + FLOOR), STEP_DENOM, Math.Rounding.Ceil);
        uint256 quantum = Math.mulDiv(1, Q64 * (BPS_BASE_U + FLOOR), STEP_DENOM, Math.Rounding.Ceil);
        assertApproxEqAbs(ask - plainAsk, quantum, 1, "cover adds exactly one scaled E8 quantum");
        assertLt((ask - plainAsk) * BPS_BASE_U / plainAsk, FLOOR / 1000, "widening is far below FLOOR");
    }

    /// @notice The upstream interval's upper edge is (mid+1)·(1+u), NOT max(mid·(1+u+floor), mid+1).
    ///         $0.000001009 at 1% confidence stores mid = 100 (floored from 100.9) with u = 1%; the
    ///         honest ask is 100.9·1.01 = 101.909e-8. The max form gives 100·1.01005 = 101.005e-8 — below
    ///         it, so LPs would sell the base under the oracle's own upper bound. Compounding gives
    ///         101·1.01005 = 102.01505e-8 >= 101.909e-8.
    function testAskCoversUpstreamUpperEdgeOnCheapFeedWithUncertainty() public {
        uint64 mid = 100; // floor(100.9)
        uint16 u = ORACLE_BPS; // 10_000 × 0.01 bps = 1%
        oracle.setData(FEED_ID, mid, u, 0, block.timestamp);

        (uint128 bid, uint128 ask, uint128 refPrice) = _read();

        // Exact rational comparisons: upstream ask 101.909e-8 = 101_909 / 1e11, bid 99.891e-8.
        assertGe(uint256(ask) * 1e11, uint256(101_909) * Q64, "ask covers the upstream upper edge");
        assertLe(uint256(bid) * 1e11, uint256(99_891) * Q64, "bid covers the upstream lower edge");
        (, uint128 refAsk) = _refBand(mid, u, FLOOR);
        assertEq(ask, refAsk, "ask = (mid+1)*(1 + u + floor)");
        assertEq(refPrice, uint128(Math.mulDiv(mid, Q64, 1e8)), "reference stays the stored mid");

        // The max(mid·(1+u+floor), mid+1) form does NOT cover it.
        uint256 half = uint256(u) * ONE_SPREAD_UNIT_E18 + FLOOR;
        uint256 maxFormAsk = Math.max(
            Math.mulDiv(mid, Q64 * (BPS_BASE_U + half), STEP_DENOM, Math.Rounding.Ceil),
            Math.mulDiv(uint256(mid) + 1, Q64 * BPS_BASE_U, STEP_DENOM, Math.Rounding.Ceil)
        );
        assertLt(maxFormAsk * 1e11, uint256(101_909) * Q64, "the max form undercovers this feed");
    }

    /// @notice The security invariant behind the cover: the quote must bracket the HIDDEN unfloored true
    ///         price. True price $0.00012345678 can only be stored as mid = 12345 ($0.00012345); the
    ///         thin band's plain ask (12345·(1+0.5bps) = 12345.617e-8) lands BELOW the true 12345.678e-8
    ///         → LPs sell the base under fair value. The cover lifts the ask to 12346e-8·(1+0.5bps) > true.
    function testHonestTruePriceBracketed() public {
        oracle.setData(FEED_ID, 12345, 0, 0, block.timestamp); // stored floor of a 12345.678e-8 truth

        (uint128 bid, uint128 ask,) = _read();

        uint256 trueX64 = Math.mulDiv(uint256(12_345_678), Q64, 1e11); // 12345.678e-8 = 12345678/1e11 in Q64
        assertGe(uint256(ask), trueX64, "ask covers the hidden true price (no LP loss on the ask leg)");
        assertLe(uint256(bid), trueX64, "bid at or below the hidden true price (conservative)");
        assertEq(
            uint256(ask),
            Math.mulDiv(uint256(12_346), Q64 * (BPS_BASE_U + FLOOR), STEP_DENOM, Math.Rounding.Ceil),
            "ask = (mid+1)*(1 + floor) honest upper bound"
        );
    }

    // ── setSource ─────────────────────────────────────────────────────────

    function testSetSourceFromFactoryAndEmits() public {
        vm.expectEmit(true, false, false, true, address(provider));
        emit AnchoredPriceProvider.SourceSet(address(src));
        provider.setSource(address(src));
        assertEq(provider.source(), address(src));
    }

    function testSetSourceRevertsNonFactory() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(AnchoredPriceProvider.OnlyFactory.selector);
        provider.setSource(address(src));
    }

    function testSetSourceZeroRestoresReferenceMode() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        src.set(1, 2); // valid but extreme source (1 < 2, in Q64 ≈ 0): passes validation and clamps wide
        provider.setSource(address(src));

        provider.setSource(address(0));
        (uint128 bid, uint128 ask,) = _read();
        (uint128 refBid, uint128 refAsk) = _refBand(185_000_000, 2, FLOOR);
        assertEq(bid, refBid);
        assertEq(ask, refAsk);
    }

    // ── Reference mode math ───────────────────────────────────────────────

    function testReferenceModeQuotesBand() public {
        uint64 mid = 185_000_000; // 1.85, 8-dec
        uint16 u = 2; // 0.02 bps reference uncertainty (2 spread units)
        oracle.setData(FEED_ID, mid, u, 0, block.timestamp);

        (uint128 bid, uint128 ask,) = _read();
        (uint128 refBid, uint128 refAsk) = _refBand(mid, u, FLOOR);

        assertEq(bid, refBid, "bid = mid - (u + floor)");
        assertEq(ask, refAsk, "ask = mid + (u + floor)");
        assertLt(bid, ask);
    }

    function testReferenceModeFloorOnlyWhenUZero() public {
        uint64 mid = 100_000_000;
        oracle.setData(FEED_ID, mid, 0, 0, block.timestamp);

        (uint128 bid, uint128 ask,) = _read();
        (uint128 refBid, uint128 refAsk) = _refBand(mid, 0, FLOOR);

        assertEq(bid, refBid);
        assertEq(ask, refAsk);
        // floor alone separates the quotes
        assertLt(bid, ask);
    }

    function testReferenceModeWideningUWidensBand() public {
        uint64 mid = 100_000_000;

        oracle.setData(FEED_ID, mid, 1, 0, block.timestamp);
        (uint128 bidNarrow, uint128 askNarrow,) = _read();

        oracle.setData(FEED_ID, mid, 100, 0, block.timestamp);
        (uint128 bidWide, uint128 askWide,) = _read();

        assertLt(bidWide, bidNarrow, "wider u lowers bid");
        assertGt(askWide, askNarrow, "wider u raises ask");
    }

    // ── Guards → FeedStalled ──────────────────────────────────────────────

    function testRevertsWhenStale() public {
        oracle.setData(FEED_ID, 100_000_000, 2, 0, block.timestamp - MAX_REF_STALENESS - 1);
        _expectStalled();
    }

    /// @dev Boundary: refTime exactly MAX_REF_STALENESS old is NOT stale (halt when
    ///      block.timestamp - refTime > maxRefStaleness), so the pool still quotes.
    function testQuotesAtExactStalenessBoundary() public {
        oracle.setData(FEED_ID, 100_000_000, 2, 0, block.timestamp - MAX_REF_STALENESS);
        (uint128 bid, uint128 ask,) = _read();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    function testRevertsWhenFutureRefTime() public {
        oracle.setData(FEED_ID, 100_000_000, 2, 0, block.timestamp + 1);
        _expectStalled();
    }

    function testRevertsWhenMidZero() public {
        oracle.setData(FEED_ID, 0, 2, 0, block.timestamp);
        _expectStalled();
    }

    /// @notice Closed RWA markets emit 65535. The saturation guard rejects both 65534 and 65535.
    function testRevertsOnOffHoursMarker() public {
        oracle.setData(FEED_ID, 100_000_000, type(uint16).max, 0, block.timestamp);
        _expectStalled();
    }

    /// @notice A representable 1% spread below the saturation ceiling still quotes.
    function testWideSpreadWidensRatherThanHalting() public {
        oracle.setData(FEED_ID, 100_000_000, ORACLE_BPS, 0, block.timestamp); // 1%
        (uint128 bid, uint128 ask,) = _read();
        assertGt(bid, 0, "1% spread still quotes");
        assertLt(bid, ask);
    }

    function testPriceGuardRejectsBelow() public {
        oracle.setData(FEED_ID, 50_000_000, 2, 0, block.timestamp);
        oracle.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);
        _expectStalled();
    }

    function testPriceGuardRejectsAbove() public {
        oracle.setData(FEED_ID, 250_000_000, 2, 0, block.timestamp);
        oracle.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);
        _expectStalled();
    }

    function testPriceGuardAcceptsWithinRange() public {
        oracle.setData(FEED_ID, 150_000_000, 2, 0, block.timestamp);
        oracle.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);
        (uint128 bid, uint128 ask,) = _read();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    // ── Source mode: clamping ─────────────────────────────────────────────

    function testSourceWiderThanBandPassesThrough() public {
        uint64 mid = 185_000_000;
        uint16 u = 2;
        oracle.setData(FEED_ID, mid, u, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(mid, u, FLOOR);

        src.set(refBid - 1000, refAsk + 1000); // strictly wider than the band on both sides
        provider.setSource(address(src));

        (uint128 bid, uint128 ask,) = _read();
        assertEq(bid, refBid - 1000, "wider source bid passes through");
        assertEq(ask, refAsk + 1000, "wider source ask passes through");
    }

    function testSourceTighterThanBandClipsBothSides() public {
        uint64 mid = 185_000_000;
        uint16 u = 2;
        oracle.setData(FEED_ID, mid, u, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(mid, u, FLOOR);

        src.set(refBid + 1000, refAsk - 1000); // tighter than the band → cannot fill better than band
        provider.setSource(address(src));

        (uint128 bid, uint128 ask,) = _read();
        assertEq(bid, refBid, "in-band source bid clipped to band edge");
        assertEq(ask, refAsk, "in-band source ask clipped to band edge");
    }

    function testSourceOneSidedClip() public {
        uint64 mid = 185_000_000;
        uint16 u = 2;
        oracle.setData(FEED_ID, mid, u, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(mid, u, FLOOR);

        src.set(refBid + 5, refAsk + 5); // bid tighter (clipped), ask wider (kept)
        provider.setSource(address(src));

        (uint128 bid, uint128 ask,) = _read();
        assertEq(bid, refBid);
        assertEq(ask, refAsk + 5);
    }

    function testSourceClampHoldsBidLtAskAlways() public {
        uint64 mid = 185_000_000;
        oracle.setData(FEED_ID, mid, 2, 0, block.timestamp);

        // source quotes an absurdly tight, shifted market — still bounded by the band
        (uint128 refBid, uint128 refAsk) = _refBand(mid, 2, FLOOR);
        src.set(refAsk + 1, refAsk + 2); // entirely above the band
        provider.setSource(address(src));

        (uint128 bid, uint128 ask,) = _read();
        assertEq(bid, refBid, "bid clipped down to band");
        assertEq(ask, refAsk + 2, "ask passes (wider)");
        assertLt(bid, ask);
    }

    // ── Source mode: fail closed ──────────────────────────────────────────

    function testSourceRevertHalts() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.Revert);
        provider.setSource(address(src));
        _expectStalled();
    }

    function testSourceGarbageReturndataHalts() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.Garbage);
        provider.setSource(address(src));
        _expectStalled();
    }

    function testSourceGasGriefHalts() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.BurnGas);
        provider.setSource(address(src));
        _expectStalled();
    }

    function testSourceDirtyWordsHalt() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.DirtyWords);
        provider.setSource(address(src));
        _expectStalled();
    }

    /// @dev Exercises the load-bearing `srcAsk > type(uint128).max` guard specifically: a valid bid
    ///      with an ask one over uint128.max. Without the guard, max(refAsk, srcAsk) would truncate
    ///      to a sub-band ask and quote a price better than the band — this must halt instead.
    function testSourceOverflowAskHalts() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.OverflowAsk);
        provider.setSource(address(src));
        _expectStalled();
    }

    /// @dev Returndata bomb: must fail closed AND keep the caller-side cost bounded (the assembly read
    ///      copies only 96 bytes, so a clean fail-closed read and a bombing read cost the same order
    ///      of gas).
    function testSourceReturndataBombFailsClosedAndBounded() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);

        // baseline: a clean fail-closed source (EOA, empty returndata)
        provider.setSource(address(0xE0A));
        _inSwapPP = address(provider);
        uint256 g0 = gasleft();
        try provider.getQuote() returns (uint128, uint128, uint128) {} catch {}
        uint256 cleanCost = g0 - gasleft();

        // bomb: ~480 KB returndata
        src.setMode(MockAnchorSource.Mode.Bomb);
        provider.setSource(address(src));
        _inSwapPP = address(provider);
        uint256 g1 = gasleft();
        try provider.getQuote() returns (uint128, uint128, uint128) {} catch {}
        uint256 bombCost = g1 - gasleft();

        // Both fail closed (revert caught). The bomb must not blow past SOURCE_GAS_LIMIT-class cost:
        // assert it stays well under the ~1M gas that copying all ~480 KB would cost.
        assertLt(bombCost, 600_000, "returndata bomb cost must stay bounded (no full copy)");
        assertLt(bombCost - cleanCost, provider.SOURCE_GAS_LIMIT(), "incremental bomb cost under the forwarded cap");
    }

    function testSourceZeroBidHalts() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        src.set(0, 1000);
        provider.setSource(address(src));
        _expectStalled();
    }

    function testSourceInvertedQuotesHalt() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        src.set(1000, 999);
        provider.setSource(address(src));
        _expectStalled();
    }

    function testSourceEoaHalts() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        provider.setSource(address(0xE0A)); // no code → empty returndata → fail closed
        _expectStalled();
    }

    function testSourceTwoWordQuoteHalts() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.TwoWordPair);
        provider.setSource(address(src));
        _expectStalled();
    }

    function testSourceReferenceBelowBidHalts() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.RefBelowBid);
        provider.setSource(address(src));
        _expectStalled();
    }

    function testSourceReferenceAboveAskHalts() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.RefAboveAsk);
        provider.setSource(address(src));
        _expectStalled();
    }

    // ── referencePrice ────────────────────────────────────────────────────

    /// @notice The reported reference is the anchor's own mid on the Q64 scale, independent of the band
    ///         edges, the knobs and the source.
    function testReferenceIsAnchorMid() public {
        uint64 mid = 185_000_000;
        oracle.setData(FEED_ID, mid, 2, 0, block.timestamp);

        (uint128 bid, uint128 ask, uint128 refPrice) = _read();

        assertEq(refPrice, uint128(Math.mulDiv(mid, Q64, 1e8)), "reference = anchor mid in Q64");
        assertLe(bid, refPrice, "bid <= reference");
        assertLe(refPrice, ask, "reference <= ask");
    }

    /// @notice The fee base cannot be moved by a source. The case under test is a source that keeps
    ///         the ask honest and collapses the bid towards zero. The quote widens (that is the documented, one-directional clamp), but the
    ///         reference the consumer charges its fee against does not budge, so the wide quote costs
    ///         the widener its own execution price instead of paying it a fee.
    function testReferenceUnmovedByCollapsedSourceBid() public {
        uint64 mid = 185_000_000;
        oracle.setData(FEED_ID, mid, 2, 0, block.timestamp);
        (, uint128 refAsk) = _refBand(mid, 2, FLOOR);

        (,, uint128 refBefore) = _read();

        src.set(1, refAsk); // bid ~0, ask honest — geometric mid would collapse with the bid
        provider.setSource(address(src));
        (uint128 bid, uint128 ask, uint128 refAfter) = _read();

        assertEq(bid, 1, "collapsed source bid passes through (clamp is one-directional)");
        assertEq(ask, refAsk, "ask unchanged");
        assertEq(refAfter, refBefore, "reference unchanged by the source");
        assertGt(refAfter, uint128(Math.sqrt(uint256(bid) * uint256(ask))), "and far above the geometric mid");
    }

    /// @notice A source may report its own fair value; it is validated in band and then discarded.
    function testSourceReportedReferenceIsIgnored() public {
        uint64 mid = 185_000_000;
        oracle.setData(FEED_ID, mid, 2, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(mid, 2, FLOOR);

        src.setWithReference(refBid - 1000, refAsk + 1000, refBid - 999); // in its own band, far off-centre
        provider.setSource(address(src));

        (,, uint128 refPrice) = _read();
        assertEq(refPrice, uint128(Math.mulDiv(mid, Q64, 1e8)), "still the anchor mid");
    }

    /// @notice Neither shaping knob moves the reference: the customizable variant may widen or tighten
    ///         its quote through confidence and marginStep, and the reference stays the anchor mid.
    function testReferenceUnmovedByKnobs() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        uint64 mid = 185_000_000;
        oracle.setData(FEED_ID, mid, 2, 0, block.timestamp);

        _inSwapPP = address(p);
        (,, uint128 refDefault) = p.getQuote();

        p.setConfidenceParam(500_000);
        _inSwapPP = address(p);
        (uint128 bid, uint128 ask, uint128 refWide) = p.getQuote();

        assertEq(refWide, refDefault, "confidence does not move the reference");
        assertEq(refWide, uint128(Math.mulDiv(mid, Q64, 1e8)), "reference = anchor mid");
        assertLe(bid, refWide);
        assertLe(refWide, ask);
    }

    /// @notice The invariant the consumer enforces, over the full parameter surface: oracle mid and
    ///         spread, the minMargin floor, and a source quoting anywhere at all.
    function testFuzzReferenceWithinQuote(uint64 mid, uint16 spread, uint128 srcBid, uint128 srcAsk) public {
        mid = uint64(bound(mid, 1, 1e18));
        spread = uint16(bound(spread, 0, U_MAX));
        oracle.setData(FEED_ID, mid, spread, 0, block.timestamp);

        (uint128 bid, uint128 ask, uint128 refPrice) = _read();
        assertLe(bid, refPrice, "reference-mode: bid <= reference");
        assertLe(refPrice, ask, "reference-mode: reference <= ask");

        // An ask of exactly uint128.max IS the halt sentinel, so stay one below it.
        srcBid = uint128(bound(srcBid, 1, type(uint128).max - 2));
        srcAsk = uint128(bound(srcAsk, uint256(srcBid) + 1, type(uint128).max - 1));
        src.set(srcBid, srcAsk);
        provider.setSource(address(src));

        (uint128 sBid, uint128 sAsk, uint128 sRef) = _read();
        assertEq(sRef, refPrice, "source mode reports the same anchor-derived reference");
        assertLe(sBid, sRef, "source-mode: bid <= reference");
        assertLe(sRef, sAsk, "source-mode: reference <= ask");
    }

    function testSourceFailureRecoversAfterSwapToZero() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.Revert);
        provider.setSource(address(src));
        _expectStalled();

        // instant swap back to reference mode — no timelock
        provider.setSource(address(0));
        (uint128 bid, uint128 ask,) = _read();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    // ── Attributed-path gating (real OracleBase) ──────────────────────────

    function testRevertsInvalidInSwapWrongProvider() public {
        _inSwapPP = address(0xBEEF); // pool declares a different provider than the caller
        oracle.setData(FEED_ID, 100_000_000, 2, 0, block.timestamp);
        vm.expectRevert(IOffchainOracle.InvalidInSwap.selector);
        provider.getQuote();
    }

    function testRevertsUnregisteredPool() public {
        MockPool pool2 = new MockPool(address(provider)); // a pool, but never registered for the feed
        oracle.setData(FEED_ID, 100_000_000, 2, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.NotRegistered.selector, FEED_ID, address(pool2)));
        pool2.getQuote();
    }

    // ── Variant flag / knob defaults ──────────────────────────────────────

    function testImmutableVariantFlagAndZeroKnobs() public view {
        assertFalse(provider.MUTABLE_PARAMS());
        assertEq(provider.confidenceParam(), 0);
        assertEq(provider.lastConfidenceUpdate(), 0);
    }

    function testMutableVariantConstructorDefaults() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        assertTrue(p.MUTABLE_PARAMS());
        assertEq(p.confidenceParam(), 0);
        assertEq(p.lastConfidenceUpdate(), 0);
    }

    // ── Setter mode-gating ────────────────────────────────────────────────

    function testSettersRevertOnImmutableProvider() public {
        // caller IS the factory — the gate hit is the variant flag
        vm.expectRevert(AnchoredPriceProvider.ImmutableProvider.selector);
        provider.setConfidenceParam(1);
    }

    function testSettersRevertForNonFactoryOnBothVariants() public {
        AnchoredPriceProvider mutableP = _deployMutableProvider();
        address stranger = address(0xDEAD);

        // OnlyFactory fires before the variant gate — strangers learn nothing about the flag
        vm.startPrank(stranger);
        vm.expectRevert(AnchoredPriceProvider.OnlyFactory.selector);
        provider.setConfidenceParam(1);
        vm.expectRevert(AnchoredPriceProvider.OnlyFactory.selector);
        mutableP.setConfidenceParam(1);
        vm.stopPrank();
    }

    // ── Mutable setters: happy path, bounds, cooldown, events ─────────────

    function testSetConfidenceParamUpdatesAndEmits() public {
        AnchoredPriceProvider p = _deployMutableProvider();

        vm.expectEmit(true, false, false, true, address(p));
        emit AnchoredPriceProvider.ConfidenceParamSet(123_456);
        p.setConfidenceParam(123_456);

        assertEq(p.confidenceParam(), 123_456);
        assertEq(p.lastConfidenceUpdate(), block.timestamp);
    }

    function testSetConfidenceParamCooldown() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        p.setConfidenceParam(1); // first set allowed immediately (lastConfidenceUpdate == 0)

        vm.expectRevert(AnchoredPriceProvider.CooldownNotElapsed.selector);
        p.setConfidenceParam(2);

        vm.warp(block.timestamp + p.CONFIDENCE_COOLDOWN());
        p.setConfidenceParam(2);
        assertEq(p.confidenceParam(), 2);
    }

    function testSetConfidenceParamOutOfBoundsReverts() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        uint256 tooBig = p.CONFIDENCE_MAX() + 1;
        vm.expectRevert(AnchoredPriceProvider.ConfidenceParamOutOfBounds.selector);
        p.setConfidenceParam(tooBig);
    }

    // ── Parity: mutable with default knobs ≡ immutable ────────────────────

    function testMutableDefaultsMatchImmutableBitForBit() public {
        AnchoredPriceProvider p = _deployMutableProvider();

        uint64[2] memory mids = [uint64(100_000_000), uint64(185_000_000)]; // 1.0 (exact Q64) and 1.85
        uint16[3] memory us = [uint16(0), uint16(2), U_MAX];

        for (uint256 i; i < mids.length; ++i) {
            for (uint256 j; j < us.length; ++j) {
                oracle.setData(FEED_ID, mids[i], us[j], 0, block.timestamp);

                (uint128 bid0, uint128 ask0,) = _read();
                _inSwapPP = address(p);
                (uint128 bid1, uint128 ask1,) = p.getQuote();

                assertEq(bid1, bid0, "bid parity");
                assertEq(ask1, ask0, "ask parity");
            }
        }
    }

    // ── Shaping + clamp (mutable, reference mode) ─────────────────────────

    /// @dev At 1× confidence the shaped quote cannot escape the band: its delta is mid·u while the band
    ///      half-width is u + FLOOR, so a confidence-only quote at this setting is clipped to the band
    ///      edges. Higher multipliers can widen past the band; see the CONFIDENCE_MAX case below.
    /// @dev A sub-1× confidence (< 10_000) tightens the shaped quote inside the band; the clamp then
    ///      floors it to the band edges — a confidence-narrowed quote is never tighter than the band.
    function testConfidenceBelowBandClippedToBandEdges() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        p.setConfidenceParam(100); // 0.01× — shaped delta far tighter than the band

        oracle.setData(FEED_ID, 150_000_000, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(150_000_000, 10, FLOOR);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask,) = p.getQuote();
        assertEq(bid, refBid, "clipped to band bid");
        assertEq(ask, refAsk, "clipped to band ask");
    }

    /// @dev At CONFIDENCE_MAX (100×) the confidence-shaped quote widens the oracle spread beyond the
    ///      reference band, so the clamp keeps the (wider) shaped quote — the band is a floor, not a cap.
    function testConfidenceMaxWidensBeyondBand() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        p.setConfidenceParam(p.CONFIDENCE_MAX()); // 100× — widens well past the band

        oracle.setData(FEED_ID, 150_000_000, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(150_000_000, 10, FLOOR);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask,) = p.getQuote();
        assertLt(bid, refBid, "confidence widens bid below the band floor");
        assertGt(ask, refAsk, "confidence widens ask above the band floor");
    }

    // ── marginStep (immutable, construction-time bias) ────────────────────

    function testConstructorMarginStepOutOfBoundsReverts() public {
        vm.expectRevert(AnchoredPriceProvider.MarginStepOutOfBounds.selector);
        new AnchoredPriceProvider(
            anchorFactory,
            address(oracle),
            FEED_ID,
            bytes32(0),
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            true,
            int256(BPS_BASE_U),
            BASE_TOKEN,
            QUOTE_TOKEN,
            _initFor(MAX_REF_STALENESS)
        );
        vm.expectRevert(AnchoredPriceProvider.MarginStepOutOfBounds.selector);
        new AnchoredPriceProvider(
            anchorFactory,
            address(oracle),
            FEED_ID,
            bytes32(0),
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            true,
            -int256(BPS_BASE_U),
            BASE_TOKEN,
            QUOTE_TOKEN,
            _initFor(MAX_REF_STALENESS)
        );
    }

    /// @dev A marginStep wider than the band half-width escapes the band: the clamp keeps any edge wider
    ///      than the band, whether a marginStep or a high confidence multiplier made it so.
    function testMarginStepWidensCustomizableQuoteBeyondBand() public {
        int256 ms = int256(BPS_BASE_U / 10); // 10% — far exceeds the u + FLOOR band half-width
        AnchoredPriceProvider p = new AnchoredPriceProvider(
            anchorFactory,
            address(oracle),
            FEED_ID,
            bytes32(0),
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            true,
            ms,
            BASE_TOKEN,
            QUOTE_TOKEN,
            _initFor(MAX_REF_STALENESS)
        );
        // confidenceParam stays 0, so marginStep alone shapes the quote.
        uint64 mid = 150_000_000;
        oracle.setData(FEED_ID, mid, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(mid, 10, FLOOR);

        // Shaped edges = mid · (BPS_BASE_U ∓ marginStep), the same _bandEdge math the contract uses.
        uint256 expBid = Math.mulDiv(mid, Q64 * (BPS_BASE_U - uint256(ms)), STEP_DENOM, Math.Rounding.Floor);
        uint256 expAsk = Math.mulDiv(mid, Q64 * (BPS_BASE_U + uint256(ms)), STEP_DENOM, Math.Rounding.Ceil);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask,) = p.getQuote();

        assertEq(bid, uint128(expBid), "bid = marginStep-shaped edge");
        assertEq(ask, uint128(expAsk), "ask = marginStep-shaped edge");
        assertLt(bid, refBid, "marginStep widened bid below the band");
        assertGt(ask, refAsk, "marginStep widened ask above the band");
    }

    /// @dev The immutable variant quotes the band directly (never calls _shapedQuote), so marginStep
    ///      is inert there even when set to an extreme value.
    function testMarginStepInertInImmutableVariant() public {
        AnchoredPriceProvider p = new AnchoredPriceProvider(
            anchorFactory,
            address(oracle),
            FEED_ID,
            bytes32(0),
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            false,
            int256(BPS_BASE_U / 10),
            BASE_TOKEN,
            QUOTE_TOKEN,
            _initFor(MAX_REF_STALENESS)
        );
        uint64 mid = 150_000_000;
        oracle.setData(FEED_ID, mid, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(mid, 10, FLOOR);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask,) = p.getQuote();
        assertEq(bid, refBid, "immutable variant ignores marginStep (band bid)");
        assertEq(ask, refAsk, "immutable variant ignores marginStep (band ask)");
    }

    /// @dev A NEGATIVE marginStep tightens (and at this magnitude inverts) the pre-clamp shaped quote;
    ///      the load-bearing band clamp must neutralize it back to the band edges. marginStep is not
    ///      envelope-bound, so this clamp is what keeps a negative marginStep from breaching the band.
    function testMarginStepNegativeIsClampedToBand() public {
        int256 ms = -int256(BPS_BASE_U / 5); // -20%: large enough to invert the pre-clamp quote
        AnchoredPriceProvider p = new AnchoredPriceProvider(
            anchorFactory,
            address(oracle),
            FEED_ID,
            bytes32(0),
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            true,
            ms,
            BASE_TOKEN,
            QUOTE_TOKEN,
            _initFor(MAX_REF_STALENESS)
        );
        uint64 mid = 150_000_000;
        oracle.setData(FEED_ID, mid, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(mid, 10, FLOOR);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask,) = p.getQuote();
        assertEq(bid, refBid, "negative marginStep clamped down to band bid");
        assertEq(ask, refAsk, "negative marginStep clamped up to band ask");
        assertLt(bid, ask, "clamp restores ordering despite an inverted pre-clamp quote");
    }

    /// @dev A POSITIVE marginStep smaller than the band half-width stays inside the band, so the shaped
    ///      quote is clipped to the band edges (the band edge is the most aggressive quote allowed).
    function testMarginStepPositiveSubBandClipsToEdge() public {
        int256 ms = int256(uint256(1e13)); // 0.1 bps marginStep, far below the u(10) + FLOOR band half-width
        AnchoredPriceProvider p = new AnchoredPriceProvider(
            anchorFactory,
            address(oracle),
            FEED_ID,
            bytes32(0),
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            true,
            ms,
            BASE_TOKEN,
            QUOTE_TOKEN,
            _initFor(MAX_REF_STALENESS)
        );
        uint64 mid = 150_000_000;
        oracle.setData(FEED_ID, mid, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(mid, 10, FLOOR);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask,) = p.getQuote();
        assertEq(bid, refBid, "sub-band marginStep clipped to band bid");
        assertEq(ask, refAsk, "sub-band marginStep clipped to band ask");
    }

    /// @dev Realistic production config: nonzero confidence AND nonzero marginStep composed in
    ///      _shapedQuote. With a band-escaping marginStep the composed quote is kept; assert it against
    ///      independently recomputed math and that it is never tighter than the band.
    function testMarginStepComposedWithConfidence() public {
        int256 ms = int256(BPS_BASE_U / 10); // 10% — escapes the band so the composed quote survives the clamp
        AnchoredPriceProvider p = new AnchoredPriceProvider(
            anchorFactory,
            address(oracle),
            FEED_ID,
            bytes32(0),
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            true,
            ms,
            BASE_TOKEN,
            QUOTE_TOKEN,
            _initFor(MAX_REF_STALENESS)
        );
        uint256 conf = p.CONFIDENCE_MAX();
        p.setConfidenceParam(conf);

        uint64 mid = 150_000_000;
        uint16 u = 10;
        oracle.setData(FEED_ID, mid, u, 0, block.timestamp);

        // Mirror _shapedQuote: delta = mid·(spreadBps·conf)/CONFIDENCE_BASE, then the marginStep factors.
        uint256 cbase = 1e10; // CONFIDENCE_BASE
        uint256 delta = uint256(mid) * (uint256(u) * conf) / cbase;
        uint256 bid8 = delta >= mid ? 0 : mid - delta;
        uint256 ask8 = mid + delta;
        uint256 expBid = Math.mulDiv(bid8, Q64 * (BPS_BASE_U - uint256(ms)), STEP_DENOM, Math.Rounding.Floor);
        uint256 expAsk = Math.mulDiv(ask8, Q64 * (BPS_BASE_U + uint256(ms)), STEP_DENOM, Math.Rounding.Ceil);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask,) = p.getQuote();
        assertEq(bid, uint128(expBid), "composed bid = confidence-narrowed mid * (1 - marginStep)");
        assertEq(ask, uint128(expAsk), "composed ask = confidence-widened mid * (1 + marginStep)");

        (uint128 refBid, uint128 refAsk) = _refBand(mid, u, FLOOR);
        assertLe(bid, refBid, "composed bid no tighter than band");
        assertGe(ask, refAsk, "composed ask no tighter than band");
    }

    /// @notice The confidence delta must be folded into the single band-edge division, NOT computed as
    ///         a floored 8-decimal integer first. On a low-priced feed
    ///         `mid · spreadBps · confidence / CONFIDENCE_BASE` truncates to ZERO, so a floored delta
    ///         would drop the whole configured confidence spread — and because a positive marginStep
    ///         carries the quote past the band, the clamp would not restore it. The pool's base fee is
    ///         derived from this spread, so the shortfall would be a straight under-collection.
    ///
    ///         Asserted as a strict inequality against the floored (integer-delta) formula, not as an
    ///         equality, so the test fails whenever the quote matches the floored form. The sibling
    ///         test above (testMarginStepComposedWithConfidence) does not tell the two apart, because
    ///         its inputs divide exactly and the two formulas agree there.
    function testConfidenceSurvivesSubQuantumOnLowPricedFeed() public {
        int256 ms = int256(BPS_BASE_U / 10); // +10% — escapes the band, so the shaped quote survives the clamp
        AnchoredPriceProvider p = new AnchoredPriceProvider(
            anchorFactory,
            address(oracle),
            FEED_ID,
            bytes32(0),
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            true,
            ms,
            BASE_TOKEN,
            QUOTE_TOKEN,
            _initFor(MAX_REF_STALENESS)
        );
        uint256 conf = 10_000; // 1x
        p.setConfidenceParam(conf);

        // mid = 299 (2.99e-6 at 8 decimals) — a realistic sub-cent token. spreadBps = 150 (1.5 bps).
        uint64 mid = 299;
        uint16 u = 150;
        oracle.setData(FEED_ID, mid, u, 0, block.timestamp);

        // The floored path: delta = mid·(u·conf)/CONFIDENCE_BASE as an 8-dec integer.
        // 299 · 150 · 10_000 = 4.485e8 < 1e10, so it floors to 0 and the confidence term disappears.
        uint256 flooredDelta = uint256(mid) * (uint256(u) * conf) / 1e10;
        assertEq(flooredDelta, 0, "precondition: floored math loses the whole confidence delta here");
        uint256 flooredAsk =
            Math.mulDiv(uint256(mid) + flooredDelta, Q64 * (BPS_BASE_U + uint256(ms)), STEP_DENOM, Math.Rounding.Ceil);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask,) = p.getQuote();

        assertGt(ask, flooredAsk, "confidence must widen the ask beyond the floored-delta quote");
        assertLt(bid, uint128(flooredAsk), "sanity: bid below the compared ask");

        // And the configured 1.5 bps is actually present, not merely a rounding crumb: the shaped ask
        // must exceed the zero-confidence ask by ~u·conf/CONFIDENCE_BASE of the mid.
        assertGe(ask - flooredAsk, (flooredAsk * uint256(u) * conf) / 1e10 / 2, "confidence spread materially applied");

        (uint128 refBid, uint128 refAsk) = _refBand(mid, u, FLOOR);
        assertLe(bid, refBid, "still no tighter than the band");
        assertGe(ask, refAsk, "still no tighter than the band");
    }

    // ── Source-mode knob independence ─────────────────────────────────────

    function testKnobsDoNotPostProcessSourceQuotes() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        p.setConfidenceParam(p.CONFIDENCE_MAX()); // extreme knob — must not touch the source path

        oracle.setData(FEED_ID, 150_000_000, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(150_000_000, 10, FLOOR);
        src.set(refBid - 1000, refAsk + 1000); // slightly wider than band — passes the clamp

        p.setSource(address(src));
        provider.setSource(address(src)); // immutable twin with the same source

        _inSwapPP = address(p);
        (uint128 bid1, uint128 ask1,) = p.getQuote();
        (uint128 bid0, uint128 ask0,) = _read();

        assertEq(bid1, bid0, "source path ignores knobs (bid)");
        assertEq(ask1, ask0, "source path ignores knobs (ask)");
        assertEq(bid1, refBid - 1000);
        assertEq(ask1, refAsk + 1000);
    }
}

/// @notice End-to-end flow: MockPool (marks itself in-swap) → AnchoredPriceProvider →
///         OracleBase.price(feedId, pool), with a clamped custom source in the loop.
contract AnchoredPriceProviderFlowTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant BPS_BASE_U = 1e18;
    uint256 private constant STEP_DENOM = 1e8 * BPS_BASE_U;
    uint256 private constant ONE_SPREAD_UNIT_E18 = 1e12; // 0.01-bps unit in 1e18 scale

    bytes32 private constant FEED_ID = keccak256("anchored-flow-feed");
    uint256 private constant FLOOR = 5e13;
    uint256 private constant MAX_REF_STALENESS = 60;
    uint16 private constant U_MAX = 150;
    uint256 private constant T0 = 1_000_000;

    TestOracle private oracle;
    MockPoolFactory private poolFactory;
    AnchoredPriceProvider private provider;
    MockPool private poolContract;
    MockAnchorSource private src;

    function setUp() public {
        vm.deal(address(this), 1 ether);
        vm.warp(T0);

        oracle = new TestOracle(address(this), 60);

        poolFactory = new MockPoolFactory();
        oracle.addApprovedFactory(address(poolFactory));

        provider = new AnchoredPriceProvider(
            address(this),
            address(oracle),
            FEED_ID,
            bytes32(0),
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            false,
            int256(0),
            address(0xBEEF),
            address(0xCAFE),
            _initFor(MAX_REF_STALENESS)
        );
        src = new MockAnchorSource();

        poolContract = new MockPool(address(provider));
        poolFactory.setPool(address(poolContract), true);
        oracle.register{value: 1}(FEED_ID, address(poolContract), address(poolFactory));
    }

    function test_flow_referenceModeEmitsPriceRead() public {
        oracle.setData(FEED_ID, 150_000_000, 3, 0, block.timestamp);

        vm.expectEmit(true, true, false, true, address(oracle));
        emit IOffchainOracle.PriceRead(address(poolContract), FEED_ID);

        (uint128 bid, uint128 ask,) = poolContract.getQuote();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    function test_flow_sourceModeClampedThroughPool() public {
        uint64 mid = 150_000_000;
        uint16 u = 3;
        oracle.setData(FEED_ID, mid, u, 0, block.timestamp);

        uint256 half = uint256(u) * ONE_SPREAD_UNIT_E18 + FLOOR;
        uint128 refBid = uint128(Math.mulDiv(mid, Q64 * (BPS_BASE_U - half), STEP_DENOM));
        // Ask edge on the honest upper bound mid + 1 (single-feed E8 quantum cover).
        uint128 refAsk =
            uint128(Math.mulDiv(uint256(mid) + 1, Q64 * (BPS_BASE_U + half), STEP_DENOM, Math.Rounding.Ceil));

        src.set(refBid + 7, refAsk - 7); // tighter than band
        provider.setSource(address(src));

        (uint128 bid, uint128 ask,) = poolContract.getQuote();
        assertEq(bid, refBid, "pool sees band-clipped bid");
        assertEq(ask, refAsk, "pool sees band-clipped ask");
    }

    function test_flow_staleHaltsThroughPool() public {
        oracle.setData(FEED_ID, 150_000_000, 3, 0, block.timestamp - MAX_REF_STALENESS - 1);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        poolContract.getQuote();
    }
}

/// @notice Synthetic ratio mode: feed1 (BTC/USD) ÷ refFeed (ETH/USD) → BTC/ETH. The test contract
///         acts as the pool (implements inSwap) and is registered for BOTH feeds.
contract AnchoredPriceProviderSyntheticTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant BPS_BASE_U = 1e18;
    uint256 private constant ONE_SPREAD_UNIT_E18 = 1e12; // 0.01-bps unit in 1e18 scale
    uint16 private constant ORACLE_BPS = 10_000;

    bytes32 private constant FEED1 = keccak256("BTC-USD"); // base leg
    bytes32 private constant FEED2 = keccak256("ETH-USD"); // ref leg (denominator)
    address private constant BTC = address(0xB7C);
    address private constant ETH = address(0xE74);
    address private constant USD = address(0x05D);

    uint256 private constant FLOOR = 5e13; // 0.5 bps
    uint256 private constant MAX_REF_STALENESS = 60;
    uint16 private constant U_MAX = 300;
    uint256 private constant T0 = 1_000_000;

    TestOracle private oracle;
    MockPoolFactory private poolFactory;
    AnchoredPriceProvider private provider;
    address private _inSwapPP;

    function inSwap() external view returns (address) {
        return _inSwapPP;
    }

    function setUp() public {
        vm.deal(address(this), 1 ether);
        vm.warp(T0);

        oracle = new TestOracle(address(this), 60);

        poolFactory = new MockPoolFactory();
        oracle.addApprovedFactory(address(poolFactory));

        // Synthetic pair tokens are explicit (the oracles are token-free): BTC/ETH.
        provider = new AnchoredPriceProvider(
            address(this),
            address(oracle),
            FEED1,
            FEED2,
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            false,
            int256(0),
            BTC,
            ETH,
            _initFor(MAX_REF_STALENESS)
        );

        // This contract is the pool; register it for BOTH legs.
        poolFactory.setPool(address(this), true);
        oracle.register{value: 1}(FEED1, address(this), address(poolFactory));
        oracle.register{value: 1}(FEED2, address(this), address(poolFactory));
    }

    function _read() internal returns (uint128 bid, uint128 ask, uint128 refPrice) {
        _inSwapPP = address(provider);
        return provider.getQuote();
    }

    function _expectStalled() internal {
        _inSwapPP = address(provider);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        provider.getQuote();
    }

    /// @dev Opposing leg interval bounds, including quantization and the additive margin.
    function _refBand(uint256 mid1, uint256 mid2, uint256 u1, uint256 u2, uint256 floor_)
        internal
        pure
        returns (uint128 refBid, uint128 refAsk)
    {
        return _expectedSyntheticBand(mid1, mid2, u1 * ONE_SPREAD_UNIT_E18, u2 * ONE_SPREAD_UNIT_E18, floor_);
    }

    /// @notice The synthetic cross reports the exact ratio mid1/mid2 as its reference — never floored
    ///         to an 8-decimal integer first — and it stays inside the covered band on both sides
    ///         (the bid cover divides by mid2 + 1, which can only sit below the reference).
    function testSyntheticReferenceIsExactCrossMid() public {
        uint256 mid1 = uint256(65_000) * 1e8;
        uint256 mid2 = uint256(3_000) * 1e8;
        oracle.setData(FEED1, uint64(mid1), 3, 0, block.timestamp);
        oracle.setData(FEED2, uint64(mid2), 5, 0, block.timestamp);

        (uint128 bid, uint128 ask, uint128 refPrice) = _read();

        assertEq(refPrice, uint128(Math.mulDiv(mid1, Q64, mid2)), "reference = exact cross mid, floored once");
        assertLe(bid, refPrice, "bid <= reference");
        assertLe(refPrice, ask, "reference <= ask");
    }

    /// @notice The same on a cross ratio far below 1, where the sub-quantum cover is load-bearing.
    function testSyntheticReferenceLowRatioWithinQuote() public {
        oracle.setData(FEED1, uint64(120), 0, 0, block.timestamp); // cheap base
        oracle.setData(FEED2, uint64(9_000 * 1e8), 0, 0, block.timestamp); // expensive quote

        (uint128 bid, uint128 ask, uint128 refPrice) = _read();

        assertEq(refPrice, uint128(Math.mulDiv(uint256(120), Q64, uint256(9_000) * 1e8)));
        assertLe(bid, refPrice, "bid <= reference");
        assertLe(refPrice, ask, "reference <= ask");
    }

    function testTokensAreFeed1BaseAndRefBase() public view {
        assertEq(provider.token0(), BTC, "token0 = feed1 base (BTC)");
        assertEq(provider.token1(), ETH, "token1 = ref feed base (ETH)");
        assertEq(provider.quoteFeedId(), FEED2);
    }

    function testSyntheticRatioMidAndBand() public {
        oracle.setData(FEED1, uint64(65_000 * 1e8), 3, 0, block.timestamp);
        oracle.setData(FEED2, uint64(3_000 * 1e8), 5, 0, block.timestamp);

        (uint128 refBid, uint128 refAsk) = _refBand(uint256(65_000) * 1e8, uint256(3_000) * 1e8, 3, 5, FLOOR);

        (uint128 bid, uint128 ask,) = _read();
        assertEq(bid, refBid, "synthetic bid divides base low by quote high");
        assertEq(ask, refAsk, "synthetic ask = band edge");
    }

    /// @dev A LOW cross ratio (cheap base priced in an expensive quote) must NOT be floored
    ///      to an 8-decimal integer. base $0.000059 (5_900 at 8-dec), quote $3000 → true cross ≈ 1.9667e-8.
    ///      A floored mid — `mulDiv(5_900, 1e8, 3_000e8) = 1` (floored from 1.9667) — would price the
    ///      whole band ~49% below fair value; an arbitrageur would sweep the base side for half price.
    ///      With the exact (num, den) band the quote sits at the true cross ± the tight band half-width.
    function testLowCrossRatioIsNotFloored() public {
        oracle.setData(FEED1, uint64(5_900), 3, 0, block.timestamp); // $0.000059
        oracle.setData(FEED2, uint64(3_000 * 1e8), 5, 0, block.timestamp); // $3000

        uint256 trueMidX64 = Math.mulDiv(uint256(5_900), Q64, uint256(3_000) * 1e8);

        (uint128 bid, uint128 ask,) = _read();

        // Exact match to the untruncated band edge (mirrors the contract math).
        (uint128 refBid, uint128 refAsk) = _refBand(uint256(5_900), uint256(3_000) * 1e8, 3, 5, FLOOR);
        assertEq(bid, refBid, "low-cross bid = exact band edge");
        assertEq(ask, refAsk, "low-cross ask = exact band edge");

        // The band hugs the true cross (half-width = 8·0.01bps + 0.5bps floor, well under 1%), so the
        // quote is NOT ~half of fair value. With a floored mid = 1 both bounds land ~49% low and fail.
        assertGe(uint256(ask), trueMidX64 * 99 / 100, "ask must reach the true cross, not ~half of it");
        assertLe(uint256(bid), trueMidX64, "bid at or below the true cross");
        assertGe(uint256(bid), trueMidX64 * 99 / 100, "bid within the tight band of the true cross");
    }

    /// @notice A cheap quote leg's E8 quantum and its uncertainty must BOTH widen the interval.
    function testBidCoversE8TruncationCheapQuoteCross() public {
        uint256 mid1 = uint256(3_000) * 1e8; // base $3000
        uint256 mid2 = 100; // quote $0.000001 (cheap → mid2 tiny, quantum ~1%)
        oracle.setData(FEED1, uint64(mid1), 3, 0, block.timestamp);
        oracle.setData(FEED2, uint64(mid2), 5, 0, block.timestamp);

        (uint128 bid, uint128 ask,) = _read();

        (uint128 refBid, uint128 refAsk) = _refBand(mid1, mid2, 3, 5, FLOOR);
        uint256 honestLower = Math.mulDiv(mid1, Q64, mid2 + 1); // mid1/(mid2+1), floor

        assertEq(bid, refBid);
        assertEq(ask, refAsk);
        assertLt(uint256(bid), honestLower, "uncertainty and margin widen beyond the quantum alone");
    }

    function testHaltsWhenRefFeedStale() public {
        oracle.setData(FEED1, uint64(65_000 * 1e8), 3, 0, block.timestamp);
        oracle.setData(FEED2, uint64(3_000 * 1e8), 5, 0, block.timestamp - MAX_REF_STALENESS - 1);
        _expectStalled();
    }

    function testHaltsWhenRefMidZero() public {
        oracle.setData(FEED1, uint64(65_000 * 1e8), 3, 0, block.timestamp);
        oracle.setData(FEED2, 0, 5, 0, block.timestamp);
        _expectStalled();
    }

    function testHaltsWhenRefOffHours() public {
        oracle.setData(FEED1, uint64(65_000 * 1e8), 3, 0, block.timestamp);
        // STALL sentinel, not ORACLE_BPS — see testRevertsOnOffHoursMarker.
        oracle.setData(FEED2, uint64(3_000 * 1e8), type(uint16).max, 0, block.timestamp);
        _expectStalled();
    }

    function testRefPriceGuardHalts() public {
        oracle.setData(FEED1, uint64(65_000 * 1e8), 3, 0, block.timestamp);
        oracle.setData(FEED2, uint64(3_000 * 1e8), 5, 0, block.timestamp);
        oracle.setPriceGuard(FEED2, uint128(1 * 1e8), uint128(100 * 1e8)); // 3000e8 above max → halt
        _expectStalled();
    }

    /// @dev Tokens are explicit and mandatory in the synthetic (ref-feed) configuration too: a zero
    ///      base token reverts at construction.
    function testConstructorZeroTokenReverts() public {
        vm.expectRevert();
        new AnchoredPriceProvider(
            address(this),
            address(oracle),
            FEED1,
            FEED2,
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            false,
            int256(0),
            address(0),
            ETH,
            _initFor(MAX_REF_STALENESS)
        );
    }

    function testConstructorEqualTokensReverts() public {
        vm.expectRevert();
        new AnchoredPriceProvider(
            address(this),
            address(oracle),
            FEED1,
            FEED2,
            FLOOR,
            MAX_REF_STALENESS,
            MULT,
            false,
            int256(0),
            BTC,
            BTC,
            _initFor(MAX_REF_STALENESS)
        );
    }
}

/// @notice Per-leg freshness bounds + per-leg spread multipliers (customizable variant). The test
///         contract is BOTH the factory (governs the knob setters) and the pool (implements inSwap),
///         registered for both legs of a synthetic BTC/ETH pair.
contract AnchoredPriceProviderKnobsTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant BPS_BASE_U = 1e18;
    uint256 private constant ONE_SPREAD_UNIT_E18 = 1e12; // 0.01-bps unit in 1e18 scale

    bytes32 private constant FEED1 = keccak256("BTC-USD"); // base leg
    bytes32 private constant FEED2 = keccak256("ETH-USD"); // quote leg (denominator)
    address private constant BTC = address(0xB7C);
    address private constant ETH = address(0xE74);

    uint256 private constant FLOOR = 5e13; // 0.5 bps
    uint256 private constant MAX_REF_STALENESS = 60;
    uint16 private constant U_MAX = 300;
    uint256 private constant COOLDOWN = 1 minutes;
    uint256 private constant T0 = 1_000_000;

    TestOracle private oracle;
    MockPoolFactory private poolFactory;
    AnchoredPriceProvider private provider; // mutable synthetic, source = 0
    address private _inSwapPP;

    function inSwap() external view returns (address) {
        return _inSwapPP;
    }

    function setUp() public {
        vm.deal(address(this), 1 ether);
        vm.warp(T0);
        oracle = new TestOracle(address(this), 60);
        poolFactory = new MockPoolFactory();
        oracle.addApprovedFactory(address(poolFactory));

        // Mutable variant (knobs active) with a 4× multiplier ceiling; confidence/marginStep 0 so
        // the shaped quote degenerates to the reference band — the output IS the (multiplied) band.
        provider = new AnchoredPriceProvider(
            address(this),
            address(oracle),
            FEED1,
            FEED2,
            FLOOR,
            MAX_REF_STALENESS,
            MULT_MAX,
            true,
            int256(0),
            BTC,
            ETH,
            _initFor(MAX_REF_STALENESS)
        );
        poolFactory.setPool(address(this), true);
        oracle.register{value: 1}(FEED1, address(this), address(poolFactory));
        oracle.register{value: 1}(FEED2, address(this), address(poolFactory));

        // Fresh, valid data on both legs (each 0.03 bps uncertainty: 3 spread units).
        oracle.setData(FEED1, uint64(65_000 * 1e8), 3, 0, block.timestamp);
        oracle.setData(FEED2, uint64(3_000 * 1e8), 3, 0, block.timestamp);
    }

    function _read() internal returns (uint128 bid, uint128 ask, uint128 refPrice) {
        _inSwapPP = address(provider);
        return provider.getQuote();
    }

    function _expectStalled() internal {
        _inSwapPP = address(provider);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        provider.getQuote();
    }

    /// @dev Apply each multiplier independently before dividing opposing interval edges.
    function _bandMul(uint256 mid1, uint256 mid2, uint256 u1, uint256 m1, uint256 u2, uint256 m2, uint256 floor_)
        internal
        pure
        returns (uint128 refBid, uint128 refAsk)
    {
        uint256 baseHalf = Math.mulDiv(u1 * ONE_SPREAD_UNIT_E18, m1, BPS_BASE_U, Math.Rounding.Ceil);
        uint256 quoteHalf = Math.mulDiv(u2 * ONE_SPREAD_UNIT_E18, m2, BPS_BASE_U, Math.Rounding.Ceil);
        return _expectedSyntheticBand(mid1, mid2, baseHalf, quoteHalf, floor_);
    }

    // ── Defaults: identical to the single-bound, 1.0× behavior ──────────
    function testDefaultsMatchUnmultipliedBand() public {
        assertEq(provider.baseMaxStaleness(), MAX_REF_STALENESS);
        assertEq(provider.quoteMaxStaleness(), MAX_REF_STALENESS);
        assertEq(provider.baseSpreadMult(), MULT);
        assertEq(provider.quoteSpreadMult(), MULT);

        (uint128 eBid, uint128 eAsk) = _bandMul(uint256(65_000) * 1e8, uint256(3_000) * 1e8, 3, MULT, 3, MULT, FLOOR);
        (uint128 bid, uint128 ask,) = _read();
        assertEq(bid, eBid);
        assertEq(ask, eAsk);
    }

    // ── Per-leg spread multipliers ──────────────────────────────────────
    function testBaseMultiplierWidensBand() public {
        provider.setSpreadMultipliers(2 * MULT, MULT); // base 2×, quote 1×
        (uint128 eBid, uint128 eAsk) =
            _bandMul(uint256(65_000) * 1e8, uint256(3_000) * 1e8, 3, 2 * MULT, 3, MULT, FLOOR);
        (uint128 bid, uint128 ask,) = _read();
        assertEq(bid, eBid, "base 2x widens the band");
        assertEq(ask, eAsk);
        // Strictly wider than the 1× default band.
        (uint128 dBid, uint128 dAsk) = _bandMul(uint256(65_000) * 1e8, uint256(3_000) * 1e8, 3, MULT, 3, MULT, FLOOR);
        assertLt(bid, dBid);
        assertGt(ask, dAsk);
    }

    function testSubUnitMultiplierTightensBand() public {
        provider.setSpreadMultipliers(MULT / 2, MULT / 2); // 0.5× both legs — allowed (<1×)
        (uint128 eBid, uint128 eAsk) =
            _bandMul(uint256(65_000) * 1e8, uint256(3_000) * 1e8, 3, MULT / 2, 3, MULT / 2, FLOOR);
        (uint128 bid, uint128 ask,) = _read();
        assertEq(bid, eBid, "0.5x tightens the band toward mid +/- floor");
        assertEq(ask, eAsk);
    }

    function testMultiplierAboveCeilingReverts() public {
        vm.expectRevert(AnchoredPriceProvider.SpreadMultOutOfBounds.selector);
        provider.setSpreadMultipliers(MULT_MAX + 1, MULT);
    }

    function testMultiplierOnlyFactory() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(AnchoredPriceProvider.OnlyFactory.selector);
        provider.setSpreadMultipliers(MULT, MULT);
    }

    function testMultiplierCooldown() public {
        provider.setSpreadMultipliers(2 * MULT, MULT);
        vm.expectRevert(AnchoredPriceProvider.CooldownNotElapsed.selector);
        provider.setSpreadMultipliers(MULT, MULT);
        vm.warp(block.timestamp + COOLDOWN);
        provider.setSpreadMultipliers(MULT, MULT); // now allowed
        assertEq(provider.baseSpreadMult(), MULT);
    }

    // ── Per-leg freshness ───────────────────────────────────────────────
    function testPerLegStalenessBaseAndQuoteIndependent() public {
        provider.setMaxStaleness(10, 50); // base tight (10s), quote loose (50s)

        // Quote 40s old: within the quote bound (50) but WAY past the base bound (10) — yet it's the
        // QUOTE leg, so it must NOT halt (proves the bounds are per-leg, not shared).
        oracle.setData(FEED1, uint64(65_000 * 1e8), 3, 0, block.timestamp);
        oracle.setData(FEED2, uint64(3_000 * 1e8), 3, 0, block.timestamp - 40);
        (uint128 bid,,) = _read();
        assertGt(bid, 0, "quote 40s old is fresh under the 50s quote bound");

        // Quote 55s old: past the 50s quote bound → halt.
        oracle.setData(FEED2, uint64(3_000 * 1e8), 3, 0, block.timestamp - 55);
        _expectStalled();
    }

    function testBaseStalenessBoundHalts() public {
        provider.setMaxStaleness(10, 50);
        // Base 20s old > 10s base bound → halt (quote fresh).
        oracle.setData(FEED1, uint64(65_000 * 1e8), 3, 0, block.timestamp - 20);
        oracle.setData(FEED2, uint64(3_000 * 1e8), 3, 0, block.timestamp);
        _expectStalled();
    }

    function testStalenessAboveHardCapReverts() public {
        vm.expectRevert(AnchoredPriceProvider.StalenessOutOfBounds.selector);
        provider.setMaxStaleness(MAX_REF_STALENESS + 1, 10);
    }

    function testStalenessOnlyFactory() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(AnchoredPriceProvider.OnlyFactory.selector);
        provider.setMaxStaleness(10, 10);
    }

    // ── Immutable variant rejects the knobs ─────────────────────────────
    function testImmutableVariantRejectsKnobs() public {
        AnchoredPriceProvider immut = new AnchoredPriceProvider(
            address(this),
            address(oracle),
            FEED1,
            FEED2,
            FLOOR,
            MAX_REF_STALENESS,
            MULT_MAX,
            false,
            int256(0),
            BTC,
            ETH,
            _initFor(MAX_REF_STALENESS)
        );
        vm.expectRevert(AnchoredPriceProvider.ImmutableProvider.selector);
        immut.setSpreadMultipliers(MULT, MULT);
        vm.expectRevert(AnchoredPriceProvider.ImmutableProvider.selector);
        immut.setMaxStaleness(10, 10);
    }

    // ── Constructor bounds ──────────────────────────────────────────────
    function testConstructorRejectsSubUnitCeiling() public {
        vm.expectRevert(AnchoredPriceProvider.MaxSpreadMultOutOfBounds.selector);
        new AnchoredPriceProvider(
            address(this),
            address(oracle),
            FEED1,
            FEED2,
            FLOOR,
            MAX_REF_STALENESS,
            MULT - 1,
            true,
            int256(0),
            BTC,
            ETH,
            _initFor(MAX_REF_STALENESS)
        );
    }

    // ── Initial config applied at construction (integrate-the-setters) ──
    function _deployWith(bool mutableParams, IAnchoredProviderFactory.InitialConfig memory init)
        internal
        returns (AnchoredPriceProvider p)
    {
        p = new AnchoredPriceProvider(
            address(this),
            address(oracle),
            FEED1,
            FEED2,
            FLOOR,
            MAX_REF_STALENESS,
            MULT_MAX,
            mutableParams,
            int256(0),
            BTC,
            ETH,
            init
        );
        poolFactory.setPool(address(this), true);
        oracle.register{value: 1}(FEED1, address(this), address(poolFactory));
        oracle.register{value: 1}(FEED2, address(this), address(poolFactory));
    }

    function testConstructorAppliesSourceAndKnobs() public {
        address curatedSource = address(0x50FACE);
        AnchoredPriceProvider p = _deployWith(
            true,
            IAnchoredProviderFactory.InitialConfig({
                source: curatedSource,
                baseMaxStaleness: 10,
                quoteMaxStaleness: 50,
                baseSpreadMult: 2 * MULT,
                quoteSpreadMult: MULT / 2
            })
        );
        assertEq(p.source(), curatedSource, "source set at construction");
        assertEq(p.baseMaxStaleness(), 10);
        assertEq(p.quoteMaxStaleness(), 50);
        assertEq(p.baseSpreadMult(), 2 * MULT);
        assertEq(p.quoteSpreadMult(), MULT / 2);
    }

    /// @dev The immutable variant, too, is born with its (permanent) custom knobs — and the read
    ///      path honours them (custom fixed knobs, not just the 1×/shared-staleness default).
    function testImmutableVariantHonoursConstructorKnobs() public {
        AnchoredPriceProvider p = _deployWith(
            false,
            IAnchoredProviderFactory.InitialConfig({
                source: address(0),
                baseMaxStaleness: MAX_REF_STALENESS,
                quoteMaxStaleness: MAX_REF_STALENESS,
                baseSpreadMult: 3 * MULT, // fixed 3× base multiplier, immutable
                quoteSpreadMult: MULT
            })
        );
        assertEq(p.baseSpreadMult(), 3 * MULT);
        oracle.setData(FEED1, uint64(65_000 * 1e8), 3, 0, block.timestamp);
        oracle.setData(FEED2, uint64(3_000 * 1e8), 3, 0, block.timestamp);
        (uint128 eBid, uint128 eAsk) =
            _bandMul(uint256(65_000) * 1e8, uint256(3_000) * 1e8, 3, 3 * MULT, 3, MULT, FLOOR);
        _inSwapPP = address(p);
        (uint128 bid, uint128 ask,) = p.getQuote();
        assertEq(bid, eBid, "immutable variant applies its fixed 3x base multiplier");
        assertEq(ask, eAsk);
        // …and it stays immutable: no setter can change it.
        vm.expectRevert(AnchoredPriceProvider.ImmutableProvider.selector);
        p.setSpreadMultipliers(MULT, MULT);
    }

    function testConstructorRejectsStalenessAboveCap() public {
        vm.expectRevert(AnchoredPriceProvider.StalenessOutOfBounds.selector);
        _deployWith(
            true,
            IAnchoredProviderFactory.InitialConfig({
                source: address(0),
                baseMaxStaleness: MAX_REF_STALENESS + 1, // > the immutable cap
                quoteMaxStaleness: MAX_REF_STALENESS,
                baseSpreadMult: MULT,
                quoteSpreadMult: MULT
            })
        );
    }

    function testConstructorRejectsMultiplierAboveCeiling() public {
        vm.expectRevert(AnchoredPriceProvider.SpreadMultOutOfBounds.selector);
        _deployWith(
            true,
            IAnchoredProviderFactory.InitialConfig({
                source: address(0),
                baseMaxStaleness: MAX_REF_STALENESS,
                quoteMaxStaleness: MAX_REF_STALENESS,
                baseSpreadMult: MULT_MAX + 1, // > the maxSpreadMult ceiling
                quoteSpreadMult: MULT
            })
        );
    }
}
