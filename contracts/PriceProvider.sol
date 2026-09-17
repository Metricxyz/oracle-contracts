// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOffchainOracle} from "./interfaces/IOffchainOracle.sol";
import {IPricedOracle} from "./interfaces/IPricedOracle.sol";
import {IPriceProvider} from "./interfaces/IPriceProvider.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract PriceProvider is IPriceProvider {
    string public constant version = "1.1.0";

    // ── Constants ────────────────────────────────────────────────────────
    uint256 internal constant Q64 = 1 << 64;
    uint256 public constant CONFIDENCE_COOLDOWN = 1 minutes;

    uint256 internal constant ORACLE_DECIMALS = 1e8;
    uint256 public constant BPS_BASE_U = 1e18;
    int256 public constant BPS_BASE = int256(BPS_BASE_U);
    uint256 public constant CONFIDENCE_MAX = 1_000_000; // 100x multiplier
    uint256 internal constant CONFIDENCE_BASE = 1e10; // 1e6 (0.01 bps) × 10_000 (multiplier base)

    uint16 internal constant ORACLE_BPS = 10_000;
    /// @dev Reserved stall/off-hours sentinel emitted by the oracles (RWA market closed, compressed
    ///      0xff/0xff marker). The ONLY spread value treated as "feed inactive" → halt.
    uint16 internal constant STALL_SPREAD = type(uint16).max;
    /// @dev Circuit breaker: a genuine oracle spread wider than this (5%) means the feed is clearly
    ///      broken/illiquid → halt (fail closed). Below it, a wide spread simply widens the band.
    ///      A constant (not a per-feed immutable) to keep the guard uniform and the factory
    ///      interface unchanged; promote to an immutable if per-feed tuning is ever needed.
    uint16 internal constant MAX_SPREAD_BPS = 5 * ORACLE_BPS;

    /// @dev ORACLE_DECIMALS (1e8) * BPS_BASE (1e18) = 1e26.
    ///      Merges Q64/1e8 conversion and BPS_BASE division
    ///      into a single Math.mulDiv — one 512-bit division.
    uint256 internal constant STEP_DENOM = ORACLE_DECIMALS * BPS_BASE_U;

    // ── Immutables ──────────────────────────────────────────────────────
    IOffchainOracle public immutable offchainOracle;
    bytes32 public immutable offchainFeedId;
    address public immutable factory;

    uint256 public immutable MAX_TIME_DELTA;

    address public immutable baseToken;
    address public immutable quoteToken;

    // ── Storage ─────────────────────────────────────────────────────────
    uint256 public confidenceParam;
    uint256 public lastConfidenceUpdate;

    /// @dev marginStep and the derived step factors — set once at construction (immutable).
    int256 public immutable marginStep;
    uint256 internal immutable stepBidFactor; // BPS_BASE_U - marginStep
    uint256 internal immutable stepAskFactor; // BPS_BASE_U + marginStep

    // ── Events / Errors ─────────────────────────────────────────────────
    event ConfidenceParamSet(uint256 indexed newValue);

    error OnlyFactory();
    error FeedStalled();
    error ConfidenceParamOutOfBounds();
    error MarginStepOutOfBounds();
    error CooldownNotElapsed();
    error MaxTimeDeltaOutOfBounds();

    // ── Constructor ─────────────────────────────────────────────────────
    // Tokens live ONLY here (the oracles are token-free): the pair is an explicit,
    // mandatory constructor input, held as immutables and exposed via token0/token1.
    constructor(
        address _factory,
        address _oracle,
        bytes32 _offchainFeedId,
        int256 _marginStep,
        uint256 _maxTimeDelta,
        address _baseToken,
        address _quoteToken
    ) {
        require(_factory != address(0));
        factory = _factory;

        offchainOracle = IOffchainOracle(_oracle);
        offchainFeedId = _offchainFeedId;

        require(_baseToken != address(0) && _quoteToken != address(0) && _baseToken != _quoteToken);
        baseToken = _baseToken;
        quoteToken = _quoteToken;

        if (_marginStep <= -BPS_BASE || _marginStep >= BPS_BASE) {
            revert MarginStepOutOfBounds();
        }
        marginStep = _marginStep;
        stepBidFactor = uint256(BPS_BASE - _marginStep);
        stepAskFactor = uint256(BPS_BASE + _marginStep);

        if (_maxTimeDelta == 0 || _maxTimeDelta > 7 days) revert MaxTimeDeltaOutOfBounds();
        MAX_TIME_DELTA = _maxTimeDelta;
    }

    // ── Factory ──────────────────────────────────────────────────────────
    function setConfidenceParam(uint256 newValue) external {
        require(msg.sender == factory, OnlyFactory());
        if (newValue > CONFIDENCE_MAX) {
            revert ConfidenceParamOutOfBounds();
        }
        if (block.timestamp < lastConfidenceUpdate + CONFIDENCE_COOLDOWN) {
            revert CooldownNotElapsed();
        }

        confidenceParam = newValue;
        lastConfidenceUpdate = block.timestamp;
        emit ConfidenceParamSet(newValue);
    }

    // ── External views ──────────────────────────────────────────────────
    function token0() external view returns (address) {
        return baseToken;
    }

    function token1() external view returns (address) {
        return quoteToken;
    }

    /// @dev `referencePrice` is the oracle's own mid, converted to Q64 — the same number the bid/ask
    ///      shaping is built around, before the confidence spread and the marginStep bias. It is what
    ///      the consumer charges its fee against, so with a symmetric `marginStep` the two sides pay
    ///      symmetric fees, and a nonzero one skews them exactly as far as the bias.
    function getQuote() external override returns (uint128 bid, uint128 ask, uint128 referencePrice) {
        (bid, ask, referencePrice) = _getQuote();
        if (bid == 0 || ask == type(uint128).max) revert FeedStalled();
    }

    // ── Staleness ───────────────────────────────────────────────────────

    /// @dev Pure staleness check. Any future refTime is stale.
    function _isStale(uint256 refTime, uint256 nowTs, uint256 maxDelta) internal pure returns (bool) {
        if (refTime == 0) return true;
        if (refTime > nowTs) return true;
        return (nowTs - refTime) > maxDelta;
    }

    // ── Oracle data helpers ──────────────────────────────────────────────

    /// @dev Full-precision shaped quote in Q64. The confidence spread multiplies the mid BEFORE the
    ///      single division, so a sub-8-decimal-quantum confidence fee is never floored away
    ///      (the earlier `delta = mid * confidence / CONFIDENCE_BASE` collapsed to 0 for low-priced
    ///      feeds, e.g. mid = 299, silently dropping the whole confidence spread). The marginStep step
    ///      factors and the 8-dec→Q64 conversion fold into the same Math.mulDiv, exactly as
    ///      AnchoredPriceProvider._shapedQuote does. `n` = spread × confidenceParam (0.01-bps ×
    ///      multiplier units).
    ///
    ///      shapedDenom = STEP_DENOM × CONFIDENCE_BASE = (1e8 × 1e18) × 1e10 = 1e36. Numerator bound:
    ///      mid ≤ 2⁶⁴ and (CONFIDENCE_BASE + n) ≤ ~6e10 → mid·(CB+n) ≤ ~1.1e30; the 512-bit product with
    ///      Q64·stepFactor (< 3.6e37) is handled by Math.mulDiv. A bid that confidence pushes to ≤ 0
    ///      (n ≥ CONFIDENCE_BASE) returns 0 and trips the bid>0 halt in the caller.
    function _shapedQuote(uint256 mid, uint256 n) internal view returns (uint256 bidOut, uint256 askOut) {
        uint256 shapedDenom = STEP_DENOM * CONFIDENCE_BASE;
        uint256 bidNum = n >= CONFIDENCE_BASE ? 0 : mid * (CONFIDENCE_BASE - n);
        uint256 askNum = mid * (CONFIDENCE_BASE + n);
        bidOut = Math.mulDiv(bidNum, Q64 * stepBidFactor, shapedDenom, Math.Rounding.Floor);
        askOut = Math.mulDiv(askNum, Q64 * stepAskFactor, shapedDenom, Math.Rounding.Ceil);
    }

    // ── Price internals ─────────────────────────────────────────────────

    function _getQuote() internal returns (uint128, uint128, uint128) {
        // 1. Read via the unified price(feedId, pool) path, forwarding the pool (msg.sender).
        //    refTime is already in seconds.
        (uint256 mid, uint256 spread,, uint256 refTime) =
            IPricedOracle(address(offchainOracle)).price(offchainFeedId, msg.sender);

        // 2. Staleness check
        if (_isStale(refTime, block.timestamp, MAX_TIME_DELTA)) {
            return (0, type(uint128).max, 0);
        }

        // 3. Basic validity — price positive, feed not stalled, spread within the circuit breaker.
        //    A genuine wide spread (below MAX_SPREAD_BPS) is NOT halted: it widens the band in step 5.
        if (mid == 0 || spread == STALL_SPREAD || spread > MAX_SPREAD_BPS) {
            return (0, type(uint128).max, 0);
        }

        // 4. Price guard check (guard values are stored on the oracle, enforced here)
        (uint128 guardMin, uint128 guardMax) = offchainOracle.priceGuard(offchainFeedId);
        guardMax = guardMax == 0 ? type(uint128).max : guardMax;
        if (mid < guardMin || mid > guardMax) {
            return (0, type(uint128).max, 0);
        }

        // 5. Full-precision shaped quote (Q64): the confidence-adjusted spread is folded into the single
        //    division rather than floored to an 8-decimal delta first (a sub-quantum confidence fee no
        //    longer collapses to 0 on a low-priced feed). confidenceParam 0 → no spread.
        uint256 n = spread * confidenceParam;
        (uint256 bidOut, uint256 askOut) = _shapedQuote(mid, n);

        //    Fail closed on a quote that is INVERTED before the quantum covers below. A negative
        //    marginStep large enough to swallow the confidence spread produces bid > ask, which is a
        //    misconfiguration, not a quote — and it must keep halting. The check has to happen HERE:
        //    the cover lifts the ask to at least `mid + 1` while the bid stays <= `mid`, so it would silently
        //    un-invert such a config into a one-quantum band with effectively no spread, which is
        //    strictly worse than refusing to quote. Strict `>` deliberately: with confidence 0 and
        //    marginStep 0 a round mid gives bid == ask (floor == ceil), and that degenerate-but-not-
        //    inverted case is exactly what the covers exist to widen.
        if (bidOut > askOut) {
            return (0, type(uint128).max, 0);
        }

        // 6. E8 quantization cover. The oracle mid is floored onto the 8-dec grid, so the true price T
        //    obeys mid <= T < mid + 1 and the configured interval's upper edge is (mid + 1)·(1 + rel),
        //    rel = spread·confidence/CONFIDENCE_BASE. Re-derive the ask from the honest upper bound
        //    (mid + 1) with the FULL shaping factor (1 + rel)·stepAskFactor, so quantization and the
        //    confidence spread compound. Taking the wider of the shaped ask mid·(1 + rel)·step and a
        //    bare (mid + 1)·step instead undercovers whenever mid·m < 1 and m < rel (m = marginStep):
        //    a cheap feed whose marginStep bias is below one quantum and below the confidence spread
        //    (a $0.000001 token at 1% spread, 1× confidence and 1 bps marginStep quoted ~0.9% under
        //    the upstream ask). The bid stays floored-conservative (bid <= mid <= T); the inversion
        //    guard above still runs on the pre-cover shaped pair, so the extra quantum cannot mask an
        //    inverted config.
        //
        //    Caveat on the premise: `mid <= T < mid + 1` is the grid of the PRICED oracles
        //    (Pyth / Chainlink), which store a plain 8-decimal integer. CompressedOracleV1 stores a
        //    U64x32 pseudo-float (27-bit mantissa / 5-bit exponent), so its representable step is
        //    2^e quanta — 65_536 of them at BTC scale, not 1 — and one quantum does not cover its
        //    rounding. The shortfall is bounded by the 2^-27 relative mantissa precision, far below
        //    any realistic spread, so this is a precision note rather than a live gap — but the
        //    inequality above is not literally true for a compressed feed.
        //
        //    The marginStep bias may only ever push this bound UP. stepAskFactor is BPS_BASE_U +
        //    marginStep, so a NEGATIVE marginStep narrows the confidence widening (as designed), but
        //    an unfloored factor would scale the bound BELOW (mid + 1) — ASK >= T would break exactly
        //    where the cover is supposed to hold, and the pool would buy token0 out of LP inventory
        //    above the true price. Flooring the combined factor at 1× (CONFIDENCE_BASE·BPS_BASE_U on
        //    its own scale) keeps the positive-bias widening (conservative for LPs) while making
        //    (mid + 1) a hard lower bound on the ask for ANY marginStep sign.
        //
        //    Bounds: (CONFIDENCE_BASE + n) ≤ ~6e10 and stepAskFactor < 2e18 → coverFactor < 1.2e29;
        //    Q64·coverFactor < 2.3e48 fits uint256, and the 512-bit product with (mid + 1) is handled
        //    by Math.mulDiv over the positive denominator STEP_DENOM·CONFIDENCE_BASE = 1e36.
        uint256 coverFactor = Math.max((CONFIDENCE_BASE + n) * stepAskFactor, CONFIDENCE_BASE * BPS_BASE_U);
        askOut = Math.mulDiv(mid + 1, Q64 * coverFactor, STEP_DENOM * CONFIDENCE_BASE, Math.Rounding.Ceil);

        //    No mirror cap is needed on the bid. `stepBidFactor` is BPS_BASE_U − marginStep, so a
        //    negative marginStep does scale the bid up — but `bid > mid` requires
        //    m > rel/(1 − rel) > rel (m = |marginStep|, rel = spread·confidence/CONFIDENCE_BASE),
        //    and m > rel is exactly the inversion condition already rejected above. So BID <= mid <= T
        //    holds for every quote that survives that guard, and an explicit cap here would be dead code.

        // 7. Validity + hard invariant: bid must be strictly less than ask. bidOut == 0 when confidence
        //    eats the whole bid (n >= CONFIDENCE_BASE), or marginStep < 0 tightens it past the ask.
        if (bidOut == 0 || bidOut > type(uint128).max || askOut > type(uint128).max || bidOut >= askOut) {
            return (0, type(uint128).max, 0);
        }

        // 8. The reported reference: the oracle mid on the same Q64 scale, floored. Every shaping
        //    factor is applied around this value, so it is the fee base the consumer is owed.
        //
        //    BID <= ref: the bid factors are (CONFIDENCE_BASE − n)/CONFIDENCE_BASE ≤ 1 and
        //    stepBidFactor/BPS_BASE_U, and step 6's note proves the only way their product exceeds 1
        //    is the inversion the guard above already rejected — so the floored bid cannot exceed the
        //    floored mid. ref <= ASK: the cover in step 6 set the ask to
        //    ceil((mid + 1)·Q64·coverFactor / (STEP_DENOM·CONFIDENCE_BASE)) with coverFactor >=
        //    CONFIDENCE_BASE·BPS_BASE_U, i.e. at least ceil((mid + 1)·Q64/1e8), strictly above
        //    floor(mid·Q64/1e8).
        uint256 refOut = Math.mulDiv(mid, Q64, ORACLE_DECIMALS, Math.Rounding.Floor);

        //    DEFENCE IN DEPTH — unreachable per the proof above, and deliberately kept: this is the
        //    invariant the consumer reverts on, so if a future change to the shaping ever breaks it,
        //    the feed must halt rather than hand the pool a quote it will reject mid-swap.
        if (refOut < bidOut || refOut > askOut) {
            return (0, type(uint128).max, 0);
        }

        return (uint128(bidOut), uint128(askOut), uint128(refOut));
    }
}
