// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PriceProviderFactoryL2} from "../contracts/PriceProviderFactoryL2.sol";
import {PriceProviderL2} from "../contracts/PriceProviderL2.sol";
import {IPriceProviderFactoryL2} from "../contracts/interfaces/IPriceProviderFactoryL2.sol";
import {IOffchainOracle} from "../contracts/interfaces/IOffchainOracle.sol";

// ── Mock oracle ────────────────────────────────────────────────────────────

// Registrationless + token-free: only the gated price() path plus priceGuard.
contract MockOracleL2 is IOffchainOracle {
    mapping(bytes32 => uint256) private refTimes;

    function setRefTime(bytes32 feedId, uint256 t) external {
        refTimes[feedId] = t;
    }

    function price(bytes32 feedId, address)
        external
        view
        returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime)
    {
        refTime = refTimes[feedId];
        if (refTime == 0) refTime = block.timestamp;
        return (150_000_000, 160_000_000, 100, refTime);
    }

    function priceGuard(bytes32) external pure override returns (uint128, uint128) { return (0, 0); }

    // --- unused stubs ---
    function getOracleData(bytes32) external pure override returns (OracleData memory d) { return d; }
    function getOracleDataBulk(bytes32[] calldata) external pure override returns (OracleData[] memory d) { return d; }
}

// ── Tests ──────────────────────────────────────────────────────────────────

contract PriceProviderFactoryL2Test is Test {
    PriceProviderFactoryL2 private factory;
    MockOracleL2 private oracle;

    address private owner = address(this);
    address private nonOwner = address(0xBAAD);
    address private updater = address(0xAAAA);
    address private creatorB = address(0xBBBB);

    address private constant BASE  = address(0xBEEF);
    address private constant QUOTE = address(0xCAFE);

    bytes32 private constant FEED_A = keccak256("feed-a");
    bytes32 private constant FEED_B = keccak256("feed-b");
    bytes32 private constant FEED_C = keccak256("feed-c");

    int256  private constant CEX_STEP = 1e14;   // 0.01%
    uint256 private constant MAX_DELTA = 1 days;
    uint256 private constant FUTURE_TOL = 10;

    function setUp() public {
        factory = new PriceProviderFactoryL2(owner);
        oracle  = new MockOracleL2();
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _create(bytes32 feedId) internal returns (address) {
        return factory.createPriceProvider(
            address(oracle), feedId, CEX_STEP, MAX_DELTA, FUTURE_TOL,
            BASE, QUOTE
        );
    }

    function _createAs(address creator, bytes32 feedId) internal returns (address) {
        vm.prank(creator);
        return factory.createPriceProvider(
            address(oracle), feedId, CEX_STEP, MAX_DELTA, FUTURE_TOL,
            BASE, QUOTE
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // createPriceProvider (permissionless)
    // ════════════════════════════════════════════════════════════════════════

    function testCreatePriceProvider() public {
        address p = _create(FEED_A);

        assertTrue(p != address(0), "provider address should be non-zero");
        assertTrue(factory.isProvider(p), "provider should be tracked");
        assertEq(factory.providerCount(), 1);
    }

    function testCreateIsPermissionless() public {
        address p = _createAs(nonOwner, FEED_A);
        assertTrue(factory.isProvider(p));
        assertEq(factory.providerOwner(p), nonOwner);
    }

    function testCreateEmitsEvent() public {
        vm.expectEmit(false, true, true, true);
        emit IPriceProviderFactoryL2.ProviderDeployed(
            address(0), // don't check provider address (unknown before deploy)
            owner,      // creator
            FEED_A,
            address(oracle),
            BASE,
            QUOTE,
            CEX_STEP,
            MAX_DELTA,
            FUTURE_TOL
        );
        _create(FEED_A);
    }

    function testCreateMultipleProviders() public {
        address p1 = _create(FEED_A);
        address p2 = _create(FEED_B);

        assertTrue(p1 != p2, "different deploy addresses");
        assertEq(factory.providerCount(), 2);
        assertTrue(factory.isProvider(p1));
        assertTrue(factory.isProvider(p2));
    }

    function testCreateProviderSetsCorrectParams() public {
        address p = _create(FEED_A);
        PriceProviderL2 pp = PriceProviderL2(p);

        assertEq(address(pp.offchainOracle()), address(oracle));
        assertEq(pp.offchainFeedId(), FEED_A);
        assertEq(pp.marginStep(), CEX_STEP);
        assertEq(pp.MAX_TIME_DELTA(), MAX_DELTA);
        assertEq(pp.FUTURE_TOLERANCE(), FUTURE_TOL);
        assertEq(pp.factory(), address(factory));

        address base = pp.token0();
        address quote = pp.token1();
        assertEq(base, BASE);
        assertEq(quote, QUOTE);
    }

    function testCreateTracksOwner() public {
        address p = _create(FEED_A);
        assertEq(factory.providerOwner(p), owner);
    }

    function testCreateTracksByCreator() public {
        _create(FEED_A);
        _createAs(creatorB, FEED_B);

        assertEq(factory.providerCountByCreator(owner), 1);
        assertEq(factory.providerCountByCreator(creatorB), 1);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Updater management
    // ════════════════════════════════════════════════════════════════════════

    function testOwnerIsImplicitUpdater() public {
        vm.warp(100);
        address p = _create(FEED_A);

        address[] memory providers = new address[](1);
        providers[0] = p;
        uint256[] memory values = new uint256[](1);
        values[0] = 500_000;

        factory.setConfidence(providers, values);
        assertEq(PriceProviderL2(p).confidenceParam(), 500_000);
    }

    function testGrantUpdater() public {
        vm.warp(100);
        address p = _create(FEED_A);

        factory.grantUpdater(p, updater);
        assertTrue(factory.isUpdater(p, updater));

        address[] memory providers = new address[](1);
        providers[0] = p;
        uint256[] memory values = new uint256[](1);
        values[0] = 500_000;

        vm.prank(updater);
        factory.setConfidence(providers, values);
        assertEq(PriceProviderL2(p).confidenceParam(), 500_000);
    }

    function testGrantUpdaterRevertsNonOwner() public {
        address p = _create(FEED_A);

        vm.expectRevert(IPriceProviderFactoryL2.NotProviderOwner.selector);
        vm.prank(nonOwner);
        factory.grantUpdater(p, updater);
    }

    function testRevokeUpdater() public {
        address p = _create(FEED_A);

        factory.grantUpdater(p, updater);
        assertTrue(factory.isUpdater(p, updater));

        factory.revokeUpdater(p, updater);
        assertFalse(factory.isUpdater(p, updater));
    }

    function testNonUpdaterCannotSetConfidence() public {
        address p = _create(FEED_A);

        address[] memory providers = new address[](1);
        providers[0] = p;
        uint256[] memory values = new uint256[](1);
        values[0] = 500_000;

        vm.expectRevert(IPriceProviderFactoryL2.NotProviderUpdater.selector);
        vm.prank(nonOwner);
        factory.setConfidence(providers, values);
    }

    // ════════════════════════════════════════════════════════════════════════
    // transferProviderOwnership
    // ════════════════════════════════════════════════════════════════════════

    function testTransferOwnership() public {
        address p = _create(FEED_A);

        factory.transferProviderOwnership(p, creatorB);

        assertEq(factory.providerOwner(p), creatorB);
        assertEq(factory.providerCountByCreator(owner), 0);
        assertEq(factory.providerCountByCreator(creatorB), 1);
    }

    function testTransferOwnershipRevertsNonOwner() public {
        address p = _create(FEED_A);

        vm.expectRevert(IPriceProviderFactoryL2.NotProviderOwner.selector);
        vm.prank(nonOwner);
        factory.transferProviderOwnership(p, creatorB);
    }

    function testNewOwnerCanUpdate() public {
        vm.warp(100);
        address p = _create(FEED_A);
        factory.transferProviderOwnership(p, creatorB);

        address[] memory providers = new address[](1);
        providers[0] = p;
        uint256[] memory values = new uint256[](1);
        values[0] = 500_000;

        vm.prank(creatorB);
        factory.setConfidence(providers, values);
        assertEq(PriceProviderL2(p).confidenceParam(), 500_000);
    }

    // ════════════════════════════════════════════════════════════════════════
    // removeProvider / addProvider
    // ════════════════════════════════════════════════════════════════════════

    function testRemoveProvider() public {
        address p = _create(FEED_A);

        factory.removeProvider(p);

        assertFalse(factory.isProvider(p));
        assertEq(factory.providerCount(), 0);
        assertEq(factory.providerCountByCreator(owner), 0);
    }

    function testRemoveEmitsEvent() public {
        address p = _create(FEED_A);

        vm.expectEmit(true, false, false, false);
        emit IPriceProviderFactoryL2.ProviderRemoved(p);

        factory.removeProvider(p);
    }

    function testRemoveRevertsNotTracked() public {
        vm.expectRevert(IPriceProviderFactoryL2.ProviderNotTracked.selector);
        factory.removeProvider(address(0xDEAD));
    }

    function testRemoveRevertsNonAdmin() public {
        address p = _create(FEED_A);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonOwner,
                factory.ADMIN_ROLE()
            )
        );
        vm.prank(nonOwner);
        factory.removeProvider(p);
    }

    function testAddProviderAfterRemove() public {
        address p = _create(FEED_A);
        factory.removeProvider(p);

        factory.addProvider(p);

        assertTrue(factory.isProvider(p));
        assertEq(factory.providerCountByCreator(owner), 1);
    }

    // ════════════════════════════════════════════════════════════════════════
    // setConfidence (batch)
    // ════════════════════════════════════════════════════════════════════════

    function testSetConfidenceBatch() public {
        vm.warp(100);
        address p1 = _create(FEED_A);
        address p2 = _create(FEED_B);

        address[] memory providers = new address[](2);
        providers[0] = p1;
        providers[1] = p2;

        uint256[] memory values = new uint256[](2);
        values[0] = 500_000;
        values[1] = 800_000;

        factory.setConfidence(providers, values);

        assertEq(PriceProviderL2(p1).confidenceParam(), 500_000);
        assertEq(PriceProviderL2(p2).confidenceParam(), 800_000);
    }

    function testSetConfidenceRevertsLengthMismatch() public {
        address[] memory providers = new address[](2);
        uint256[] memory values = new uint256[](1);

        vm.expectRevert(IPriceProviderFactoryL2.LengthMismatch.selector);
        factory.setConfidence(providers, values);
    }

    function testSetConfidenceEmptyArrays() public {
        address[] memory providers = new address[](0);
        uint256[] memory values = new uint256[](0);

        factory.setConfidence(providers, values);
    }

    // ════════════════════════════════════════════════════════════════════════
    // View functions
    // ════════════════════════════════════════════════════════════════════════

    function testIsProviderReturnsFalseForUnknown() public view {
        assertFalse(factory.isProvider(address(0xDEAD)));
    }

    function testProviderAtReturnsCorrectAddress() public {
        address p1 = _create(FEED_A);
        address p2 = _create(FEED_B);

        assertEq(factory.providerAt(0), p1);
        assertEq(factory.providerAt(1), p2);
    }

    function testProviderCountStartsAtZero() public view {
        assertEq(factory.providerCount(), 0);
    }

    // ── getProviders (by creator) ─────────────────────────────────────────

    function testGetProvidersByCreator() public {
        address pA = _create(FEED_A);
        address pB = _createAs(creatorB, FEED_B);
        address pC = _create(FEED_C);

        (address[] memory providers,, uint256 total) = factory.getProviders(owner, 0, 10);
        assertEq(total, 2);
        assertEq(providers[0], pA);
        assertEq(providers[1], pC);

        (address[] memory providersB,, uint256 totalB) = factory.getProviders(creatorB, 0, 10);
        assertEq(totalB, 1);
        assertEq(providersB[0], pB);
    }

    function testGetProvidersByCreatorEmpty() public view {
        (address[] memory providers,, uint256 total) = factory.getProviders(nonOwner, 0, 10);
        assertEq(total, 0);
        assertEq(providers.length, 0);
    }

    // ── getAllProviders ────────────────────────────────────────────────────

    function testGetAllProvidersFullPage() public {
        address p1 = _create(FEED_A);
        address p2 = _createAs(creatorB, FEED_B);
        address p3 = _create(FEED_C);

        (address[] memory providers,, uint256 total) = factory.getAllProviders(0, 10);

        assertEq(total, 3);
        assertEq(providers.length, 3);
        assertEq(providers[0], p1);
        assertEq(providers[1], p2);
        assertEq(providers[2], p3);
    }

    function testGetAllProvidersWithOffset() public {
        _create(FEED_A);
        address p2 = _create(FEED_B);
        address p3 = _create(FEED_C);

        (address[] memory providers,, uint256 total) = factory.getAllProviders(1, 10);

        assertEq(total, 3);
        assertEq(providers.length, 2);
        assertEq(providers[0], p2);
        assertEq(providers[1], p3);
    }

    function testGetAllProvidersEmpty() public view {
        (address[] memory providers,, uint256 total) = factory.getAllProviders(0, 10);

        assertEq(total, 0);
        assertEq(providers.length, 0);
    }

    function testGetAllProvidersReturnsUpdatableAfter() public {
        vm.warp(100);
        address p1 = _create(FEED_A);
        _create(FEED_B);

        uint256 cooldown = PriceProviderL2(p1).CONFIDENCE_COOLDOWN();

        (, uint256[] memory updatable,) = factory.getAllProviders(0, 10);
        assertEq(updatable.length, 2);
        assertEq(updatable[0], cooldown);
        assertEq(updatable[1], cooldown);

        address[] memory targets = new address[](1);
        targets[0] = p1;
        uint256[] memory vals = new uint256[](1);
        vals[0] = 500_000;
        factory.setConfidence(targets, vals);

        (, uint256[] memory updatable2,) = factory.getAllProviders(0, 10);
        assertEq(updatable2[0], block.timestamp + cooldown);
        assertEq(updatable2[1], cooldown);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Multicall
    // ════════════════════════════════════════════════════════════════════════

    function testMulticall() public {
        vm.warp(100);
        address p1 = _create(FEED_A);
        address p2 = _create(FEED_B);

        address[] memory p1arr = new address[](1);
        p1arr[0] = p1;
        uint256[] memory v1 = new uint256[](1);
        v1[0] = 500_000;

        address[] memory p2arr = new address[](1);
        p2arr[0] = p2;
        uint256[] memory v2 = new uint256[](1);
        v2[0] = 800_000;

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(factory.setConfidence, (p1arr, v1));
        calls[1] = abi.encodeCall(factory.setConfidence, (p2arr, v2));

        factory.multicall(calls);

        assertEq(PriceProviderL2(p1).confidenceParam(), 500_000);
        assertEq(PriceProviderL2(p2).confidenceParam(), 800_000);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Roles
    // ════════════════════════════════════════════════════════════════════════

    function testAdminRoleIsSetCorrectly() public view {
        assertTrue(factory.hasRole(factory.ADMIN_ROLE(), owner));
    }

    function testNonAdminCannotGrantRoles() public {
        bytes32 adminRole = factory.ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nonOwner,
                factory.ADMIN_ROLE()
            )
        );
        vm.prank(nonOwner);
        factory.grantRole(adminRole, nonOwner);
    }
}
