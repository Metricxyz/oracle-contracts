// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TimeMs} from "../oracles/utils/TimeMs.sol";
import {IOffchainOracle} from "./IOffchainOracle.sol";

interface ICompressedOracleV1 {
    struct CompressedOracleData {
        uint32 p; // pseudo-float encoded price
        uint8 s0; // spread index in codebook
        uint8 s1; // spread index in codebook
    } // 32+8+8 = 48

    struct SlotLayout {
        CompressedOracleData oracle0;
        CompressedOracleData oracle1;
        CompressedOracleData oracle2;
        CompressedOracleData oracle3;
        TimeMs timestampMs; // unix timestamp in milliseconds
    } // 48*4 + 64 = 248

    error InvalidPosition(uint8 index);
    error CodebookDecodeFailed(uint8 index);
    error InvalidManager(address manager);

    error InvalidNamespace();
    error NoSelfRemapping();

    function getSlotLayout(bytes32 feedId) external view returns (SlotLayout memory);
    function getCompressedOracle(bytes32 feedId)
        external
        view
        returns (CompressedOracleData memory data, TimeMs timestamp);

    /// Deterministic, registrationless feed id: the feed's location IS its identity.
    /// bits [255:96] creator, [95:16] chainid, [15:8] slotIndex, [7:0] positionIndex.
    function feedIdOf(address creator, uint8 slotIndex, uint8 positionIndex) external view returns (bytes32);

    event PusherAuthorized(address indexed pusher, address indexed creator);
    event PusherRevoked(address indexed pusher, address indexed creator);
}
