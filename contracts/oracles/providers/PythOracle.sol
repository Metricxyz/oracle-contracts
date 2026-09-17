// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OracleBase} from "./OracleBase.sol";
import {LazerConsumer, PythLazerStructs} from "../utils/LazerConsumer.sol";

import {IOffchainOracle} from "../../interfaces/IOffchainOracle.sol";

/// @notice Registrationless Pyth Lazer oracle: there is no feed registry — any feed id
///         carried in a Lazer-SIGNED payload is stored on push (the signature check in
///         `LazerConsumer._verifyAndStore` is the trust anchor; an id Lazer never signed
///         cannot get in). A feed "exists" for readers once its first verified update
///         lands — that is the only existence condition readers observe.
contract PythOracle is OracleBase, LazerConsumer {
    string public constant version = "1.1.0";
    /// @notice Oracle family discriminator for off-chain introspection (matches the
    ///         pusher/console `kind` vocabulary).
    string public constant kind = "pyth-lazer";

    constructor(address _owner, address _lazerAddress, uint256 maxTimeDrift, uint8[] memory expectedProperties)
        OracleBase(_owner, maxTimeDrift)
        LazerConsumer(_lazerAddress, maxTimeDrift, expectedProperties)
    {}

    /*
     *
     * Main logic
     *
     */

    /// calldata format: [feedsLength:2][feedIds:feedsLength×4][priceUpdate:rest]
    /// No deadline prefix: every feed in the payload carries its own SIGNED
    /// FeedUpdateTimestamp — replay is neutralized by the per-feed monotonicity check.
    fallback() external payable override {
        uint256 end;

        assembly ("memory-safe") {
            end := calldatasize()
        }

        uint256 feedsLength;
        assembly ("memory-safe") {
            feedsLength := shr(240, calldataload(0)) // first 2 bytes
        }

        // Bound the caller-controlled length BEFORE allocating and before the slice arithmetic
        // below. `feedsLength` comes from 2 attacker-chosen calldata bytes (up to 65535), and
        // `priceUpdateOffset = 2 + feedsLength * 4` is subtracted from `end` inside an unchecked
        // assembly block — an oversized value would underflow that subtraction to ~2^256, handing
        // the parser a slice whose length invariant does not hold. That would fail closed downstream
        // on the envelope magic check, but only by luck; reject it here instead, and skip the
        // oversized memory allocation while we are at it.
        require(2 + feedsLength * 4 <= end, FeedsLengthMismatch(2 + feedsLength * 4, end));

        uint32[] memory updateFeedIds = new uint32[](feedsLength);
        assembly ("memory-safe") {
            let dst := add(updateFeedIds, 32) // skip length slot
            let src := 2 // offset after feedsLength(2)

            for { let i := 0 } lt(i, feedsLength) { i := add(i, 1) } {
                // load 32 bytes, shift right to get uint32 from high bits
                mstore(dst, shr(224, calldataload(src)))
                dst := add(dst, 32)
                src := add(src, 4)
            }
        }

        uint256 priceUpdateOffset = 2 + feedsLength * 4;
        bytes calldata priceUpdate;
        assembly ("memory-safe") {
            priceUpdate.offset := priceUpdateOffset
            priceUpdate.length := sub(end, priceUpdateOffset)
        }

        _verifyAndStore(oracleData, updateFeedIds, priceUpdate);
    }

    receive() external payable override {}
}
