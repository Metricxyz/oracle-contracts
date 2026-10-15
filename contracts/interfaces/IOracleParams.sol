// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The issuer's view of a multiplier-based tokenized stock: its current multiplier and whether
///         its price feed should be paused. One adapter per token family implements it for
///         MultiplierOracle: B20AssetParams (Coinbase B20 Assets, via the issuer's OracleRegistry, which
///         exposes this same call) and RobinhoodStockTokenParams (Robinhood Stock Tokens).
interface IOracleParams {
    /// @return multiplier WAD number of underlying shares one whole token (10**decimals raw units)
    ///         redeems for. While a scheduled change of at most SMALL_CHANGE_BPS is pending, the
    ///         shipped adapters return the announced value instead of the current one.
    /// @return paused     True while the multiplier may be out of sync with the share's market price:
    ///         the issuer sets it while a corporate action (split, dividend) is in flight, and the
    ///         shipped adapters also answer true while a scheduled change larger than
    ///         ScheduledMultiplier.SMALL_CHANGE_BPS is pending (until its `effectiveAt`).
    function getOracleParams(address token) external view returns (uint256 multiplier, bool paused);
}
