// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IOffchainOracle} from "./interfaces/IOffchainOracle.sol";
import {IPricedOracle} from "./interfaces/IPricedOracle.sol";
import {IAnchorSource} from "./interfaces/IAnchorSource.sol";
import {IPriceProvider} from "./interfaces/IPriceProvider.sol";
import {IAnchoredProviderFactory} from "./interfaces/IAnchoredProviderFactory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Anchored Price Provider (APP) — the one standard provider for public pools. Every quote is
///         clamped to the reference band derived from the anchor oracle's own uncertainty:
///
///             bid = min(refBid, custom_bid)
///             ask = max(refAsk, custom_ask)
///
///         Single-feed reference: mid ± mid·(multiplied spread + minMargin). Synthetic reference:
///         base low / quote high and base high / quote low, with an additive mid·minMargin per side.
///
///         Two modes, one contract:
///         - Reference mode (source = 0, default): quotes the reference interval directly.
///         - Source mode: an arbitrary curator contract supplies bid/ask, clipped into the band.
///           The reference bounds how TIGHT it may quote — a source can never quote inside the
///           oracle's own uncertainty to extract LP value. Widening is NOT bounded: the pool will
///           quote arbitrarily far outside the band if the source says so. That is reachable with
///           nobody malicious — an honest source reading a venue an outsider can move hands that
///           outsider the pool's price. Accepted deliberately: the outward side is the OPERATOR's
///           due diligence, so treat a source as trusted and the clamp as protection in ONE
///           direction only.
///
///         The third output, referencePrice, is the anchor's own mid and is NOT shapeable: no source,
///         confidence, marginStep or spread multiplier touches it. Consumers charge their fee from
///         that value out to whichever edge executes, so widening a quote only worsens the widener's
///         own execution — it cannot inflate the fee base. That is what keeps an instant source swap
///         economically harmless; see _computeBidAsk.
///
///         Clamp parameters (minMargin, MAX_REF_STALENESS) and the reference binding are immutable;
///         the source pointer is instantly swappable (no timelock needed: any source is clamp-bounded
///         at all times). No proxies — upgrades are new deployments.
///
///         Two deployment variants, selected by the immutable MUTABLE_PARAMS flag:
///         - Immutable (false): nothing is tunable except the source pointer.
///         - Customizable (true): the curator may additionally tune confidenceParam; a fixed marginStep
///           bias is set at construction (immutable). For the SHAPED quote — and unlike the source
///           path above, which is bounded on both edges — the guarantee is one-directional: the final
///           quote is never TIGHTER than the multiplied reference interval plus minMargin, and nothing caps
///           how far it may widen. Note the multiplied spread: a sub-1× per-leg multiplier tightens
///           that term, so minMargin (required positive) is the only part no live knob can move.
///           Confidence is clipped to the band edge on the tight side, but a LARGE confidence widens
///           the shaped quote past the band and the clamp lets that through (see
///           testConfidenceMaxWidensBeyondBand) — "confidence only ever tightens" is false. A positive
///           marginStep likewise widens BEYOND the band. That asymmetry is deliberate: both shaping
///           inputs are factory-bounded values chosen by the provider owner, whereas a source is
///           arbitrary external code. With confidence 0 and marginStep 0 the shaped quote degenerates
///           to the band edges — behaviorally identical to the immutable variant.
///
///         Reads go through the access-gated providers oracle (Pyth / Chainlink), exclusively via
///         the attributed, non-view `price(feedId, pool)` path: the pool marks itself in-swap with
///         this provider and calls `getQuote()` (no args); this provider forwards the pool
///         (its `msg.sender`) to the oracle, which binds the read via `pool.inSwap() == provider`.
contract AnchoredPriceProvider is IPriceProvider {
    string public constant version = "1.1.0";

    // ── Constants ────────────────────────────────────────────────────────
    uint256 internal constant Q64 = 1 << 64;

    uint256 internal constant ORACLE_DECIMALS = 1e8;
    uint256 public constant BPS_BASE_U = 1e18;
    int256 public constant BPS_BASE = int256(BPS_BASE_U);
    uint16 internal constant ORACLE_BPS = 10_000;
    /// @dev Pyth/Chainlink saturate at 65534; the true uncertainty is then unknown. Reject that
    ///      value and the 65535 stall sentinel on EACH leg, before any spread multiplier is applied.
    ///      This also rejects an honest spread rounded to exactly 65534, conservatively.
    uint16 internal constant SATURATED_SPREAD = type(uint16).max - 1;
    /// @dev Oracle spread0 is in 0.01-bps units (fraction × 1e6),
    ///      matching the priced oracles (Pyth/Chainlink) and the compressed codebook. `minMargin` is
    ///      BPS_BASE_U-scale. One spread unit (0.01 bps) = 1e12 in BPS_BASE_U (1e18) scale.
    uint256 internal constant ONE_SPREAD_UNIT_E18 = 1e12;

    uint256 public constant CONFIDENCE_COOLDOWN = 1 minutes;
    uint256 public constant CONFIDENCE_MAX = 1_000_000; // 100x multiplier
    uint256 internal constant CONFIDENCE_BASE = 1e10; // 1e6 (0.01 bps) × 10_000 (multiplier base)

    /// @dev Gas forwarded to the source staticcall — bounds gas-griefing; OOG fails closed.
    uint256 public constant SOURCE_GAS_LIMIT = 500_000;

    // ── Immutables ──────────────────────────────────────────────────────
    IOffchainOracle public immutable offchainOracle;
    bytes32 public immutable baseFeedId;
    /// @notice Optional second feed for synthetic ratio quoting; zero = single-feed (no conversion).
    ///         Synthetic mid = price(baseFeedId) / price(quoteFeedId), e.g. BTC/USD ÷ ETH/USD = BTC/ETH.
    bytes32 public immutable quoteFeedId;
    /// @dev anchor factory (governs setSource), NOT the AMM pool factory passed at read.
    address public immutable factory;

    /// @notice Per-side minimum margin on top of the reference spread, BPS_BASE_U scale (1 bps = 1e14).
    uint256 public immutable minMargin;
    /// @notice Reference older than this (seconds) halts quoting — never clamp to a stale anchor.
    ///         Zero means the reference must be in the current block (refTime == block.timestamp).
    uint256 public immutable MAX_REF_STALENESS;
    /// @notice Hard ceiling for the per-leg spread multipliers (BPS_BASE_U scale, 1e18 = 1.0×).
    ///         Bounds how far a live multiplier can WIDEN the band. >= BPS_BASE_U so the 1.0×
    ///         default is always in range. A band whose upper relative deviation reaches 100% fails closed at
    ///         read time (upper relative deviation plus minMargin >= 100%), not at construction.
    uint256 public immutable maxSpreadMult;

    address public immutable baseToken;
    address public immutable quoteToken;

    /// @notice Variant flag: false = fully immutable (source swap only), true = the quote-shaping
    ///         knobs below are tunable through the factory. The band params stay immutable either way.
    bool public immutable MUTABLE_PARAMS;

    // ── Storage ─────────────────────────────────────────────────────────
    /// @notice Custom quote source; zero = reference mode.
    address public source;

    // ── Knobs (tunable only when MUTABLE_PARAMS; the immutable variant keeps the construction
    //    defaults forever AND never SLOADs them — the reads are gated behind MUTABLE_PARAMS). ─
    uint256 public confidenceParam;
    uint256 public lastConfidenceUpdate;

    /// @notice Per-leg reference staleness (seconds): the base and quote feeds each have their own
    ///         freshness bound. Default = MAX_REF_STALENESS (identical to the single-bound behavior
    ///         until tuned); a setter may only tighten them to <= MAX_REF_STALENESS (the hard cap).
    uint256 public baseMaxStaleness;
    uint256 public quoteMaxStaleness;
    uint256 public lastStalenessUpdate;

    /// @notice Per-leg spread multiplier (BPS_BASE_U scale, 1e18 = 1.0×): scales each leg's oracle
    ///         spread when forming the reference band. Default = 1.0×. May tighten (< 1×) or widen
    ///         (up to maxSpreadMult) the band. The immutable minMargin remains the absolute
    ///         half-width floor, so the band can never fully collapse regardless of these.
    uint256 public baseSpreadMult;
    uint256 public quoteSpreadMult;
    uint256 public lastSpreadMultUpdate;

    /// @dev marginStep bias and its derived step factors for the shaped reference quote — all set once
    ///      at construction (immutable). Effective only in the customizable variant (the immutable variant
    ///      quotes the band directly). marginStep can widen OR — for negative values — tighten/invert the
    ///      PRE-clamp shaped quote; what keeps the FINAL quote no tighter than the audited band, for ANY
    ///      marginStep sign, is the load-bearing band clamp in _computeBidAsk (min/max vs refBid/refAsk)
    ///      plus the bidOut>=askOut halt and Floor/Ceil rounding — NOT any monotonicity of marginStep.
    ///      That clamp is why marginStep needs no factory envelope bound; it must never be removed.
    int256 public immutable marginStep;
    uint256 internal immutable stepBidFactor; // BPS_BASE_U - marginStep
    uint256 internal immutable stepAskFactor; // BPS_BASE_U + marginStep

    // ── Events / Errors ─────────────────────────────────────────────────
    event SourceSet(address indexed source);
    event ConfidenceParamSet(uint256 indexed newValue);
    event MaxStalenessSet(uint256 baseMaxStaleness, uint256 quoteMaxStaleness);
    event SpreadMultipliersSet(uint256 baseSpreadMult, uint256 quoteSpreadMult);

    error OnlyFactory();
    error FeedStalled();
    error MaxRefStalenessOutOfBounds();
    error MaxSpreadMultOutOfBounds();
    error MinMarginZero();
    error ImmutableProvider();
    error ConfidenceParamOutOfBounds();
    error SpreadMultOutOfBounds();
    error StalenessOutOfBounds();
    error MarginStepOutOfBounds();
    error CooldownNotElapsed();

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(
        address _factory,
        address _oracle,
        bytes32 _baseFeedId,
        bytes32 _quoteFeedId,
        uint256 _minMargin,
        uint256 _maxRefStaleness,
        uint256 _maxSpreadMult,
        bool _mutableParams,
        int256 _marginStep,
        address _baseToken,
        address _quoteToken,
        IAnchoredProviderFactory.InitialConfig memory _init
    ) {
        require(_factory != address(0));
        factory = _factory;

        offchainOracle = IOffchainOracle(_oracle);
        baseFeedId = _baseFeedId;
        quoteFeedId = _quoteFeedId;

        // Tokens live ONLY here (the oracles are token-free): the pair is an explicit,
        // mandatory input — including the synthetic (two-feed) mode, where the factory
        // knows the pair when it creates the pool.
        require(_baseToken != address(0) && _quoteToken != address(0) && _baseToken != _quoteToken);
        baseToken = _baseToken;
        quoteToken = _quoteToken;

        if (_maxRefStaleness > 7 days) revert MaxRefStalenessOutOfBounds(); // 0 allowed = same-block reference
        MAX_REF_STALENESS = _maxRefStaleness;

        // Spread-multiplier ceiling. Must be >= 1.0× so the 1.0× default is in range (a multiplier
        // may tighten below 1× at runtime, but the CEILING bounds how far it can WIDEN the band).
        if (_maxSpreadMult < BPS_BASE_U) revert MaxSpreadMultOutOfBounds();
        maxSpreadMult = _maxSpreadMult;

        // minMargin must be strictly positive. The `refBid >= refAsk` halt in _computeBidAsk is not
        // a sufficient safety net on its own: it only fires on an EXACTLY collapsed band, and with
        // minMargin == 0 and spreadBps == 1 the band is ~0.0001% wide, passes every guard, and the
        // provider still reports `isProvider() == true` — the audited "never tighter than
        // mid ± (spreadBps + minMargin)" floor would be satisfiable by a band of essentially zero
        // width. A positive minMargin is the only term that does not depend on the oracle's spread.
        if (_minMargin == 0) revert MinMarginZero();
        // Band-width checks run at read time: reject saturated legs, nonpositive interval edges,
        // and an upper relative deviation plus minMargin reaching 100%.
        minMargin = _minMargin;

        // Initial config (source + per-leg staleness + per-leg multipliers), applied through the SAME
        // internal helpers the post-deploy setters use — one validated path (StalenessOutOfBounds /
        // SpreadMultOutOfBounds against the immutables set just above). Applies to BOTH variants: for
        // the immutable variant these become the permanent values (no setters); pass
        // {source:0, maxRefStaleness, maxRefStaleness, 1e18, 1e18} for the plain 1.0×/shared-staleness default.
        _applySource(_init.source);
        _applyStaleness(_init.baseMaxStaleness, _init.quoteMaxStaleness);
        _applySpreadMultipliers(_init.baseSpreadMult, _init.quoteSpreadMult);

        MUTABLE_PARAMS = _mutableParams;
        // marginStep bias + derived step factors (immutable). The customizable variant shapes the quote
        // with confidence then this fixed bias; the load-bearing band clamp in _computeBidAsk keeps the
        // final quote no tighter than the band edge for ANY marginStep sign (a negative value tightens or
        // inverts the pre-clamp quote; the clamp neutralizes it). The immutable variant ignores them.
        if (_marginStep <= -BPS_BASE || _marginStep >= BPS_BASE) revert MarginStepOutOfBounds();
        marginStep = _marginStep;
        stepBidFactor = uint256(BPS_BASE - _marginStep);
        stepAskFactor = uint256(BPS_BASE + _marginStep);
    }

    // ── Factory ──────────────────────────────────────────────────────────

    /// @notice Swap the custom source (zero → reference mode). Instant: the band bounds any source
    ///         at all times, so no timelock is needed inside the APP.
    function setSource(address newSource) external {
        require(msg.sender == factory, OnlyFactory());
        _applySource(newSource);
    }

    // ── Shared apply logic (constructor + the factory-gated setters call these) ─────────
    // Validate + store + emit; no access/cooldown gates here — the public setters add those.

    function _applySource(address newSource) internal {
        source = newSource;
        emit SourceSet(newSource);
    }

    function _applyStaleness(uint256 newBase, uint256 newQuote) internal {
        // Each leg's bound may only be <= MAX_REF_STALENESS (the immutable, envelope-bound hard cap):
        // no knob — construction or live — can accept a staler reference than the audited ceiling.
        if (newBase > MAX_REF_STALENESS || newQuote > MAX_REF_STALENESS) revert StalenessOutOfBounds();
        baseMaxStaleness = newBase;
        quoteMaxStaleness = newQuote;
        emit MaxStalenessSet(newBase, newQuote);
    }

    function _applySpreadMultipliers(uint256 newBase, uint256 newQuote) internal {
        // Each may be < 1× (tighten) or up to maxSpreadMult (widen). Saturation is checked on the
        // raw spread before multiplication; nonpositive or oversized reference intervals halt.
        if (newBase > maxSpreadMult || newQuote > maxSpreadMult) revert SpreadMultOutOfBounds();
        baseSpreadMult = newBase;
        quoteSpreadMult = newQuote;
        emit SpreadMultipliersSet(newBase, newQuote);
    }

    // ── Factory: quote-shaping knobs (customizable variant only) ─────────

    function setConfidenceParam(uint256 newValue) external override {
        require(msg.sender == factory, OnlyFactory());
        if (!MUTABLE_PARAMS) revert ImmutableProvider();
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

    /// @notice Set the per-leg reference staleness bounds (seconds). Each may only be TIGHTENED to
    ///         <= MAX_REF_STALENESS (the immutable, envelope-bound hard cap) — a live knob can never
    ///         accept a staler reference than the audited ceiling. Cooldown-rate-limited.
    function setMaxStaleness(uint256 newBase, uint256 newQuote) external {
        require(msg.sender == factory, OnlyFactory());
        if (!MUTABLE_PARAMS) revert ImmutableProvider();
        if (block.timestamp < lastStalenessUpdate + CONFIDENCE_COOLDOWN) revert CooldownNotElapsed();

        _applyStaleness(newBase, newQuote);
        lastStalenessUpdate = block.timestamp;
    }

    /// @notice Set the per-leg spread multipliers (BPS_BASE_U scale, 1e18 = 1.0×). Each may be below
    ///         1× (tighten) or up to maxSpreadMult (widen). Saturation remains a raw per-leg check;
    ///         invalid resulting reference intervals halt at read time. Cooldown-limited.
    function setSpreadMultipliers(uint256 newBase, uint256 newQuote) external {
        require(msg.sender == factory, OnlyFactory());
        if (!MUTABLE_PARAMS) revert ImmutableProvider();
        if (block.timestamp < lastSpreadMultUpdate + CONFIDENCE_COOLDOWN) revert CooldownNotElapsed();

        _applySpreadMultipliers(newBase, newQuote);
        lastSpreadMultUpdate = block.timestamp;
    }

    // ── External reads ───────────────────────────────────────────────────
    function token0() external view override returns (address) {
        return baseToken;
    }

    function token1() external view override returns (address) {
        return quoteToken;
    }

    /// @notice Attributed swap-time read. Called (no args) by the pool, which has marked itself in-swap
    ///         with this provider. Forwards the pool (`msg.sender`) to `oracle.price(feedId, pool)` so
    ///         the read is attributed to the pool and recorded by the oracle's event.
    /// @dev    `referencePrice` is the ANCHOR's own mid — see _computeBidAsk. It is never taken from a
    ///         source, so `bid <= referencePrice <= ask` holds by construction and no source swap can
    ///         move the fee base the consumer charges against.
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

    // ── Core math ───────────────────────────────────────────────────────

    /// @dev Applies the band edge factor to a mid expressed as the exact ratio `num / den`, converting
    ///      to Q64 in a single division. The synthetic cross is NEVER materialised as an 8-decimal
    ///      integer (which would floor away most of a low cross ratio); it is carried as (num, den) and
    ///      divided out only here, so the sole rounding is the ~2⁻⁶⁴ Q64 quantisation.
    ///
    ///      Single-feed: (num, den) = (mid, ORACLE_DECIMALS) → den·BPS_BASE_U = ORACLE_DECIMALS·BPS_BASE_U,
    ///      i.e. the original 8-decimal→Q64 conversion, byte-identical.
    ///      Synthetic: (num, den) = (mid1, mid2) → exact cross with no intermediate truncation.
    ///
    ///      Numerator upper bounds: Q64 ≈ 1.8e19, edgeFactor < 2e18 → max ≈ 3.6e37, fits uint256; the
    ///      512-bit product with `num` is handled by Math.mulDiv. `den` is always > 0 (mid2 == 0 halts
    ///      the read; ORACLE_DECIMALS is a nonzero constant).
    ///
    ///      `den` bound, by caller: from _computeBidAsk it is a raw mid, so den·BPS_BASE_U ≲ 1.8e37
    ///      (uint64 mid). From _shapedQuote it is `den · CONFIDENCE_BASE` (1e10), i.e. up to ~1.8e47 —
    ///      still far inside uint256, and the denominator argument of mulDiv never overflows since it
    ///      is a plain multiplication of two bounded uint256 values.
    ///
    /// @param  num        Mid numerator (base 8-decimal price)
    /// @param  den        Mid denominator (ORACLE_DECIMALS single-feed, quote 8-decimal price synthetic)
    /// @param  edgeFactor BPS_BASE_U − half (bid edge) or BPS_BASE_U + half (ask edge)
    /// @param  rounding   Floor for bid (down), Ceil for ask (up)
    function _bandEdge(uint256 num, uint256 den, uint256 edgeFactor, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(num, Q64 * edgeFactor, den * BPS_BASE_U, rounding);
    }

    // ── Price internals ─────────────────────────────────────────────────

    /// @dev Reads via the oracle's non-view, attributed `price(feedId, pool)` (emits PriceRead),
    ///      forwarding `msg.sender` (the pool). Single-feed: the anchor mid directly. Synthetic
    ///      (quoteFeedId set): the ratio price(baseFeedId)/price(quoteFeedId) — the shared quote
    ///      cancels (e.g. BTC/USD ÷ ETH/USD = BTC/ETH). Reference edges divide the opposing leg
    ///      interval bounds; the raw spread sum is retained only for the optional shaped quote.
    function _getQuote() internal returns (uint128, uint128, uint128) {
        // Per-leg knobs (staleness + multiplier) are read from storage for BOTH variants: they are
        // set at construction, so the immutable variant may hold custom FIXED values too (not
        // just the 1.0×/shared default). A few extra SLOADs on top of the two external oracle reads
        // per leg is negligible.
        (uint256 mid, uint256 spreadBps,, bool ok) = _readLeg(baseFeedId, baseMaxStaleness);
        if (!ok) return (0, type(uint128).max, 0);

        // Band half-width contribution (BPS_BASE_U scale): the leg's oracle spread scaled by its
        // multiplier. Ceil so rounding only ever WIDENS the band (conservative).
        uint256 baseHalf = _scaledHalf(spreadBps, baseSpreadMult);
        uint256 quoteHalf;

        // Mid as the exact ratio midNum / midDen. Single-feed: den = ORACLE_DECIMALS (mid is the
        // 8-decimal anchor). Synthetic: den = mid2, so the cross mid1/mid2 is carried at full precision
        // and divided out only inside the band edge — never floored to an 8-decimal integer (which would
        // wipe out most of a low cross ratio, e.g. a cheap base token quoted in an expensive one).
        uint256 midNum = mid;
        uint256 midDen = ORACLE_DECIMALS;

        bytes32 _quote = quoteFeedId;
        if (_quote != bytes32(0)) {
            (uint256 mid2, uint256 spreadBps2,, bool ok2) = _readLeg(_quote, quoteMaxStaleness);
            if (!ok2 || mid2 == 0) return (0, type(uint128).max, 0);
            // Synthetic ratio: keep the two relative uncertainties separate for interval division.
            //
            // The quote currencies cancelling is an ASSUMPTION, enforced nowhere on-chain. Nothing
            // here, in the factory (whose envelope is keyed on baseFeedId alone), or in the pool checks
            // that the two legs share a denominator — so a misconfigured pair such as BTC/USD ÷ EUR/USD
            // produces a confident, tightly-banded, completely meaningless cross that passes every
            // guard in this contract. Choosing two legs that actually share a quote currency is the
            // deployer's responsibility and part of the LP's diligence before depositing; there is no
            // on-chain backstop for getting it wrong.
            midDen = mid2;
            spreadBps += spreadBps2;
            quoteHalf = _scaledHalf(spreadBps2, quoteSpreadMult);
        }

        return _computeBidAsk(midNum, midDen, spreadBps, baseHalf, quoteHalf, _quote != bytes32(0));
    }

    /// @dev One leg's band half-width contribution: `legSpreadBps · ONE_SPREAD_UNIT_E18 · mult / BPS_BASE_U`,
    ///      rounded UP (a larger band is the safe direction).
    function _scaledHalf(uint256 legSpreadBps, uint256 mult) internal pure returns (uint256) {
        return Math.mulDiv(legSpreadBps * ONE_SPREAD_UNIT_E18, mult, BPS_BASE_U, Math.Rounding.Ceil);
    }

    /// @dev Reads one feed and runs its per-leg guards. ok=false (→ caller halts, fail closed) on:
    ///      stale reference, mid == 0, saturated/stalled spread, or a priceGuard violation.
    ///      Each leg is read through the attributed path independently.
    function _readLeg(bytes32 feedId, uint256 maxStaleness)
        internal
        returns (uint256 mid, uint256 spreadBps, uint256 refTime, bool ok)
    {
        (mid, spreadBps,, refTime) = IPricedOracle(address(offchainOracle)).price(feedId, msg.sender);

        // Stale reference → not ok (per-leg bound). Clamping to a stale anchor is the one false-safety case.
        if (_isStale(refTime, block.timestamp, maxStaleness)) return (mid, spreadBps, refTime, false);

        // Saturation loses the upstream uncertainty. A zero or sub-unit multiplier must not turn
        // this unknown interval back into a live quote. Values above uint16 are rejected as well.
        if (mid == 0 || spreadBps >= SATURATED_SPREAD) return (mid, spreadBps, refTime, false);

        // Per-leg price guard.
        (uint128 guardMin, uint128 guardMax) = offchainOracle.priceGuard(feedId);
        guardMax = guardMax == 0 ? type(uint128).max : guardMax;
        if (mid < guardMin || mid > guardMax) return (mid, spreadBps, refTime, false);

        ok = true;
    }

    /// @dev Anchored band + optional source clamp over an already-validated leg read.
    ///      `spreadBps` is the raw spread sum, used only by the optional shaped quote;
    ///      `baseHalf` and `quoteHalf` are multiplied per-leg uncertainties (BPS_BASE_U scale).
    ///      Returns the (0, max, 0) sentinel on any failure — fail closed, withdrawals unaffected.
    ///
    ///      The third return is the reported referencePrice: the ANCHOR's own mid, carried at full
    ///      precision as `midNum / midDen` and divided out once here. It is deliberately independent
    ///      of every quote-shaping input — source, confidence, marginStep, spread multipliers — because
    ///      the consumer charges its fee from this value to the edge being executed. A source that
    ///      widens its quote therefore worsens its own execution price without moving the fee base,
    ///      and `setSource` (instant, by design) cannot touch it at all.
    function _computeBidAsk(
        uint256 midNum,
        uint256 midDen,
        uint256 spreadBps,
        uint256 baseHalf,
        uint256 quoteHalf,
        bool synthetic
    ) internal view returns (uint128, uint128, uint128) {
        // Check each term before adding/subtracting: even arbitrarily large configured multipliers
        // or margins must halt without arithmetic overflow or a nonpositive denominator.
        if (baseHalf >= BPS_BASE_U || quoteHalf >= BPS_BASE_U || minMargin >= BPS_BASE_U) {
            return (0, type(uint128).max, 0);
        }

        // For a ratio, the upper relative deviation is (baseHalf + quoteHalf)/(1 - quoteHalf).
        // Preserve the 100% upper-band guard using the actual interval, rather than its linear sum.
        uint256 askHalf = synthetic
            ? Math.mulDiv(baseHalf + quoteHalf, BPS_BASE_U, BPS_BASE_U - quoteHalf, Math.Rounding.Ceil)
            : baseHalf;
        if (askHalf >= BPS_BASE_U - minMargin) return (0, type(uint128).max, 0);

        uint256 refBid;
        uint256 refAsk;
        if (synthetic) {
            // Divide opposing interval edges, including each E8 mid's [mid, mid+1) quantum.
            // Products are bounded by uint64 mids and factors < 2e18; denominators are positive.
            refBid = Math.mulDiv(midNum, Q64 * (BPS_BASE_U - baseHalf), (midDen + 1) * (BPS_BASE_U + quoteHalf));
            refAsk = Math.mulDiv(
                midNum + 1, Q64 * (BPS_BASE_U + baseHalf), midDen * (BPS_BASE_U - quoteHalf), Math.Rounding.Ceil
            );
            // minMargin is additive relative to the anchor mid, once per side. Round its Q64
            // amount up so subtraction lowers the bid and addition raises the ask conservatively.
            uint256 margin = _bandEdge(midNum, midDen, minMargin, Math.Rounding.Ceil);
            if (refBid <= margin) return (0, type(uint128).max, 0);
            refBid -= margin;
            refAsk += margin;
        } else {
            uint256 half = baseHalf + minMargin;
            refBid = _bandEdge(midNum, midDen, BPS_BASE_U - half, Math.Rounding.Floor);
            refAsk = _bandEdge(midNum, midDen, BPS_BASE_U + half, Math.Rounding.Ceil);
        }
        // The reported reference: the anchor's own mid, `midNum / midDen` floored onto Q64. NOT the
        // geometric mean of the band edges, which depends on uncertainty and margin.
        uint256 refMid = _bandEdge(midNum, midDen, BPS_BASE_U, Math.Rounding.Floor);
        // Degenerate/zero band halts BEFORE the quantum cover — fail closed on a fully-collapsed band
        // (minMargin 0 AND spread 0), exactly as before; the cover must not resurrect it into a quote.
        if (refBid == 0 || refAsk > type(uint128).max || refBid >= refAsk) {
            return (0, type(uint128).max, 0);
        }

        // Single-feed E8 cover. The stored mid is floored onto the 8-decimal grid, so the true mid T
        // obeys mid <= T < mid + 1 and the upstream interval's upper edge is (mid + 1)·(1 + u). Apply
        // the uncertainty AND the margin to `midNum + 1` so quantization and uncertainty compound,
        // exactly as the synthetic edges above already do. Taking the wider of mid·(1 + u + m) and a
        // bare (mid + 1) instead undercovers whenever mid·m < 1 + u — a cheap feed with a sub-quantum
        // margin (a $0.000001 token at 1% uncertainty and 1 bps margin quoted ~0.9% under the
        // upstream ask). The result is never below the pre-cover edge, so refBid <= refMid < refAsk
        // holds in either mode and the clamp preserves this bracket.
        if (!synthetic) {
            refAsk = _bandEdge(midNum + 1, midDen, BPS_BASE_U + baseHalf + minMargin, Math.Rounding.Ceil);
        }
        if (refAsk > type(uint128).max) {
            return (0, type(uint128).max, 0);
        }

        // Custom quote: source (both variants) or shaped reference quote (customizable variant).
        //    Immutable reference mode quotes the band directly — zero knob SLOADs.
        address _source = source;
        uint256 cBid;
        uint256 cAsk;
        if (_source != address(0)) {
            // 7a. Source mode: any failure (revert, OOG, garbage, zero, inverted) halts — fail
            //     closed. Knobs do NOT post-process the source output (the source shapes itself).
            bool ok;
            (ok, cBid, cAsk) = _readSource(_source);
            if (!ok) {
                return (0, type(uint128).max, 0);
            }
            // NB: the source's own reference is validated in _readSource and then dropped — the
            //     reference this provider reports is always the anchor's.
        } else if (MUTABLE_PARAMS) {
            // 7b. Shaped reference quote: mid ± mid·spreadBps·confidence, then the marginStep step
            //     factors — PriceProvider semantics, clamped into the band below.
            bool ok;
            (ok, cBid, cAsk) = _shapedQuote(midNum, midDen, spreadBps);
            if (!ok) {
                return (0, type(uint128).max, 0);
            }
        } else {
            return (uint128(refBid), uint128(refAsk), uint128(refMid));
        }

        // 8. Clamp: out-of-band custom quotes are clipped silently to the band edge.
        //    bid ≤ refBid < refAsk ≤ ask, so bid < ask holds by construction.
        uint256 bidOut = Math.min(refBid, cBid);
        uint256 askOut = Math.max(refAsk, cAsk);

        if (bidOut == 0 || bidOut >= askOut) {
            return (0, type(uint128).max, 0);
        }

        return (uint128(bidOut), uint128(askOut), uint128(refMid));
    }

    /// @dev Shaped reference quote (customizable variant, reference mode). The pre-clamp quote is
    ///      mid·(1 ∓ spreadBps·confidence) scaled by the marginStep step factors. Like the reference
    ///      band, the mid is carried as the exact ratio `num / den` (den·CONFIDENCE_BASE folds the
    ///      confidence scaling into the single band-edge division), so the synthetic cross is never
    ///      floored to an 8-decimal integer. With confidenceParam == 0 the CONFIDENCE_BASE factor
    ///      cancels exactly and this reduces to the marginStep-only band edge.
    ///
    ///      Deliberately NO `sBid >= sAsk` pre-clamp halt: with knobs at 0 (confidence 0, marginStep 0)
    ///      and a round mid, floor == ceil gives sBid == sAsk, and the band clamp restores ordering —
    ///      that is exactly the immutable-variant identity. The `sAsk > uint128.max` check MUST stay
    ///      pre-clamp (mirrors `_readSource`'s srcAsk guard): truncating later would let an
    ///      overflowing ask wrap to a sub-band quote.
    function _shapedQuote(uint256 num, uint256 den, uint256 spreadBps)
        internal
        view
        returns (bool ok, uint256 sBid, uint256 sAsk)
    {
        // N = spreadBps·confidence (0.01-bps × multiplier units); the shaped mid is num·(CB ∓ N)/(den·CB).
        uint256 n = spreadBps * confidenceParam;
        uint256 shapedDen = den * CONFIDENCE_BASE;
        uint256 bidNum = n >= CONFIDENCE_BASE ? 0 : num * (CONFIDENCE_BASE - n);
        uint256 askNum = num * (CONFIDENCE_BASE + n);

        sBid = _bandEdge(bidNum, shapedDen, stepBidFactor, Math.Rounding.Floor);
        sAsk = _bandEdge(askNum, shapedDen, stepAskFactor, Math.Rounding.Ceil);
        if (sBid == 0 || sAsk > type(uint128).max) return (false, 0, 0);

        return (true, sBid, sAsk);
    }

    /// @dev Gas-bounded staticcall to the source. Tolerates any source behavior without reverting:
    ///      revert, out-of-gas, wrong returndata size, dirty words and uint128 overflow all report
    ///      failure instead. A pre-referencePrice source returning two words is a wrong size and so
    ///      halts — sources are versioned with the provider, not independently.
    ///
    ///      Uses a raw assembly staticcall into a fixed 96-byte buffer. A high-level
    ///      `(bool, bytes memory)` call would `returndatacopy` the source's ENTIRE returndata into
    ///      caller memory before any length check, charging the pool's swap for the copy + memory
    ///      expansion — a returndata bomb costs ~2× SOURCE_GAS_LIMIT on the caller side. Capping the
    ///      output at 96 bytes makes the caller-side cost O(96) regardless of returndatasize, so
    ///      SOURCE_GAS_LIMIT is the true griefing bound. returndatasize() is still read in full for
    ///      the exact-96 check (the bomb's extra bytes are discarded, not copied).
    function _readSource(address _source) internal view returns (bool ok, uint256 srcBid, uint256 srcAsk) {
        bytes4 sel = IAnchorSource.getQuote.selector;
        bool success;
        uint256 retSize;
        uint256 b;
        uint256 a;
        uint256 r;
        assembly ("memory-safe") {
            // Scratch beyond the free-memory pointer; never updated, so this is memory-safe.
            let ptr := mload(0x40)
            mstore(ptr, sel) // 4-byte selector, left-aligned
            // Input is consumed before output is written, so in/out may share ptr. Output is capped
            // at 0x60 bytes: a larger returndata is NOT copied (only returndatasize() reports it).
            success := staticcall(SOURCE_GAS_LIMIT, _source, ptr, 0x04, ptr, 0x60)
            retSize := returndatasize()
            b := mload(ptr)
            a := mload(add(ptr, 0x20))
            r := mload(add(ptr, 0x40))
        }
        if (!success || retSize != 96) return (false, 0, 0);

        srcBid = b;
        srcAsk = a;
        // The source's reference is required and range-checked — a source that cannot place its own
        // fair value inside its own quote is malformed, and this is the only place we can say so — but
        // the value is then DROPPED: the reference this provider reports is the anchor's mid, which is
        // what keeps an instant source swap away from the consumer's fee base.
        if (srcBid == 0 || srcBid >= srcAsk || srcAsk > type(uint128).max || r < srcBid || r > srcAsk) {
            return (false, 0, 0);
        }

        return (true, srcBid, srcAsk);
    }
}
