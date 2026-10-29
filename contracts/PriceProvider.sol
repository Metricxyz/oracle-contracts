// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOffchainOracle} from "./interfaces/IOffchainOracle.sol";
import {IPricedOracle} from "./interfaces/IPricedOracle.sol";
import {IPriceProvider} from "./interfaces/IPriceProvider.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";


contract PriceProvider is IPriceProvider {

    // ── Constants ────────────────────────────────────────────────────────
    uint256 internal constant Q64 = 1 << 64;
    uint256 public constant CONFIDENCE_COOLDOWN = 1 minutes;

    uint256 internal constant ORACLE_DECIMALS = 1e8;
    uint256 public  constant BPS_BASE_U = 1e18;
    int256  public  constant BPS_BASE   = int256(BPS_BASE_U);
    uint256 public  constant CONFIDENCE_MAX  = 1_000_000; // 100x multiplier
    uint256 internal constant CONFIDENCE_BASE = 1e10;     // 1e6 (0.01 bps) × 10_000 (multiplier base)

    uint16  internal constant ORACLE_BPS = 10_000;

    /// @dev ORACLE_DECIMALS (1e8) * BPS_BASE (1e18) = 1e26.
    ///      Merges Q64/1e8 conversion and BPS_BASE division
    ///      into a single Math.mulDiv — one 512-bit division.
    uint256 internal constant STEP_DENOM = ORACLE_DECIMALS * BPS_BASE_U;

    // ── Immutables ──────────────────────────────────────────────────────
    IOffchainOracle public immutable offchainOracle;
    bytes32         public immutable offchainFeedId;
    address         public immutable factory;

    uint256 public immutable MAX_TIME_DELTA;

    address public immutable baseToken;
    address public immutable quoteToken;

    // ── Storage ─────────────────────────────────────────────────────────
    uint256 public confidenceParam;
    uint256 public lastConfidenceUpdate;

    /// @dev marginStep and the derived step factors — set once at construction (immutable).
    int256  public immutable marginStep;
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
        int256  _marginStep,
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
        marginStep       = _marginStep;
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

    function getBidAndAskPrice()
        external override returns (uint128 bid, uint128 ask)
    {
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

    function _getBidAndAskPrice() internal returns (uint128, uint128) {
        // 1. Read via the unified price(feedId, pool) path, forwarding the pool (msg.sender).
        //    refTime is already in seconds.
        (uint256 mid, uint256 spread, , uint256 refTime) =
            IPricedOracle(address(offchainOracle)).price(offchainFeedId, msg.sender);

        // 2. Staleness check
        if (_isStale(refTime, block.timestamp, MAX_TIME_DELTA)) {
            return (0, type(uint128).max);
        }

        // 3. Basic validity — price must be positive, spread must not be stalled marker
        if (mid == 0 || spread >= ORACLE_BPS) {
            return (0, type(uint128).max);
        }

        // 4. Price guard check (moved from oracle)
        (uint128 guardMin, uint128 guardMax) = offchainOracle.priceGuard(offchainFeedId);
        guardMax = guardMax == 0 ? type(uint128).max : guardMax;
        if (mid < guardMin || mid > guardMax) {
            return (0, type(uint128).max);
        }

        // 5. Compute bid/ask from mid + confidence-adjusted spread
        //    confidenceParam multiplies oracle spread; 0 means no spread
        uint256 adjustedSpread = spread * confidenceParam;
        (uint256 bid, uint256 ask) = _getBidAskFrom(mid, adjustedSpread);

        // 6. Apply marginStep adjustment
        (uint256 bidOut, bool bidOk) = _applyBidAdjustments(bid);
        if (!bidOk || bidOut > type(uint128).max) return (0, type(uint128).max);

        (uint256 askOut, bool askOk) = _applyAskAdjustments(ask);
        if (!askOk || askOut > type(uint128).max) return (0, type(uint128).max);

        // 7. Hard invariant: bid must be strictly less than ask.
        //    Can be violated when marginStep < 0 and confidence is too small.
        if (bidOut >= askOut) return (0, type(uint128).max);

        return (uint128(bidOut), uint128(askOut));
    }
}
