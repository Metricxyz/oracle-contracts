// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IOffchainOracle} from "./interfaces/IOffchainOracle.sol";
import {IPricedOracle} from "./interfaces/IPricedOracle.sol";
import {IAnchorSource} from "./interfaces/IAnchorSource.sol";
import {IPriceProvider} from "./interfaces/IPriceProvider.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";


/// @notice Anchored Price Provider (APP) — the one standard provider for public pools. Every quote is
///         clamped to the reference band derived from the anchor oracle's own uncertainty:
///
///             bid = min(mid − spreadBps − minMargin, custom_bid)
///             ask = max(mid + spreadBps + minMargin, custom_ask)
///
///         Two modes, one contract:
///         - Reference mode (source = 0, default): quotes mid ± (spreadBps + minMargin) directly.
///         - Source mode: an arbitrary curator contract supplies bid/ask, clipped into the band.
///           The source is never reviewed — the reference bounds how wrong it can be.
///
///         Clamp parameters (minMargin, MAX_REF_STALENESS, MAX_SPREAD_BPS) and the reference binding are immutable;
///         the source pointer is instantly swappable (no timelock needed: any source is clamp-bounded
///         at all times). No proxies — upgrades are new deployments.
///
///         Two deployment variants, selected by the immutable MUTABLE_PARAMS flag:
///         - Immutable (false): nothing is tunable except the source pointer.
///         - Customizable (true): the curator may additionally tune marginStep and confidenceParam.
///           The knobs shape the reference-mode quote INSIDE the band only: shaped quotes tighter than
///           mid ± (spreadBps + minMargin) are clipped to the band edges (the band edge is the most aggressive
///           quote allowed), so the audit-once band guarantee holds for both variants. With all knobs
///           at their defaults (confidence 0, marginStep 0) the shaped quote degenerates to the band
///           edges — behaviorally identical to the immutable variant.
///
///         Reads go through the abuse-protected providers oracle (Pyth / Chainlink), exclusively via
///         the attributed, non-view `price(feedId, pool)` path: the pool marks itself in-swap with
///         this provider and calls `getBidAndAskPrice()` (no args); this provider forwards the pool
///         (its `msg.sender`) to the oracle, which binds the read via `pool.inSwap() == provider`.
contract AnchoredPriceProvider is IPriceProvider {

    // ── Constants ────────────────────────────────────────────────────────
    uint256 internal constant Q64 = 1 << 64;

    uint256 internal constant ORACLE_DECIMALS = 1e8;
    uint256 public  constant BPS_BASE_U = 1e18;
    int256  public  constant BPS_BASE   = int256(BPS_BASE_U);
    uint16  internal constant ORACLE_BPS = 10_000;
    /// @dev Oracle spread/maxSpreadBps are whole bps; minMargin is BPS_BASE_U-scale. 1 bps = 1e14.
    uint256 internal constant ONE_BPS_E18 = 1e14;

    uint256 public  constant CONFIDENCE_COOLDOWN = 1 minutes;
    uint256 public  constant CONFIDENCE_MAX  = 1_000_000; // 100x multiplier
    uint256 internal constant CONFIDENCE_BASE = 1e10;     // 1e6 (0.01 bps) × 10_000 (multiplier base)

    /// @dev ORACLE_DECIMALS (1e8) * BPS_BASE (1e18) = 1e26.
    ///      Merges Q64/1e8 conversion and BPS_BASE division
    ///      into a single Math.mulDiv — one 512-bit division.
    uint256 internal constant STEP_DENOM = ORACLE_DECIMALS * BPS_BASE_U;

    /// @dev Gas forwarded to the source staticcall — bounds gas-griefing; OOG fails closed.
    uint256 public constant SOURCE_GAS_LIMIT = 500_000;

    // ── Immutables ──────────────────────────────────────────────────────
    IOffchainOracle public immutable offchainOracle;
    bytes32         public immutable baseFeedId;
    /// @notice Optional second feed for synthetic ratio quoting; zero = single-feed (no conversion).
    ///         Synthetic mid = price(baseFeedId) / price(quoteFeedId), e.g. BTC/USD ÷ ETH/USD = BTC/ETH.
    bytes32         public immutable quoteFeedId;
    /// @dev anchor factory (governs setSource), NOT the AMM pool factory passed at read.
    address         public immutable factory;

    /// @notice Per-side minimum margin on top of the reference spread, BPS_BASE_U scale (1 bps = 1e14).
    uint256 public immutable minMargin;
    /// @notice Reference older than this (seconds) halts quoting — never clamp to a stale anchor.
    uint256 public immutable MAX_REF_STALENESS;
    /// @notice Circuit breaker: reference uncertainty above this (bps) means the feed is broken — halt.
    ///         Below it, growing `spreadBps` only widens the band (widen, don't halt).
    uint16  public immutable MAX_SPREAD_BPS;

    address public immutable baseToken;
    address public immutable quoteToken;

    /// @notice Variant flag: false = fully immutable (source swap only), true = the quote-shaping
    ///         knobs below are tunable through the factory. The band params stay immutable either way.
    bool public immutable MUTABLE_PARAMS;

    // ── Storage ─────────────────────────────────────────────────────────
    /// @notice Custom quote source; zero = reference mode.
    address public source;

    // ── Knobs (active only when MUTABLE_PARAMS; zero-initialized otherwise) ─
    uint256 public confidenceParam;
    uint256 public lastConfidenceUpdate;

    /// @dev marginStep and step factors — mutable (debug, will be immutable in production)
    int256  public marginStep;
    uint256 internal stepBidFactor; // BPS_BASE_U - marginStep
    uint256 internal stepAskFactor; // BPS_BASE_U + marginStep

    // ── Events / Errors ─────────────────────────────────────────────────
    event SourceSet(address indexed source);
    event ConfidenceParamSet(uint256 indexed newValue);
    event MarginStepUpdated(int256 indexed newMarginStep);

    error OnlyFactory();
    error FeedStalled();
    error MinMarginZero();
    error MaxRefStalenessOutOfBounds();
    error MaxSpreadOutOfBounds();
    error BandTooWide();
    error ImmutableProvider();
    error ConfidenceParamOutOfBounds();
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
        uint16  _maxSpreadBps,
        bool    _mutableParams,
        address _baseTokenOverride,
        address _quoteTokenOverride
    ) {
        require(_factory != address(0));
        factory = _factory;

        offchainOracle = IOffchainOracle(_oracle);
        baseFeedId = _baseFeedId;
        quoteFeedId = _quoteFeedId;

        IOffchainOracle.OracleInfo memory info =
            offchainOracle.getOracleInfo(_baseFeedId);

        // Default quote token: single-feed → feed1's quote; synthetic → the ref feed's base (the
        // shared quote, e.g. USD, cancels in feed1/refFeed). getOracleInfo reverts FeedNotFound if
        // the ref feed is not registered, validating it at construction.
        address _defaultQuote = _quoteFeedId == bytes32(0)
            ? info.quoteToken
            : offchainOracle.getOracleInfo(_quoteFeedId).baseToken;

        address _baseToken  = _baseTokenOverride == address(0) ? info.baseToken : _baseTokenOverride;
        address _quoteToken = _quoteTokenOverride == address(0) ? _defaultQuote : _quoteTokenOverride;

        require(_baseToken != address(0) && _quoteToken != address(0));
        baseToken = _baseToken;
        quoteToken = _quoteToken;

        if (_maxRefStaleness == 0 || _maxRefStaleness > 7 days) revert MaxRefStalenessOutOfBounds();
        MAX_REF_STALENESS = _maxRefStaleness;

        if (_maxSpreadBps == 0 || _maxSpreadBps >= ORACLE_BPS) revert MaxSpreadOutOfBounds();
        MAX_SPREAD_BPS = _maxSpreadBps;

        // A zero minMargin lets the band collapse to 0 width when spreadBps == 0 (e.g. an open-market RWA
        // report writes spreadBps = 0), making the pool flap between a zero-margin quote and a halt. The
        // minMargin exists precisely to guarantee a minimum per-side margin, so it must be positive.
        if (_minMargin == 0) revert MinMarginZero();

        // Worst-case half-width must stay below 100% so the clamped bid is always positive.
        if (uint256(_maxSpreadBps) * ONE_BPS_E18 + _minMargin >= BPS_BASE_U) revert BandTooWide();
        minMargin = _minMargin;

        MUTABLE_PARAMS = _mutableParams;
        if (_mutableParams) {
            // Knob defaults reproduce the immutable variant's behavior exactly:
            // confidence 0 + identity step factors shape the quote to mid, which the band
            // clamp expands to the band edges.
            stepBidFactor = BPS_BASE_U;
            stepAskFactor = BPS_BASE_U;
        }
    }

    // ── Factory ──────────────────────────────────────────────────────────

    /// @notice Swap the custom source (zero → reference mode). Instant: the band bounds any source
    ///         at all times, so no timelock is needed inside the APP.
    function setSource(address newSource) external {
        require(msg.sender == factory, OnlyFactory());
        source = newSource;
        emit SourceSet(newSource);
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

    /// @dev DEBUG ONLY — will be removed before production deployment
    function setMarginStep(int256 _marginStep) external override {
        require(msg.sender == factory, OnlyFactory());
        if (!MUTABLE_PARAMS) revert ImmutableProvider();
        if (_marginStep <= -BPS_BASE || _marginStep >= BPS_BASE) {
            revert MarginStepOutOfBounds();
        }
        marginStep       = _marginStep;
        stepBidFactor = uint256(BPS_BASE - _marginStep);
        stepAskFactor = uint256(BPS_BASE + _marginStep);

        emit MarginStepUpdated(_marginStep);
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
    function getBidAndAskPrice() external override returns (uint128 bid, uint128 ask) {
        (bid, ask) = _getBidAndAskPrice();
        if (bid == 0 || ask == type(uint128).max) revert FeedStalled();
    }

    // ── Staleness ───────────────────────────────────────────────────────

    /// @dev Pure staleness check (L1). Any future refTime is stale.
    function _isStale(
        uint256 refTime,
        uint256 nowTs,
        uint256 maxDelta
    ) internal pure returns (bool) {
        if (refTime == 0) return true;
        if (refTime > nowTs) return true;
        return (nowTs - refTime) > maxDelta;
    }

    // ── Core math ───────────────────────────────────────────────────────

    /// @dev Converts the 8-decimal oracle mid to Q64 and applies the band edge factor.
    ///
    ///      Numerator upper bounds:
    ///      Q64 ≈ 1.8e19, edgeFactor < 2e18
    ///      → max numerator ≈ 3.6e37, fits uint256.
    ///      The 512-bit product with `mid` is handled by Math.mulDiv.
    ///
    /// @param  mid        Oracle mid price (8-decimal)
    /// @param  edgeFactor BPS_BASE_U − half (bid edge) or BPS_BASE_U + half (ask edge)
    /// @param  rounding   Floor for bid (down), Ceil for ask (up)
    function _bandEdge(
        uint256       mid,
        uint256       edgeFactor,
        Math.Rounding rounding
    ) internal pure returns (uint256) {
        return Math.mulDiv(mid, Q64 * edgeFactor, STEP_DENOM, rounding);
    }

    // ── Price internals ─────────────────────────────────────────────────

    /// @dev Reads via the oracle's non-view, attributed `price(feedId, pool)` (emits PriceRead),
    ///      forwarding `msg.sender` (the pool). Single-feed: the anchor mid directly. Synthetic
    ///      (quoteFeedId set): the ratio price(baseFeedId)/price(quoteFeedId) — the shared quote
    ///      cancels (e.g. BTC/USD ÷ ETH/USD = BTC/ETH) — with the per-leg spreads added (spreadBps += spreadBps2).
    function _getBidAndAskPrice() internal returns (uint128, uint128) {
        (uint256 mid, uint256 spreadBps, , bool ok) = _readLeg(baseFeedId);
        if (!ok) return (0, type(uint128).max);

        bytes32 _quote = quoteFeedId;
        if (_quote != bytes32(0)) {
            (uint256 mid2, uint256 spreadBps2, , bool ok2) = _readLeg(_quote);
            if (!ok2 || mid2 == 0) return (0, type(uint128).max);
            // Synthetic ratio (8-decimal): mid1 / mid2. Relative uncertainties of a ratio add.
            mid = Math.mulDiv(mid, ORACLE_DECIMALS, mid2);
            spreadBps += spreadBps2;
        }

        return _computeBidAsk(mid, spreadBps);
    }

    /// @dev Reads one feed and runs its per-leg guards. ok=false (→ caller halts, fail closed) on:
    ///      stale reference, mid == 0, spreadBps == the off-hours/stall marker (spreadBps >= ORACLE_BPS), or a
    ///      priceGuard violation. Each leg is read through the attributed path independently.
    function _readLeg(bytes32 feedId)
        internal returns (uint256 mid, uint256 spreadBps, uint256 refTime, bool ok)
    {
        (mid, spreadBps, , refTime) = IPricedOracle(address(offchainOracle)).price(feedId, msg.sender);

        // Stale reference → not ok. Clamping to a stale anchor is the one false-safety case.
        if (_isStale(refTime, block.timestamp, MAX_REF_STALENESS)) return (mid, spreadBps, refTime, false);

        // Basic validity — mid positive, spreadBps not the stalled/off-hours marker (the Chainlink oracle
        // writes spreadBps = ORACLE_BPS when an RWA market is closed).
        if (mid == 0 || spreadBps >= ORACLE_BPS) return (mid, spreadBps, refTime, false);

        // Per-leg price guard.
        (uint128 guardMin, uint128 guardMax) = offchainOracle.priceGuard(feedId);
        guardMax = guardMax == 0 ? type(uint128).max : guardMax;
        if (mid < guardMin || mid > guardMax) return (mid, spreadBps, refTime, false);

        ok = true;
    }

    /// @dev Anchored band + optional source clamp over an already-validated (mid, spreadBps).
    ///      Returns the (0, max) sentinel on any failure — fail closed, withdrawals unaffected.
    function _computeBidAsk(uint256 mid, uint256 spreadBps)
        internal view returns (uint128, uint128)
    {
        // Circuit breaker: extreme (combined) uncertainty means the feed is clearly broken.
        if (spreadBps > MAX_SPREAD_BPS) {
            return (0, type(uint128).max);
        }

        // Reference band: mid ± (spreadBps + minMargin), bid rounded down, ask rounded up.
        uint256 half = spreadBps * ONE_BPS_E18 + minMargin; // < BPS_BASE_U by construction (spreadBps <= MAX_SPREAD_BPS here)
        uint256 refBid = _bandEdge(mid, BPS_BASE_U - half, Math.Rounding.Floor);
        uint256 refAsk = _bandEdge(mid, BPS_BASE_U + half, Math.Rounding.Ceil);
        if (refBid == 0 || refAsk > type(uint128).max || refBid >= refAsk) {
            return (0, type(uint128).max);
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
                return (0, type(uint128).max);
            }
        } else if (MUTABLE_PARAMS) {
            // 7b. Shaped reference quote: mid ± mid·spreadBps·confidence, then marginStep factors —
            //     PriceProvider semantics, clamped into the band below.
            bool ok;
            (ok, cBid, cAsk) = _shapedQuote(mid, spreadBps);
            if (!ok) {
                return (0, type(uint128).max);
            }
        } else {
            return (uint128(refBid), uint128(refAsk));
        }

        // 8. Clamp: out-of-band custom quotes are clipped silently to the band edge.
        //    bid ≤ refBid < refAsk ≤ ask, so bid < ask holds by construction.
        uint256 bidOut = Math.min(refBid, cBid);
        uint256 askOut = Math.max(refAsk, cAsk);
        if (bidOut == 0 || bidOut >= askOut) {
            return (0, type(uint128).max);
        }

        return (uint128(bidOut), uint128(askOut));
    }

    /// @dev Shaped reference quote (customizable variant, reference mode): delta = mid·spreadBps·confidence,
    ///      then the marginStep factors via `_bandEdge` (byte-identical to PriceProvider's step math).
    ///
    ///      Deliberately NO `sBid >= sAsk` pre-clamp halt (unlike PriceProvider): with knobs at 0 and
    ///      a round mid, floor == ceil gives sBid == sAsk, and the band clamp restores ordering —
    ///      that is exactly the immutable-variant identity. The `sAsk > uint128.max` check MUST stay
    ///      pre-clamp (mirrors `_readSource`'s srcAsk guard): truncating later would let an
    ///      overflowing ask wrap to a sub-band quote.
    function _shapedQuote(uint256 mid, uint256 spreadBps)
        internal view returns (bool ok, uint256 sBid, uint256 sAsk)
    {
        uint256 delta = mid * (spreadBps * confidenceParam) / CONFIDENCE_BASE;
        uint256 bid8 = delta >= mid ? 0 : mid - delta;
        uint256 ask8 = mid + delta;

        sBid = _bandEdge(bid8, stepBidFactor, Math.Rounding.Floor);
        sAsk = _bandEdge(ask8, stepAskFactor, Math.Rounding.Ceil);
        if (sBid == 0 || sAsk > type(uint128).max) return (false, 0, 0);

        return (true, sBid, sAsk);
    }

    /// @dev Gas-bounded staticcall to the source. Tolerates any source behavior without reverting:
    ///      revert, out-of-gas, wrong returndata size, dirty words and uint128 overflow all report
    ///      failure instead.
    ///
    ///      Uses a raw assembly staticcall into a fixed 64-byte buffer. A high-level
    ///      `(bool, bytes memory)` call would `returndatacopy` the source's ENTIRE returndata into
    ///      caller memory before any length check, charging the pool's swap for the copy + memory
    ///      expansion — a returndata bomb costs ~2× SOURCE_GAS_LIMIT on the caller side. Capping the
    ///      output at 64 bytes makes the caller-side cost O(64) regardless of returndatasize, so
    ///      SOURCE_GAS_LIMIT is the true griefing bound. returndatasize() is still read in full for
    ///      the exact-64 check (the bomb's extra bytes are discarded, not copied).
    function _readSource(address _source)
        internal view returns (bool ok, uint256 srcBid, uint256 srcAsk)
    {
        bytes4 sel = IAnchorSource.getBidAndAskPrice.selector;
        bool success;
        uint256 retSize;
        uint256 b;
        uint256 a;
        assembly ("memory-safe") {
            // Scratch beyond the free-memory pointer; never updated, so this is memory-safe.
            let ptr := mload(0x40)
            mstore(ptr, sel) // 4-byte selector, left-aligned
            // Input is consumed before output is written, so in/out may share ptr. Output is capped
            // at 0x40 bytes: a larger returndata is NOT copied (only returndatasize() reports it).
            success := staticcall(SOURCE_GAS_LIMIT, _source, ptr, 0x04, ptr, 0x40)
            retSize := returndatasize()
            b := mload(ptr)
            a := mload(add(ptr, 0x20))
        }
        if (!success || retSize != 64) return (false, 0, 0);

        srcBid = b;
        srcAsk = a;
        if (srcBid == 0 || srcBid >= srcAsk || srcAsk > type(uint128).max) return (false, 0, 0);

        return (true, srcBid, srcAsk);
    }
}
