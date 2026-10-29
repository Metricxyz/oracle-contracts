// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {OracleBase} from "./OracleBase.sol";
import {TimeMs, toTimeMs} from "../utils/TimeMs.sol";
import {IVerifierProxy, ReportV3, ReportV4, ReportHFS} from "../../interfaces/IDataStreams.sol";

/// @notice Chainlink Data Streams consumer. Verifies DON-signed reports via the VerifierProxy,
///         decodes the schema (v3/v4 standard + High Frequency Streams), normalizes to the shared
///         8-decimal OracleData and stores it — identical format to PythOracle, so the same
///         PriceProvider / ProtectedPriceProvider consumes Chainlink feeds unchanged.
///         Registrationless: any feed id from a DON-VERIFIED report is stored — the
///         VerifierProxy signature check is the trust anchor, not a registry.
/// @dev    Reads (`price(feedId, factory)` / `integratorPrice`) and the abuse-protection layer come
///         entirely from OracleBase; this contract only adds Data Streams ingestion.
contract ChainlinkOracle is OracleBase {
    using SafeCast for uint256;

    string public constant version = "0.2.1";
    /// @notice Oracle family discriminator for off-chain introspection (matches the
    ///         pusher/console `kind` vocabulary).
    string public constant kind = "chainlink-datastreams";

    /// @dev Per-report verification fee, paid from the contract balance
    ///      Fixed constant by design — fund the contract with native to ingest.
    uint256 internal constant VERIFICATION_FEE = 0 wei;

    /// @dev Data Streams prices are 18-decimal; OracleData is 8-decimal (`decimals`). 1e18 / 1e8.
    uint256 internal constant PRICE_SCALE = 1e10;

    // Report schema versions for standard feeds (high 2 bytes of feedId).
    uint16 internal constant REPORT_V3 = 3;
    uint16 internal constant REPORT_V4 = 4;

    // Timestamp resolution, encoded in the high nibble of feedId byte 0.
    uint8 internal constant RESOLUTION_SECONDS = 0;
    uint8 internal constant RESOLUTION_MILLISECONDS = 1;

    // v4 market status: 0 = unknown, 1 = closed, 2 = open.
    uint32 internal constant MARKET_STATUS_OPEN = 2;

    IVerifierProxy public immutable verifierProxy;
    /// @dev Fee token passed in the verify parameterPayload (this network's native fee token).
    address public immutable feeToken;

    event ReportStored(bytes32 indexed feedId, uint64 price, uint16 spread, TimeMs timestampMs);

    error UnsupportedReportSchema(uint16 schemaVersion);
    error InvalidReportPrice();

    constructor(address _owner, uint256 maxTimeDrift, address _verifierProxy, address _feeToken)
        OracleBase(_owner, maxTimeDrift)
    {
        require(_verifierProxy != address(0));
        verifierProxy = IVerifierProxy(_verifierProxy);
        feeToken = _feeToken;
    }

    /*
     *
     * Ingestion (permissionless; the real DON verify authenticates the data)
     *
     */

    function updateReport(bytes calldata fullReport) external {
        _store(_verifyReport(fullReport));
    }

    function updateReports(bytes[] calldata fullReports) external {
        for (uint256 i; i < fullReports.length; ++i) {
            _store(_verifyReport(fullReports[i]));
        }
    }

    /// @dev Verifies a DON-signed report via the Data Streams VerifierProxy, paying a fixed fee from
    ///      the contract balance, and returns the verified report blob. Virtual: a future stream
    ///      family (e.g. a distinct HFS verification flow) can override.
    function _verifyReport(bytes calldata fullReport) internal virtual returns (bytes memory reportData) {
        return verifierProxy.verify{value: VERIFICATION_FEE}(fullReport, abi.encode(feeToken));
    }

    function _store(bytes memory reportData) internal {
        (bytes32 feedId, OracleData memory d) = _decodeReport(reportData);

        d.timestampMs.revertIfZero();
        d.timestampMs.revertIfAfterBlockTimeWithDrift(MAX_TIME_DRIFT);

        if (d.timestampMs.isAfter(oracleData[feedId].timestampMs)) {
            oracleData[feedId] = d;
            emit ReportStored(feedId, d.price, d.spread0, d.timestampMs);
        }
    }

    /*
     *
     * Schema decode / normalize — extension seam for future report versions
     *
     */

    /// @dev Dispatches on the feed-ID resolution nibble (ms ⇒ HFS family) then, for standard feeds,
    ///      on the schema version. New families/versions plug in here (or override this in a subclass).
    function _decodeReport(bytes memory reportData)
        internal
        pure
        virtual
        returns (bytes32 feedId, OracleData memory d)
    {
        feedId = _peekFeedId(reportData);

        if (_feedResolution(feedId) == RESOLUTION_MILLISECONDS) {
            return _normalizeHFS(reportData); // High Frequency Streams (ms)
        }

        uint16 schemaVersion = uint16(uint256(feedId) >> 240);
        if (schemaVersion == REPORT_V3) return _normalizeV3(reportData);
        if (schemaVersion == REPORT_V4) return _normalizeV4(reportData);

        // --- future-version seam: add a branch / new struct here, or override _decodeReport ---
        revert UnsupportedReportSchema(schemaVersion);
    }

    /// @dev Timestamp resolution: high nibble of feedId byte 0 (0 = seconds, 1 = milliseconds).
    function _feedResolution(bytes32 feedId) internal pure returns (uint8) {
        return uint8(feedId[0]) >> 4;
    }

    function _peekFeedId(bytes memory reportData) internal pure returns (bytes32 feedId) {
        // The feedId is the first field of every report schema → first 32-byte word.
        assembly ("memory-safe") {
            feedId := mload(add(reportData, 0x20))
        }
    }

    function _normalizeV3(bytes memory reportData) internal pure returns (bytes32 feedId, OracleData memory d) {
        ReportV3 memory r = abi.decode(reportData, (ReportV3));
        feedId = r.feedId;
        d.price = _toMid8(r.price);
        d.spread0 = _spreadFromBidAsk(r.price, r.bid, r.ask);
        d.spread1 = 0xFFFF;
        d.timestampMs = toTimeMs(uint256(r.observationsTimestamp) * 1000); // seconds → ms
    }

    function _normalizeV4(bytes memory reportData) internal pure returns (bytes32 feedId, OracleData memory d) {
        ReportV4 memory r = abi.decode(reportData, (ReportV4));
        feedId = r.feedId;
        d.price = _toMid8(r.price);
        // No bid/ask in v4: open market → no spread; otherwise mark stalled (PriceProvider returns sentinel).
        d.spread0 = r.marketStatus == MARKET_STATUS_OPEN ? uint16(0) : BPS_BASE;
        d.spread1 = 0xFFFF;
        d.timestampMs = toTimeMs(uint256(r.observationsTimestamp) * 1000); // seconds → ms
    }

    function _normalizeHFS(bytes memory reportData) internal pure returns (bytes32 feedId, OracleData memory d) {
        ReportHFS memory r = abi.decode(reportData, (ReportHFS));
        feedId = r.feedId;
        d.price = _toMid8(r.benchmarkPrice);
        d.spread0 = _spreadFromBidAsk(r.benchmarkPrice, r.bid, r.ask);
        d.spread1 = 0xFFFF;
        d.timestampMs = toTimeMs(uint256(r.observationsTimestamp)); // already milliseconds
    }

    /// @dev 18-decimal Data Streams price → 8-decimal OracleData price.
    function _toMid8(int192 price) private pure returns (uint64) {
        require(price > 0, InvalidReportPrice());
        return (uint256(int256(price)) / PRICE_SCALE).toUint64();
    }

    /// @dev Confidence spread in bps from bid/ask (same convention as Pyth): ceil(BPS_BASE·half/mid),
    ///      capped at BPS_BASE (cap == stalled marker for the PriceProvider).
    function _spreadFromBidAsk(int192 price, int192 bid, int192 ask) private pure returns (uint16) {
        require(price > 0 && ask >= bid, InvalidReportPrice());
        uint256 half = uint256(int256(ask) - int256(bid)) / 2;
        uint256 spread = Math.ceilDiv(uint256(BPS_BASE) * half, uint256(int256(price)));
        return (spread > BPS_BASE ? uint256(BPS_BASE) : spread).toUint16();
    }

    receive() external override payable {}
}
