// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IPriceProvider {

    function setConfidenceParam(uint256 newValue) external;

    function token0() external view returns (address baseToken);
    function token1() external view returns (address quoteToken);  

    /// @dev Mutable: the attributed providers read through the oracle's non-view
    ///      `price(feedId, pool)` path. View-only providers (legacy, view oracle) may implement it
    ///      as `view`. Reverts on a stalled feed.
    function getBidAndAskPrice() external returns (uint128 bidPrice, uint128 askPrice);
}
