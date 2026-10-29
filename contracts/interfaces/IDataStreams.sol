// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal Chainlink Data Streams VerifierProxy surface used by ChainlinkOracle.
/// @dev    ABI-identical mirror of the official `verify` in chainlink-brownie-contracts
///         (src/v0.8/llo-feeds/v0.3.0/interfaces/IVerifierProxy.sol). Declared locally (not imported)
///         because the official file pins `pragma solidity 0.8.19`, which is incompatible with this
///         project (^0.8.28 / solc 0.8.33 / prague). Same function selector, so it is a drop-in
///         against the real on-chain VerifierProxy.
interface IVerifierProxy {
    /// @notice Verifies a DON-signed report and returns the verified report blob.
    /// @param  payload          The full (signed) report.
    /// @param  parameterPayload ABI-encoded billing parameters (fee token address).
    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory verifierResponse);
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
