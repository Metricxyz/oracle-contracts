// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Custom quote source for an AnchoredPriceProvider (source mode). Any contract — open or
///         opaque, deployed by anyone — may implement it; the provider clamps its quotes into the
///         reference band, so source code is never reviewed.
///
///         READ THIS BEFORE WRITING A SOURCE. The clamp is ONE-DIRECTIONAL: it bounds only how TIGHT
///         your quote may be (never inside the configured reference band: per-leg multipliers applied, plus minMargin) and places NO bound on how
///         WIDE it may be. A quote far outside the reference band is passed through unchanged, so the
///         band does not make an arbitrary source safe.
///
///         In particular, if your source derives its quote from a venue whose price an outsider can
///         move, that outsider moves your quote with it and the anchor will not stop them — nobody
///         has to be malicious, and the victim is whoever trades while the quote is dislocated.
///
///         This is a deliberate position, not an oversight: bounding the outward side is the
///         OPERATOR's due diligence. Point a source only at a venue whose price you would be willing
///         to quote directly, and treat swapping the source as a change to the pool's pricing rather
///         than a bounded, reversible knob.
///
///         What widening CANNOT do is inflate fees. The provider derives the referencePrice it
///         reports from the ANCHOR's own mid, never from this call — your reference is validated to
///         sit in `[bid, ask]` and is then discarded. So a wide quote costs whoever trades against
///         it the wide execution price, but it cannot move the fee base the pool charges against.
/// @dev    Q64 quotes, same convention (and same selector) as IPriceProvider.getQuote — any
///         view provider qualifies as a source. The provider calls this via a gas-bounded staticcall
///         and fails closed on revert, out-of-gas, malformed returndata (anything other than exactly
///         three words — a two-word source without a referencePrice does not
///         qualify), zero bid, bid >= ask, or a reference outside [bid, ask].
interface IAnchorSource {
    function getQuote() external view returns (uint128 bid, uint128 ask, uint128 referencePrice);
}
