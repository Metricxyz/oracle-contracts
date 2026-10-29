// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../../interfaces/AggregatorV3Interface.sol";
import "../../interfaces/IChainlinkVerifier.sol";
import {OracleMath} from "./OracleMath.sol";

contract ChainlinkVerifierL2 is IChainlinkVerifier {
    AggregatorV3Interface public immutable sequencerUptimeFeed;
    uint256 public constant GRACE_PERIOD = 1 hours;

    mapping(address => ClOracleInfo) internal clOracles;
    uint8 internal constant CL_TARGET_DECIMALS = 8;

    constructor(address _sequencerUptimeFeed) {
        sequencerUptimeFeed = AggregatorV3Interface(_sequencerUptimeFeed);
    }

    /// @dev Returns true if sequencer is healthy, false otherwise.
    function _checkSequencer() internal view returns (bool) {
        if (address(sequencerUptimeFeed) == address(0)) return true;

        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();

        // answer == 0: sequencer is up, answer == 1: sequencer is down
        if (answer != 0) return false;

        // Ensure grace period has passed since sequencer came back up
        if (startedAt > block.timestamp || block.timestamp - startedAt <= GRACE_PERIOD) return false;

        return true;
    }

    function __normalizeToTargetDecimals(
        uint256 rawBaseRefPrice,
        uint8 baseDecimals,
        uint256 rawQuoteRefPrice,
        uint8 quoteDecimals
    ) private pure returns (uint256 refPrice) {
        int256 exp = int256(uint256(quoteDecimals)) + int256(uint256(CL_TARGET_DECIMALS)) - int256(uint256(baseDecimals));
        if (exp >= 0) {
            refPrice = Math.mulDiv(rawBaseRefPrice, OracleMath.pow10(uint8(uint256(exp))), rawQuoteRefPrice);
        } else {
            refPrice = Math.mulDiv(rawBaseRefPrice, 1, rawQuoteRefPrice * OracleMath.pow10(uint8(uint256(-exp))));
        }
    }

    function _setClOracle(address _token, address _oracle, uint32 _heartbeat) internal {
        clOracles[_token] = ClOracleInfo({
            oracle: _oracle,
            decimals: AggregatorV3Interface(_oracle).decimals(),
            heartbeat: _heartbeat
        });

        emit ClOracleSet(_token, _oracle, _heartbeat);
    }

    function _removeClOracle(address _token) internal {
        delete clOracles[_token];
        emit ClOracleRemoved(_token);
    }

    function __sanityCheck(
        int256 refPrice,
        uint256 updatedAt
    ) private pure returns (bool) {
        return refPrice > 0 && updatedAt > 0;
    }

    function _cloPriceInQuote(address _fromToken, address _toToken)
        internal
        view
        returns (bool oracleFound, uint256 refPrice, uint256 refTime, uint256 heartbeat)
    {
        if (!_checkSequencer()) return (false, 0, 0, 0);

        ClOracleInfo memory clInfo = clOracles[_fromToken];
        ClOracleInfo memory quoteInfo = clOracles[_toToken];
        address baseOracle = clInfo.oracle;
        address quoteOracle = quoteInfo.oracle;
        if (baseOracle == address(0) || quoteOracle == address(0)) return (false, 0, 0, 0);

        int256 answer;
        uint256 updatedAt;

        (, answer,, updatedAt,) = AggregatorV3Interface(baseOracle).latestRoundData();
        if (!__sanityCheck(answer, updatedAt)) return (false, 0, 0, 0);
        uint256 basePrice = uint256(answer);
        uint256 baseUpdatedAt = updatedAt;

        (, answer,, updatedAt,) = AggregatorV3Interface(quoteOracle).latestRoundData();
        if (!__sanityCheck(answer, updatedAt)) return (false, 0, 0, 0);
        uint256 quotePrice = uint256(answer);
        uint256 quoteUpdatedAt = updatedAt;

        refPrice = __normalizeToTargetDecimals(basePrice, clInfo.decimals, quotePrice, quoteInfo.decimals);
        if (refPrice == 0) return (false, 0, 0, 0);

        refTime = baseUpdatedAt > quoteUpdatedAt ? quoteUpdatedAt : baseUpdatedAt;
        heartbeat = clInfo.heartbeat < quoteInfo.heartbeat ? clInfo.heartbeat : quoteInfo.heartbeat;
        oracleFound = true;
    }
}