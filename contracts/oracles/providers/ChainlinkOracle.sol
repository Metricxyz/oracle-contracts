// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {OracleBase} from "./OracleBase.sol";
import {TimeMs, toTimeMs} from "../utils/TimeMs.sol";
import {IVerifierProxy, ReportV3, ReportV4, ReportHFS} from "../../interfaces/IDataStreams.sol";

/// @notice Chainlink Data Streams consumer. Verifies DON-signed reports via the VerifierProxy,
///         decodes the schema (v3/v4 standard + High Frequency Streams), normalizes to the shared
///         8-decimal OracleData and stores it — identical format to PythOracle, so the same
///         PriceProvider consumes Chainlink feeds unchanged.
///         Registrationless: any feed id from a DON-VERIFIED report is stored — the
///         VerifierProxy signature check is the trust anchor, not a registry.
/// @dev    Reads (`price(feedId, pool)` / `integratorPrice`) and the read-access layer come
///         entirely from OracleBase; this contract only adds Data Streams ingestion.
///
///         Multi-version routing: Chainlink ships several VerifierProxy versions (v0.5.0, v0.5.1)
///         that may be deployed side by side on one chain, serving different DONs/feeds. Every
///         ingested payload is prefixed off-chain with a one-byte version tag; the oracle strips it
///         and forwards the rest to the VerifierProxy registered under that tag. A verifier flagged
///         `supportsView` (v0.5.1) is verified via the fee-free `verifyView`; otherwise via the
///         payable `verify`. See `verifierByTag` and `TAG_V050` / `TAG_V051`.
contract ChainlinkOracle is OracleBase {
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    string public constant version = "1.1.0";
    /// @notice Oracle family discriminator for off-chain introspection (matches the
    ///         pusher/console `kind` vocabulary).
    string public constant kind = "chainlink-datastreams";

    /// @dev Per-report verification fee forwarded to `VerifierProxy.verify`. It is ZERO, and the
    ///      deployment depends on it staying zero: Chainlink's on-chain per-verification billing is
    ///      effectively deprecated in favour of off-chain subscription billing for whitelisted
    ///      consumers, and `verify{value: 0}` is retained for backwards compatibility. Confirmed with
    ///      Chainlink for this deployment.
    ///
    ///      Consequences, so nobody "fixes" this by raising the constant:
    ///      - ingestion is NOT payable and there is no LINK `approve` path anywhere in `contracts/`,
    ///        so a nonzero effective fee cannot be paid — pushes through that route would revert
    ///        permanently; the remedies are rerouting the tag with `setVerifier` to a fee-free
    ///        `verifyView` proxy, where one serves that feed on that chain, or a redeploy (this is a
    ///        `constant`, and `feeToken` is `immutable`);
    ///      - `verify` is called BEFORE `_store`'s monotonic gate, so a nonzero fee would also make
    ///        the oracle pay for reports it then discards: anyone could replay an already-consumed
    ///        report, burn the fee and write nothing, draining the balance one verification at a time.
    uint256 internal constant VERIFICATION_FEE = 0 wei;

    /// @dev Data Streams prices are 18-decimal; OracleData is 8-decimal (`decimals`). 1e18 / 1e8.
    uint256 internal constant PRICE_SCALE = 1e10;

    /// @dev spread0 is stored in 0.01-bps units (fraction × 1e6). This matches the compressed
    ///      lane / codebook and the price providers' confidence math, where
    ///      delta/mid = spread0 × confidenceParam / 1e10, so confidenceParam = 10_000 means 1×.
    uint256 internal constant SPREAD_SCALE = 1e6;

    /// @dev Saturation ceiling, distinct from STALL_SPREAD. At this value the original uncertainty
    ///      cannot be recovered. APP rejects it; the plain provider halts at its lower 5% threshold.
    ///      Direct integrators must apply their own equivalent guard.
    uint16 internal constant MAX_REAL_SPREAD = type(uint16).max - 1;

    // Report schema versions for standard feeds (high 2 bytes of feedId).
    uint16 internal constant REPORT_V3 = 3;
    uint16 internal constant REPORT_V4 = 4;

    // Timestamp resolution, encoded in the high nibble of feedId byte 0.
    uint8 internal constant RESOLUTION_SECONDS = 0;
    uint8 internal constant RESOLUTION_MILLISECONDS = 1;

    // v4 market status: 0 = unknown, 1 = closed, 2 = open.
    uint32 internal constant MARKET_STATUS_OPEN = 2;

    /// @notice Default version-tag convention shared with the off-chain pusher. Values are
    ///         arbitrary — ADMIN may register any tag byte → any proxy — but these are the
    ///         canonical defaults for the two supported Chainlink VerifierProxy versions.
    uint8 public constant TAG_V050 = 0x50; // v0.5.0 — payable `verify` only
    uint8 public constant TAG_V051 = 0x51; // v0.5.1 — fee-free `verifyView` available

    /// @dev A registered VerifierProxy and how to call it. `supportsView == true` selects the
    ///      fee-free `verifyView` path (v0.5.1); otherwise the payable `verify` path (v0.5.0).
    struct Verifier {
        IVerifierProxy proxy;
        bool supportsView;
    }

    /// @dev Constructor / setter input: a tag mapped to a proxy and its verify capability.
    struct VerifierRoute {
        uint8 tag;
        address proxy;
        bool supportsView;
    }

    /// @notice Version tag → registered VerifierProxy. The payload's first byte selects the entry.
    mapping(uint8 => Verifier) public verifierByTag;
    /// @dev Registered tags, for enumeration / introspection.
    EnumerableSet.UintSet private _tags;

    /// @dev Fee token passed in the verify parameterPayload (this network's native fee token).
    address public immutable feeToken;

    error UnsupportedReportSchema(uint16 schemaVersion);
    error InvalidReportPrice();
    /// @notice The payload carried no version-tag byte (needs at least 1 byte).
    error EmptyPayload();
    /// @notice No VerifierProxy is registered under the payload's version tag.
    error UnknownVerifierTag(uint8 tag);
    error NoVerifiers();

    event VerifierSet(uint8 indexed tag, address indexed proxy, bool supportsView);
    event VerifierRemoved(uint8 indexed tag);

    constructor(address _owner, uint256 maxTimeDrift, VerifierRoute[] memory routes, address _feeToken)
        OracleBase(_owner, maxTimeDrift)
    {
        require(routes.length > 0, NoVerifiers());
        for (uint256 i; i < routes.length; ++i) {
            _setVerifier(routes[i].tag, routes[i].proxy, routes[i].supportsView);
        }
        feeToken = _feeToken;
    }

    /*
     *
     * Verifier registry (ADMIN)
     *
     */

    /// @notice Register (or update) the VerifierProxy served under `tag`. `supportsView` must be
    ///         true only for v0.5.1+ proxies (those exposing `verifyView`).
    /// @dev    ⚠️ ADMIN_ROLE MUST BE A MULTISIG. `_verifyReport` is the only trust anchor of this
    ///         lane, and the proxy routes are mutable:
    ///         a single ADMIN key can point a tag at a contract that echoes back
    ///         whatever it is handed, after which any unprivileged caller can store arbitrary prices
    ///         for every pool on every feed of this oracle; `removeVerifier` likewise bricks a whole
    ///         lane in one transaction. There is no timelock and no two-step handoff on the
    ///         verifier routes, so the multisig IS the control — it is an operational invariant, not
    ///         something the code enforces (accepted deliberately). `supportsView` is likewise an
    ///         unverified assertion: nothing probes the target for `verifyView`. It only selects the
    ///         method: `true` on a proxy without `verifyView` fails closed at push time (the call
    ///         reverts and that tag stops ingesting), while `false` on a proxy that has both simply
    ///         routes through the payable `verify`.
    function setVerifier(uint8 tag, address proxy, bool supportsView) external onlyRole(ADMIN_ROLE) {
        _setVerifier(tag, proxy, supportsView);
    }

    /// @notice Deregister the VerifierProxy served under `tag`. Payloads carrying that tag then revert.
    function removeVerifier(uint8 tag) external onlyRole(ADMIN_ROLE) {
        require(_tags.remove(tag), UnknownVerifierTag(tag));
        delete verifierByTag[tag];
        emit VerifierRemoved(tag);
    }

    /// @notice The set of registered version tags.
    function verifierTags() external view returns (uint256[] memory) {
        return _tags.values();
    }

    function _setVerifier(uint8 tag, address proxy, bool supportsView) internal {
        require(proxy != address(0));
        verifierByTag[tag] = Verifier(IVerifierProxy(proxy), supportsView);
        _tags.add(tag);
        emit VerifierSet(tag, proxy, supportsView);
    }

    /*
     *
     * Ingestion (permissionless; the real DON verify authenticates the data)
     *
     */

    /// @param taggedReport `<1-byte version tag> || <DON full report>`. The tag selects the
    ///        VerifierProxy version (see `verifierByTag`); it is stripped before verification.
    function updateReport(bytes calldata taggedReport) external {
        _store(_verifyReport(taggedReport));
    }

    /// @param taggedReports Each element is a `<version tag> || <full report>` payload; every entry
    ///        is routed independently, so a batch may mix v0.5.0 and v0.5.1 reports.
    function updateReports(bytes[] calldata taggedReports) external {
        for (uint256 i; i < taggedReports.length; ++i) {
            _store(_verifyReport(taggedReports[i]));
        }
    }

    /// @dev Routes a tagged payload to the right VerifierProxy version and returns the verified
    ///      report blob. The first byte is the version tag (set off-chain); the remainder is the
    ///      original DON full report forwarded to the proxy. v0.5.1 verifiers (`supportsView`) use
    ///      the fee-free `verifyView`; v0.5.0 use the payable `verify`, forwarding the fixed
    ///      VERIFICATION_FEE (zero; see above) from the contract balance. Virtual: a future stream family can override.
    function _verifyReport(bytes calldata taggedReport) internal virtual returns (bytes memory reportData) {
        require(taggedReport.length >= 1, EmptyPayload());
        uint8 tag = uint8(taggedReport[0]);
        Verifier memory v = verifierByTag[tag];
        require(address(v.proxy) != address(0), UnknownVerifierTag(tag));

        bytes calldata report = taggedReport[1:];
        if (v.supportsView) {
            // v0.5.1: fee-free view verification (allowed from this non-view context; it still costs gas).
            return v.proxy.verifyView(report);
        }
        return v.proxy.verify{value: VERIFICATION_FEE}(report, abi.encode(feeToken));
    }

    function _store(bytes memory reportData) internal {
        (bytes32 feedId, OracleData memory d) = _decodeReport(reportData);

        // A strictly-positive report price below 1e-8 floors to 0 after PRICE_SCALE (the price > 0
        // guard in _toMid8 is on the pre-scale value). Skip it — do NOT overwrite the last good value
        // or advance the timestamp with a zero-price entry; other reports in the batch still store.
        if (d.price == 0) return;

        d.timestampMs.revertIfZero();
        d.timestampMs.revertIfAfterBlockTimeWithDrift(MAX_TIME_DRIFT);

        if (d.timestampMs.isAfter(oracleData[feedId].timestampMs)) {
            oracleData[feedId] = d;
            emit FeedUpdated(feedId);
        }
    }

    /*
     *
     * Schema decode / normalize — extension seam for future report versions
     *
     */

    /// @dev Dispatches on BOTH the feed-ID resolution nibble (ms ⇒ HFS family) AND the base schema
    ///      version. The resolution nibble is the top 4 bits of the 2-byte schema-version field, so we
    ///      strip it (`& 0x0FFF`) before matching: routing on the nibble alone would send any schema
    ///      version ≥ 0x1000 to the HFS decoder. HFS currently ships only the v3-shaped schema
    ///      (benchmarkPrice + bid/ask), so an ms feed whose base schema is not v3 fails closed rather
    ///      than misdecoding. New families/versions plug in here (or override this in a subclass).
    function _decodeReport(bytes memory reportData)
        internal
        pure
        virtual
        returns (bytes32 feedId, OracleData memory d)
    {
        feedId = _peekFeedId(reportData);

        uint16 schemaVersion = uint16(uint256(feedId) >> 240);
        uint16 baseSchema = schemaVersion & 0x0FFF; // low 12 bits: schema version with the nibble removed

        uint8 resolution = _feedResolution(feedId);
        if (resolution == RESOLUTION_MILLISECONDS) {
            if (baseSchema == REPORT_V3) return _normalizeHFS(reportData); // High Frequency Streams (ms)
            revert UnsupportedReportSchema(schemaVersion);
        }

        // Fail closed on an UNKNOWN resolution nibble. Matching goes off the masked baseSchema (so
        // the ms lane can reuse the v3 schema id), which means the seconds lane by itself never
        // looks at the nibble — without this check a feedId with nibble 2..15 would silently decode
        // as seconds and have its timestamp multiplied by 1000. Unknown resolution must
        // revert, not be assumed to be seconds.
        if (resolution != RESOLUTION_SECONDS) revert UnsupportedReportSchema(schemaVersion);

        if (baseSchema == REPORT_V3) return _normalizeV3(reportData);
        if (baseSchema == REPORT_V4) return _normalizeV4(reportData);

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
        // No bid/ask in v4: open market → no spread; otherwise emit the stall sentinel so the
        // provider halts (RWA market closed).
        d.spread0 = r.marketStatus == MARKET_STATUS_OPEN ? uint16(0) : STALL_SPREAD;
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

    /// @dev Symmetric uncertainty around the benchmark in 0.01-bps units, rounded up. Unlike Pyth
    ///      confidence, bid/ask need not be symmetric: cover their maximum deviation from price.
    ///      Values saturate at MAX_REAL_SPREAD; consumers must halt at that ambiguous ceiling.
    function _spreadFromBidAsk(int192 price, int192 bid, int192 ask) private pure returns (uint16) {
        require(price > 0 && ask >= bid, InvalidReportPrice());
        int256 up = int256(ask) - int256(price);
        int256 down = int256(price) - int256(bid);
        // ask >= bid implies max(up, down) >= 0, even when price lies outside [bid, ask].
        uint256 deviation = uint256(up > down ? up : down);
        uint256 spread = Math.ceilDiv(SPREAD_SCALE * deviation, uint256(int256(price)));
        return (spread > MAX_REAL_SPREAD ? uint256(MAX_REAL_SPREAD) : spread).toUint16();
    }

    receive() external payable override {}
}
