// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {CompressedOracleV1} from "../../../contracts/oracles/compressed/CompressedOracle.sol";
import {ICompressedOracleV1} from "../../../contracts/interfaces/ICompressedOracleV1.sol";
import {IOffchainOracle} from "../../../contracts/interfaces/IOffchainOracle.sol";

/// @dev Regression tests for `_isDataValid` lane masking.
contract CompressedOracleIsDataValidBugTest is Test {
    CompressedOracleV1 private oracle;

    function setUp() public {
        oracle = new CompressedOracleV1(address(this), 0);
    }

    function testUpdateBySignatureRevertsForEmptyCurrentSlot() public {
        vm.warp(1_000);

        uint256 creatorKey = 0xC0FFEE;
        address creator = vm.addr(creatorKey);

        _createFeeds(creator, 4); // fills slot 0, advances `currentSlotIndex` to 1 with `nextPositionIndex == 0`

        uint8 emptySlotId = 1;
        uint56 timestampMs = uint56(block.timestamp * 1000);
        uint48 lane0 = 0x010203040506;
        uint256 newSlotValue = (uint256(lane0) << 208) | (uint256(timestampMs) << 8) | uint256(emptySlotId);

        uint256 deadline = block.timestamp + 60;
        bytes memory sig = _signUpdate(creatorKey, creator, deadline, newSlotValue);

        // Regression: slotId == currentSlotIndex must be rejected while nextPositionIndex == 0 (slot is empty).
        vm.expectRevert(ICompressedOracleV1.UninializedPush.selector);
        oracle.updateBySignature(creator, deadline, newSlotValue, sig);
    }

    function testUpdateBySignatureAllowsUpdateWhenSlotHasThreeFeeds() public {
        vm.warp(2_000);

        uint256 creatorKey = 0xBEEF;
        address creator = vm.addr(creatorKey);

        _createFeeds(creator, 3); // slot 0 has lanes 0..2 initialized, lane 3 must remain zero

        bytes32 slotKey = _slotKey(creator, 0);
        uint256 existing = uint256(vm.load(address(oracle), slotKey));

        uint56 timestampMs = uint56(block.timestamp * 1000);
        uint256 newSlotValue = existing | (uint256(timestampMs) << 8); // slotId is 0 so LSB stays 0

        uint256 deadline = block.timestamp + 60;
        bytes memory sig = _signUpdate(creatorKey, creator, deadline, newSlotValue);

        // Regression: updating the current (partially filled) slot must be accepted as long as all uncreated lanes
        // remain zero.
        bool ok = oracle.updateBySignature(creator, deadline, newSlotValue, sig);
        assertTrue(ok, "expected update to succeed");
    }

    function _createFeeds(address creator, uint256 count)
        private
        returns (IOffchainOracle.CreationResponse[] memory responses)
    {
        IOffchainOracle.CreationRequest[] memory reqs = new IOffchainOracle.CreationRequest[](count);
        for (uint256 i; i < count; i++) {
            reqs[i] = IOffchainOracle.CreationRequest({
                baseToken: address(uint160(0x1000 + i * 2)),
                quoteToken: address(uint160(0x1000 + i * 2 + 1)),
                minPrice: 0,
                maxPrice: type(uint128).max,
                stateGuard: address(0),
                misc: ""
            });
        }

        vm.prank(creator);
        responses = oracle.createOracles(reqs);
    }

    function _slotKey(address creator, uint8 slotId) private pure returns (bytes32) {
        uint256 namespace = uint256(uint160(creator)) << 96;
        return bytes32(namespace | uint256(slotId));
    }

    function _signUpdate(uint256 creatorKey, address creator, uint256 deadline, uint256 newSlotValue)
        private
        view
        returns (bytes memory)
    {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(block.chainid, address(oracle), creator, deadline, newSlotValue))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(creatorKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
