// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PythLazer} from "pyth-lazer-sdk/PythLazer.sol";
import {PythLazerStructs} from "pyth-lazer-sdk/PythLazerStructs.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./TimeMs.sol";
import {IOffchainOracle} from "../../interfaces/IOffchainOracle.sol";

/// @dev Strict Pyth Lazer payload parser with configurable expected properties.
///
/// All feeds in an update packet MUST carry the exact same set of properties
/// specified at deploy time via `expectedProperties`.
/// The parser reverts on any unexpected property ID or wrong property count —
/// unknown fields are never silently skipped.
///
/// Freshness comes from the per-feed `FeedUpdateTimestamp` property (ID 12), NOT
/// from the packet-header timestamp: Lazer carries prices forward during off-hours
/// and when fewer than `min_pub` publishers contribute, so the header timestamp
/// would overstate freshness. Property 12 is therefore mandatory in
/// `expectedProperties`. A feed whose FeedUpdateTimestamp is absent (exists flag
/// = 0) is treated as invalid and skipped on store; the rest of the batch is
/// processed normally.
///
/// Property config is encoded once in the constructor into three immutables:
///   - `PROP_CONFIG`          – 4-bit size per property ID (0 = disallowed)
///   - `EXPECTED_MASK`        – bitmask of expected property IDs
///   - `EXPECTED_PROPS_COUNT` – popcount of EXPECTED_MASK
contract LazerConsumer {
    using SafeCast for *;

    PythLazer immutable pythLazer;

    // Intentional trade-off: a fixed verification fee paid from the contract balance keeps the
    // price-update path cheap and simple. If Pyth ever raises its on-chain verification_fee above
    // this, pushes revert until the constant is bumped (redeploy) — accepted to avoid a per-update
    // fee read on the hot update path.
    uint256 private constant PYTH_VERIFICATION_FEE = 1 wei;
    uint256 private immutable MAX_TIME_DRIFT;

    uint256 private constant BPS_BASE = 10_000;
    int256 private constant TARGET_DECIMALS = 8;

    uint32 private constant FORMAT_MAGIC = 2479346549;

    uint256 private constant X64 = 0xFFffFFffFFffFFff;
    uint256 private constant X48 = 0xFFffFFffFFff;
    uint256 private constant X32 = 0xFFffFFff;
    uint256 private constant X16 = 0xFFff;

    /// @dev Protocol-defined byte sizes for Pyth Lazer properties 0–12.
    /// Each property ID maps to a 4-bit size nibble (packed right-to-left).
    /// Variable-length properties 6, 7 and 8 have size 0 and are not supported.
    /// Property 12 (FeedUpdateTimestamp) is variable-length on the wire — a 1-byte
    /// exists flag followed by an 8-byte value when the flag is set; its nibble is
    /// the special value 9 and the parser handles the exists flag explicitly.
    ///
    /// Mapping (see `PythLazerStructs.PriceFeedProperty`):
    ///   ID  Name                    Size
    ///   0   Price                   8
    ///   1   BestBidPrice            8
    ///   2   BestAskPrice            8
    ///   3   PublisherCount          2
    ///   4   Exponent                2
    ///   5   Confidence              8
    ///   6   FundingRate             0 (exists byte + 8, unsupported)
    ///   7   FundingTimestamp        0 (exists byte + 8, unsupported)
    ///   8   FundingRateInterval     0 (exists byte + 8, unsupported)
    ///   9   MarketSession           2
    ///   10  EmaPrice                8
    ///   11  EmaConfidence           8
    ///   12  FeedUpdateTimestamp     9 (1 exists byte + 8 value bytes)
    uint256 private constant KNOWN_PROP_SIZES = 0x9882000822888;

    /// @dev Per-deploy property config: 4-bit byte size for each expected property ID.
    /// Zero for any property ID that is not expected (parser will revert on it).
    uint256 private immutable PROP_CONFIG;

    /// @dev Bitmask where bit `i` is set if property ID `i` is expected in every feed.
    uint256 private immutable EXPECTED_MASK;

    /// @dev Number of expected properties (popcount of EXPECTED_MASK).
    /// Used for early `numProps` validation before parsing individual properties.
    uint256 private immutable EXPECTED_PROPS_COUNT;

    error InvalidMagic();
    error FeedsLengthMismatch(uint256 expected, uint256 actual);
    error NoFeeds();
    error FeedIdMismatch(uint256 index, uint32 expected, uint32 actual);
    error PayloadLengthMismatch(uint256 pos, uint256 length);
    error UnknownProperty(uint8 pid);
    error UnexpectedPropsCount(uint256 expected, uint256 actual);

    /// @param expectedProperties Array of property IDs that every feed must include.
    ///        Example: `[0, 4, 5, 12]` = Price + Exponent + Confidence + FeedUpdateTimestamp.
    ///        All feeds must carry all listed properties. Property 12 (FeedUpdateTimestamp)
    ///        is mandatory — it is the only freshness source for parsed prices.
    ///        Variable-length properties 6, 7 and 8 are not supported and will revert.
    constructor(
        address pythLazerAddress,
        uint256 maxTimeDrift,
        uint8[] memory expectedProperties
    ) {
        pythLazer = PythLazer(pythLazerAddress);
        MAX_TIME_DRIFT = maxTimeDrift;

        uint256 propConfig;
        uint256 expectedMask;
        uint256 count = expectedProperties.length;
        for (uint256 i; i < count; ++i) {
            uint8 pid = expectedProperties[i];
            require(pid <= 12, "property ID out of range");
            uint256 size = (KNOWN_PROP_SIZES >> (pid * 4)) & 0xF;
            require(size > 0, "variable-length property not supported");
            propConfig |= size << (pid * 4);
            expectedMask |= 1 << pid;
        }
        require(expectedMask & (1 << 12) != 0, "FeedUpdateTimestamp property required");
        PROP_CONFIG = propConfig;
        EXPECTED_MASK = expectedMask;
        EXPECTED_PROPS_COUNT = count;
    }

    // @note: expects:
    // - `feedIds` aligned 1:1 with the feeds in `priceUpdate` (same order)
    // - each feed must include all properties specified at deploy time
    // - the packed timestamp is the feed's own FeedUpdateTimestamp in ms (0 = absent)
    // Registrationless: every feed id in the VERIFIED payload is stored — the Lazer
    // signature (checked in _verifyPayload) is the trust anchor, not a registry.
    function _verifyAndStore(
        mapping(bytes32 => IOffchainOracle.OracleData) storage __data,
        uint32[] memory feedIds,
        bytes memory priceUpdate
    ) internal {
        (uint256[] memory raw, uint256 pos, uint256 payloadLen) = _verifyPayload(feedIds, priceUpdate);

        unchecked {
            for (uint256 i = 0; i < raw.length; ++i) {
                uint256 v = raw[i];

                uint256 tsMs = (v >> 64) & X48;
                // Feed had no FeedUpdateTimestamp — nothing to anchor freshness to;
                // skip it without touching storage, the rest of the batch proceeds.
                if (tsMs == 0) continue;

                bytes32 feedId;
                uint64 normPrice;
                uint256 spreadU;

                if ((v & 1) == 0) {
                    feedId = bytes32(v >> 32 & X32);
                    normPrice = 0;
                    spreadU = 0xFFFF;
                } else {
                    (normPrice, spreadU, feedId) = _normalize(v);
                }

                TimeMs ts = toTimeMs(tsMs);
                ts.revertIfAfterBlockTimeWithDrift(MAX_TIME_DRIFT);

                if (ts.isAfter(__data[feedId].timestampMs)) {
                    __data[feedId] = IOffchainOracle.OracleData({
                        price: normPrice,
                        spread0: spreadU.toUint16(),
                        spread1: 0xFFFF,
                        timestampMs: ts
                    });
                }
            }
        }

        if (pos != payloadLen) revert PayloadLengthMismatch(pos, payloadLen);
    }

    // Parses every feed uniformly (header + properties → marker-bit-packed word).
    function _verifyPayload(
        uint32[] memory feedIds,
        bytes memory priceUpdate
    ) private returns (
        uint256[] memory values,
        uint256 pos,
        uint256 payloadLen
    ) {
        (bytes memory payload,) = pythLazer.verifyUpdate{value: PYTH_VERIFICATION_FEE}(priceUpdate);
        payloadLen = payload.length;

        uint256 feedsLen;
        uint256 propCfg = PROP_CONFIG;
        uint256 expMask = EXPECTED_MASK;
        uint256 expCount = EXPECTED_PROPS_COUNT;

        assembly ("memory-safe") {
            let base := add(payload, 0x20)
            let w0 := mload(base)

            // Magic check
            if iszero(eq(shr(224, w0), FORMAT_MAGIC)) {
                mstore(0x00, 0x24a7661d) // InvalidMagic()
                revert(0x1c, 0x04)
            }

            // header layout: magic(4) | timestampUs(8) | channel(1) | feedsLen(1);
            // the header timestamp is intentionally unused — freshness comes from
            // each feed's own FeedUpdateTimestamp property
            feedsLen := and(shr(144, w0), 0xFF)
            pos := 14
        }

        if (feedIds.length != feedsLen) revert FeedsLengthMismatch(feedsLen, feedIds.length);
        if (feedsLen == 0) revert NoFeeds();

        // ═══════════════════════════════════════════════════════════════
        // Parse all feeds
        // ═══════════════════════════════════════════════════════════════
        values = new uint256[](feedsLen);

        assembly ("memory-safe") {
            // ── Yul helper: parses one feed AND packs the marker word, so the
            // parse locals die inside the helper.
            function parseAndPack2(base, fpos, cfg, mask, cnt)
                -> fid, packedVal, npos
            {
                let hdr := mload(add(base, fpos))
                fid := shr(224, hdr)
                let numProps := and(shr(216, hdr), 0xFF)
                npos := add(fpos, 5)

                if iszero(eq(numProps, cnt)) {
                    mstore(0x00, shl(224, 0xf777c38b)) // UnexpectedPropsCount(uint256,uint256)
                    mstore(0x04, cnt)
                    mstore(0x24, numProps)
                    revert(0x00, 0x44)
                }

                let price := 0
                let expo := 0
                let conf := 0
                let fts := 0
                let foundMask := 0
                for { let j := 0 } lt(j, numProps) { j := add(j, 1) } {
                    let w := mload(add(base, npos))
                    let pid := shr(248, w)
                    npos := add(npos, 1)

                    let size := and(shr(mul(pid, 4), cfg), 0xF)
                    if iszero(size) {
                        mstore(0x00, shl(224, 0x0ca46524)) // UnknownProperty(uint8)
                        mstore(0x04, pid)
                        revert(0x00, 0x24)
                    }

                    switch pid
                    case 0 { price := signextend(7, shr(192, shl(8, w))) }
                    case 4 { expo := signextend(1, shr(240, shl(8, w))) }
                    case 5 { conf := shr(192, shl(8, w)) }
                    case 12 {
                        // byte 1 of w is the exists flag; the 8-byte value follows it
                        switch byte(1, w)
                        case 0 { size := 1 }
                        default { fts := shr(192, shl(16, w)) }
                    }
                    default {}

                    npos := add(npos, size)
                    foundMask := or(foundMask, shl(pid, 1))
                }

                if iszero(eq(foundMask, mask)) {
                    mstore(0x00, shl(224, 0xf777c38b)) // UnexpectedPropsCount(uint256,uint256)
                    mstore(0x04, mask)
                    mstore(0x24, foundMask)
                    revert(0x00, 0x44)
                }

                // Per-feed update timestamp µs → ms. The packed ts field is 48 bits
                // (enough until year ~10889); an out-of-range value is treated the
                // same as an absent one.
                let tsMs := div(fts, 1000)
                if gt(tsMs, 0xFFFFFFFFFFFF) { tsMs := 0 }

                // price <= 0 or missing timestamp → invalid entry. Bit 0 (the marker)
                // is structurally clear here, so an odd tsMs can never be mistaken
                // for a marker-packed value.
                switch or(iszero(sgt(price, 0)), iszero(tsMs))
                case 1 {
                    packedVal := or(shl(64, tsMs), shl(32, fid))
                }
                default {
                    // Pack raw data with marker bit
                    // Layout: p[192:255] | expo[176:191] | conf[112:175] | tsMs[64:111] | feedId[32:63] | marker[0]
                    packedVal := or(
                        or(
                            or(
                                or(shl(192, price), shl(176, and(expo, 0xFFFF))),
                                shl(112, conf)
                            ),
                            or(shl(64, tsMs), shl(32, fid))
                        ),
                        1
                    )
                }
            }

            let base := add(payload, 0x20)
            let valuesPtr := add(values, 0x20)
            let feedIdsPtr := add(feedIds, 0x20)

            for { let i := 0 } lt(i, feedsLen) { i := add(i, 1) } {
                let feedId, packedVal
                feedId, packedVal, pos := parseAndPack2(base, pos, propCfg, expMask, expCount)

                // Verify feedId
                let expected := mload(add(feedIdsPtr, mul(i, 0x20)))
                if iszero(eq(expected, feedId)) {
                    mstore(0x00, shl(224, 0xf9d041bd)) // FeedIdMismatch(uint256,uint32,uint32)
                    mstore(0x04, i)
                    mstore(0x24, expected)
                    mstore(0x44, feedId)
                    revert(0x00, 0x64)
                }

                mstore(add(valuesPtr, mul(i, 0x20)), packedVal)
            }
        }
    }

    // Decimal normalization for a single marker-packed value: rescale the feed's
    // own price to TARGET_DECIMALS (8) — no cross-quote conversion.
    function _normalize(
        uint256 raw
    ) private pure returns (uint64 normPrice, uint256 spreadU, bytes32 feedId) {
        unchecked {
            uint256 pU = (raw >> 192 & X64).toUint64();
            int256 expo = int16((raw >> 176 & X16).toUint16());
            uint64 conf = (raw >> 112 & X64).toUint64();
            feedId = bytes32(raw >> 32 & X32);

            // Bound chosen so the unchecked multiplication below cannot wrap:
            // pU ≤ 2^64−1 and 10^57 ≈ 2^189.4 → pU·10^57 < 2^253.4 < 2^256.
            // Real-world totalExpo is ≈ −10..20, so the bound is never limiting.
            int256 totalExpo = expo + TARGET_DECIMALS;
            require(totalExpo >= -57 && totalExpo <= 57);

            uint256 rawPrice;
            if (totalExpo >= 0) {
                rawPrice = pU * (10 ** totalExpo.toUint256());
            } else {
                rawPrice = pU / (10 ** (-totalExpo).toUint256());
            }

            normPrice = rawPrice.toUint64();

            spreadU = Math.ceilDiv(BPS_BASE * uint256(conf), pU);
            if (spreadU > BPS_BASE) spreadU = BPS_BASE;
        }
    }
}
