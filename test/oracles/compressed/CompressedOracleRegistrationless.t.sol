// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {CompressedOracleV1, ICompressedOracleV1} from "../../../contracts/oracles/compressed/CompressedOracle.sol";
import {IOffchainOracle} from "../../../contracts/interfaces/IOffchainOracle.sol";
import {U64x32} from "../../../contracts/oracles/utils/U64x32.sol";
import {TimeMs} from "../../../contracts/oracles/utils/TimeMs.sol";

/// @dev Registrationless semantics: a feed's LOCATION (creator, chainid, slot, position)
///      IS its identity. No creation step, no registry, no seeding.
contract CompressedOracleRegistrationlessTest is Test {
    CompressedOracleV1 private oracle;

    uint8 private constant MAX_PER_SLOT = 4;
    uint256 private constant X80 = 0xFFFFFFFFFFFFFFFFFFFF;

    function setUp() public {
        oracle = new CompressedOracleV1(address(this), 0);
        vm.warp(1_700_000_000);
    }

    /*
     * a. fuzz roundtrip: feedIdOf() encodes exactly what reads decode.
     */
    function testFuzzFeedIdRoundtrip(uint160 creatorRaw, uint8 slotId, uint8 pos, uint32 price) public {
        vm.assume(creatorRaw != 0);
        address creator = address(creatorRaw);
        pos = uint8(bound(pos, 0, MAX_PER_SLOT - 1));

        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 raw = _packRaw(price, 4, 6);

        vm.prank(creator);
        (bool ok,) = address(oracle).call(_wordAt(slotId, pos, raw, tsMs));
        assertTrue(ok, "push failed");

        bytes32 feedId = oracle.feedIdOf(creator, slotId, pos);
        IOffchainOracle.OracleData memory data = oracle.getOracleData(feedId);
        assertEq(data.price, U64x32.decode(price), "roundtrip price mismatch");
        assertEq(TimeMs.unwrap(data.timestampMs), uint256(tsMs), "roundtrip ts mismatch");

        // The feedId decodes back to the same coordinates via a fresh derivation.
        assertEq(feedId, oracle.feedIdOf(creator, slotId, pos), "feedId not deterministic");
    }

    /*
     * b. foreign-chainid feedId reverts FeedNotFound on reads.
     */
    function testForeignChainIdReverts() public {
        address creator = address(0xC0FFEE);
        bytes32 good = oracle.feedIdOf(creator, 3, 1);

        // flip the chainid field (bits [95:16]) to something other than block.chainid
        uint256 foreignChain = block.chainid ^ 1;
        bytes32 foreign =
            bytes32((uint256(uint160(creator)) << 96) | (foreignChain << 16) | (uint256(3) << 8) | uint256(1));
        assertTrue(foreign != good, "sanity: foreign id differs");

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, foreign));
        oracle.getOracleData(foreign);

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, foreign));
        oracle.price(foreign, address(0));

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, foreign));
        oracle.getSlotLayout(foreign);

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, foreign));
        oracle.getCompressedOracle(foreign);
    }

    /*
     * c. position >= 4 reverts FeedNotFound.
     */
    function testPositionOutOfRangeReverts() public {
        address creator = address(0xC0FFEE);
        bytes32 badPos =
            bytes32((uint256(uint160(creator)) << 96) | (block.chainid << 16) | (uint256(0) << 8) | uint256(4));

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, badPos));
        oracle.getOracleData(badPos);

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, badPos));
        oracle.price(badPos, address(0));
    }

    function testZeroCreatorReverts() public {
        bytes32 zeroCreator = bytes32((block.chainid << 16) | uint256(0));
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, zeroCreator));
        oracle.getOracleData(zeroCreator);
    }

    /*
     * d. push into a never-"created" slot, then price() returns the data with no registration.
     *    A never-pushed feedId reads ts=0/price=0.
     */
    function testZeroSetupPushThenPrice() public {
        address creator = address(0xABCD);
        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 raw = _packRaw(1_234_000, 5, 3);

        // No createOracles, no seeding — the creator pushes straight into (slot=8, pos=1).
        vm.prank(creator);
        (bool ok,) = address(oracle).call(_wordAt(8, 1, raw, tsMs));
        assertTrue(ok, "zero-setup push failed");

        (uint256 mid,,, uint256 refTime) = oracle.price(oracle.feedIdOf(creator, 8, 1), address(0));
        assertEq(mid, U64x32.decode(uint32(raw >> 16)), "price() should return pushed data");
        assertEq(refTime, uint256(tsMs) / 1000, "refTime mismatch");

        // A sibling lane in the SAME slot shares the slot's 56-bit timestamp word, but its own
        // 48-bit price lane was never written → price 0 (the timestamp is per-slot, not per-lane).
        IOffchainOracle.OracleData memory sibling = oracle.getOracleData(oracle.feedIdOf(creator, 8, 0));
        assertEq(sibling.price, 0, "never-pushed lane price should be zero");

        // A feed in a DIFFERENT, never-pushed slot reads all-zero (ts 0 ⇒ stale to consumers).
        IOffchainOracle.OracleData memory untouched = oracle.getOracleData(oracle.feedIdOf(creator, 9, 0));
        assertEq(untouched.price, 0, "never-pushed price should be zero");
        assertEq(TimeMs.unwrap(untouched.timestampMs), 0, "never-pushed ts should be zero");
    }

    /*
     * e. namespace-hijack impossible.
     */
    function testHijackWithoutSignatureReverts() public {
        uint256 victimKey = 0xC0DE;
        address victim = vm.addr(victimKey);
        address attacker = address(0xA77ACc);
        uint256 deadline = block.timestamp + 1 days;

        address[] memory pushers = new address[](1);
        pushers[0] = victim;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = ""; // no consent

        vm.prank(attacker);
        vm.expectRevert();
        oracle.allowPushers(deadline, pushers, sigs);
    }

    function testHijackWithSignatureForDifferentCreatorReverts() public {
        uint256 victimKey = 0xBEEF;
        address victim = vm.addr(victimKey);
        address attacker = address(0xA77ACc);
        address otherCreator = address(0xFEED);
        uint256 deadline = block.timestamp + 1 days;

        // Victim signed consent to be a pusher for `otherCreator`, NOT for the attacker.
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(block.chainid, address(oracle), deadline, victim, otherCreator))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(victimKey, digest);

        address[] memory pushers = new address[](1);
        pushers[0] = victim;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);

        // Attacker replays it in their own namespace: recovered signer != victim → revert.
        vm.prank(attacker);
        vm.expectRevert();
        oracle.allowPushers(deadline, pushers, sigs);
    }

    /*
     * f. self-push: a wallet with no remapping pushes into its OWN namespace.
     */
    function testSelfPushLandsInOwnNamespace() public {
        address wallet = address(0x5E1F);
        assertEq(oracle.namespaceRemapping(wallet), address(0), "precondition: no remapping");

        uint56 tsMs = uint56(block.timestamp * 1000);
        uint48 raw = _packRaw(555_000, 3, 3);

        vm.prank(wallet);
        (bool ok,) = address(oracle).call(_wordAt(4, 2, raw, tsMs));
        assertTrue(ok, "self push failed");

        IOffchainOracle.OracleData memory data = oracle.getOracleData(oracle.feedIdOf(wallet, 4, 2));
        assertEq(data.price, U64x32.decode(uint32(raw >> 16)), "self push should be readable via feedIdOf(wallet, ...)");
    }

    /*
     * g. setPriceGuard auth: creator can set, stranger reverts, and after a stateGuard
     *    handover the new guard can set while the creator can no longer.
     */
    function testGuardHandover() public {
        address creator = address(0xC0FFEE);
        address newGuard = address(0x6A6D);
        bytes32 feedId = oracle.feedIdOf(creator, 0, 0);

        // creator-from-feedId is the default authority
        vm.prank(creator);
        oracle.setPriceGuard(feedId, 1, 100);

        // stranger cannot
        address stranger = address(0xDEAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.InvalidGuard.selector, stranger));
        oracle.setPriceGuard(feedId, 2, 200);

        // creator hands the guard role over
        vm.prank(creator);
        oracle.setPendingStateGuardRole(feedId, newGuard);
        vm.prank(newGuard);
        oracle.acceptStateGuardRole(feedId);
        assertEq(oracle.stateGuard(feedId), newGuard, "stateGuard should be the new guard");

        // new guard can set
        vm.prank(newGuard);
        oracle.setPriceGuard(feedId, 5, 500);

        // creator can no longer
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.InvalidGuard.selector, creator));
        oracle.setPriceGuard(feedId, 6, 600);
    }

    /*
     * Helpers
     */
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
