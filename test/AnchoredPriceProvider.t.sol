// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {AnchoredPriceProvider} from "../contracts/AnchoredPriceProvider.sol";
import {IOffchainOracle} from "../contracts/interfaces/IOffchainOracle.sol";
import {OracleBase} from "../contracts/oracles/providers/OracleBase.sol";
import {toTimeMs} from "../contracts/oracles/utils/TimeMs.sol";

import {TestOracle} from "./ProtectedPriceProvider.t.sol";
import {MockPoolFactory} from "./mocks/MockPoolFactory.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockAnchorSource} from "./mocks/MockAnchorSource.sol";

/// @notice Providers-oracle test double with PER-FEED data (the shared TestOracle serves one global
///         blob) — needed so the two synthetic-ratio legs can hold distinct mid/u/refTime.
contract MultiFeedOracle is OracleBase {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    mapping(bytes32 => IOffchainOracle.OracleData) internal _data;

    constructor(address _owner, uint256 maxTimeDrift) OracleBase(_owner, maxTimeDrift) {}

    function registerFeed(bytes32 feedId, address base, address quote) external {
        feedIds.add(feedId);
        oracleInfo[feedId] = IOffchainOracle.OracleInfo({baseToken: base, quoteToken: quote, misc: ""});
    }

    function setData(bytes32 feedId, uint64 price_, uint16 spread_, uint16 vol_, uint256 refTimeSec) external {
        _data[feedId] = IOffchainOracle.OracleData({
            price: price_, spread: spread_, volatility: vol_, timestampMs: toTimeMs(refTimeSec * 1000)
        });
    }

    function _oracleDataRaw(bytes32 feedId) internal view override returns (IOffchainOracle.OracleData memory) {
        return _data[feedId];
    }
}

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
        oracle.registerFeed(FEED_ID, BASE_TOKEN, QUOTE_TOKEN);

        poolFactory = new MockPoolFactory();
        oracle.addApprovedFactory(address(poolFactory));

        provider = _deployProvider(FLOOR, MAX_REF_STALENESS, U_MAX, address(0), address(0));
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
            anchorFactory, address(oracle), FEED_ID, bytes32(0), floor_, staleness, uMax, false, base, quote
        );
    }

    function _deployMutableProvider() internal returns (AnchoredPriceProvider) {
        return new AnchoredPriceProvider(
            anchorFactory, address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, true, address(0), address(0)
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

    function testConstructorUsesTokenOverrides() public {
        AnchoredPriceProvider p = _deployProvider(FLOOR, MAX_REF_STALENESS, U_MAX, address(0xA11CE), address(0xB0B));
        address base = p.token0();
        address quote = p.token1();
        assertEq(base, address(0xA11CE));
        assertEq(quote, address(0xB0B));
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

    function testConstructorZeroFactoryReverts() public {
        vm.expectRevert();
        new AnchoredPriceProvider(
            address(0), address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, false, address(0), address(0)
        );
    }

    function testConstructorStalenessZeroReverts() public {
        vm.expectRevert(AnchoredPriceProvider.MaxRefStalenessOutOfBounds.selector);
        _deployProvider(FLOOR, 0, U_MAX, address(0), address(0));
    }

    function testConstructorStalenessTooLargeReverts() public {
        vm.expectRevert(AnchoredPriceProvider.MaxRefStalenessOutOfBounds.selector);
        _deployProvider(FLOOR, 7 days + 1, U_MAX, address(0), address(0));
    }

    function testConstructorUMaxZeroReverts() public {
        vm.expectRevert(AnchoredPriceProvider.MaxSpreadOutOfBounds.selector);
        _deployProvider(FLOOR, MAX_REF_STALENESS, 0, address(0), address(0));
    }

    function testConstructorUMaxAtBpsBaseReverts() public {
        vm.expectRevert(AnchoredPriceProvider.MaxSpreadOutOfBounds.selector);
        _deployProvider(FLOOR, MAX_REF_STALENESS, ORACLE_BPS, address(0), address(0));
    }

    function testConstructorBandTooWideReverts() public {
        // uMax 9_999 bps + floor 1e14 → worst-case half-width = 1e18 (100%) → bid could hit zero
        vm.expectRevert(AnchoredPriceProvider.BandTooWide.selector);
        _deployProvider(1e14, MAX_REF_STALENESS, 9_999, address(0), address(0));
    }

    function testConstructorMinMarginZeroReverts() public {
        // floor 0 with u == 0 collapses the band to zero width — disallowed.
        vm.expectRevert(AnchoredPriceProvider.MinMarginZero.selector);
        _deployProvider(0, MAX_REF_STALENESS, U_MAX, address(0), address(0));
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
        oracle.setData(185_000_000, 2, 0, block.timestamp);
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
        oracle.setData(mid, u, 0, block.timestamp);

        (uint128 bid, uint128 ask) = _read();
        (uint128 refBid, uint128 refAsk) = _refBand(mid, u, FLOOR);

        assertEq(bid, refBid, "bid = mid - (u + floor)");
        assertEq(ask, refAsk, "ask = mid + (u + floor)");
        assertLt(bid, ask);
    }

    function testReferenceModeFloorOnlyWhenUZero() public {
        uint64 mid = 100_000_000;
        oracle.setData(mid, 0, 0, block.timestamp);

        (uint128 bid, uint128 ask) = _read();
        (uint128 refBid, uint128 refAsk) = _refBand(mid, 0, FLOOR);

        assertEq(bid, refBid);
        assertEq(ask, refAsk);
        // floor alone separates the quotes
        assertLt(bid, ask);
    }

    function testReferenceModeWideningUWidensBand() public {
        uint64 mid = 100_000_000;

        oracle.setData(mid, 1, 0, block.timestamp);
        (uint128 bidNarrow, uint128 askNarrow) = _read();

        oracle.setData(mid, 100, 0, block.timestamp);
        (uint128 bidWide, uint128 askWide) = _read();

        assertLt(bidWide, bidNarrow, "wider u lowers bid");
        assertGt(askWide, askNarrow, "wider u raises ask");
    }

    function testReferenceModeUAtUMaxStillQuotes() public {
        oracle.setData(100_000_000, U_MAX, 0, block.timestamp);
        (uint128 bid, uint128 ask) = _read();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    // ── Guards → FeedStalled ──────────────────────────────────────────────

    function testRevertsWhenStale() public {
        oracle.setData(100_000_000, 2, 0, block.timestamp - MAX_REF_STALENESS - 1);
        _expectStalled();
    }

    /// @dev Boundary: refTime exactly MAX_REF_STALENESS old is NOT stale (spec: halt when
    ///      timestamp > maxRefStaleness), so the pool still quotes.
    function testQuotesAtExactStalenessBoundary() public {
        oracle.setData(100_000_000, 2, 0, block.timestamp - MAX_REF_STALENESS);
        (uint128 bid, uint128 ask) = _read();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    function testRevertsWhenFutureRefTime() public {
        oracle.setData(100_000_000, 2, 0, block.timestamp + 1);
        _expectStalled();
    }

    function testRevertsWhenMidZero() public {
        oracle.setData(0, 2, 0, block.timestamp);
        _expectStalled();
    }

    function testRevertsOnOffHoursMarker() public {
        // ChainlinkOracle writes u = ORACLE_BPS when an RWA market is closed
        oracle.setData(100_000_000, ORACLE_BPS, 0, block.timestamp);
        _expectStalled();
    }

    function testRevertsWhenUAboveUMax() public {
        oracle.setData(100_000_000, U_MAX + 1, 0, block.timestamp);
        _expectStalled();
    }

    function testPriceGuardRejectsBelow() public {
        oracle.setData(50_000_000, 2, 0, block.timestamp);
        oracle.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);
        _expectStalled();
    }

    function testPriceGuardRejectsAbove() public {
        oracle.setData(250_000_000, 2, 0, block.timestamp);
        oracle.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);
        _expectStalled();
    }

    function testPriceGuardAcceptsWithinRange() public {
        oracle.setData(150_000_000, 2, 0, block.timestamp);
        oracle.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);
        (uint128 bid, uint128 ask) = _read();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    // ── Source mode: clamping ─────────────────────────────────────────────

    function testSourceWiderThanBandPassesThrough() public {
        uint64 mid = 185_000_000;
        uint16 u = 2;
        oracle.setData(mid, u, 0, block.timestamp);
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
        oracle.setData(mid, u, 0, block.timestamp);
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
        oracle.setData(mid, u, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(mid, u, FLOOR);

        src.set(refBid + 5, refAsk + 5); // bid tighter (clipped), ask wider (kept)
        provider.setSource(address(src));

        (uint128 bid, uint128 ask) = _read();
        assertEq(bid, refBid);
        assertEq(ask, refAsk + 5);
    }

    function testSourceClampHoldsBidLtAskAlways() public {
        uint64 mid = 185_000_000;
        oracle.setData(mid, 2, 0, block.timestamp);

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
        oracle.setData(185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.Revert);
        provider.setSource(address(src));
        _expectStalled();
    }

    function testSourceGarbageReturndataHalts() public {
        oracle.setData(185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.Garbage);
        provider.setSource(address(src));
        _expectStalled();
    }

    function testSourceGasGriefHalts() public {
        oracle.setData(185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.BurnGas);
        provider.setSource(address(src));
        _expectStalled();
    }

    function testSourceDirtyWordsHalt() public {
        oracle.setData(185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.DirtyWords);
        provider.setSource(address(src));
        _expectStalled();
    }

    /// @dev Exercises the load-bearing `srcAsk > type(uint128).max` guard specifically: a valid bid
    ///      with an ask one over uint128.max. Without the guard, max(refAsk, srcAsk) would truncate
    ///      to a sub-band ask and quote a price better than the band — this must halt instead.
    function testSourceOverflowAskHalts() public {
        oracle.setData(185_000_000, 2, 0, block.timestamp);
        src.setMode(MockAnchorSource.Mode.OverflowAsk);
        provider.setSource(address(src));
        _expectStalled();
    }

    /// @dev Returndata bomb: must fail closed AND keep the caller-side cost bounded (the hardened
    ///      assembly read copies only 64 bytes, so a clean fail-closed read and a bombing read cost
    ///      the same order of gas — far below ~2× SOURCE_GAS_LIMIT a high-level call would incur).
    function testSourceReturndataBombFailsClosedAndBounded() public {
        oracle.setData(185_000_000, 2, 0, block.timestamp);

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
        oracle.setData(185_000_000, 2, 0, block.timestamp);
        src.set(0, 1000);
        provider.setSource(address(src));
        _expectStalled();
    }

    function testSourceInvertedQuotesHalt() public {
        oracle.setData(185_000_000, 2, 0, block.timestamp);
        src.set(1000, 999);
        provider.setSource(address(src));
        _expectStalled();
    }

    function testSourceEoaHalts() public {
        oracle.setData(185_000_000, 2, 0, block.timestamp);
        provider.setSource(address(0xE0A)); // no code → empty returndata → fail closed
        _expectStalled();
    }

    function testSourceFailureRecoversAfterSwapToZero() public {
        oracle.setData(185_000_000, 2, 0, block.timestamp);
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
        oracle.setData(100_000_000, 2, 0, block.timestamp);
        vm.expectRevert(IOffchainOracle.InvalidInSwap.selector);
        provider.getBidAndAskPrice();
    }

    function testRevertsUnregisteredPool() public {
        MockPool pool2 = new MockPool(address(provider)); // a pool, but never registered for the feed
        oracle.setData(100_000_000, 2, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.NotRegistered.selector, FEED_ID, address(pool2)));
        pool2.getBidAndAskPrice();
    }

    // ── Variant flag / knob defaults ──────────────────────────────────────

    function testImmutableVariantFlagAndZeroKnobs() public view {
        assertFalse(provider.MUTABLE_PARAMS());
        assertEq(provider.confidenceParam(), 0);
        assertEq(provider.lastConfidenceUpdate(), 0);
        assertEq(provider.marginStep(), 0);
    }

    function testMutableVariantConstructorDefaults() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        assertTrue(p.MUTABLE_PARAMS());
        assertEq(p.confidenceParam(), 0);
        assertEq(p.lastConfidenceUpdate(), 0);
        assertEq(p.marginStep(), 0);
    }

    // ── Setter mode-gating ────────────────────────────────────────────────

    function testSettersRevertOnImmutableProvider() public {
        // caller IS the factory — the gate hit is the variant flag
        vm.expectRevert(AnchoredPriceProvider.ImmutableProvider.selector);
        provider.setConfidenceParam(1);
        vm.expectRevert(AnchoredPriceProvider.ImmutableProvider.selector);
        provider.setMarginStep(1);
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
        vm.expectRevert(AnchoredPriceProvider.OnlyFactory.selector);
        mutableP.setMarginStep(1);
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

    function testSetMarginStepUpdatesAndEmits() public {
        AnchoredPriceProvider p = _deployMutableProvider();

        vm.expectEmit(true, false, false, true, address(p));
        emit AnchoredPriceProvider.MarginStepUpdated(int256(1e14));
        p.setMarginStep(1e14);
        assertEq(p.marginStep(), 1e14);

        p.setMarginStep(-1e14); // no cooldown on marginStep
        assertEq(p.marginStep(), -1e14);
    }

    function testSetMarginStepOutOfBoundsReverts() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        vm.expectRevert(AnchoredPriceProvider.MarginStepOutOfBounds.selector);
        p.setMarginStep(int256(BPS_BASE_U));
        vm.expectRevert(AnchoredPriceProvider.MarginStepOutOfBounds.selector);
        p.setMarginStep(-int256(BPS_BASE_U));
    }

    // ── Parity: mutable with default knobs ≡ immutable ────────────────────

    function testMutableDefaultsMatchImmutableBitForBit() public {
        AnchoredPriceProvider p = _deployMutableProvider();

        uint64[2] memory mids = [uint64(100_000_000), uint64(185_000_000)]; // 1.0 (exact Q64) and 1.85
        uint16[3] memory us = [uint16(0), uint16(2), U_MAX];

        for (uint256 i; i < mids.length; ++i) {
            for (uint256 j; j < us.length; ++j) {
                oracle.setData(mids[i], us[j], 0, block.timestamp);

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
    ///      clipped to the band edges. Only marginStep can push the quote wider than the band.
    function testConfidenceOnlyAlwaysClippedToBandEdges() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        p.setConfidenceParam(p.CONFIDENCE_MAX()); // strongest possible confidence shaping

        oracle.setData(150_000_000, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(150_000_000, 10, FLOOR);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask) = p.getBidAndAskPrice();
        assertEq(bid, refBid, "clipped to band bid");
        assertEq(ask, refAsk, "clipped to band ask");
    }

    function testPositiveMarginStepWidensBeyondBand() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        p.setMarginStep(1e16); // 100 bps step ≫ band half (10 bps + 0.5 bps)

        oracle.setData(150_000_000, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(150_000_000, 10, FLOOR);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask) = p.getBidAndAskPrice();
        assertLt(bid, refBid, "bid wider than band");
        assertGt(ask, refAsk, "ask wider than band");

        // exact PriceProvider step math: mid·(1 ∓ s) in Q64 (confidence 0 → delta 0)
        uint256 sBid = Math.mulDiv(150_000_000, Q64 * (BPS_BASE_U - 1e16), STEP_DENOM);
        uint256 sAsk = Math.mulDiv(150_000_000, Q64 * (BPS_BASE_U + 1e16), STEP_DENOM, Math.Rounding.Ceil);
        assertEq(bid, uint128(sBid), "shaped bid passes through");
        assertEq(ask, uint128(sAsk), "shaped ask passes through");
    }

    function testNegativeMarginStepClippedToBandEdges() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        p.setMarginStep(-1e16); // tighter-than-band quote must be clipped, not inverted/halted

        oracle.setData(150_000_000, 10, 0, block.timestamp);
        (uint128 refBid, uint128 refAsk) = _refBand(150_000_000, 10, FLOOR);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask) = p.getBidAndAskPrice();
        assertEq(bid, refBid);
        assertEq(ask, refAsk);
    }

    function testAsymmetricMarginStepComposesWithConfidence() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        p.setConfidenceParam(p.CONFIDENCE_MAX()); // delta = mid·u
        p.setMarginStep(1e15);                       // + 10 bps step on both sides

        uint64 mid = 150_000_000;
        uint16 u = 10;
        oracle.setData(mid, u, 0, block.timestamp);

        // shaped: (mid ∓ mid·u)·(1 ∓ s) — strictly outside the band on both sides
        uint256 delta = uint256(mid) * (uint256(u) * 1_000_000) / 1e10;
        uint256 sBid = Math.mulDiv(uint256(mid) - delta, Q64 * (BPS_BASE_U - 1e15), STEP_DENOM);
        uint256 sAsk = Math.mulDiv(uint256(mid) + delta, Q64 * (BPS_BASE_U + 1e15), STEP_DENOM, Math.Rounding.Ceil);

        _inSwapPP = address(p);
        (uint128 bid, uint128 ask) = p.getBidAndAskPrice();
        assertEq(bid, uint128(sBid));
        assertEq(ask, uint128(sAsk));
    }

    function testShapedZeroBidHalts() public {
        // A shaped bid that rounds to zero (tiny mid × near-max negative step) must halt,
        // mirroring PriceProvider's zero-bid guard.
        AnchoredPriceProvider p = _deployMutableProvider();
        p.setMarginStep(int256(BPS_BASE_U) - 1); // stepBidFactor = BPS_BASE − marginStep = 1 → tiny mid rounds to 0

        oracle.setData(1, 10, 0, block.timestamp); // smallest positive mid
        _inSwapPP = address(p);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        p.getBidAndAskPrice();
    }

    // ── Source-mode knob independence ─────────────────────────────────────

    function testKnobsDoNotPostProcessSourceQuotes() public {
        AnchoredPriceProvider p = _deployMutableProvider();
        p.setConfidenceParam(p.CONFIDENCE_MAX());
        p.setMarginStep(5e17); // extreme knobs — must not touch the source path

        oracle.setData(150_000_000, 10, 0, block.timestamp);
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
        oracle.registerFeed(FEED_ID, address(0xBEEF), address(0xCAFE));

        poolFactory = new MockPoolFactory();
        oracle.addApprovedFactory(address(poolFactory));

        provider = new AnchoredPriceProvider(
            address(this), address(oracle), FEED_ID, bytes32(0), FLOOR, MAX_REF_STALENESS, U_MAX, false, address(0), address(0)
        );
        src = new MockAnchorSource();

        poolContract = new MockPool(address(provider));
        poolFactory.setPool(address(poolContract), true);
        oracle.register{value: 1}(FEED_ID, address(poolContract), address(poolFactory));
    }

    function test_flow_referenceModeEmitsPriceRead() public {
        oracle.setData(150_000_000, 3, 0, block.timestamp);

        vm.expectEmit(true, true, false, true, address(oracle));
        emit IOffchainOracle.PriceRead(address(poolContract), FEED_ID);

        (uint128 bid, uint128 ask) = poolContract.getBidAndAskPrice();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    function test_flow_sourceModeClampedThroughPool() public {
        uint64 mid = 150_000_000;
        uint16 u = 3;
        oracle.setData(mid, u, 0, block.timestamp);

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
        oracle.setData(150_000_000, 3, 0, block.timestamp - MAX_REF_STALENESS - 1);
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

    MultiFeedOracle private oracle;
    MockPoolFactory private poolFactory;
    AnchoredPriceProvider private provider;
    address private _inSwapPP;

    function inSwap() external view returns (address) { return _inSwapPP; }

    function setUp() public {
        vm.deal(address(this), 1 ether);
        vm.warp(T0);

        oracle = new MultiFeedOracle(address(this), 60);
        oracle.registerFeed(FEED1, BTC, USD);
        oracle.registerFeed(FEED2, ETH, USD);

        poolFactory = new MockPoolFactory();
        oracle.addApprovedFactory(address(poolFactory));

        provider = new AnchoredPriceProvider(
            address(this), address(oracle), FEED1, FEED2, FLOOR, MAX_REF_STALENESS, U_MAX, false, address(0), address(0)
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

    function testConstructorRevertsUnregisteredRefFeed() public {
        bytes32 missing = keccak256("missing");
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, missing));
        new AnchoredPriceProvider(
            address(this), address(oracle), FEED1, missing, FLOOR, MAX_REF_STALENESS, U_MAX, false, address(0), address(0)
        );
    }
}
