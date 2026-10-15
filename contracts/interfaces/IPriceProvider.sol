// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IPriceProvider {
    function setConfidenceParam(uint256 newValue) external;

    function token0() external view returns (address baseToken);
    function token1() external view returns (address quoteToken);

    /// @notice The provider's quote: the two executable edges plus the fair value the consumer
    ///         charges its fee against.
    /// @dev Mutable: the attributed providers read through the oracle's non-view
    ///      `price(feedId, pool)` path. View-only providers may implement it as `view`. Reverts on a
    ///      stalled feed.
    /// @return bidPrice Executable bid (Q64.64) — the price the pool buys token0 at.
    /// @return askPrice Executable ask (Q64.64) — the price the pool sells token0 at.
    /// @return referencePrice Provider's fair-value estimate used for fees, aggregation, and price
    ///         discovery (Q64.64). Must satisfy `bidPrice <= referencePrice && referencePrice <=
    ///         askPrice`; otherwise the consumer reverts. The fee each side pays is measured from
    ///         this value to the edge it executes at, so placing it off-centre splits the spread
    ///         asymmetrically between buys and sells.
    /// @custom:security Detected misreporting will result in pool deprioritization or blacklisting.
    function getQuote() external returns (uint128 bidPrice, uint128 askPrice, uint128 referencePrice);
}
