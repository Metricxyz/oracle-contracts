// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CompressedOracleV1, ICompressedOracleV1} from "../../../contracts/oracles/compressed/CompressedOracle.sol";
import {IOffchainOracle} from "../../../contracts/interfaces/IOffchainOracle.sol";

/// @dev Mock that always returns true for isPusher
contract MockPusherAllowed {
    function isPusher(address) external pure returns (bool) {
        return true;
    }
}

/// @dev Mock that always returns false for isPusher
contract MockPusherDenied {
    function isPusher(address) external pure returns (bool) {
        return false;
    }
}

/// @dev Mock that returns true only for a specific creator
contract MockPusherSelective {
    address public allowedCreator;

    constructor(address _allowedCreator) {
        allowedCreator = _allowedCreator;
    }

    function isPusher(address caller) external view returns (bool) {
        return caller == allowedCreator;
    }
}

/// @dev Mock that reverts on isPusher
contract MockPusherReverting {
    function isPusher(address) external pure returns (bool) {
        revert("not supported");
    }
}

/// @dev Contract with no isPusher function
contract MockNoPusherInterface {
}

contract CompressedOracleContractPushersTest is Test {
    CompressedOracleV1 private oracle;

    address private creator;

    function setUp() public {
        oracle = new CompressedOracleV1(address(this), 0);
        creator = address(0xC0FFEE);

        // Creator must call createOracles first to initialize namespace
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](1);
        requests[0] = IOffchainOracle.CreationRequest({
            baseToken: address(1),
            quoteToken: address(2),
            minPrice: 0,
            maxPrice: type(uint128).max,
            stateGuard: address(0),
            misc: ""
        });
        vm.prank(creator);
        oracle.createOracles(requests);
    }

    function testAllowContractPusherSuccess() public {
        MockPusherAllowed pusherContract = new MockPusherAllowed();
        uint256 deadline = block.timestamp + 1 days;

        address[] memory pushers = new address[](1);
        pushers[0] = address(pusherContract);

        vm.prank(creator);
        oracle.allowContractPushers(deadline, pushers);

        assertEq(oracle.namespaceRemapping(address(pusherContract)), creator);
    }

    function testAllowMultipleContractPushers() public {
        MockPusherAllowed pusher1 = new MockPusherAllowed();
        MockPusherAllowed pusher2 = new MockPusherAllowed();
        uint256 deadline = block.timestamp + 1 days;

        address[] memory pushers = new address[](2);
        pushers[0] = address(pusher1);
        pushers[1] = address(pusher2);

        vm.prank(creator);
        oracle.allowContractPushers(deadline, pushers);

        assertEq(oracle.namespaceRemapping(address(pusher1)), creator);
        assertEq(oracle.namespaceRemapping(address(pusher2)), creator);
    }

    function testAllowContractPusherRevertsWhenDenied() public {
        MockPusherDenied pusherContract = new MockPusherDenied();
        uint256 deadline = block.timestamp + 1 days;

        address[] memory pushers = new address[](1);
        pushers[0] = address(pusherContract);

        vm.prank(creator);
        vm.expectRevert();
        oracle.allowContractPushers(deadline, pushers);
    }

    function testAllowContractPusherSelectiveCreator() public {
        MockPusherSelective pusherContract = new MockPusherSelective(creator);
        uint256 deadline = block.timestamp + 1 days;

        address[] memory pushers = new address[](1);
        pushers[0] = address(pusherContract);

        // Correct creator succeeds
        vm.prank(creator);
        oracle.allowContractPushers(deadline, pushers);
        assertEq(oracle.namespaceRemapping(address(pusherContract)), creator);
    }

    function testAllowContractPusherSelectiveWrongCreator() public {
        address wrongCreator = address(0xBAAD);
        // wrongCreator needs to call createOracles to initialize namespace
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](1);
        requests[0] = IOffchainOracle.CreationRequest({
            baseToken: address(3),
            quoteToken: address(4),
            minPrice: 0,
            maxPrice: type(uint128).max,
            stateGuard: address(0),
            misc: ""
        });
        vm.prank(wrongCreator);
        oracle.createOracles(requests);

        MockPusherSelective pusherContract = new MockPusherSelective(creator);
        uint256 deadline = block.timestamp + 1 days;

        address[] memory pushers = new address[](1);
        pushers[0] = address(pusherContract);

        // Wrong creator — isPusher returns false
        vm.prank(wrongCreator);
        vm.expectRevert();
        oracle.allowContractPushers(deadline, pushers);
    }

    function testAllowContractPusherRevertsOnRevertingContract() public {
        MockPusherReverting pusherContract = new MockPusherReverting();
        uint256 deadline = block.timestamp + 1 days;

        address[] memory pushers = new address[](1);
        pushers[0] = address(pusherContract);

        vm.prank(creator);
        vm.expectRevert();
        oracle.allowContractPushers(deadline, pushers);
    }

    function testAllowContractPusherRevertsOnNoInterface() public {
        MockNoPusherInterface pusherContract = new MockNoPusherInterface();
        uint256 deadline = block.timestamp + 1 days;

        address[] memory pushers = new address[](1);
        pushers[0] = address(pusherContract);

        vm.prank(creator);
        vm.expectRevert();
        oracle.allowContractPushers(deadline, pushers);
    }

    function testAllowContractPusherRevertsOnExpiredDeadline() public {
        MockPusherAllowed pusherContract = new MockPusherAllowed();
        vm.warp(1000);
        uint256 deadline = block.timestamp - 1;

        address[] memory pushers = new address[](1);
        pushers[0] = address(pusherContract);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.DeadlineExceeded.selector));
        oracle.allowContractPushers(deadline, pushers);
    }

    function testAllowContractPusherRevertsOnSelfRemapping() public {
        uint256 deadline = block.timestamp + 1 days;

        address[] memory pushers = new address[](1);
        pushers[0] = creator; // self — hits CreatorCannotBeRemapped because creator is already mapped to self

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.CreatorCannotBeRemapped.selector));
        oracle.allowContractPushers(deadline, pushers);
    }

    function testAllowContractPusherRevertsOnCreatorRemapping() public {
        // creator already has namespaceRemapping[creator] == creator from createOracles
        // Another caller tries to remap a known creator
        address anotherCreator = address(0xFACE);
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](1);
        requests[0] = IOffchainOracle.CreationRequest({
            baseToken: address(5),
            quoteToken: address(6),
            minPrice: 0,
            maxPrice: type(uint128).max,
            stateGuard: address(0),
            misc: ""
        });
        vm.prank(anotherCreator);
        oracle.createOracles(requests);

        // Now try to remap `creator` (who is already a creator) via anotherCreator
        uint256 deadline = block.timestamp + 1 days;
        address[] memory pushers = new address[](1);
        pushers[0] = creator; // already mapped to self

        vm.prank(anotherCreator);
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.CreatorCannotBeRemapped.selector));
        oracle.allowContractPushers(deadline, pushers);
    }

    function testAllowContractPusherEmptyArraySucceeds() public {
        uint256 deadline = block.timestamp + 1 days;
        address[] memory pushers = new address[](0);

        vm.prank(creator);
        oracle.allowContractPushers(deadline, pushers);
        // No revert, no state changes
    }

    function testContractPusherCanDelegateFallback() public {
        vm.warp(1000);

        // Create 4 feeds to fill the slot completely (avoids _isDataValid rejection)
        IOffchainOracle.CreationRequest[] memory requests = new IOffchainOracle.CreationRequest[](4);
        for (uint256 i; i < 4; i++) {
            requests[i] = IOffchainOracle.CreationRequest({
                baseToken: address(uint160(0xAA01 + i * 2)),
                quoteToken: address(uint160(0xAA02 + i * 2)),
                minPrice: 0,
                maxPrice: type(uint128).max,
                stateGuard: address(0),
                misc: ""
            });
        }
        vm.prank(creator);
        oracle.createOracles(requests);

        MockPusherAllowed pusherContract = new MockPusherAllowed();
        uint256 deadline = block.timestamp + 1 days;

        address[] memory pushers = new address[](1);
        pushers[0] = address(pusherContract);

        vm.prank(creator);
        oracle.allowContractPushers(deadline, pushers);

        // Build a fallback payload: 4-byte deadline + 32-byte entry
        uint32 fbDeadline = uint32(block.timestamp + 10);
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint256 word = uint256(tsMs) << 8; // timestamp in bits [8..63]
        word |= uint256(0); // slotId = 0
        // put data in oracle0 position (shift = 16 + (4-0)*48 = 208)
        word |= uint256(uint48(0x000100FF01)) << 208;
        bytes memory payload = abi.encodePacked(fbDeadline, word);

        vm.prank(address(pusherContract));
        (bool ok, bytes memory revertData) = address(oracle).call(payload);
        if (!ok) emit log_bytes(revertData);
        assertTrue(ok, "delegated fallback via contract pusher should succeed");
    }

    function testContractPusherRevokedCannotPush() public {
        vm.warp(1000);
        MockPusherAllowed pusherContract = new MockPusherAllowed();
        uint256 deadline = block.timestamp + 1 days;

        address[] memory pushers = new address[](1);
        pushers[0] = address(pusherContract);

        vm.prank(creator);
        oracle.allowContractPushers(deadline, pushers);
        assertEq(oracle.namespaceRemapping(address(pusherContract)), creator);

        // Creator removes the pusher
        vm.prank(creator);
        oracle.removePushers(pushers);
        assertEq(oracle.namespaceRemapping(address(pusherContract)), address(0));

        // Build fallback payload
        uint32 fbDeadline = uint32(block.timestamp + 10);
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint256 word = uint256(tsMs) << 8;
        bytes memory payload = abi.encodePacked(fbDeadline, word);

        vm.prank(address(pusherContract));
        vm.expectRevert(abi.encodeWithSelector(ICompressedOracleV1.InvalidNamespace.selector));
        (bool ok,) = address(oracle).call(payload);
        assertTrue(ok, "expectRevert should have caught the revert");
    }

    function testAllowContractPusherRevertsOnEOA() public {
        // EOA has no code, so staticcall to isPusher will fail
        address eoa = address(0xDEAD);
        uint256 deadline = block.timestamp + 1 days;

        address[] memory pushers = new address[](1);
        pushers[0] = eoa;

        vm.prank(creator);
        vm.expectRevert();
        oracle.allowContractPushers(deadline, pushers);
    }

    function testContractPusherCanSelfRevoke() public {
        MockPusherAllowed pusherContract = new MockPusherAllowed();
        uint256 deadline = block.timestamp + 1 days;

        address[] memory pushers = new address[](1);
        pushers[0] = address(pusherContract);

        vm.prank(creator);
        oracle.allowContractPushers(deadline, pushers);
        assertEq(oracle.namespaceRemapping(address(pusherContract)), creator);

        vm.prank(address(pusherContract));
        oracle.revokePusher();
        assertEq(oracle.namespaceRemapping(address(pusherContract)), address(0));
    }
}
