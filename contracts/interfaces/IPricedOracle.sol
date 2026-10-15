// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Attributed on-chain price read: non-view, emits PriceRead(pool, feedId). Both price
///         providers read through it. Declared separately from IOffchainOracle. Implementations:
///         - Providers oracles (Pyth / Chainlink) and MultiplierOracle gate the read: `pool` must
///           report `IPool(pool).inSwap() == msg.sender`, be registered for the feed and not be
///           blacklisted. The gate is skipped when `tx.origin == address(0)`.
///         - CompressedOracleV1 has no gate: it does not check `pool` and only logs it.
interface IPricedOracle {
    /// @param pool the calling pool (forwarded by its price provider); a gated oracle checks it as
    ///        above, and every implementation attributes the logged read to it.
    function price(bytes32 feedId, address pool)
        external
        returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime);
}
