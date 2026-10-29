// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AnchoredPriceProvider} from "../contracts/AnchoredPriceProvider.sol";
import {IOffchainOracle} from "../contracts/interfaces/IOffchainOracle.sol";
import {OracleBase} from "../contracts/oracles/providers/OracleBase.sol";
import {toTimeMs} from "../contracts/oracles/utils/TimeMs.sol";

import {TestOracle} from "./ProtectedPriceProvider.t.sol";
import {MockPoolFactory} from "./mocks/MockPoolFactory.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockAnchorSource} from "./mocks/MockAnchorSource.sol";

contract AnchoredPriceProviderTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant BPS_BASE_U = 1e18;
    uint256 private constant STEP_DENOM = 1e8 * BPS_BASE_U;
    uint16  private constant ORACLE_BPS = 10_000;
    uint256 private constant ONE_BPS_E18 = 1e14;

    bytes32 private constant FEED_ID = keccak256("anchored-feed");
    address private constant BASE_TOKEN = address(0xBEEF);
    address private constant QUOTE_TOKEN = address(0xCAFE);

    // Majors-class parameters (floor 0.5 bps/side, uMax 150 bps).
    uint256 private constant FLOOR = 5e13;
    uint256 private constant MAX_REF_STALENESS = 60;
    uint16  private constant U_MAX = 150;
    uint256 private constant T0 = 1_000_000;

    TestOracle private oracle;
    MockPoolFactory private poolFactory;   // AMM pool factory (oracle-approved)
    AnchoredPriceProvider private provider;
    MockAnchorSource private src;

    address private anchorFactory;         // provider's immutable factory (governs setSource)
    address private pool;                  // == address(this): this contract acts as the pool
    address private _inSwapPP;             // IPool.inSwap() backing

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

        provider = _deployProvider(FLOOR, MAX_REF_STALENESS, U_MAX, BASE_TOKEN, QUOTE_TOKEN);
        src = new MockAnchorSource();

        // This test contract is the registered pool (it calls the provider directly).
        pool = address(this);
        poolFactory.setPool(pool, true);
        oracle.register{value: 1}(FEED_ID, pool, address(poolFactory));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _deployProvider(uint256 floor_, uint256 staleness, uint16 uMax, address base, address quote)
        internal
        returns (AnchoredPriceProvider)
    {
        return new AnchoredPriceProvider(
            anchorFactory, address(oracle), FEED_ID, bytes32(0), floor_, staleness, uMax, false, int256(0), base, quote
        );
    }

    function _deployMutableProvider() internal returns (AnchoredPriceProvider) {
        return new AnchoredPriceProvider(
            anchorFactory, address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, true, int256(0), BASE_TOKEN, QUOTE_TOKEN
        );
    }

    /// @dev Expected reference band, mirroring the contract math.
    function _refBand(uint64 mid, uint16 u, uint256 floor_) internal pure returns (uint128 refBid, uint128 refAsk) {
        uint256 half = uint256(u) * ONE_BPS_E18 + floor_;
        refBid = uint128(Math.mulDiv(mid, Q64 * (BPS_BASE_U - half), STEP_DENOM));
        refAsk = uint128(Math.mulDiv(mid, Q64 * (BPS_BASE_U + half), STEP_DENOM, Math.Rounding.Ceil));
    }

    function _read() internal returns (uint128 bid, uint128 ask) {
        _inSwapPP = address(provider); // mark this pool in-swap with the provider, then read (no args)
        return provider.getBidAndAskPrice();
    }

    function _expectStalled() internal {
        _inSwapPP = address(provider);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        provider.getBidAndAskPrice();
    }

    // ── Construction / tokens ─────────────────────────────────────────────

    function testGetTokensReturnsConfiguredPair() public view {
        address base = provider.token0();
        address quote = provider.token1();
        assertEq(base, BASE_TOKEN);
        assertEq(quote, QUOTE_TOKEN);
    }

    function testConstructorSetsExplicitTokens() public {
        AnchoredPriceProvider p = _deployProvider(FLOOR, MAX_REF_STALENESS, U_MAX, address(0xA11CE), address(0xB0B));
        address base = p.token0();
        address quote = p.token1();
        assertEq(base, address(0xA11CE));
        assertEq(quote, address(0xB0B));
    }

    function testConstructorZeroBaseTokenReverts() public {
        vm.expectRevert();
        _deployProvider(FLOOR, MAX_REF_STALENESS, U_MAX, address(0), QUOTE_TOKEN);
    }

    function testConstructorZeroQuoteTokenReverts() public {
        vm.expectRevert();
        _deployProvider(FLOOR, MAX_REF_STALENESS, U_MAX, BASE_TOKEN, address(0));
    }

    function testConstructorEqualTokensReverts() public {
        vm.expectRevert();
        _deployProvider(FLOOR, MAX_REF_STALENESS, U_MAX, BASE_TOKEN, BASE_TOKEN);
    }

    function testConstructorStoresClampParams() public view {
        assertEq(provider.minMargin(), FLOOR);
        assertEq(provider.MAX_REF_STALENESS(), MAX_REF_STALENESS);
        assertEq(provider.MAX_SPREAD_BPS(), U_MAX);
        assertEq(provider.factory(), anchorFactory);
        assertEq(address(provider.offchainOracle()), address(oracle));
        assertEq(provider.baseFeedId(), FEED_ID);
        assertEq(provider.source(), address(0));
    }

    function testConstructorStoresMarginStep() public {
        AnchoredPriceProvider pPos = new AnchoredPriceProvider(
            anchorFactory, address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, true, int256(5e16), BASE_TOKEN, QUOTE_TOKEN
        );
        assertEq(pPos.marginStep(), int256(5e16), "positive marginStep stored");
        AnchoredPriceProvider pNeg = new AnchoredPriceProvider(
            anchorFactory, address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, true, -int256(5e16), BASE_TOKEN, QUOTE_TOKEN
        );
        assertEq(pNeg.marginStep(), -int256(5e16), "negative marginStep stored");
    }

    function testConstructorZeroFactoryReverts() public {
        vm.expectRevert();
        new AnchoredPriceProvider(
            address(0), address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN
        );
    }

    function testConstructorStalenessZeroAllowed() public {
        AnchoredPriceProvider p = _deployProvider(FLOOR, 0, U_MAX, BASE_TOKEN, QUOTE_TOKEN);
        assertEq(p.MAX_REF_STALENESS(), 0, "staleness 0 allowed = reference must be in the current block");
    }

    function testConstructorStalenessTooLargeReverts() public {
        vm.expectRevert(AnchoredPriceProvider.MaxRefStalenessOutOfBounds.selector);
        _deployProvider(FLOOR, 7 days + 1, U_MAX, BASE_TOKEN, QUOTE_TOKEN);
    }

    function testConstructorUMaxZeroReverts() public {
        vm.expectRevert(AnchoredPriceProvider.MaxSpreadOutOfBounds.selector);
        _deployProvider(FLOOR, MAX_REF_STALENESS, 0, BASE_TOKEN, QUOTE_TOKEN);
    }

    function testConstructorUMaxAtBpsBaseReverts() public {
        vm.expectRevert(AnchoredPriceProvider.MaxSpreadOutOfBounds.selector);
        _deployProvider(FLOOR, MAX_REF_STALENESS, ORACLE_BPS, BASE_TOKEN, QUOTE_TOKEN);
    }

    function testConstructorBandTooWideReverts() public {
        // uMax 9_999 bps + floor 1e14 → worst-case half-width = 1e18 (100%) → bid could hit zero
        vm.expectRevert(AnchoredPriceProvider.BandTooWide.selector);
        _deployProvider(1e14, MAX_REF_STALENESS, 9_999, BASE_TOKEN, QUOTE_TOKEN);
    }

    function testConstructorMinMarginZeroAllowed() public {
        AnchoredPriceProvider p = _deployProvider(0, MAX_REF_STALENESS, U_MAX, BASE_TOKEN, QUOTE_TOKEN);
        assertEq(p.minMargin(), 0, "minMargin 0 allowed (band relies on the oracle spread)");
    }

    function testMinMarginZeroWithZeroSpreadHalts() public {
        // minMargin 0 AND spreadBps 0 -> band collapses on a round mid -> read halts (no tighter quote).
        AnchoredPriceProvider p = _deployProvider(0, MAX_REF_STALENESS, U_MAX, BASE_TOKEN, QUOTE_TOKEN);
        oracle.setData(FEED_ID, 100_000_000, 0, 0, block.timestamp); // mid = 1.0 (round), u = 0
        _inSwapPP = address(p);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        p.getBidAndAskPrice();
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
        src.set(1, 2); // degenerate source: would halt if consulted... (1 < 2, in Q64 ≈ 0) — clamps wide
        provider.setSource(address(src));

        provider.setSource(address(0));
        (uint128 bid, uint128 ask) = _read();
        (uint128 refBid, uint128 refAsk) = _refBand(185_000_000, 2, FLOOR);
        assertEq(bid, refBid);
        assertEq(ask, refAsk);
    }

    // ── Reference mode math ───────────────────────────────────────────────

    function testReferenceModeQuotesBand() public {
        uint64 mid = 185_000_000; // 1.85, 8-dec
        uint16 u = 2;             // 2 bps reference uncertainty
        oracle.setData(FEED_ID, mid, u, 0, block.timestamp);

        (uint128 bid, uint128 ask) = _read();
        (uint128 refBid, uint128 refAsk) = _refBand(mid, u, FLOOR);

        assertEq(bid, refBid, "bid = mid - (u + floor)");
        assertEq(ask, refAsk, "ask = mid + (u + floor)");
        assertLt(bid, ask);
    }

    function testReferenceModeFloorOnlyWhenUZero() public {
        uint64 mid = 100_000_000;
        oracle.setData(FEED_ID, mid, 0, 0, block.timestamp);

        (uint128 bid, uint128 ask) = _read();
        (uint128 refBid, uint128 refAsk) = _refBand(mid, 0, FLOOR);

        assertEq(bid, refBid);
        assertEq(ask, refAsk);
        // floor alone separates the quotes
        assertLt(bid, ask);
    }

    function testReferenceModeWideningUWidensBand() public {
        uint64 mid = 100_000_000;

        oracle.setData(FEED_ID, mid, 1, 0, block.timestamp);
        (uint128 bidNarrow, uint128 askNarrow) = _read();

        oracle.setData(FEED_ID, mid, 100, 0, block.timestamp);
        (uint128 bidWide, uint128 askWide) = _read();

        assertLt(bidWide, bidNarrow, "wider u lowers bid");
        assertGt(askWide, askNarrow, "wider u raises ask");
    }

    function testReferenceModeUAtUMaxStillQuotes() public {
        oracle.setData(FEED_ID, 100_000_000, U_MAX, 0, block.timestamp);
        (uint128 bid, uint128 ask) = _read();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    // ── Guards → FeedStalled ──────────────────────────────────────────────

    function testRevertsWhenStale() public {
        oracle.setData(FEED_ID, 100_000_000, 2, 0, block.timestamp - MAX_REF_STALENESS - 1);
        _expectStalled();
    }

    /// @dev Boundary: refTime exactly MAX_REF_STALENESS old is NOT stale (spec: halt when
    ///      timestamp > maxRefStaleness), so the pool still quotes.
    function testQuotesAtExactStalenessBoundary() public {
        oracle.setData(FEED_ID, 100_000_000, 2, 0, block.timestamp - MAX_REF_STALENESS);
        (uint128 bid, uint128 ask) = _read();
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

    function testRevertsOnOffHoursMarker() public {
        // ChainlinkOracle writes u = ORACLE_BPS when an RWA market is closed
        oracle.setData(FEED_ID, 100_000_000, ORACLE_BPS, 0, block.timestamp);
        _expectStalled();
    }

    function testRevertsWhenUAboveUMax() public {
        oracle.setData(FEED_ID, 100_000_000, U_MAX + 1, 0, block.timestamp);
        _expectStalled();
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
        (uint128 bid, uint128 ask) = _read();
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

        (uint128 bid, uint128 ask) = _read();
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

        (uint128 bid, uint128 ask) = _read();
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

        (uint128 bid, uint128 ask) = _read();
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

        (uint128 bid, uint128 ask) = _read();
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

    /// @dev Returndata bomb: must fail closed AND keep the caller-side cost bounded (the hardened
    ///      assembly read copies only 64 bytes, so a clean fail-closed read and a bombing read cost
    ///      the same order of gas — far below ~2× SOURCE_GAS_LIMIT a high-level call would incur).
    function testSourceReturndataBombFailsClosedAndBounded() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);

        // baseline: a clean fail-closed source (EOA, empty returndata)
        provider.setSource(address(0xE0A));
        _inSwapPP = address(provider);
        uint256 g0 = gasleft();
        try provider.getBidAndAskPrice() returns (uint128, uint128) {} catch {}
        uint256 cleanCost = g0 - gasleft();

        // bomb: ~480 KB returndata
        src.setMode(MockAnchorSource.Mode.Bomb);
        provider.setSource(address(src));
        _inSwapPP = address(provider);
        uint256 g1 = gasleft();
        try provider.getBidAndAskPrice() returns (uint128, uint128) {} catch {}
        uint256 bombCost = g1 - gasleft();

        // Both fail closed (revert caught). The bomb must not blow past SOURCE_GAS_LIMIT-class cost:
        // assert it stays well under the ~1M a full returndatacopy would have charged.
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

    function testSourceFailureRecoversAfterSwapToZero() public {
        oracle.setData(FEED_ID, 185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.Revert);
        provider.setSource(address(src));
        _expectStalled();

        // instant swap back to reference mode — no timelock
        provider.setSource(address(0));
        (uint128 bid, uint128 ask) = _read();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    // ── Attributed-path gating (real OracleBase) ──────────────────────────

    function testRevertsInvalidInSwapWrongProvider() public {
        _inSwapPP = address(0xBEEF); // pool declares a different provider than the caller
        oracle.setData(FEED_ID, 100_000_000, 2, 0, block.timestamp);
        vm.expectRevert(IOffchainOracle.InvalidInSwap.selector);
        provider.getBidAndAskPrice();
    }

    function testRevertsUnregisteredPool() public {
        MockPool pool2 = new MockPool(address(provider)); // a pool, but never registered for the feed
        oracle.setData(FEED_ID, 100_000_000, 2, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.NotRegistered.selector, FEED_ID, address(pool2)));
        pool2.getBidAndAskPrice();
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

                (uint128 bid0, uint128 ask0) = _read();
                _inSwapPP = address(p);
                (uint128 bid1, uint128 ask1) = p.getBidAndAskPrice();

                assertEq(bid1, bid0, "bid parity");
                assertEq(ask1, ask0, "ask parity");
            }
        }
    }

    // ── Shaping + clamp (mutable, reference mode) ─────────────────────────

    /// @dev Confidence alone can never escape the band: max delta = mid·u (confidence ceiling)
    ///      while the band half-width is u + FLOOR — so a confidence-only shaped quote is always
    ///      clipped to the band edges (the shaped quote can only ever be tighter than the band).
    function testConfidenceOnlyAlwaysClippedToBandEdges() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        p.setConfidenceParam(p.CONFIDENCE_MAX()); // strongest possible confidence shaping

        oracle.setData(FEED_ID, 150_000_000, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(150_000_000, 10, FLOOR);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask) = p.getBidAndAskPrice();
        assertEq(bid, refBid, "clipped to band bid");
        assertEq(ask, refAsk, "clipped to band ask");
    }

    // ── marginStep (immutable, construction-time bias) ────────────────────

    function testConstructorMarginStepOutOfBoundsReverts() public {
        vm.expectRevert(AnchoredPriceProvider.MarginStepOutOfBounds.selector);
        new AnchoredPriceProvider(
            anchorFactory, address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, true, int256(BPS_BASE_U), BASE_TOKEN, QUOTE_TOKEN
        );
        vm.expectRevert(AnchoredPriceProvider.MarginStepOutOfBounds.selector);
        new AnchoredPriceProvider(
            anchorFactory, address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, true, -int256(BPS_BASE_U), BASE_TOKEN, QUOTE_TOKEN
        );
    }

    /// @dev A marginStep wider than the band half-width escapes the band: unlike confidence (which only
    ///      tightens and is clipped), marginStep widens the shaped quote, so the clamp keeps it.
    function testMarginStepWidensCustomizableQuoteBeyondBand() public {
        int256 ms = int256(BPS_BASE_U / 10); // 10% — far exceeds the u + FLOOR band half-width
        AnchoredPriceProvider p = new AnchoredPriceProvider(
            anchorFactory, address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, true, ms, BASE_TOKEN, QUOTE_TOKEN
        );
        // confidenceParam stays 0, so marginStep alone shapes the quote.
        uint64 mid = 150_000_000;
        oracle.setData(FEED_ID, mid, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(mid, 10, FLOOR);

        // Shaped edges = mid · (BPS_BASE_U ∓ marginStep), the same _bandEdge math the contract uses.
        uint256 expBid = Math.mulDiv(mid, Q64 * (BPS_BASE_U - uint256(ms)), STEP_DENOM, Math.Rounding.Floor);
        uint256 expAsk = Math.mulDiv(mid, Q64 * (BPS_BASE_U + uint256(ms)), STEP_DENOM, Math.Rounding.Ceil);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask) = p.getBidAndAskPrice();

        assertEq(bid, uint128(expBid), "bid = marginStep-shaped edge");
        assertEq(ask, uint128(expAsk), "ask = marginStep-shaped edge");
        assertLt(bid, refBid, "marginStep widened bid below the band");
        assertGt(ask, refAsk, "marginStep widened ask above the band");
    }

    /// @dev The immutable variant quotes the band directly (never calls _shapedQuote), so marginStep
    ///      is inert there even when set to an extreme value.
    function testMarginStepInertInImmutableVariant() public {
        AnchoredPriceProvider p = new AnchoredPriceProvider(
            anchorFactory, address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, false, int256(BPS_BASE_U / 10), BASE_TOKEN, QUOTE_TOKEN
        );
        uint64 mid = 150_000_000;
        oracle.setData(FEED_ID, mid, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(mid, 10, FLOOR);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask) = p.getBidAndAskPrice();
        assertEq(bid, refBid, "immutable variant ignores marginStep (band bid)");
        assertEq(ask, refAsk, "immutable variant ignores marginStep (band ask)");
    }

    /// @dev A NEGATIVE marginStep tightens (and at this magnitude inverts) the pre-clamp shaped quote;
    ///      the load-bearing band clamp must neutralize it back to the band edges. This is the case the
    ///      omit-the-envelope-bound decision depends on — a permanent regression guard on the clamp.
    function testMarginStepNegativeIsClampedToBand() public {
        int256 ms = -int256(BPS_BASE_U / 5); // -20%: large enough to invert the pre-clamp quote
        AnchoredPriceProvider p = new AnchoredPriceProvider(
            anchorFactory, address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, true, ms, BASE_TOKEN, QUOTE_TOKEN
        );
        uint64 mid = 150_000_000;
        oracle.setData(FEED_ID, mid, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(mid, 10, FLOOR);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask) = p.getBidAndAskPrice();
        assertEq(bid, refBid, "negative marginStep clamped up to band bid");
        assertEq(ask, refAsk, "negative marginStep clamped down to band ask");
        assertLt(bid, ask, "clamp restores ordering despite an inverted pre-clamp quote");
    }

    /// @dev A POSITIVE marginStep smaller than the band half-width stays inside the band, so the shaped
    ///      quote is clipped to the band edges (the band edge is the most aggressive quote allowed).
    function testMarginStepPositiveSubBandClipsToEdge() public {
        int256 ms = int256(ONE_BPS_E18); // 1 bps, far below the u(10) + FLOOR band half-width
        AnchoredPriceProvider p = new AnchoredPriceProvider(
            anchorFactory, address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, true, ms, BASE_TOKEN, QUOTE_TOKEN
        );
        uint64 mid = 150_000_000;
        oracle.setData(FEED_ID, mid, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(mid, 10, FLOOR);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask) = p.getBidAndAskPrice();
        assertEq(bid, refBid, "sub-band marginStep clipped to band bid");
        assertEq(ask, refAsk, "sub-band marginStep clipped to band ask");
    }

    /// @dev Realistic production config: nonzero confidence AND nonzero marginStep composed in
    ///      _shapedQuote. With a band-escaping marginStep the composed quote is kept; assert it against
    ///      independently recomputed math and that it is never tighter than the band.
    function testMarginStepComposedWithConfidence() public {
        int256 ms = int256(BPS_BASE_U / 10); // 10% — escapes the band so the composed quote survives the clamp
        AnchoredPriceProvider p = new AnchoredPriceProvider(
            anchorFactory, address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, true, ms, BASE_TOKEN, QUOTE_TOKEN
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
        (uint128 bid, uint128 ask) = p.getBidAndAskPrice();
        assertEq(bid, uint128(expBid), "composed bid = confidence-narrowed mid * (1 - marginStep)");
        assertEq(ask, uint128(expAsk), "composed ask = confidence-widened mid * (1 + marginStep)");

        (uint128 refBid, uint128 refAsk) = _refBand(mid, u, FLOOR);
        assertLe(bid, refBid, "composed bid no tighter than band");
        assertGe(ask, refAsk, "composed ask no tighter than band");
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
        (uint128 bid1, uint128 ask1) = p.getBidAndAskPrice();
        (uint128 bid0, uint128 ask0) = _read();

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
    uint256 private constant ONE_BPS_E18 = 1e14;

    bytes32 private constant FEED_ID = keccak256("anchored-flow-feed");
    uint256 private constant FLOOR = 5e13;
    uint256 private constant MAX_REF_STALENESS = 60;
    uint16  private constant U_MAX = 150;
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
            address(this), address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, false, int256(0), address(0xBEEF), address(0xCAFE)
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

        (uint128 bid, uint128 ask) = poolContract.getBidAndAskPrice();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    function test_flow_sourceModeClampedThroughPool() public {
        uint64 mid = 150_000_000;
        uint16 u = 3;
        oracle.setData(FEED_ID, mid, u, 0, block.timestamp);

        uint256 half = uint256(u) * ONE_BPS_E18 + FLOOR;
        uint128 refBid = uint128(Math.mulDiv(mid, Q64 * (BPS_BASE_U - half), STEP_DENOM));
        uint128 refAsk = uint128(Math.mulDiv(mid, Q64 * (BPS_BASE_U + half), STEP_DENOM, Math.Rounding.Ceil));

        src.set(refBid + 7, refAsk - 7); // tighter than band
        provider.setSource(address(src));

        (uint128 bid, uint128 ask) = poolContract.getBidAndAskPrice();
        assertEq(bid, refBid, "pool sees band-clipped bid");
        assertEq(ask, refAsk, "pool sees band-clipped ask");
    }

    function test_flow_staleHaltsThroughPool() public {
        oracle.setData(FEED_ID, 150_000_000, 3, 0, block.timestamp - MAX_REF_STALENESS - 1);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        poolContract.getBidAndAskPrice();
    }
}

/// @notice Synthetic ratio mode: feed1 (BTC/USD) ÷ refFeed (ETH/USD) → BTC/ETH. The test contract
///         acts as the pool (implements inSwap) and is registered for BOTH feeds.
contract AnchoredPriceProviderSyntheticTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant BPS_BASE_U = 1e18;
    uint256 private constant STEP_DENOM = 1e8 * BPS_BASE_U;
    uint256 private constant ONE_BPS_E18 = 1e14;
    uint16  private constant ORACLE_BPS = 10_000;

    bytes32 private constant FEED1 = keccak256("BTC-USD"); // base leg
    bytes32 private constant FEED2 = keccak256("ETH-USD"); // ref leg (denominator)
    address private constant BTC = address(0xB7C);
    address private constant ETH = address(0xE74);
    address private constant USD = address(0x05D);

    uint256 private constant FLOOR = 5e13; // 0.5 bps
    uint256 private constant MAX_REF_STALENESS = 60;
    uint16  private constant U_MAX = 300;
    uint256 private constant T0 = 1_000_000;

    TestOracle private oracle;
    MockPoolFactory private poolFactory;
    AnchoredPriceProvider private provider;
    address private _inSwapPP;

    function inSwap() external view returns (address) { return _inSwapPP; }

    function setUp() public {
        vm.deal(address(this), 1 ether);
        vm.warp(T0);

        oracle = new TestOracle(address(this), 60);

        poolFactory = new MockPoolFactory();
        oracle.addApprovedFactory(address(poolFactory));

        // Synthetic pair tokens are explicit now (the oracles are token-free): BTC/ETH.
        provider = new AnchoredPriceProvider(
            address(this), address(oracle), FEED1, FEED2, FLOOR, MAX_REF_STALENESS, U_MAX, false, int256(0), BTC, ETH
        );

        // This contract is the pool; register it for BOTH legs.
        poolFactory.setPool(address(this), true);
        oracle.register{value: 1}(FEED1, address(this), address(poolFactory));
        oracle.register{value: 1}(FEED2, address(this), address(poolFactory));
    }

    function _read() internal returns (uint128 bid, uint128 ask) {
        _inSwapPP = address(provider);
        return provider.getBidAndAskPrice();
    }

    function _expectStalled() internal {
        _inSwapPP = address(provider);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        provider.getBidAndAskPrice();
    }

    function _refBand(uint256 mid, uint256 u, uint256 floor_) internal pure returns (uint128 refBid, uint128 refAsk) {
        uint256 half = u * ONE_BPS_E18 + floor_;
        refBid = uint128(Math.mulDiv(mid, Q64 * (BPS_BASE_U - half), STEP_DENOM));
        refAsk = uint128(Math.mulDiv(mid, Q64 * (BPS_BASE_U + half), STEP_DENOM, Math.Rounding.Ceil));
    }

    function testTokensAreFeed1BaseAndRefBase() public view {
        assertEq(provider.token0(), BTC, "token0 = feed1 base (BTC)");
        assertEq(provider.token1(), ETH, "token1 = ref feed base (ETH)");
        assertEq(provider.quoteFeedId(), FEED2);
    }

    function testSyntheticRatioMidAndBand() public {
        oracle.setData(FEED1, uint64(65_000 * 1e8), 3, 0, block.timestamp);
        oracle.setData(FEED2, uint64(3_000 * 1e8), 5, 0, block.timestamp);

        uint256 synthMid = Math.mulDiv(uint256(65_000) * 1e8, 1e8, uint256(3_000) * 1e8);
        (uint128 refBid, uint128 refAsk) = _refBand(synthMid, 3 + 5, FLOOR); // u = u1 + u2

        (uint128 bid, uint128 ask) = _read();
        assertEq(bid, refBid, "synthetic bid = band edge of mid1/mid2 with u1+u2");
        assertEq(ask, refAsk, "synthetic ask = band edge");
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
        oracle.setData(FEED2, uint64(3_000 * 1e8), ORACLE_BPS, 0, block.timestamp); // off-hours marker
        _expectStalled();
    }

    function testHaltsWhenCombinedUExceedsUMax() public {
        // u1 + u2 = 200 + 200 = 400 > U_MAX (300); each leg alone is valid.
        oracle.setData(FEED1, uint64(65_000 * 1e8), 200, 0, block.timestamp);
        oracle.setData(FEED2, uint64(3_000 * 1e8), 200, 0, block.timestamp);
        _expectStalled();
    }

    function testRefPriceGuardHalts() public {
        oracle.setData(FEED1, uint64(65_000 * 1e8), 3, 0, block.timestamp);
        oracle.setData(FEED2, uint64(3_000 * 1e8), 5, 0, block.timestamp);
        oracle.setPriceGuard(FEED2, uint128(1 * 1e8), uint128(100 * 1e8)); // 3000e8 above max → halt
        _expectStalled();
    }

    /// @dev Tokens are explicit and mandatory now; the constructor no longer reads the oracle for
    ///      feed metadata, so a nonexistent ref feed does NOT revert at construction. It fails closed
    ///      later at read time (see testHaltsWhenRefFeedStale et al.).
    function testConstructorZeroTokenReverts() public {
        vm.expectRevert();
        new AnchoredPriceProvider(
            address(this), address(oracle), FEED1, FEED2, FLOOR, MAX_REF_STALENESS, U_MAX, false, int256(0), address(0), ETH
        );
    }

    function testConstructorEqualTokensReverts() public {
        vm.expectRevert();
        new AnchoredPriceProvider(
            address(this), address(oracle), FEED1, FEED2, FLOOR, MAX_REF_STALENESS, U_MAX, false, int256(0), BTC, BTC
        );
    }
}
