// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CompressedOracleV1, ICompressedOracleV1} from "../../../contracts/oracles/compressed/CompressedOracle.sol";
import {IOffchainOracle} from "../../../contracts/interfaces/IOffchainOracle.sol";
import {U64x32} from "../../../contracts/oracles/utils/U64x32.sol";
import {TimeMs} from "../../../contracts/oracles/utils/TimeMs.sol";

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
contract MockNoPusherInterface {}

/// @dev Registrationless contract-pusher delegation: consent is proven by a live
///      isPusher(creator) staticcall, so there is no deadline and no creation step.
contract CompressedOracleContractPushersTest is Test {
    CompressedOracleV1 private oracle;

    address private creator;
    uint8 private constant MAX_PER_SLOT = 4;

    function setUp() public {
        oracle = new CompressedOracleV1(address(this), 0);
        creator = address(0xC0FFEE);
        vm.warp(1_700_000_000);
    }

    function _pushers(address a) internal pure returns (address[] memory p) {
        p = new address[](1);
        p[0] = a;
    }

    function testAllowContractPusherSuccess() public {
        MockPusherAllowed pusherContract = new MockPusherAllowed();

        vm.prank(creator);
        oracle.allowContractPushers(_pushers(address(pusherContract)));

        assertEq(oracle.namespaceRemapping(address(pusherContract)), creator);
    }

    function testAllowMultipleContractPushers() public {
        MockPusherAllowed pusher1 = new MockPusherAllowed();
        MockPusherAllowed pusher2 = new MockPusherAllowed();

        address[] memory pushers = new address[](2);
        pushers[0] = address(pusher1);
        pushers[1] = address(pusher2);

        vm.prank(creator);
        oracle.allowContractPushers(pushers);

        assertEq(oracle.namespaceRemapping(address(pusher1)), creator);
        assertEq(oracle.namespaceRemapping(address(pusher2)), creator);
    }

    function testAllowContractPusherRevertsWhenDenied() public {
        MockPusherDenied pusherContract = new MockPusherDenied();

        vm.prank(creator);
        vm.expectRevert();
        oracle.allowContractPushers(_pushers(address(pusherContract)));
    }

    function testAllowContractPusherSelectiveCreator() public {
        MockPusherSelective pusherContract = new MockPusherSelective(creator);

        vm.prank(creator);
        oracle.allowContractPushers(_pushers(address(pusherContract)));
        assertEq(oracle.namespaceRemapping(address(pusherContract)), creator);
    }

    function testAllowContractPusherSelectiveWrongCreator() public {
        address wrongCreator = address(0xBAAD);
        MockPusherSelective pusherContract = new MockPusherSelective(creator);

        vm.prank(wrongCreator);
        vm.expectRevert();
        oracle.allowContractPushers(_pushers(address(pusherContract)));
    }

    function testAllowContractPusherRevertsOnRevertingContract() public {
        MockPusherReverting pusherContract = new MockPusherReverting();

        vm.prank(creator);
        vm.expectRevert();
        oracle.allowContractPushers(_pushers(address(pusherContract)));
    }

    function testAllowContractPusherRevertsOnNoInterface() public {
        MockNoPusherInterface pusherContract = new MockNoPusherInterface();

        vm.prank(creator);
        vm.expectRevert();
        oracle.allowContractPushers(_pushers(address(pusherContract)));
    }

    function testAllowContractPusherRevertsOnSelfRemapping() public {
        vm.prank(creator);
        vm.expectRevert(ICompressedOracleV1.NoSelfRemapping.selector);
        oracle.allowContractPushers(_pushers(creator));
    }

    function testAllowContractPusherEmptyArraySucceeds() public {
        address[] memory pushers = new address[](0);

        vm.prank(creator);
        oracle.allowContractPushers(pushers);
        // No revert, no state changes
    }

    function testAllowContractPusherRevertsOnEOA() public {
        // EOA has no code, so staticcall to isPusher will fail
        address eoa = address(0xDEAD);

        vm.prank(creator);
        vm.expectRevert();
        oracle.allowContractPushers(_pushers(eoa));
    }

    function testContractPusherCanDelegatePush() public {
        MockPusherAllowed pusherContract = new MockPusherAllowed();

        vm.prank(creator);
        oracle.allowContractPushers(_pushers(address(pusherContract)));

        // push lands in the CREATOR namespace, not the pusher contract's own
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 raw = _packRaw(1_000_000, 5, 3);
        bytes memory payload = _wordAt(7, 2, raw, tsMs);

        vm.prank(address(pusherContract));
        (bool ok, bytes memory revertData) = address(oracle).call(payload);
        if (!ok) emit log_bytes(revertData);
        assertTrue(ok, "delegated push via contract pusher should succeed");

        IOffchainOracle.OracleData memory data = oracle.getOracleData(oracle.feedIdOf(creator, 7, 2));
        assertEq(data.price, U64x32.decode(uint32(raw >> 16)), "delegated push should land in creator namespace");
        assertEq(oracle.getOracleData(oracle.feedIdOf(address(pusherContract), 7, 2)).price, 0, "own ns must stay empty");
    }

    function testContractPusherRevokedPushesOwnNamespace() public {
        MockPusherAllowed pusherContract = new MockPusherAllowed();

        vm.prank(creator);
        oracle.allowContractPushers(_pushers(address(pusherContract)));
        assertEq(oracle.namespaceRemapping(address(pusherContract)), creator);

        vm.prank(creator);
        oracle.removePushers(_pushers(address(pusherContract)));
        assertEq(oracle.namespaceRemapping(address(pusherContract)), address(0));

        // After revocation the wallet falls back to pushing into its OWN namespace (no revert).
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 raw = _packRaw(800_000, 2, 2);
        vm.prank(address(pusherContract));
        (bool ok,) = address(oracle).call(_wordAt(0, 0, raw, tsMs));
        assertTrue(ok, "post-revoke self push should succeed");

        assertEq(
            oracle.getOracleData(oracle.feedIdOf(address(pusherContract), 0, 0)).price,
            U64x32.decode(uint32(raw >> 16)),
            "post-revoke push lands in own namespace"
        );
        assertEq(oracle.getOracleData(oracle.feedIdOf(creator, 0, 0)).price, 0, "creator namespace must stay empty");
    }

    function testContractPusherCanSelfRevoke() public {
        MockPusherAllowed pusherContract = new MockPusherAllowed();

        vm.prank(creator);
        oracle.allowContractPushers(_pushers(address(pusherContract)));
        assertEq(oracle.namespaceRemapping(address(pusherContract)), creator);

        vm.prank(address(pusherContract));
        oracle.revokePusher();
        assertEq(oracle.namespaceRemapping(address(pusherContract)), address(0));
    }

    /*
     * Helpers
     */

    /// Slot word layout: [data0:6][data1:6][data2:6][data3:6][ts:7][slotId:1]
    function _wordAt(uint8 slotId, uint8 pos, uint48 raw, uint56 tsMs) internal pure returns (bytes memory) {
        require(pos < MAX_PER_SLOT, "invalid position");
        uint256 word = (uint256(tsMs) << 8) | uint256(slotId);
        word |= uint256(raw) << (208 - uint256(pos) * 48);
        return abi.encodePacked(word);
    }

    function _packRaw(uint32 price, uint8 s0, uint8 s1) internal pure returns (uint48) {
        return (uint48(price) << 16) | (uint48(s0) << 8) | uint48(s1);
    }
}
