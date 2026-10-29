// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Attributed on-chain price read on the providers oracle (Pyth/Chainlink): non-view, emits
///         PriceRead and enforces the abuse-protection gates. Declared separately from IOffchainOracle
///         so existing IOffchainOracle implementers (compressed oracle, mocks) are not forced to
///         implement it.
interface IPricedOracle {
    /// @param pool the calling pool (forwarded by its price provider); the oracle binds the read via
    ///        `IPool(pool).inSwap() == msg.sender` and attributes the logged read to it.
    function price(bytes32 feedId, address pool)
        external
        returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime);
}
