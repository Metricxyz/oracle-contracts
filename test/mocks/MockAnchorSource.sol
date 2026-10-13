// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Configurable anchor source: normal quotes plus every misbehavior mode the
///         AnchoredPriceProvider must fail closed on (revert, gas grief, malformed returndata).
contract MockAnchorSource {
    enum Mode {
        Normal, // return (bid, ask, reference)
        Revert, // plain revert
        Garbage, // wrong returndata size (32 bytes)
        BurnGas, // consume all forwarded gas (true OOG, not a checked-math panic)
        DirtyWords, // 96 bytes, all words == 2^256-1 (caught by bid >= ask)
        OverflowAsk, // 96 bytes, valid bid but ask > type(uint128).max (exercises the range guard)
        Bomb, // huge returndata (returndata-bomb griefing)
        LegacyPair, // 64 bytes: a pre-referencePrice source, now a wrong size
        RefBelowBid, // 96 bytes, reference under the bid (invariant violation)
        RefAboveAsk // 96 bytes, reference over the ask (invariant violation)
    }

    Mode public mode;
    uint128 public bid = 1e4;
    uint128 public ask = 1e8;
    /// @dev Zero = report the arithmetic mid of bid/ask, which is in band whenever bid <= ask.
    uint128 public referencePrice;

    address public token0 = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public token1 = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function set(uint128 _bid, uint128 _ask) external {
        mode = Mode.Normal;
        bid = _bid;
        ask = _ask;
        referencePrice = 0;
    }

    /// @notice Quote with an explicit (in-band) reference — the provider must ignore it and report
    ///         the anchor's mid regardless.
    function setWithReference(uint128 _bid, uint128 _ask, uint128 _referencePrice) external {
        mode = Mode.Normal;
        bid = _bid;
        ask = _ask;
        referencePrice = _referencePrice;
    }

    function setTokens(address _token0, address _token1) external {
        token0 = _token0;
        token1 = _token1;
    }

    function setMode(Mode _mode) external {
        mode = _mode;
    }

    function getQuote() external view returns (uint128, uint128, uint128) {
        Mode m = mode;
        if (m == Mode.Revert) revert("source failure");
        if (m == Mode.Garbage) {
            assembly ("memory-safe") {
                mstore(0, 42)
                return(0, 32) // 32 bytes instead of 96
            }
        }
        if (m == Mode.BurnGas) {
            // Expand memory unboundedly — quadratic gas cost guarantees a true out-of-gas inside
            // the provider's SOURCE_GAS_LIMIT cap (unlike a checked-math overflow, which would just
            // panic-revert and be indistinguishable from Mode.Revert).
            assembly {
                let p := 0
                for {} 1 {} {
                    mstore(p, 1)
                    p := add(p, 0x20)
                }
            }
        }
        if (m == Mode.DirtyWords) {
            assembly ("memory-safe") {
                mstore(0, not(0)) // bid word > type(uint128).max
                mstore(32, not(0))
                mstore(64, not(0))
                return(0, 96)
            }
        }
        if (m == Mode.OverflowAsk) {
            // bid is a small valid value (< ask), ask is exactly 2^128 (one over uint128.max) — this
            // passes the bid != 0 and bid < ask checks and reaches the `srcAsk > uint128.max` guard,
            // the load-bearing check that prevents truncating a > uint128 ask down into the band.
            assembly ("memory-safe") {
                mstore(0, 1000)
                mstore(32, shl(128, 1)) // 2^128
                mstore(64, 2000)
                return(0, 96)
            }
        }
        if (m == Mode.Bomb) {
            // ~480 KB of returndata. A high-level call would returndatacopy all of it into the
            // caller's memory before any length check; the hardened assembly read copies only 96
            // bytes, so the caller-side cost stays bounded regardless.
            assembly {
                return(0, 0x76000)
            }
        }
        if (m == Mode.LegacyPair) {
            // Exactly what every source written before referencePrice returns: two words. The
            // provider's exact-96 check must halt on it rather than read a third word that isn't there.
            uint256 b = bid;
            uint256 a = ask;
            assembly ("memory-safe") {
                mstore(0, b)
                mstore(32, a)
                return(0, 64)
            }
        }
        uint128 ref = referencePrice == 0 ? uint128((uint256(bid) + uint256(ask)) / 2) : referencePrice;
        if (m == Mode.RefBelowBid) ref = bid == 0 ? 0 : bid - 1;
        if (m == Mode.RefAboveAsk) ref = ask == type(uint128).max ? ask : ask + 1;
        return (bid, ask, ref);
    }
}
