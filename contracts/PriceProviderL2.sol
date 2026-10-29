// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IOffchainOracle} from "./interfaces/IOffchainOracle.sol";
import {IPriceProvider} from "./interfaces/IPriceProvider.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ChainlinkVerifierL2} from "./oracles/utils/ChainlinkVerifierL2.sol";
import {TimeMs} from "./oracles/utils/TimeMs.sol";


contract PriceProviderL2 is IPriceProvider, ChainlinkVerifierL2 {

    // ── Constants ────────────────────────────────────────────────────────
    uint256 internal constant Q64 = 1 << 64;
    uint256 public constant CONFIDENCE_COOLDOWN = 1 minutes;

    uint256 internal constant ORACLE_DECIMALS = 1e8;
    uint256 public  constant BPS_BASE_U = 1e18;
    int256  public  constant BPS_BASE   = int256(BPS_BASE_U);
    uint256 public  constant CONFIDENCE_MAX  = 1_000_000; // 100x multiplier
    uint256 internal constant CONFIDENCE_BASE = 1e10;     // 1e6 (0.01 bps) × 10_000 (multiplier base)

    uint16  internal constant ORACLE_BPS = 10_000;
    uint16  internal constant CL_DEVIATION_CHECK_DISABLED = type(uint16).max;

    /// @dev ORACLE_DECIMALS (1e8) * BPS_BASE (1e18) = 1e26.
    ///      Merges Q64/1e8 conversion and BPS_BASE division
    ///      into a single Math.mulDiv — one 512-bit division.
    uint256 internal constant STEP_DENOM = ORACLE_DECIMALS * BPS_BASE_U;

    // ── Immutables ──────────────────────────────────────────────────────
    IOffchainOracle public immutable offchainOracle;
    bytes32         public immutable offchainFeedId;
    address         public immutable factory;

    uint256 public immutable MAX_TIME_DELTA;

    /// @dev L2 sequencer timestamp can lag behind oracle publication time.
    ///      Allows refTime up to FUTURE_TOLERANCE seconds ahead of block.timestamp.
    uint256 public immutable FUTURE_TOLERANCE;

    address public immutable baseToken;
    address public immutable quoteToken;

    // ── Storage ─────────────────────────────────────────────────────────
    uint256 public confidenceParam;
    uint256 public lastConfidenceUpdate;

    /// @dev cexStep and step factors — mutable (debug, will be immutable in production)
    int256  public cexStep;
    uint256 internal stepBidFactor; // BPS_BASE_U - cexStep
    uint256 internal stepAskFactor; // BPS_BASE_U + cexStep

    uint16 public maxClDeviation;

    // ── Events / Errors ─────────────────────────────────────────────────
    event ConfidenceParamSet(uint256 indexed newValue);
    event CexStepUpdated(int256 indexed newCexStep);
    event MaxClDeviationUpdated(uint16 indexed newMaxClDeviation);

    error OnlyFactory();
    error FeedStalled();
    error ConfidenceParamOutOfBounds();
    error CexStepOutOfBounds();
    error CooldownNotElapsed();
    error MaxClDeviationOutOfBounds();
    error MaxTimeDeltaOutOfBounds();
    error FutureToleranceOutOfBounds();

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(
        address _factory,
        address _oracle,
        bytes32 _offchainFeedId,
        int256  _cexStep,
        uint256 _maxTimeDelta,
        uint256 _futureTolerance,
        address _sequencerUptimeFeed,
        uint16  _maxClDeviation,
        address _baseTokenOverride,
        address _quoteTokenOverride
    ) ChainlinkVerifierL2(_sequencerUptimeFeed) {
        require(_factory != address(0));
        factory = _factory;

        offchainOracle = IOffchainOracle(_oracle);
        offchainFeedId = _offchainFeedId;

        IOffchainOracle.OracleInfo memory info =
            offchainOracle.getOracleInfo(offchainFeedId);

        address _baseToken   = _baseTokenOverride == address(0) ? info.baseToken : _baseTokenOverride;
        address _quoteToken  = _quoteTokenOverride == address(0) ? info.quoteToken : _quoteTokenOverride;

        require(_baseToken != address(0) && _quoteToken != address(0));
        baseToken  = _baseToken;
        quoteToken = _quoteToken;

        if (_maxClDeviation > ORACLE_BPS && _maxClDeviation != CL_DEVIATION_CHECK_DISABLED) {
            revert MaxClDeviationOutOfBounds();
        }
        maxClDeviation = _maxClDeviation;

        if (_cexStep <= -BPS_BASE || _cexStep >= BPS_BASE) {
            revert CexStepOutOfBounds();
        }
        cexStep       = _cexStep;
        stepBidFactor = uint256(BPS_BASE - _cexStep);
        stepAskFactor = uint256(BPS_BASE + _cexStep);

        if (_maxTimeDelta == 0 || _maxTimeDelta > 7 days) revert MaxTimeDeltaOutOfBounds();
        if (_futureTolerance > 1 hours) revert FutureToleranceOutOfBounds();
        MAX_TIME_DELTA   = _maxTimeDelta;
        FUTURE_TOLERANCE = _futureTolerance;
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

    /// @dev DEBUG ONLY — will be removed before production deployment
    function setCexStep(int256 _cexStep) external {
        require(msg.sender == factory, OnlyFactory());
        if (_cexStep <= -BPS_BASE || _cexStep >= BPS_BASE) {
            revert CexStepOutOfBounds();
        }
        cexStep       = _cexStep;
        stepBidFactor = uint256(BPS_BASE - _cexStep);
        stepAskFactor = uint256(BPS_BASE + _cexStep);
        emit CexStepUpdated(_cexStep);
    }

    function setClOracle(address token, address oracle, uint32 heartbeat) external {
        require(msg.sender == factory, OnlyFactory());
        if (token == address(0) || oracle == address(0) || heartbeat == 0) revert IOffchainOracle.BadCreationRequest();
        _setClOracle(token, oracle, heartbeat);
    }

    function removeClOracle(address token) external {
        require(msg.sender == factory, OnlyFactory());
        if (clOracles[token].oracle == address(0)) revert ClOracleNotFound();
        _removeClOracle(token);
    }

    function setMaxClDeviation(uint16 newMaxDeviation) external {
        require(msg.sender == factory, OnlyFactory());
        if (newMaxDeviation > ORACLE_BPS && newMaxDeviation != CL_DEVIATION_CHECK_DISABLED) {
            revert MaxClDeviationOutOfBounds();
        }
        maxClDeviation = newMaxDeviation;
        emit MaxClDeviationUpdated(newMaxDeviation);
    }

    // ── External views ──────────────────────────────────────────────────
    function getTokens() external view returns (address, address) {
        return (baseToken, quoteToken);
    }

    function getBidPrice() external view returns (uint256 bidPrice) {
        (uint128 bid,) = _getBidAndAskPrice();
        if (bid == 0) revert FeedStalled();
        return bid;
    }

    function getBidPriceUi() external view returns (uint256) {
        (uint128 bid,) = _getBidAndAskPrice();
        return bid;
    }

    function getAskPrice() external view returns (uint256 askPrice) {
        (, uint128 ask) = _getBidAndAskPrice();
        if (ask == type(uint128).max) revert FeedStalled();
        return ask;
    }

    function getAskPriceUi() external view returns (uint256) {
        (, uint128 ask) = _getBidAndAskPrice();
        return ask;
    }

    function getBidAndAskPrice()
        external view override returns (uint128 bid, uint128 ask)
    {
        (bid, ask) = _getBidAndAskPrice();
        if (bid == 0 || ask == type(uint128).max) revert FeedStalled();
    }

    function getBidAndAskPriceUi()
        external view override returns (uint128 bid, uint128 ask)
    {
        return _getBidAndAskPrice();
    }

    // ── Staleness ───────────────────────────────────────────────────────

    /// @dev Pure staleness check. L2-aware: tolerates oracle refTime slightly
    ///      ahead of block.timestamp (sequencer clock skew).
    ///      Uses subtraction only — no addition that could theoretically overflow.
    function _isStale(
        uint256 refTime,
        uint256 nowTs,
        uint256 maxDelta,
        uint256 futureTol
    ) internal pure returns (bool) {
        if (refTime == 0) return true;

        if (refTime > nowTs) {
            // refTime in the future: tolerate only within futureTol
            return (refTime - nowTs) > futureTol;
        }

        // refTime in the past or equal: check age
        return (nowTs - refTime) > maxDelta;
    }

    // ── Oracle data helpers (moved from oracle) ─────────────────────────

    function _getBidAskFrom(uint256 midPrice, uint256 confidence) internal pure returns (uint256 bid, uint256 ask) {
        uint256 delta = midPrice * confidence / CONFIDENCE_BASE;
        bid = delta >= midPrice ? 0 : midPrice - delta;
        ask = midPrice + delta;
    }

    // ── Core math ───────────────────────────────────────────────────────

    /// @notice Bid adjustment: rounds DOWN (floor).
    ///         out = price * Q64 * stepBidFactor / 1e26
    function _applyBidAdjustments(
        uint256 price
    ) internal view returns (uint256 out, bool ok) {
        return _applyStepAdjustment(price, stepBidFactor, Math.Rounding.Floor);
    }

    /// @notice Ask adjustment: rounds UP (ceil).
    ///         out = price * Q64 * stepAskFactor / 1e26
    function _applyAskAdjustments(
        uint256 price
    ) internal view returns (uint256 out, bool ok) {
        return _applyStepAdjustment(price, stepAskFactor, Math.Rounding.Ceil);
    }

    /// @dev Converts oracle price (8-decimal) to Q64 and applies CEX step.
    ///
    ///      Numerator upper bounds:
    ///      Q64 ≈ 1.8e19, stepFactor < 2e18
    ///      → max numerator ≈ 3.6e37, fits uint256.
    ///      The 512-bit product with `price` is handled by Math.mulDiv.
    ///
    /// @param  price      Oracle bid/ask price (8-decimal)
    /// @param  stepFactor Precomputed stepBidFactor or stepAskFactor
    /// @param  rounding   Math.Rounding.Floor for bid, Math.Rounding.Ceil for ask
    /// @return out        Adjusted price in Q64 format, 0 if invalid
    /// @return ok         false if result is zero
    function _applyStepAdjustment(
        uint256        price,
        uint256        stepFactor,
        Math.Rounding  rounding
    ) private pure returns (uint256 out, bool ok) {
        if (price == 0) return (0, false);

        uint256 numerator = Q64 * stepFactor;

        out = Math.mulDiv(price, numerator, STEP_DENOM, rounding);

        if (out == 0) return (0, false);

        return (out, true);
    }

    // ── Price internals ─────────────────────────────────────────────────

    function _getBidAndAskPrice() internal view returns (uint128, uint128) {
        // 1. Get raw data from oracle
        IOffchainOracle.OracleData memory data = offchainOracle.getOracleData(offchainFeedId);
        uint256 refTime = data.timestampMs.toSeconds();

        // 2. Staleness check
        if (_isStale(refTime, block.timestamp, MAX_TIME_DELTA, FUTURE_TOLERANCE)) {
            return (0, type(uint128).max);
        }

        // 3. Basic validity — price must be positive, spread must not be stalled marker
        if (data.price == 0 || data.spread >= ORACLE_BPS) {
            return (0, type(uint128).max);
        }

        // 4. Price guard check (moved from oracle)
        (uint128 guardMin, uint128 guardMax) = offchainOracle.priceGuard(offchainFeedId);
        guardMax = guardMax == 0 ? type(uint128).max : guardMax;
        if (data.price < guardMin || data.price > guardMax) {
            return (0, type(uint128).max);
        }

        // 5. CL deviation check (uses PriceProvider's own CL verifier)
        //    NOTE: If a Chainlink feed reverts (decommissioned, frozen, etc.),
        //    this call will propagate the revert and brick the provider.
        //    This is acceptable for a service contract — remediation options:
        //      a) Disable CL check via setMaxClDeviation(CL_DEVIATION_CHECK_DISABLED)
        //      b) Wait for the CL feed to recover
        //      c) Redeploy the provider if the feed is permanently dead
        //    On L2, sequencer downtime is handled gracefully (_checkSequencer returns false),
        //    so only individual feed reverts are a concern.
        uint16 _maxClDeviation = maxClDeviation;
        if (_maxClDeviation != CL_DEVIATION_CHECK_DISABLED) {
            (bool cloFound, uint256 cloPrice_, uint256 cloRefTime, uint256 cloHeartbeat) =
                _cloPriceInQuote(baseToken, quoteToken);

            if (cloFound) {
                cloFound = !_isStale(cloRefTime, block.timestamp, cloHeartbeat, FUTURE_TOLERANCE);
            }

            if (cloFound && cloPrice_ != 0) {
                bool inBound =
                    cloPrice_ - (cloPrice_ * _maxClDeviation) / ORACLE_BPS <= data.price
                    && data.price <= cloPrice_ + (cloPrice_ * _maxClDeviation) / ORACLE_BPS;
                if (!inBound) return (0, type(uint128).max);
            }
            // if CL not found/stale, proceed without CL check (same as previous behavior)
        }

        // 6. Compute bid/ask from mid + confidence-adjusted spread
        //    confidenceParam multiplies oracle spread; 0 means no spread
        uint256 adjustedSpread = uint256(data.spread) * confidenceParam;
        (uint256 bid, uint256 ask) = _getBidAskFrom(uint256(data.price), adjustedSpread);

        // 7. Apply cexStep adjustment
        (uint256 bidOut, bool bidOk) = _applyBidAdjustments(bid);
        if (!bidOk || bidOut > type(uint128).max) return (0, type(uint128).max);

        (uint256 askOut, bool askOk) = _applyAskAdjustments(ask);
        if (!askOk || askOut > type(uint128).max) return (0, type(uint128).max);

        // 8. Hard invariant: bid must be strictly less than ask.
        //    Can be violated when cexStep < 0 and confidence is too small.
        if (bidOut >= askOut) return (0, type(uint128).max);

        return (uint128(bidOut), uint128(askOut));
    }
}
