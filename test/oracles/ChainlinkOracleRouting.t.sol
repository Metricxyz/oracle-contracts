// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ChainlinkOracle} from "../../contracts/oracles/providers/ChainlinkOracle.sol";
import {ReportV3} from "../../contracts/interfaces/IDataStreams.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockVerifierProxy} from "../mocks/MockVerifierProxy.sol";
import {MockPoolFactory} from "../mocks/MockPoolFactory.sol";
import {IPool} from "../../contracts/interfaces/IPoolFactory.sol";

/// @notice Version-tag routing: a one-byte tag prefixes every payload and selects which
///         VerifierProxy (and which verify path — payable `verify` vs gasless `verifyView`)
///         the report is forwarded to. Covers the registry admin surface, per-tag routing,
///         and mixed-version batches.
contract ChainlinkOracleRoutingTest is Test {
    uint256 private constant MAX_DRIFT = 60;
    uint256 private constant T0 = 1_000_000;

    int192 private constant PRICE = 150e18;
    uint64 private constant MID8 = 15_000_000_000;

    uint8 private constant TAG_V050 = 0x50;
    uint8 private constant TAG_V051 = 0x51;

    ChainlinkOracle private oracle;
    MockVerifierProxy private v050; // payable verify
    MockVerifierProxy private v051; // gasless verifyView
    MockPoolFactory private factory;
    address private pool;
    address private stranger = makeAddr("stranger");

    function setUp() public {
        v050 = new MockVerifierProxy();
        v051 = new MockVerifierProxy();

        ChainlinkOracle.VerifierRoute[] memory routes = new ChainlinkOracle.VerifierRoute[](2);
        routes[0] = ChainlinkOracle.VerifierRoute(TAG_V050, address(v050), false);
        routes[1] = ChainlinkOracle.VerifierRoute(TAG_V051, address(v051), true);
        oracle = new ChainlinkOracle(address(this), MAX_DRIFT, routes, makeAddr("feeToken"));
        vm.deal(address(oracle), 1 ether);

        factory = new MockPoolFactory();
        oracle.addApprovedFactory(address(factory));
        pool = makeAddr("pool");
        factory.setPool(pool, true);
        vm.deal(address(this), 1 ether);

        vm.warp(T0);
    }

    // ── helpers ──
    function _report(uint8 tag, bytes32 feedId, int192 price, uint32 obsSec) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                tag, abi.encode(ReportV3(feedId, obsSec, obsSec, 0, 0, obsSec + 3600, price, price, price))
            );
    }

    function _feed(uint16 idx) internal pure returns (bytes32) {
        return bytes32((uint256(3) << 240) | uint256(idx));
    }

    function _read(bytes32 feedId) internal returns (uint256 mid) {
        if (!oracle.registeredPool(feedId, pool)) oracle.register{value: 1}(feedId, pool, address(factory));
        vm.mockCall(pool, abi.encodeWithSelector(IPool.inSwap.selector), abi.encode(address(this)));
        (mid,,,) = oracle.price(feedId, pool);
    }

    // ── constructor / registry ──

    function test_constructor_registersRoutes() public view {
        (, bool view050) = oracle.verifierByTag(TAG_V050);
        (, bool view051) = oracle.verifierByTag(TAG_V051);
        assertEq(view050, false);
        assertEq(view051, true);
        assertEq(oracle.verifierTags().length, 2, "both tags registered");
    }

    function test_constructor_requiresAtLeastOne() public {
        ChainlinkOracle.VerifierRoute[] memory empty = new ChainlinkOracle.VerifierRoute[](0);
        vm.expectRevert(ChainlinkOracle.NoVerifiers.selector);
        new ChainlinkOracle(address(this), MAX_DRIFT, empty, makeAddr("feeToken"));
    }

    // ── routing per tag ──

    function test_routesToV050_payablePath() public {
        bytes32 feedId = _feed(1);
        uint256 balBefore = address(oracle).balance;
        oracle.updateReport(_report(TAG_V050, feedId, PRICE, uint32(T0)));
        uint256 balAfter = address(oracle).balance; // measure before _read (which registers, +1 wei)

        assertEq(_read(feedId), MID8, "stored via v0.5.0 proxy");
        // The payable path routes through v050; the fee (0 here) equals what v050 received.
        assertEq(balBefore - balAfter, v050.received(), "fee accrues to v0.5.0 verifier");
        assertEq(v051.received(), 0, "v0.5.1 verifier untouched");
    }

    function test_routesToV051_viewPath_noFee() public {
        bytes32 feedId = _feed(2);
        uint256 balBefore = address(oracle).balance;
        oracle.updateReport(_report(TAG_V051, feedId, PRICE, uint32(T0)));
        uint256 balAfter = address(oracle).balance; // measure before _read (which registers, +1 wei)

        assertEq(_read(feedId), MID8, "stored via v0.5.1 proxy");
        assertEq(balAfter, balBefore, "verifyView takes no fee");
        assertEq(v050.received(), 0, "v0.5.0 verifier untouched");
    }

    function test_unknownTag_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.UnknownVerifierTag.selector, uint8(0x00)));
        oracle.updateReport(_report(0x00, _feed(1), PRICE, uint32(T0)));
    }

    function test_emptyPayload_reverts() public {
        vm.expectRevert(ChainlinkOracle.EmptyPayload.selector);
        oracle.updateReport("");
    }

    // ── mixed-version batch ──

    function test_batch_mixedTags_routeIndependently() public {
        bytes32 f1 = _feed(1);
        bytes32 f2 = _feed(2);
        bytes[] memory reports = new bytes[](2);
        reports[0] = _report(TAG_V050, f1, PRICE, uint32(T0)); // payable
        reports[1] = _report(TAG_V051, f2, 200e18, uint32(T0)); // view
        oracle.updateReports(reports);

        assertEq(_read(f1), MID8);
        assertEq(_read(f2), 20_000_000_000);
    }

    // ── admin set / remove ──

    function test_setVerifier_addsNewTag() public {
        MockVerifierProxy extra = new MockVerifierProxy();
        vm.expectEmit(true, true, false, true, address(oracle));
        emit ChainlinkOracle.VerifierSet(0x60, address(extra), true);
        oracle.setVerifier(0x60, address(extra), true);

        bytes32 feedId = _feed(7);
        oracle.updateReport(_report(0x60, feedId, PRICE, uint32(T0)));
        assertEq(_read(feedId), MID8, "routes to the newly registered tag");
    }

    function test_setVerifier_updatesExistingTag() public {
        MockVerifierProxy replacement = new MockVerifierProxy();
        oracle.setVerifier(TAG_V050, address(replacement), true); // flip to the view path too
        assertEq(oracle.verifierTags().length, 2, "updating a tag does not add a new one");

        // The replacement (view path) now serves TAG_V050; the old payable verifier is untouched.
        bytes32 feedId = _feed(9);
        oracle.updateReport(_report(TAG_V050, feedId, PRICE, uint32(T0)));
        assertEq(_read(feedId), MID8, "routes to the replacement verifier");
        assertEq(v050.received(), 0, "old verifier no longer receives");
    }

    function test_removeVerifier_makesTagRevert() public {
        oracle.removeVerifier(TAG_V051);
        assertEq(oracle.verifierTags().length, 1, "tag removed");

        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.UnknownVerifierTag.selector, TAG_V051));
        oracle.updateReport(_report(TAG_V051, _feed(1), PRICE, uint32(T0)));
    }

    function test_removeVerifier_unknownTag_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.UnknownVerifierTag.selector, uint8(0xEE)));
        oracle.removeVerifier(0xEE);
    }

    function test_setVerifier_zeroProxy_reverts() public {
        vm.expectRevert();
        oracle.setVerifier(0x70, address(0), false);
    }

    // ── access control ──

    function test_setVerifier_onlyAdmin() public {
        bytes32 adminRole = oracle.ADMIN_ROLE(); // resolve before prank so the view call doesn't consume it
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        vm.prank(stranger);
        oracle.setVerifier(0x80, address(v050), false);
    }

    function test_removeVerifier_onlyAdmin() public {
        bytes32 adminRole = oracle.ADMIN_ROLE(); // resolve before prank so the view call doesn't consume it
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        vm.prank(stranger);
        oracle.removeVerifier(TAG_V050);
    }
}
