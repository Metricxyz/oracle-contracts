// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Custom quote source for an AnchoredPriceProvider (source mode). Any contract — open or
///         opaque, deployed by anyone — may implement it; the provider clamps its quotes into the
///         reference band, so source code is never reviewed.
/// @dev    Q64 quotes, same convention as IPriceProvider.getBidAndAskPrice — any view provider
///         qualifies as a source. The provider calls this via a gas-bounded staticcall and fails
///         closed on revert, out-of-gas, malformed returndata, zero bid or bid >= ask.
interface IAnchorSource {
    function getBidAndAskPrice() external view returns (uint128 bid, uint128 ask);
}
