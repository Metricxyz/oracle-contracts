// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PythLazer} from "pyth-lazer-sdk/PythLazer.sol";
import {PythLazerStructs} from "pyth-lazer-sdk/PythLazerStructs.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./TimeMs.sol";
import {IOffchainOracle} from "../../interfaces/IOffchainOracle.sol";

/// @dev Strict Pyth Lazer payload parser with configurable expected properties.
///
/// All feeds in an update packet (including the USDT conversion feed) MUST carry
/// the exact same set of properties specified at deploy time via `expectedProperties`.
/// The parser reverts on any unexpected property ID or wrong property count —
/// unknown fields are never silently skipped.
///
/// Property config is encoded once in the constructor into three immutables:
///   - `PROP_CONFIG`          – 4-bit size per property ID (0 = disallowed)
///   - `EXPECTED_MASK`        – bitmask of expected property IDs
///   - `EXPECTED_PROPS_COUNT` – popcount of EXPECTED_MASK
contract LazerConsumer {
    using EnumerableSet for *;
    using SafeCast for *;

    PythLazer immutable pythLazer;

    uint256 private constant PYTH_VERIFICATION_FEE = 1 wei;
    uint256 private immutable MAX_TIME_DRIFT;

    uint256 private constant BPS_BASE = 10_000;
    int256 private constant TARGET_DECIMALS = 8;

    uint32 private immutable USD_CONVERTION_FEED_ID;
    uint32 private constant FORMAT_MAGIC = 2479346549;

    uint256 private constant X64 = 0xFFffFFffFFffFFff;
    uint256 private constant X32 = 0xFFffFFff;
    uint256 private constant X16 = 0xFFff;

    /// @dev Protocol-defined byte sizes for Pyth Lazer properties 0–12.
    /// Each property ID maps to a fixed byte size (4 bits each, packed right-to-left).
    /// Variable-length properties (6, 7, 8, 12) have size 0 and are not supported.
    ///
    /// Mapping (see `PythLazerStructs.PriceFeedProperty`):
    ///   ID  Name                    Size
    ///   0   Price                   8
    ///   1   BestBidPrice            8
    ///   2   BestAskPrice            8
    ///   3   PublisherCount          2
    ///   4   Exponent                2
    ///   5   Confidence              8
    ///   6   (variable-length)       0 (unsupported)
    ///   7   (variable-length)       0 (unsupported)
    ///   8   (variable-length)       0 (unsupported)
    ///   9   FundingRate             2
    ///   10  EmaPrice                8
    ///   11  EmaConfidence           8
    ///   12  (variable-length)       0 (unsupported)
    uint256 private constant KNOWN_PROP_SIZES = 0x0882000822888;

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
    error WrongUsdtFeedId(uint32 actual);
    error InvalidUsdtPrice();
    error FeedIdMismatch(uint256 index, uint32 expected, uint32 actual);
    error PayloadLengthMismatch(uint256 pos, uint256 length);
    error UnknownProperty(uint8 pid);
    error UnexpectedPropsCount(uint256 expected, uint256 actual);
    error NotRegisteredFeedId(bytes32 feedId);

    /// @param expectedProperties Array of property IDs that every feed must include.
    ///        Example: `[0, 4, 5]` = Price + Exponent + Confidence.
    ///        All feeds including the USDT conversion feed must carry all listed properties.
    ///        Variable-length properties (6, 7, 8, 12) are not supported and will revert.
    constructor(
        address pythLazerAddress,
        uint256 maxTimeDrift,
        uint32 usdConversionFeedId,
        uint8[] memory expectedProperties
    ) {
        pythLazer = PythLazer(pythLazerAddress);
        MAX_TIME_DRIFT = maxTimeDrift;
        USD_CONVERTION_FEED_ID = usdConversionFeedId;

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
        PROP_CONFIG = propConfig;
        EXPECTED_MASK = expectedMask;
        EXPECTED_PROPS_COUNT = count;
    }

    function verifyAndStream(
        uint32[] calldata feedIds,
        bytes calldata priceUpdate
    ) external returns (uint256[] memory values) {
        return _verifyAndStream(feedIds, priceUpdate);
    }

    // @note: functions expect:
    // - USDT feed at 0 index of `feedIds` and `priceUpdate`
    // - each feed must include all properties specified at deploy time
    function _verifyAndStream(
        uint32[] memory feedIds,
        bytes memory priceUpdate
    ) internal returns (uint256[] memory values) {
        (uint256[] memory raw, uint256 usdtRateU, int256 usdtExpo, uint256 tsPart, uint256 pos, uint256 payloadLen) =
            _verifyPayload(feedIds, priceUpdate);

        values = raw;
        unchecked {
            for (uint256 i = 0; i < values.length; ++i) {
                uint256 v = values[i];
                if ((v & 1) == 0) continue;

                (uint64 normPrice, uint256 spreadU, bytes32 feedId) =
                    _normalize(v, usdtRateU, usdtExpo);

                values[i] =
                    (uint256(feedId) << 128) |
                    (uint256(normPrice) << 96) |
                    (spreadU << 80) |
                    tsPart;
            }
        }

        if (pos != payloadLen) revert PayloadLengthMismatch(pos, payloadLen);
    }

    function _verifyAndStore(
        EnumerableSet.Bytes32Set storage __feedIds,
        mapping(bytes32 => IOffchainOracle.OracleData) storage __data,
        uint32[] memory feedIds,
        bytes memory priceUpdate
    ) internal {
        (uint256[] memory raw, uint256 usdtRateU, int256 usdtExpo, uint256 tsPart, uint256 pos, uint256 payloadLen) =
            _verifyPayload(feedIds, priceUpdate);

        unchecked {
            for (uint256 i = 0; i < raw.length; ++i) {
                uint256 v = raw[i];

                bytes32 feedId;
                uint64 normPrice;
                uint256 spreadU;

                if ((v & 1) == 0) {
                    feedId = bytes32(v >> 128 & X32);
                    normPrice = 0;
                    spreadU = 0xFFFF;
                } else {
                    (normPrice, spreadU, feedId) = _normalize(v, usdtRateU, usdtExpo);
                }

                TimeMs ts = toTimeMs(tsPart);
                ts.revertIfZero();
                ts.revertIfAfterBlockTimeWithDrift(MAX_TIME_DRIFT);

                if (!__feedIds.contains(feedId)) {
                    revert NotRegisteredFeedId(feedId);
                }

                if (ts.isAfter(__data[feedId].timestampMs)) {
                    __data[feedId] = IOffchainOracle.OracleData({
                        price: normPrice,
                        spread: spreadU.toUint16(),
                        volatility: 0xFFFF,
                        timestampMs: ts
                    });
                }
            }
        }

        if (pos != payloadLen) revert PayloadLengthMismatch(pos, payloadLen);
    }

    // Phase 1 (USDT) + Phase 2 (remaining feeds parsing + marker-bit packing)
    function _verifyPayload(
        uint32[] memory feedIds,
        bytes memory priceUpdate
    ) private returns (
        uint256[] memory values,
        uint256 usdtRateU,
        int256 usdtExpo,
        uint256 tsPart,
        uint256 pos,
        uint256 payloadLen
    ) {
        (bytes memory payload,) = pythLazer.verifyUpdate{value: PYTH_VERIFICATION_FEE}(priceUpdate);
        payloadLen = payload.length;

        uint256 feedsLen;
        uint32 _usdFeedId = USD_CONVERTION_FEED_ID;
        uint256 propCfg = PROP_CONFIG;
        uint256 expMask = EXPECTED_MASK;
        uint256 expCount = EXPECTED_PROPS_COUNT;

        assembly ("memory-safe") {
            // ── Yul helper: parse one feed's header + properties ──────────
            // Reverts on unexpected pids, wrong count, or missing fields.
            // Returns: feedId, price, expo, conf, newPos
            function parseFeedProps(base, fpos, cfg, mask, cnt)
                -> fid, price, expo, conf, npos
            {
                let hdr := mload(add(base, fpos))
                fid := shr(224, hdr)
                let numProps := and(shr(216, hdr), 0xFF)
                npos := add(fpos, 5)

                // Revert if numProps != expected count
                if iszero(eq(numProps, cnt)) {
                    mstore(0x00, 0xf777c38b) // UnexpectedPropsCount(uint256,uint256)
                    mstore(0x04, cnt)
                    mstore(0x24, numProps)
                    revert(0x00, 0x44)
                }

                let foundMask := 0
                for { let j := 0 } lt(j, numProps) { j := add(j, 1) } {
                    let w := mload(add(base, npos))
                    let pid := shr(248, w)
                    npos := add(npos, 1)

                    let size := and(shr(mul(pid, 4), cfg), 0xF)
                    // Revert if property not in config
                    if iszero(size) {
                        mstore(0x00, 0x0ca46524) // UnknownProperty(uint8)
                        mstore(0x04, pid)
                        revert(0x00, 0x24)
                    }

                    switch pid
                    case 0 { price := signextend(7, shr(192, shl(8, w))) }
                    case 4 { expo := signextend(1, shr(240, shl(8, w))) }
                    case 5 { conf := shr(192, shl(8, w)) }
                    default {}

                    npos := add(npos, size)
                    foundMask := or(foundMask, shl(pid, 1))
                }

                // Revert if not all expected fields were found
                if iszero(eq(foundMask, mask)) {
                    mstore(0x00, 0xf777c38b) // UnexpectedPropsCount(uint256,uint256)
                    mstore(0x04, mask)
                    mstore(0x24, foundMask)
                    revert(0x00, 0x44)
                }
            }

            let base := add(payload, 0x20)
            let w0 := mload(base)

            // Magic check
            if iszero(eq(shr(224, w0), FORMAT_MAGIC)) {
                mstore(0x00, 0x01d369bb)
                revert(0x1c, 0x04)
            }

            // timestamp μs -> ms
            tsPart := div(and(shr(160, w0), 0xFFFFFFFFFFFFFFFF), 1000)

            feedsLen := and(shr(144, w0), 0xFF)
            pos := 14

            // ═══════════════════════════════════════════════════════════
            // Phase 1: Parse USD Convertion feed
            // ═══════════════════════════════════════════════════════════
            let feedId, price, expo, _conf
            feedId, price, expo, _conf, pos :=
                parseFeedProps(base, pos, propCfg, expMask, expCount)

            if iszero(eq(feedId, _usdFeedId)) {
                mstore(0x00, 0x7e5a9e87)
                mstore(0x04, feedId)
                revert(0x00, 0x24)
            }

            if iszero(sgt(price, 0)) {
                mstore(0x00, 0x8cd22d19)
                revert(0x1c, 0x04)
            }

            usdtRateU := price
            usdtExpo := expo
        }

        if (feedIds.length != feedsLen) revert FeedsLengthMismatch(feedsLen, feedIds.length);
        if (feedsLen == 0) revert NoFeeds();

        // ═══════════════════════════════════════════════════════════════
        // Phase 2: Parse remaining feeds
        // ═══════════════════════════════════════════════════════════════
        values = new uint256[](feedsLen - 1);
        uint256 defaultPacked = (BPS_BASE << 80) | (uint256(type(uint16).max) << 64) | tsPart;

        assembly ("memory-safe") {
            // ── Yul helper (repeated for second assembly block) ───────────
            function parseFeedProps2(base, fpos, cfg, mask, cnt)
                -> fid, price, expo, conf, npos
            {
                let hdr := mload(add(base, fpos))
                fid := shr(224, hdr)
                let numProps := and(shr(216, hdr), 0xFF)
                npos := add(fpos, 5)

                if iszero(eq(numProps, cnt)) {
                    mstore(0x00, 0xf777c38b) // UnexpectedPropsCount(uint256,uint256)
                    mstore(0x04, cnt)
                    mstore(0x24, numProps)
                    revert(0x00, 0x44)
                }

                let foundMask := 0
                for { let j := 0 } lt(j, numProps) { j := add(j, 1) } {
                    let w := mload(add(base, npos))
                    let pid := shr(248, w)
                    npos := add(npos, 1)

                    let size := and(shr(mul(pid, 4), cfg), 0xF)
                    if iszero(size) {
                        mstore(0x00, 0x0ca46524) // UnknownProperty(uint8)
                        mstore(0x04, pid)
                        revert(0x00, 0x24)
                    }

                    switch pid
                    case 0 { price := signextend(7, shr(192, shl(8, w))) }
                    case 4 { expo := signextend(1, shr(240, shl(8, w))) }
                    case 5 { conf := shr(192, shl(8, w)) }
                    default {}

                    npos := add(npos, size)
                    foundMask := or(foundMask, shl(pid, 1))
                }

                if iszero(eq(foundMask, mask)) {
                    mstore(0x00, 0xf777c38b) // UnexpectedPropsCount(uint256,uint256)
                    mstore(0x04, mask)
                    mstore(0x24, foundMask)
                    revert(0x00, 0x44)
                }
            }

            let base := add(payload, 0x20)
            let valuesPtr := add(values, 0x20)
            let feedIdsPtr := add(feedIds, 0x20)

            for { let i := 1 } lt(i, feedsLen) { i := add(i, 1) } {
                let feedId, p, expo, conf
                feedId, p, expo, conf, pos :=
                    parseFeedProps2(base, pos, propCfg, expMask, expCount)

                let expected := mload(add(feedIdsPtr, mul(i, 0x20)))
                let slot := add(valuesPtr, mul(sub(i, 1), 0x20))

                // Verify feedId
                if iszero(eq(expected, feedId)) {
                    mstore(0x00, 0xf9d041bd)
                    mstore(0x04, i)
                    mstore(0x24, expected)
                    mstore(0x44, feedId)
                    revert(0x00, 0x64)
                }

                // price <= 0 → default
                if iszero(sgt(p, 0)) {
                    mstore(slot, or(defaultPacked, shl(128, feedId)))
                    continue
                }

                // Pack raw data with marker bit
                // Layout: p[192:255] | expo[176:191] | conf[112:175] | feedId[32:63] | marker[0]
                mstore(
                    slot,
                    or(
                        or(
                            or(
                                or(shl(192, p), shl(176, and(expo, 0xFFFF))),
                                shl(112, conf)
                            ),
                            shl(32, feedId)
                        ),
                        1
                    )
                )
            }
        }
    }

    // Phase 3: Decimal normalization for a single marker-packed value
    function _normalize(
        uint256 raw,
        uint256 usdtRateU,
        int256 usdtExpo
    ) private pure returns (uint64 normPrice, uint256 spreadU, bytes32 feedId) {
        unchecked {
            uint256 pU = (raw >> 192 & X64).toUint64();
            int256 expo = int16((raw >> 176 & X16).toUint16());
            uint64 conf = (raw >> 112 & X64).toUint64();
            feedId = bytes32(raw >> 32 & X32);

            int256 totalExpo = expo - usdtExpo + TARGET_DECIMALS;
            require(totalExpo >= -77 && totalExpo <= 77);

            uint256 rawPrice;
            if (totalExpo >= 0) {
                uint256 scale = 10 ** totalExpo.toUint256();
                rawPrice = (pU * scale) / usdtRateU;
            } else {
                uint256 scale = 10 ** (-totalExpo).toUint256();
                rawPrice = pU / (usdtRateU * scale);
            }

            normPrice = rawPrice.toUint64();

            spreadU = Math.ceilDiv(BPS_BASE * uint256(conf), pU);
            if (spreadU > BPS_BASE) spreadU = BPS_BASE;
        }
    }

    function unpack(
        uint256 packed
    ) external pure returns (uint32 feedId, uint64 price, uint16 spread, uint64 ts) {
        return _unpack(packed);
    }

    function _unpack(
        uint256 packed
    ) internal pure returns (uint32 feedId, uint64 price, uint16 spread, uint64 ts) {
        assembly {
            feedId := shr(128, packed)
            price := shr(96, packed)
            spread := and(shr(80, packed), 0xFFFF)
            ts := and(packed, 0xFFFFFFFFFFFFFFFFFF)
        }
    }
}
