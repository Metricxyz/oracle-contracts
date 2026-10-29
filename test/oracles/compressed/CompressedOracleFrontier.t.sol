// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CompressedOracleV1, ICompressedOracleV1} from "../../../contracts/oracles/compressed/CompressedOracle.sol";
import {IOffchainOracle} from "../../../contracts/interfaces/IOffchainOracle.sol";

contract CompressedOracleFrontierTest is Test {
    CompressedOracleV1 private oracle;

    address private constant CREATOR = address(0xC0FFEE);

    function setUp() public {
        oracle = new CompressedOracleV1(address(this), 0);
        vm.warp(1000);
    }

    function _mkRequest(address base, address quote)
        internal
        pure
        returns (IOffchainOracle.CreationRequest memory req)
    {
        req.baseToken = base;
        req.quoteToken = quote;
        req.minPrice = 0;
        req.maxPrice = type(uint128).max;
    }

    function _createFeeds(address creator, uint256 count) internal returns (IOffchainOracle.CreationResponse[] memory) {
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](count);
        for (uint256 i; i < count; i++) {
            requests[i] = _mkRequest(
                address(uint160(0x1000 + i * 2)),
                address(uint160(0x1001 + i * 2))
            );
        }
        vm.prank(creator);
        return oracle.createOracles(requests);
    }

    function _unpackMisc(bytes memory data) internal pure returns (address creator, uint8 slotIndex, uint8 positionIndex) {
        assembly ("memory-safe") {
            let packed := mload(add(data, 32))
            creator := shr(96, packed)
            slotIndex := byte(20, packed)
            positionIndex := byte(21, packed)
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  moveFeeds — frontier guard
    // ═══════════════════════════════════════════════════════════

    function testMoveToFutureLaneOnCurrentSlotReverts() public {
        // Create 6 feeds: slot 0 full [0,1,2,3], slot 1 [0,1]
        // Frontier: {currentSlotIndex: 1, nextPositionIndex: 2}
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 6);

        // Deactivate slot 1 pos 0 → explicit occupancy set
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[4].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Try to move feed from slot 0 → slot 1 pos 3 (future lane: 3 >= nextPositionIndex=2)
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[0].feedId,
            targetSlotIndex: 1,
            targetPositionIndex: 3
        });

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.InvalidTargetPosition.selector, 3));
        oracle.moveFeeds(CREATOR, moves);
    }

    function testMoveToExactFrontierPositionReverts() public {
        // Create 5 feeds: slot 0 full, slot 1 [0]. Frontier: {1, 1}
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 5);

        // Deactivate something on a past slot to free it
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[0].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Try to move to slot 1 pos 1 (== nextPositionIndex, should be blocked)
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[1].feedId,
            targetSlotIndex: 1,
            targetPositionIndex: 1
        });

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.InvalidTargetPosition.selector, 1));
        oracle.moveFeeds(CREATOR, moves);
    }

    function testMoveToAllocatedPositionOnCurrentSlotAllowed() public {
        // Create 6 feeds: slot 0 full, slot 1 [0,1]. Frontier: {1, 2}
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 6);

        // Deactivate slot 1 pos 0 → free an allocated position
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[4].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Move feed from slot 0 → slot 1 pos 0 (allocated: 0 < nextPositionIndex=2)
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[0].feedId,
            targetSlotIndex: 1,
            targetPositionIndex: 0
        });

        vm.prank(CREATOR);
        oracle.moveFeeds(CREATOR, moves);

        assertTrue(oracle.isFeedActive(res[0].feedId));
        IOffchainOracle.OracleInfo memory info = oracle.getOracleInfo(res[0].feedId);
        (, uint8 s, uint8 p) = _unpackMisc(info.misc);
        assertEq(s, 1);
        assertEq(p, 0);
    }

    function testMoveToPastSlotUnrestricted() public {
        // Create 8 feeds: slot 0 full, slot 1 full. Frontier: {2, 0}
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 8);

        // Deactivate slot 0 pos 0
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[0].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);

        // Move feed from slot 1 → slot 0 pos 0 (past slot, always allowed)
        ICompressedOracleV1.SlotMoveRequest[] memory moves = new ICompressedOracleV1.SlotMoveRequest[](1);
        moves[0] = ICompressedOracleV1.SlotMoveRequest({
            feedId: res[4].feedId,
            targetSlotIndex: 0,
            targetPositionIndex: 0
        });

        vm.prank(CREATOR);
        oracle.moveFeeds(CREATOR, moves);
        assertTrue(oracle.isFeedActive(res[4].feedId));
    }

    // ═══════════════════════════════════════════════════════════
    //  createOracles — occupancy sync
    // ═══════════════════════════════════════════════════════════

    function testCreateAfterDeactivateSyncsOccupancy() public {
        // Create 3 feeds: slot 0 [0,1,2]. Frontier: {0, 3}
        IOffchainOracle.CreationResponse[] memory res = _createFeeds(CREATOR, 3);
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x07);

        // Deactivate pos 0 → explicit occupancy: pos 1,2 (0x06)
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res[0].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x06);

        // Create 1 more feed → goes to pos 3
        IOffchainOracle.CreationResponse[] memory res2 = _createFeeds(CREATOR, 1);

        // New feed at pos 3 must be visible in explicit occupancy
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x0E, "pos 1,2,3 occupied");
        assertTrue(oracle.isFeedActive(res2[0].feedId), "new feed should be active");
        assertFalse(oracle.isFeedActive(res[0].feedId), "deactivated feed still inactive");
    }

    function testCreateAfterDeactivateNoGhostAlias() public {
        // Create 2 feeds: slot 0 [0,1]. Frontier: {0, 2}
        IOffchainOracle.CreationResponse[] memory res1 = _createFeeds(CREATOR, 2);

        // Deactivate pos 1 → explicit occ: pos 0 (0x01)
        bytes32[] memory deactFeeds = new bytes32[](1);
        deactFeeds[0] = res1[1].feedId;
        vm.prank(CREATOR);
        oracle.deactivateFeeds(deactFeeds);
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x01);

        // Create 2 more feeds → pos 2, pos 3
        IOffchainOracle.CreationResponse[] memory res2 = _createFeeds(CREATOR, 2);

        // Occupancy: pos 0,2,3 = 0x0D
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x0D);
        assertTrue(oracle.isFeedActive(res1[0].feedId));
        assertFalse(oracle.isFeedActive(res1[1].feedId));
        assertTrue(oracle.isFeedActive(res2[0].feedId));
        assertTrue(oracle.isFeedActive(res2[1].feedId));

        // No alias: each feedId has unique (slot, position)
        IOffchainOracle.OracleInfo memory i0 = oracle.getOracleInfo(res2[0].feedId);
        (, uint8 s0, uint8 p0) = _unpackMisc(i0.misc);
        IOffchainOracle.OracleInfo memory i1 = oracle.getOracleInfo(res2[1].feedId);
        (, uint8 s1, uint8 p1) = _unpackMisc(i1.misc);
        assertTrue(s0 != s1 || p0 != p1, "no alias");
    }

    function testCreateWithoutPriorReorgNoExtraGas() public {
        // Normal path: no reorg, no explicit occupancy — SLOAD reads 0, no SSTORE
        _createFeeds(CREATOR, 4);
        // Just verify it works and occupancy is derived (no explicit flag)
        assertEq(oracle.getSlotOccupancy(CREATOR, 0), 0x0F);
    }
}
