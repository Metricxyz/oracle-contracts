// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal Chainlink Data Streams VerifierProxy surface used by ChainlinkOracle.
/// @dev    ABI-identical mirror of the official interface in chainlink-evm
///         (src/v0.8/llo-feeds/v0.5.0 and v0.5.1). Declared locally (not imported) because the
///         official files pin `pragma solidity 0.8.19`, which is incompatible with this project
///         (^0.8.28 / solc 0.8.33 / prague). Same function selectors, so it is a drop-in against
///         the real on-chain VerifierProxy of either version.
///
///         `verify` is present in both v0.5.0 and v0.5.1 (payable, state-changing, pays the fee
///         via the FeeManager). `verifyView` was added in v0.5.1: a fee-free `view`
///         verification — calling it on a v0.5.0 proxy reverts (the function does not exist).
///         ChainlinkOracle picks the path per registered verifier (see `supportsView`).
interface IVerifierProxy {
    /// @notice Verifies a DON-signed report and returns the verified report blob.
    /// @param  payload          The full (signed) report.
    /// @param  parameterPayload ABI-encoded billing parameters (fee token address).
    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory verifierResponse);

    /// @notice v0.5.1+: verifies a DON-signed report as a `view` call — no fee, no state change.
    /// @dev    Not present on v0.5.0 proxies (a call there reverts). No `parameterPayload`: the
    ///         view path does not route through the FeeManager.
    /// @param  payload The full (signed) report.
    function verifyView(bytes calldata payload) external view returns (bytes memory verifierResponse);
}

// ── Report schemas ──────────────────────────────────────────────────────
// Timestamps are SECONDS for standard feeds (feed-ID resolution nibble = 0) and MILLISECONDS for
// High Frequency Streams (nibble = 1). The resolution is the high nibble of feedId byte 0.

/// @dev v3 — Crypto streams (price + bid/ask), seconds.
struct ReportV3 {
    bytes32 feedId;
    uint32 validFromTimestamp;
    uint32 observationsTimestamp;
    uint192 nativeFee;
    uint192 linkFee;
    uint32 expiresAt;
    int192 price;
    int192 bid;
    int192 ask;
}

/// @dev v4 — RWA streams (price + market status), seconds.
struct ReportV4 {
    bytes32 feedId;
    uint32 validFromTimestamp;
    uint32 observationsTimestamp;
    uint192 nativeFee;
    uint192 linkFee;
    uint32 expiresAt;
    int192 price;
    uint32 marketStatus;
}

/// @dev High Frequency Streams (benchmarkPrice + bid/ask), milliseconds (uint64 timestamps).
struct ReportHFS {
    bytes32 feedId;
    uint64 validFromTimestamp;
    uint64 observationsTimestamp;
    uint192 nativeFee;
    uint192 linkFee;
    uint64 expiresAt;
    int192 benchmarkPrice;
    int192 bid;
    int192 ask;
}
