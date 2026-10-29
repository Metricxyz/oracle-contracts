// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TimeMs} from "../oracles/utils/TimeMs.sol";
import {IOffchainOracle} from "./IOffchainOracle.sol";

interface ICompressedOracleV1 {
    struct RegistryInfo {
        uint8 currentSlotIndex;
        uint8 nextPositionIndex;
    } // 8+8 = 16

    struct CompressedOracleData {
        uint32 p; // pseudo-float encoded price
        uint8 s; // spread index in codebook
        uint8 v; // volatility index in codebook
    } // 32+8+8 = 48

    struct SlotLayout {
        CompressedOracleData oracle0;
        CompressedOracleData oracle1;
        CompressedOracleData oracle2;
        CompressedOracleData oracle3;
        TimeMs timestampMs; // unix timestamp in milliseconds
    } // 48*4 + 64 = 248

    struct SlotMoveRequest {
        bytes32 feedId;
        uint8 targetSlotIndex;
        uint8 targetPositionIndex;
    }

    struct SlotSwapRequest {
        bytes32 feedIdA;
        bytes32 feedIdB;
    }

    error SlotLimitExceeded(address creator);
    error InvalidManager(address manager);
    error InvalidPosition(uint8 index);
    error CodebookDecodeFailed(uint8 index);
    error InvalidSlotIndex();

    error InvalidNamespace();
    error CreatorCannotBeRemapped();
    error NoSelfRemapping();

    error UninializedPush();

    error PositionOccupied(uint8 slotIndex, uint8 positionIndex);
    error PositionEmpty(uint8 slotIndex, uint8 positionIndex);
    error NotCreatorOrOwner();
    error InvalidTargetPosition(uint8 positionIndex);
    error FeedNotOwnedByCreator(bytes32 feedId);
    error MoveToSamePosition(bytes32 feedId);


    event FeedMoved(bytes32 indexed feedId, uint8 fromSlotIndex, uint8 fromPositionIndex, uint8 toSlotIndex, uint8 toPositionIndex);
    event FeedDeactivated(bytes32 indexed feedId, uint8 slotIndex, uint8 positionIndex);
    event FeedSwapped(bytes32 indexed feedIdA, bytes32 indexed feedIdB, uint8 slotIndexA, uint8 posA, uint8 slotIndexB, uint8 posB);

    function getSlotLayout(bytes32 feedId) external view returns (SlotLayout memory);
    function getCompressedOracle(bytes32 feedId)
        external
        view
        returns (CompressedOracleData memory data, TimeMs timestamp);

    function deactivateFeeds(bytes32[] calldata feeds) external;
    function moveFeeds(address creator, SlotMoveRequest[] calldata moves) external;
    function swapFeeds(address creator, SlotSwapRequest[] calldata swaps) external;
    function getSlotOccupancy(address creator, uint8 slotIndex) external view returns (uint8);
    function isFeedActive(bytes32 feedId) external view returns (bool);

    event OracleManagerUpdated(bytes32 indexed feedId, address indexed previousManager, address indexed newManager);
    event PusherAuthorized(address indexed pusher, address indexed creator);
    event PusherRevoked(address indexed pusher, address indexed creator);
}
