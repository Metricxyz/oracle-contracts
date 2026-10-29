// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ProtectedPriceProvider} from "../contracts/ProtectedPriceProvider.sol";
import {OracleBase} from "../contracts/oracles/providers/OracleBase.sol";
import {IOffchainOracle} from "../contracts/interfaces/IOffchainOracle.sol";
import {TimeMs, toTimeMs} from "../contracts/oracles/utils/TimeMs.sol";

import {MockPoolFactory} from "./mocks/MockPoolFactory.sol";
import {MockPool} from "./mocks/MockPool.sol";

/// @notice Minimal concrete OracleBase for tests: real abuse-protection `price(feedId, pool)`
///         gating with settable per-feed oracle data. Registrationless like the real oracles —
///         a feed exists once its data is written (no verified push needed).
contract TestOracle is OracleBase {
    constructor(address _owner, uint256 maxTimeDrift) OracleBase(_owner, maxTimeDrift) {}

    function setData(bytes32 feedId, uint64 price_, uint16 spread0_, uint16 spread1_, uint256 refTimeSec) external {
        oracleData[feedId] = IOffchainOracle.OracleData({
            price: price_,
            spread0: spread0_,
            spread1: spread1_,
            timestampMs: toTimeMs(refTimeSec * 1000)
        });
    }
}

contract ProtectedPriceProviderTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant BPS_BASE_U = 1e18;
    uint256 private constant STEP_DENOM = 1e8 * BPS_BASE_U;
    uint16  private constant ORACLE_BPS = 10_000;
    uint256 private constant CONFIDENCE_BASE = 1e10;

    bytes32 private constant FEED_ID = keccak256("feed-id");
    address private constant BASE_TOKEN = address(0xBEEF);
    address private constant QUOTE_TOKEN = address(0xCAFE);

    int256  private constant CEX_STEP = 100_000_000_000_000; // 0.01% (1e14)
    uint256 private constant MAX_TIME_DELTA = 1 days;
    uint256 private constant T0 = 1_000_000; // base timestamp

    uint256 private immutable STEP_BID_FACTOR = BPS_BASE_U - uint256(CEX_STEP);
    uint256 private immutable STEP_ASK_FACTOR = BPS_BASE_U + uint256(CEX_STEP);

    TestOracle private oracle;
    MockPoolFactory private factory;       // AMM pool factory (oracle-approved)
    ProtectedPriceProvider private provider;

    address private adminFactory;          // provider's immutable factory (onlyFactory setters)
    address private pool;                   // == address(this): this contract acts as the pool
    address private _inSwapPP;              // IPool.inSwap() backing — the provider this pool reads through

    /// @dev IPool surface: the oracle queries this to bind the read to the calling provider.
    function inSwap() external view returns (address) {
        return _inSwapPP;
    }

    function setUp() public {
        adminFactory = address(this);
        vm.deal(address(this), 1 ether);
        vm.warp(T0);

        oracle = new TestOracle(address(this), 60);

        factory = new MockPoolFactory();
        oracle.addApprovedFactory(address(factory));

        provider = new ProtectedPriceProvider(
            adminFactory,
            address(oracle),
            FEED_ID,
            CEX_STEP,
            MAX_TIME_DELTA,
            BASE_TOKEN,
            QUOTE_TOKEN
        );

        // This test contract is the registered pool (it calls the provider directly).
        pool = address(this);
        factory.setPool(pool, true);
        oracle.register{value: 1}(FEED_ID, pool, address(factory));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _bidFrom(uint64 mid, uint256 adjustedSpread) internal pure returns (uint256) {
        uint256 delta = uint256(mid) * adjustedSpread / CONFIDENCE_BASE;
        return delta >= mid ? 0 : uint256(mid) - delta;
    }

    function _askFrom(uint64 mid, uint256 adjustedSpread) internal pure returns (uint256) {
        return uint256(mid) + uint256(mid) * adjustedSpread / CONFIDENCE_BASE;
    }

    function _read() internal returns (uint128 bid, uint128 ask) {
        _inSwapPP = address(provider); // mark this pool in-swap with the provider, then read (no args)
        return provider.getBidAndAskPrice();
    }

    function _deployProvider(int256 marginStep, address base, address quote)
        internal
        returns (ProtectedPriceProvider)
    {
        return new ProtectedPriceProvider(
            adminFactory, address(oracle), FEED_ID, marginStep, MAX_TIME_DELTA, base, quote
        );
    }

    // ── Construction / tokens ─────────────────────────────────────────────

    function testGetTokensReturnsConfiguredPair() public view {
        address base = provider.token0();
        address quote = provider.token1();
        assertEq(base, BASE_TOKEN);
        assertEq(quote, QUOTE_TOKEN);
    }

    function testConstructorSetsExplicitTokens() public {
        ProtectedPriceProvider p = _deployProvider(CEX_STEP, address(0xA11CE), address(0xB0B));
        address base = p.token0();
        address quote = p.token1();
        assertEq(base, address(0xA11CE));
        assertEq(quote, address(0xB0B));
    }

    function testConstructorZeroBaseTokenReverts() public {
        vm.expectRevert();
        _deployProvider(CEX_STEP, address(0), QUOTE_TOKEN);
    }

    function testConstructorZeroQuoteTokenReverts() public {
        vm.expectRevert();
        _deployProvider(CEX_STEP, BASE_TOKEN, address(0));
    }

    function testConstructorEqualTokensReverts() public {
        vm.expectRevert();
        _deployProvider(CEX_STEP, BASE_TOKEN, BASE_TOKEN);
    }

    function testConstructorMarginStepOutOfBoundsReverts() public {
        vm.expectRevert(ProtectedPriceProvider.MarginStepOutOfBounds.selector);
        _deployProvider(int256(BPS_BASE_U), BASE_TOKEN, QUOTE_TOKEN);
    }

    function testConstructorMaxTimeDeltaZeroReverts() public {
        vm.expectRevert(ProtectedPriceProvider.MaxTimeDeltaOutOfBounds.selector);
        new ProtectedPriceProvider(adminFactory, address(oracle), FEED_ID, CEX_STEP, 0, BASE_TOKEN, QUOTE_TOKEN);
    }

    function testConstructorMaxTimeDeltaTooLargeReverts() public {
        vm.expectRevert(ProtectedPriceProvider.MaxTimeDeltaOutOfBounds.selector);
        new ProtectedPriceProvider(adminFactory, address(oracle), FEED_ID, CEX_STEP, 7 days + 1, BASE_TOKEN, QUOTE_TOKEN);
    }

    function testConstructorZeroFactoryReverts() public {
        vm.expectRevert();
        new ProtectedPriceProvider(address(0), address(oracle), FEED_ID, CEX_STEP, MAX_TIME_DELTA, BASE_TOKEN, QUOTE_TOKEN);
    }

    // ── Setters: confidence ───────────────────────────────────────────────

    function testSetConfidenceParamFromFactory() public {
        provider.setConfidenceParam(500_000);
        assertEq(provider.confidenceParam(), 500_000);
    }

    function testSetConfidenceParamRevertsNonFactory() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(ProtectedPriceProvider.OnlyFactory.selector);
        provider.setConfidenceParam(1);
    }

    function testSetConfidenceParamRevertsOutOfBounds() public {
        uint256 tooBig = provider.CONFIDENCE_MAX() + 1;
        vm.expectRevert(ProtectedPriceProvider.ConfidenceParamOutOfBounds.selector);
        provider.setConfidenceParam(tooBig);
    }

    function testSetConfidenceParamRevertsCooldown() public {
        provider.setConfidenceParam(1);
        vm.expectRevert(ProtectedPriceProvider.CooldownNotElapsed.selector);
        provider.setConfidenceParam(2);
    }

    function testSetConfidenceParamAfterCooldown() public {
        provider.setConfidenceParam(1);
        vm.warp(block.timestamp + provider.CONFIDENCE_COOLDOWN());
        provider.setConfidenceParam(2);
        assertEq(provider.confidenceParam(), 2);
    }

    // ── Constructor: marginStep bounds (immutable; set once at deploy) ─────────

    function testConstructorRevertsMarginStepOutOfBounds() public {
        vm.expectRevert(ProtectedPriceProvider.MarginStepOutOfBounds.selector);
        _deployProvider(int256(BPS_BASE_U), BASE_TOKEN, QUOTE_TOKEN);
    }

    // ── Happy path + pricing math ─────────────────────────────────────────

    function testGetBidAndAskPriceReturnsAdjustedQuotesAndEmits() public {
        uint64 mid = 185_000_000;
        uint16 spread = 250;
        uint256 confidence = 100_000;
        oracle.setData(FEED_ID, mid, spread, 0, block.timestamp);
        provider.setConfidenceParam(confidence);

        vm.expectEmit(true, true, false, true, address(oracle));
        emit IOffchainOracle.PriceRead(pool, FEED_ID);
        (uint128 bid, uint128 ask) = _read();

        uint256 adjustedSpread = uint256(spread) * confidence;
        uint256 expectedBid = Math.mulDiv(_bidFrom(mid, adjustedSpread), Q64 * STEP_BID_FACTOR, STEP_DENOM);
        uint256 expectedAsk = Math.mulDiv(_askFrom(mid, adjustedSpread), Q64 * STEP_ASK_FACTOR, STEP_DENOM, Math.Rounding.Ceil);

        assertEq(bid, expectedBid, "bid parity with legacy computation");
        assertEq(ask, expectedAsk, "ask parity with legacy computation");
    }

    function testConfidenceMultipliesSpreadE2E() public {
        uint64 mid = 100_000_000;
        oracle.setData(FEED_ID, mid, 500, 0, block.timestamp);

        provider.setConfidenceParam(10_000); // 1x
        (uint128 bidSmall, uint128 askSmall) = _read();

        vm.warp(block.timestamp + provider.CONFIDENCE_COOLDOWN());
        oracle.setData(FEED_ID, mid, 500, 0, block.timestamp);
        provider.setConfidenceParam(100_000); // 10x
        (uint128 bidLarge, uint128 askLarge) = _read();

        assertGt(askLarge - bidLarge, askSmall - bidSmall, "higher confidence widens spread");
        assertLt(bidLarge, bidSmall);
        assertGt(askLarge, askSmall);
    }

    function testConfidenceZeroMeansNoSpread() public {
        oracle.setData(FEED_ID, 100_000_000, 500, 0, block.timestamp);
        // confidenceParam = 0 (default) → only marginStep separation
        (uint128 bid, uint128 ask) = _read();

        uint256 expectedBid = Math.mulDiv(uint256(100_000_000), Q64 * STEP_BID_FACTOR, STEP_DENOM);
        uint256 expectedAsk = Math.mulDiv(uint256(100_000_000), Q64 * STEP_ASK_FACTOR, STEP_DENOM, Math.Rounding.Ceil);
        assertEq(bid, expectedBid);
        assertEq(ask, expectedAsk);
        assertLt(bid, ask);
    }

    function testNegMarginStepInversionRevertsFeedStalled() public {
        ProtectedPriceProvider neg = _deployProvider(-5e14, BASE_TOKEN, QUOTE_TOKEN);
        _inSwapPP = address(neg);
        oracle.setData(FEED_ID, 100_000_000, 200, 0, block.timestamp);
        neg.setConfidenceParam(10_000); // adjustedSpread 2 bps < 5 bps step → inversion

        vm.expectRevert(ProtectedPriceProvider.FeedStalled.selector);
        neg.getBidAndAskPrice();
    }

    function testNegMarginStepWithSufficientConfidence() public {
        ProtectedPriceProvider neg = _deployProvider(-5e14, BASE_TOKEN, QUOTE_TOKEN);
        _inSwapPP = address(neg);
        oracle.setData(FEED_ID, 100_000_000, 200, 0, block.timestamp);
        neg.setConfidenceParam(250_000); // 50 bps > 5 bps step

        (uint128 bid, uint128 ask) = neg.getBidAndAskPrice();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    // ── Sentinel → FeedStalled ────────────────────────────────────────────

    function testRevertsWhenPriceZero() public {
        oracle.setData(FEED_ID, 0, 300, 0, block.timestamp);
        vm.expectRevert(ProtectedPriceProvider.FeedStalled.selector);
        _read();
    }

    function testRevertsWhenStale() public {
        oracle.setData(FEED_ID, 120_000_000, 400, 0, block.timestamp - MAX_TIME_DELTA - 1);
        vm.expectRevert(ProtectedPriceProvider.FeedStalled.selector);
        _read();
    }

    function testRevertsWhenFutureRefTime() public {
        oracle.setData(FEED_ID, 120_000_000, 400, 0, block.timestamp + 1);
        vm.expectRevert(ProtectedPriceProvider.FeedStalled.selector);
        _read();
    }

    function testRevertsWhenSpreadAtBpsBase() public {
        oracle.setData(FEED_ID, 100_000_000, ORACLE_BPS, 0, block.timestamp);
        vm.expectRevert(ProtectedPriceProvider.FeedStalled.selector);
        _read();
    }

    // ── Price guard ───────────────────────────────────────────────────────

    function testPriceGuardRejectsBelow() public {
        oracle.setData(FEED_ID, 50_000_000, 300, 0, block.timestamp);
        oracle.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);
        vm.expectRevert(ProtectedPriceProvider.FeedStalled.selector);
        _read();
    }

    function testPriceGuardRejectsAbove() public {
        oracle.setData(FEED_ID, 250_000_000, 300, 0, block.timestamp);
        oracle.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);
        vm.expectRevert(ProtectedPriceProvider.FeedStalled.selector);
        _read();
    }

    function testPriceGuardAcceptsWithinRange() public {
        oracle.setData(FEED_ID, 150_000_000, 300, 0, block.timestamp);
        oracle.setPriceGuard(FEED_ID, 100_000_000, 200_000_000);
        provider.setConfidenceParam(100_000);
        (uint128 bid, uint128 ask) = _read();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    function testPriceGuardDefaultUnlimited() public {
        // No guard set (default 0/0) → any positive price accepted
        oracle.setData(FEED_ID, 900_000_000, 300, 0, block.timestamp);
        (uint128 bid, uint128 ask) = _read();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }

    // ── Attributed-path gating (real OracleBase) ──────────────────────────

    function testRevertsInvalidInSwapWrongProvider() public {
        _inSwapPP = address(0xBEEF); // pool declares a different provider than the caller
        oracle.setData(FEED_ID, 100_000_000, 300, 0, block.timestamp);
        vm.expectRevert(IOffchainOracle.InvalidInSwap.selector);
        provider.getBidAndAskPrice();
    }

    function testRevertsWhenNoInSwapDeclared() public {
        _inSwapPP = address(0); // pool has not marked itself in-swap
        oracle.setData(FEED_ID, 100_000_000, 300, 0, block.timestamp);
        vm.expectRevert(IOffchainOracle.InvalidInSwap.selector);
        provider.getBidAndAskPrice();
    }

    function testRevertsUnregisteredPool() public {
        MockPool pool2 = new MockPool(address(provider)); // a pool, but never registered for the feed
        oracle.setData(FEED_ID, 100_000_000, 300, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.NotRegistered.selector, FEED_ID, address(pool2)));
        pool2.getBidAndAskPrice();
    }

    function testRevertsBlacklistedPool() public {
        oracle.setBlacklist(pool, true);
        oracle.setData(FEED_ID, 100_000_000, 300, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.Blacklisted.selector, pool));
        _read();
    }

    function testRevertsBlacklistedProvider() public {
        oracle.setBlacklist(address(provider), true);
        oracle.setData(FEED_ID, 100_000_000, 300, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.Blacklisted.selector, address(provider)));
        _read();
    }

    function testRegisterClearsBlacklistRecovery() public {
        oracle.setData(FEED_ID, 100_000_000, 300, 0, block.timestamp);

        oracle.setBlacklist(pool, true);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.Blacklisted.selector, pool));
        _read();

        // Paying registration again clears the blacklist (R1 redemption)
        oracle.register{value: 1}(FEED_ID, pool, address(factory));
        (uint128 bid, uint128 ask) = _read();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }
}

/// @notice End-to-end flow: MockPool (marks itself in-swap) → ProtectedPriceProvider →
///         OracleBase.price(feedId, pool). Exercises the full attributed read chain with the pool as
///         the entry point (real OracleBase gating via TestOracle).
contract ProtectedPriceProviderFlowTest is Test {
    bytes32 private constant FEED_ID = keccak256("flow-feed");
    address private constant BASE_TOKEN = address(0xBEEF);
    address private constant QUOTE_TOKEN = address(0xCAFE);
    int256  private constant CEX_STEP = 100_000_000_000_000; // 1e14
    uint256 private constant MAX_TIME_DELTA = 1 days;
    uint256 private constant T0 = 1_000_000;

    TestOracle private oracle;
    MockPoolFactory private factory;
    ProtectedPriceProvider private provider;
    MockPool private poolContract;

    function setUp() public {
        vm.deal(address(this), 1 ether);
        vm.warp(T0);

        oracle = new TestOracle(address(this), 60);

        factory = new MockPoolFactory();
        oracle.addApprovedFactory(address(factory));

        provider = new ProtectedPriceProvider(
            address(this), address(oracle), FEED_ID, CEX_STEP, MAX_TIME_DELTA, BASE_TOKEN, QUOTE_TOKEN
        );

        poolContract = new MockPool(address(provider));
        factory.setPool(address(poolContract), true);
        oracle.register{value: 1}(FEED_ID, address(poolContract), address(factory));
    }

    // ── Happy flow ─────────────────────────────────────────────────────

    function test_flow_poolEntryReturnsBidAskAndEmitsPriceRead() public {
        oracle.setData(FEED_ID, 150_000_000, 300, 0, block.timestamp);
        provider.setConfidenceParam(100_000);

        // The oracle attributes the read to the pool (not the provider).
        vm.expectEmit(true, true, false, true, address(oracle));
        emit IOffchainOracle.PriceRead(address(poolContract), FEED_ID);

        (uint128 bid, uint128 ask) = poolContract.getBidAndAskPrice();

        assertGt(bid, 0, "bid > 0");
        assertLt(bid, ask, "bid < ask");
    }

    function test_flow_transientMarkerClearsBetweenCalls() public {
        oracle.setData(FEED_ID, 150_000_000, 300, 0, block.timestamp);
        provider.setConfidenceParam(100_000);

        (uint128 bid1, uint128 ask1) = poolContract.getBidAndAskPrice();
        // A second, independent call works because the pool re-sets its in-swap marker each time.
        (uint128 bid2, uint128 ask2) = poolContract.getBidAndAskPrice();
        assertEq(bid1, bid2);
        assertEq(ask1, ask2);
    }

    // ── Negative flows (revert propagates through the whole chain) ──────

    function test_flow_unregisteredPool_reverts() public {
        MockPool other = new MockPool(address(provider)); // a pool, but never registered for the feed
        oracle.setData(FEED_ID, 150_000_000, 300, 0, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.NotRegistered.selector, FEED_ID, address(other)));
        other.getBidAndAskPrice();
    }

    function test_flow_blacklistedPool_reverts() public {
        oracle.setData(FEED_ID, 150_000_000, 300, 0, block.timestamp);
        oracle.setBlacklist(address(poolContract), true);

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.Blacklisted.selector, address(poolContract)));
        poolContract.getBidAndAskPrice();
    }

    function test_flow_staleData_revertsFeedStalled() public {
        oracle.setData(FEED_ID, 150_000_000, 300, 0, block.timestamp - MAX_TIME_DELTA - 1);
        vm.expectRevert(ProtectedPriceProvider.FeedStalled.selector);
        poolContract.getBidAndAskPrice();
    }

    function test_flow_recoveryAfterBlacklist() public {
        oracle.setData(FEED_ID, 150_000_000, 300, 0, block.timestamp);
        provider.setConfidenceParam(100_000);

        oracle.setBlacklist(address(poolContract), true);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.Blacklisted.selector, address(poolContract)));
        poolContract.getBidAndAskPrice();

        // Re-paying registration clears the blacklist and re-enables the read.
        oracle.register{value: 1}(FEED_ID, address(poolContract), address(factory));
        (uint128 bid, uint128 ask) = poolContract.getBidAndAskPrice();
        assertGt(bid, 0);
        assertLt(bid, ask);
    }
}
