// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {AnchoredPriceProvider} from "../contracts/AnchoredPriceProvider.sol";
import {AnchoredProviderFactory} from "../contracts/AnchoredProviderFactory.sol";
import {IAnchoredProviderFactory} from "../contracts/interfaces/IAnchoredProviderFactory.sol";

import {TestOracle} from "./ProtectedPriceProvider.t.sol";
import {MockAnchorSource} from "./mocks/MockAnchorSource.sol";

contract AnchoredProviderFactoryTest is Test {
    bytes32 private constant FEED_ID = keccak256("factory-feed");
    bytes32 private constant MAJORS = keccak256("MAJORS");
    address private constant BASE_TOKEN = address(0xBEEF);
    address private constant QUOTE_TOKEN = address(0xCAFE);

    // In-envelope deploy params (majors)
    uint256 private constant FLOOR = 5e13;          // 0.5 bps
    uint256 private constant STALENESS = 2;
    uint16  private constant U_MAX = 150;

    TestOracle private oracle;
    AnchoredProviderFactory private factory;
    address private curator = address(0xC04A);
    address private stranger = address(0xDEAD);

    function setUp() public {
        vm.warp(1_000_000); // past CONFIDENCE_COOLDOWN so a fresh provider's first set succeeds
        oracle = new TestOracle(address(this), 60);
        oracle.setData(FEED_ID, 100_000_000, 0, 0, block.timestamp);

        factory = new AnchoredProviderFactory(address(this));
        factory.addOracle(address(oracle)); // allow-list starts empty; add the oracle explicitly

        factory.setEnvelope(MAJORS, _majorsEnvelope());
        factory.setFeedClass(FEED_ID, MAJORS);
    }

    function _majorsEnvelope() internal pure returns (IAnchoredProviderFactory.Envelope memory) {
        return IAnchoredProviderFactory.Envelope({
            minMarginMin: 1e13,      // 0.1 bps
            minMarginMax: 1e15,      // 10 bps
            stalenessMin: 1,
            stalenessMax: 60,
            maxSpreadMin: 10,
            maxSpreadMax: 300,
            exists: false        // ignored on input; the factory sets it
        });
    }

    function _create() internal returns (address) {
        vm.prank(curator);
        return factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), FLOOR, STALENESS, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
    }

    function _expectNotAdmin(address account) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, account, factory.ADMIN_ROLE()
            )
        );
    }

    // ── Construction ──────────────────────────────────────────────────────

    function testFreshFactoryHasEmptyAllowList() public {
        AnchoredProviderFactory f = new AnchoredProviderFactory(address(this));
        assertEq(f.oracleCount(), 0, "no oracle is seeded at construction");
    }

    function testOracleAllowListedViaAddOracle() public view {
        // setUp adds the oracle via addOracle — the only way in, since the constructor seeds nothing.
        assertTrue(factory.isOracle(address(oracle)));
        assertEq(factory.oracleCount(), 1);
        address[] memory all = factory.getOracles(0, 1);
        assertEq(all.length, 1);
        assertEq(all[0], address(oracle));
    }

    // ── Oracle allow-list CRUD ─────────────────────────────────────────────

    function _newOracleWithFeed() internal returns (TestOracle o) {
        o = new TestOracle(address(this), 60);
        o.setData(FEED_ID, 100_000_000, 0, 0, block.timestamp);
    }

    function testAddOracleEmitsAndAllows() public {
        address o2 = address(_newOracleWithFeed());
        vm.expectEmit(true, false, false, false, address(factory));
        emit IAnchoredProviderFactory.OracleAdded(o2);
        factory.addOracle(o2);
        assertTrue(factory.isOracle(o2));
        assertEq(factory.oracleCount(), 2);
    }

    function testAddOracleZeroReverts() public {
        vm.expectRevert(IAnchoredProviderFactory.ZeroOracle.selector);
        factory.addOracle(address(0));
    }

    function testAddOracleDuplicateReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAnchoredProviderFactory.OracleAlreadyAllowed.selector, address(oracle)));
        factory.addOracle(address(oracle));
    }

    function testAddOracleNonAdminReverts() public {
        _expectNotAdmin(stranger);
        vm.prank(stranger);
        factory.addOracle(address(0xABCD));
    }

    function testRemoveOracleEmitsAndBlocks() public {
        vm.expectEmit(true, false, false, false, address(factory));
        emit IAnchoredProviderFactory.OracleRemoved(address(oracle));
        factory.removeOracle(address(oracle));
        assertFalse(factory.isOracle(address(oracle)));
        assertEq(factory.oracleCount(), 0);
    }

    function testRemoveOracleNotFoundReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IAnchoredProviderFactory.OracleNotFound.selector, address(0xABCD)));
        factory.removeOracle(address(0xABCD));
    }

    function testRemoveOracleNonAdminReverts() public {
        _expectNotAdmin(stranger);
        vm.prank(stranger);
        factory.removeOracle(address(oracle));
    }

    function testCreateOnNonAllowedOracleReverts() public {
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAnchoredProviderFactory.OracleNotAllowed.selector, address(0xBAD)));
        factory.createAnchoredProvider(address(0xBAD), FEED_ID, bytes32(0), FLOOR, STALENESS, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
    }

    function testCreateOnAddedOracleAnchorsToIt() public {
        TestOracle o2 = _newOracleWithFeed();
        factory.addOracle(address(o2));
        vm.prank(curator);
        address provider = factory.createAnchoredProvider(address(o2), FEED_ID, bytes32(0), FLOOR, STALENESS, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
        assertEq(address(AnchoredPriceProvider(provider).offchainOracle()), address(o2), "anchored to the chosen allow-listed oracle");
        assertTrue(factory.isProvider(provider));
    }

    function testRemovedOracleBlocksNewButKeepsExisting() public {
        address provider = _create();              // created while the seeded oracle is allow-listed
        assertTrue(factory.isProvider(provider));
        factory.removeOracle(address(oracle));
        assertTrue(factory.isProvider(provider), "already-deployed provider unaffected by removal");
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAnchoredProviderFactory.OracleNotAllowed.selector, address(oracle)));
        factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), FLOOR, STALENESS, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
    }

    // ── Envelope administration ───────────────────────────────────────────

    function testSetEnvelopeStoresAndEmits() public {
        bytes32 classId = keccak256("STABLES");
        vm.expectEmit(true, false, false, true, address(factory));
        emit IAnchoredProviderFactory.EnvelopeSet(classId, 1e13, 1e15, 1, 60, 10, 300);
        factory.setEnvelope(classId, _majorsEnvelope());

        (,,,,,, bool exists) = factory.envelopes(classId);
        assertTrue(exists, "exists flag forced on by the factory");
    }

    function testSetEnvelopeRevertsNonAdmin() public {
        _expectNotAdmin(stranger);
        vm.prank(stranger);
        factory.setEnvelope(keccak256("X"), _majorsEnvelope());
    }

    function testSetEnvelopeRevertsZeroClassId() public {
        vm.expectRevert(IAnchoredProviderFactory.BadEnvelope.selector);
        factory.setEnvelope(bytes32(0), _majorsEnvelope());
    }

    function testSetEnvelopeRevertsMinAboveMax() public {
        IAnchoredProviderFactory.Envelope memory env = _majorsEnvelope();
        env.minMarginMin = env.minMarginMax + 1;
        vm.expectRevert(IAnchoredProviderFactory.BadEnvelope.selector);
        factory.setEnvelope(keccak256("X"), env);
    }

    // ── Envelope must stay inside the provider's hard bounds ──────────────
    // (so every in-envelope param is constructor-valid; create() can only ParamsOutOfEnvelope).

    function testSetEnvelopeAllowsMinMarginZero() public {
        IAnchoredProviderFactory.Envelope memory env = _majorsEnvelope();
        env.minMarginMin = 0;
        factory.setEnvelope(keccak256("X"), env);
        (uint256 minMarginMin, , , , , , bool exists) = factory.envelopes(keccak256("X"));
        assertTrue(exists);
        assertEq(minMarginMin, 0, "minMarginMin 0 allowed (no extra floor)");
    }

    function testSetEnvelopeAllowsStalenessZero() public {
        IAnchoredProviderFactory.Envelope memory env = _majorsEnvelope();
        env.stalenessMin = 0;
        factory.setEnvelope(keccak256("X"), env);
        (, , uint256 stalenessMin, , , , bool exists) = factory.envelopes(keccak256("X"));
        assertTrue(exists);
        assertEq(stalenessMin, 0, "stalenessMin 0 allowed (same-block updates)");
    }

    function testSetEnvelopeRejectsStalenessAboveHardMax() public {
        IAnchoredProviderFactory.Envelope memory env = _majorsEnvelope();
        env.stalenessMax = 7 days + 1;
        vm.expectRevert(IAnchoredProviderFactory.BadEnvelope.selector);
        factory.setEnvelope(keccak256("X"), env);
    }

    function testSetEnvelopeRejectsUMaxAtOrAboveBpsBase() public {
        IAnchoredProviderFactory.Envelope memory env = _majorsEnvelope();
        env.maxSpreadMax = 10_000;
        vm.expectRevert(IAnchoredProviderFactory.BadEnvelope.selector);
        factory.setEnvelope(keccak256("X"), env);
    }

    function testSetEnvelopeRejectsUMaxZero() public {
        IAnchoredProviderFactory.Envelope memory env = _majorsEnvelope();
        env.maxSpreadMin = 0;
        vm.expectRevert(IAnchoredProviderFactory.BadEnvelope.selector);
        factory.setEnvelope(keccak256("X"), env);
    }

    function testSetEnvelopeRejectsBandTooWideCorner() public {
        // Each field individually plausible, but maxSpreadMax (9_000 bps) + minMarginMax (0.2e18) at the
        // envelope's high corner exceeds 100% half-width → would revert BandTooWide at create.
        IAnchoredProviderFactory.Envelope memory env = _majorsEnvelope();
        env.maxSpreadMax = 9_000;        // 9_000 * 1e14 = 9e17
        env.minMarginMax = 2e17;        // 9e17 + 2e17 = 1.1e18 >= 1e18
        vm.expectRevert(IAnchoredProviderFactory.BadEnvelope.selector);
        factory.setEnvelope(keccak256("X"), env);
    }

    function testRemoveEnvelope() public {
        factory.removeEnvelope(MAJORS);
        (,,,,,, bool exists) = factory.envelopes(MAJORS);
        assertFalse(exists);
    }

    function testRemoveEnvelopeRevertsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(IAnchoredProviderFactory.EnvelopeNotFound.selector, keccak256("X")));
        factory.removeEnvelope(keccak256("X"));
    }

    function testRemoveEnvelopeRevertsNonAdmin() public {
        _expectNotAdmin(stranger);
        vm.prank(stranger);
        factory.removeEnvelope(MAJORS);
    }

    function testSetFeedClassRevertsUnknownClass() public {
        vm.expectRevert(abi.encodeWithSelector(IAnchoredProviderFactory.EnvelopeNotFound.selector, keccak256("X")));
        factory.setFeedClass(FEED_ID, keccak256("X"));
    }

    function testSetFeedClassZeroUnassigns() public {
        factory.setFeedClass(FEED_ID, bytes32(0));
        assertEq(factory.feedClass(FEED_ID), bytes32(0));
    }

    function testSetFeedClassRevertsNonAdmin() public {
        _expectNotAdmin(stranger);
        vm.prank(stranger);
        factory.setFeedClass(FEED_ID, MAJORS);
    }

    // ── createAnchoredProvider ────────────────────────────────────────────

    function testCreateDeploysWiredProvider() public {
        address provider = _create();

        AnchoredPriceProvider p = AnchoredPriceProvider(provider);
        assertEq(p.factory(), address(factory));
        assertEq(address(p.offchainOracle()), address(oracle));
        assertEq(p.baseFeedId(), FEED_ID);
        assertEq(p.minMargin(), FLOOR);
        assertEq(p.MAX_REF_STALENESS(), STALENESS);
        assertEq(p.MAX_SPREAD_BPS(), U_MAX);
        assertEq(p.baseToken(), BASE_TOKEN);
        assertEq(p.quoteToken(), QUOTE_TOKEN);

        assertTrue(factory.isProvider(provider), "machine-checkable predicate");
        assertEq(factory.providerOwner(provider), curator);
        assertEq(factory.providerCount(), 1);
        assertEq(factory.providerAt(0), provider);
    }

    function testCreateUnassignedNoDefaultReverts() public {
        // No explicit class AND no DEFAULT_CLASS envelope configured -> reverts loud (audit-once preserved).
        bytes32 otherFeed = keccak256("unassigned-feed");
        oracle.setData(otherFeed, 100_000_000, 0, 0, block.timestamp);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IAnchoredProviderFactory.EnvelopeNotFound.selector, factory.DEFAULT_CLASS()));
        factory.createAnchoredProvider(address(oracle), otherFeed, bytes32(0), FLOOR, STALENESS, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
    }

    function testCreateUnassignedUsesDefaultEnvelope() public {
        // Configure the default envelope; an unassigned feed then deploys against it.
        bytes32 otherFeed = keccak256("unassigned-feed");
        oracle.setData(otherFeed, 100_000_000, 0, 0, block.timestamp);
        factory.setEnvelope(factory.DEFAULT_CLASS(), _majorsEnvelope());
        vm.prank(curator);
        address provider = factory.createAnchoredProvider(address(oracle), otherFeed, bytes32(0), FLOOR, STALENESS, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
        assertTrue(factory.isProvider(provider), "unassigned feed used the DEFAULT_CLASS envelope");
    }

    function testCreateWithZeroStalenessSucceeds() public {
        // stalenessMin 0 in the envelope -> a creator may pick maxRefStaleness 0 (same-block reference).
        IAnchoredProviderFactory.Envelope memory env = _majorsEnvelope();
        env.stalenessMin = 0;
        factory.setEnvelope(MAJORS, env);
        vm.prank(curator);
        address provider = factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), FLOOR, 0, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
        assertEq(AnchoredPriceProvider(provider).MAX_REF_STALENESS(), 0);
    }

    function testCreateRevertsAfterEnvelopeRemoved() public {
        factory.removeEnvelope(MAJORS); // feed still points at the class, envelope gone
        vm.expectRevert(abi.encodeWithSelector(IAnchoredProviderFactory.EnvelopeNotFound.selector, MAJORS));
        factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), FLOOR, STALENESS, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
    }

    function testCreateRevertsFloorBelowEnvelope() public {
        vm.expectRevert(IAnchoredProviderFactory.ParamsOutOfEnvelope.selector);
        factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), 1e13 - 1, STALENESS, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
    }

    function testCreateRevertsFloorAboveEnvelope() public {
        vm.expectRevert(IAnchoredProviderFactory.ParamsOutOfEnvelope.selector);
        factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), 1e15 + 1, STALENESS, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
    }

    function testCreateRevertsStalenessBelowEnvelope() public {
        vm.expectRevert(IAnchoredProviderFactory.ParamsOutOfEnvelope.selector);
        factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), FLOOR, 0, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
    }

    function testCreateRevertsStalenessAboveEnvelope() public {
        vm.expectRevert(IAnchoredProviderFactory.ParamsOutOfEnvelope.selector);
        factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), FLOOR, 61, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
    }

    function testCreateRevertsUMaxBelowEnvelope() public {
        vm.expectRevert(IAnchoredProviderFactory.ParamsOutOfEnvelope.selector);
        factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), FLOOR, STALENESS, 9, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
    }

    function testCreateRevertsUMaxAboveEnvelope() public {
        vm.expectRevert(IAnchoredProviderFactory.ParamsOutOfEnvelope.selector);
        factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), FLOOR, STALENESS, 301, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
    }

    function testCreateAtEnvelopeBoundsSucceeds() public {
        address provider = factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), 1e13, 1, 10, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
        assertTrue(factory.isProvider(provider));
        provider = factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), 1e15, 60, 300, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
        assertTrue(factory.isProvider(provider));
    }

    function testCreateIsPermissionless() public {
        vm.prank(stranger); // anyone can deploy — only the params are policed
        address provider = factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), FLOOR, STALENESS, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);
        assertEq(factory.providerOwner(provider), stranger);
    }

    // ── setSource through the factory ─────────────────────────────────────

    function testSetSourceByOwner() public {
        address provider = _create();
        MockAnchorSource src = new MockAnchorSource();

        vm.expectEmit(true, true, false, true, address(factory));
        emit IAnchoredProviderFactory.SourceSet(provider, address(src));
        vm.prank(curator);
        factory.setSource(provider, address(src));

        assertEq(AnchoredPriceProvider(provider).source(), address(src), "source actually swapped");

        vm.prank(curator);
        factory.setSource(provider, address(0)); // instant swap back to reference mode
        assertEq(AnchoredPriceProvider(provider).source(), address(0));
    }

    function testSetSourceRevertsNonOwner() public {
        address provider = _create();
        vm.prank(stranger);
        vm.expectRevert(IAnchoredProviderFactory.NotProviderOwner.selector);
        factory.setSource(provider, address(0xABCD));
    }

    function testProviderSetSourceRevertsDirectCall() public {
        address provider = _create();
        // even the owner cannot bypass the factory on the provider itself
        vm.prank(curator);
        vm.expectRevert(AnchoredPriceProvider.OnlyFactory.selector);
        AnchoredPriceProvider(provider).setSource(address(0xABCD));
    }

    // ── Ownership transfer ────────────────────────────────────────────────

    function testTransferProviderOwnership() public {
        address provider = _create();
        address newOwner = address(0xA11CE);

        vm.prank(curator);
        factory.transferProviderOwnership(provider, newOwner);
        assertEq(factory.providerOwner(provider), newOwner);

        // old owner lost control
        vm.prank(curator);
        vm.expectRevert(IAnchoredProviderFactory.NotProviderOwner.selector);
        factory.setSource(provider, address(0xABCD));

        // new owner has it
        vm.prank(newOwner);
        factory.setSource(provider, address(0xABCD));
        assertEq(AnchoredPriceProvider(provider).source(), address(0xABCD));
    }

    function testTransferProviderOwnershipRevertsNonOwner() public {
        address provider = _create();
        vm.prank(stranger);
        vm.expectRevert(IAnchoredProviderFactory.NotProviderOwner.selector);
        factory.transferProviderOwnership(provider, stranger);
    }

    // ── Views / pagination ────────────────────────────────────────────────

    function testPaginationByCreatorAndGlobal() public {
        address p1 = _create();
        address p2 = _create();
        vm.prank(stranger);
        address p3 = factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), FLOOR, STALENESS, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);

        assertEq(factory.providerCount(), 3);
        assertEq(factory.providerCountByCreator(curator), 2);

        (address[] memory mine, uint256 totalMine) = factory.getProviders(curator, 0, 10);
        assertEq(totalMine, 2);
        assertEq(mine.length, 2);
        assertEq(mine[0], p1);
        assertEq(mine[1], p2);

        (address[] memory page, uint256 total) = factory.getAllProviders(1, 1);
        assertEq(total, 3);
        assertEq(page.length, 1);
        assertEq(page[0], p2);

        (address[] memory empty,) = factory.getAllProviders(5, 10);
        assertEq(empty.length, 0);

        assertTrue(factory.isProvider(p3));
        assertFalse(factory.isProvider(address(0xBAD)));
    }

    // ── Customizable variant: create with flag ────────────────────────────

    function _createMutable() internal returns (address) {
        vm.prank(curator);
        return factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), FLOOR, STALENESS, U_MAX, true, int256(0), BASE_TOKEN, QUOTE_TOKEN);
    }

    function testCreateMutableWiresFlagAndEmits() public {
        vm.expectEmit(false, true, true, false, address(factory));
        emit IAnchoredProviderFactory.ProviderDeployed(
            address(0), curator, FEED_ID, bytes32(0), MAJORS, BASE_TOKEN, QUOTE_TOKEN, FLOOR, STALENESS, U_MAX, true, int256(0), address(oracle)
        );
        address provider = _createMutable();

        assertTrue(AnchoredPriceProvider(provider).MUTABLE_PARAMS());
        assertTrue(factory.isProvider(provider), "both variants are envelope-attested providers");
    }

    function testCreateForwardsMarginStepAndEmits() public {
        int256 ms = 5e16; // 5%, in bounds
        vm.expectEmit(false, true, true, true, address(factory));
        emit IAnchoredProviderFactory.ProviderDeployed(
            address(0), curator, FEED_ID, bytes32(0), MAJORS, BASE_TOKEN, QUOTE_TOKEN, FLOOR, STALENESS, U_MAX, true, ms, address(oracle)
        );
        vm.prank(curator);
        address provider = factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), FLOOR, STALENESS, U_MAX, true, ms, BASE_TOKEN, QUOTE_TOKEN);
        assertEq(AnchoredPriceProvider(provider).marginStep(), ms, "factory forwards marginStep to the provider");
    }

    function testCreateMarginStepOutOfBoundsBubblesUp() public {
        vm.prank(curator);
        vm.expectRevert(AnchoredPriceProvider.MarginStepOutOfBounds.selector);
        factory.createAnchoredProvider(address(oracle), FEED_ID, bytes32(0), FLOOR, STALENESS, U_MAX, true, int256(1e18), BASE_TOKEN, QUOTE_TOKEN);
    }

    function testCreateSyntheticWiresRefFeed() public {
        bytes32 refFeed = keccak256("ref-feed");
        oracle.setData(refFeed, 100_000_000, 0, 0, block.timestamp);
        vm.prank(curator);
        address provider =
            factory.createAnchoredProvider(address(oracle), FEED_ID, refFeed, FLOOR, STALENESS, U_MAX, false, int256(0), BASE_TOKEN, QUOTE_TOKEN);

        assertEq(AnchoredPriceProvider(provider).quoteFeedId(), refFeed, "ref feed wired");
        // Tokens are now explicit constructor inputs (no derivation from the ref feed).
        assertEq(AnchoredPriceProvider(provider).token0(), BASE_TOKEN, "token0 = explicit base");
        assertEq(AnchoredPriceProvider(provider).token1(), QUOTE_TOKEN, "token1 = explicit quote");
    }

    function testCreateImmutableFlagFalse() public {
        address provider = _create();
        assertFalse(AnchoredPriceProvider(provider).MUTABLE_PARAMS());
    }

    // ── Updater management ────────────────────────────────────────────────

    function testGrantAndRevokeUpdater() public {
        address provider = _createMutable();
        address updater = address(0x0BD8);

        vm.expectEmit(true, true, false, true, address(factory));
        emit IAnchoredProviderFactory.UpdaterGranted(provider, updater);
        vm.prank(curator);
        factory.grantUpdater(provider, updater);
        assertTrue(factory.isUpdater(provider, updater));

        vm.expectEmit(true, true, false, true, address(factory));
        emit IAnchoredProviderFactory.UpdaterRevoked(provider, updater);
        vm.prank(curator);
        factory.revokeUpdater(provider, updater);
        assertFalse(factory.isUpdater(provider, updater));
    }

    function testGrantUpdaterRevertsNonOwner() public {
        address provider = _createMutable();
        vm.prank(stranger);
        vm.expectRevert(IAnchoredProviderFactory.NotProviderOwner.selector);
        factory.grantUpdater(provider, stranger);
    }

    function testUpdaterCannotSetSource() public {
        address provider = _createMutable();
        address updater = address(0x0BD8);
        vm.prank(curator);
        factory.grantUpdater(provider, updater);

        vm.prank(updater);
        vm.expectRevert(IAnchoredProviderFactory.NotProviderOwner.selector);
        factory.setSource(provider, address(0xABCD));
    }

    // ── Batch knob setters ────────────────────────────────────────────────

    function _one(address provider) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = provider;
    }

    function testBatchSettersByOwnerAndUpdater() public {
        address provider = _createMutable();
        address updater = address(0x0BD8);
        vm.prank(curator);
        factory.grantUpdater(provider, updater);
        AnchoredPriceProvider p = AnchoredPriceProvider(provider);

        uint256[] memory conf = new uint256[](1);
        conf[0] = 777;
        vm.prank(curator);
        factory.setConfidence(_one(provider), conf);
        assertEq(p.confidenceParam(), 777);
    }

    function testBatchSettersRevertForStranger() public {
        address provider = _createMutable();
        uint256[] memory conf = new uint256[](1);
        conf[0] = 1;

        vm.prank(stranger);
        vm.expectRevert(IAnchoredProviderFactory.NotProviderUpdater.selector);
        factory.setConfidence(_one(provider), conf);
    }

    function testBatchSettersLengthMismatch() public {
        address provider = _createMutable();
        uint256[] memory conf = new uint256[](2);

        vm.prank(curator);
        vm.expectRevert(IAnchoredProviderFactory.LengthMismatch.selector);
        factory.setConfidence(_one(provider), conf);
    }

    function testBatchSettersUntrackedProvider() public {
        uint256[] memory conf = new uint256[](1);
        vm.prank(curator);
        vm.expectRevert(IAnchoredProviderFactory.ProviderNotTracked.selector);
        factory.setConfidence(_one(address(0xBAD)), conf);
    }

    function testBatchSettersImmutableProviderBubblesAtomically() public {
        address provider = _create(); // immutable variant
        uint256[] memory conf = new uint256[](1);
        conf[0] = 1;

        vm.prank(curator);
        vm.expectRevert(AnchoredPriceProvider.ImmutableProvider.selector);
        factory.setConfidence(_one(provider), conf);
    }

    function testBatchSettersCooldownBubbles() public {
        address provider = _createMutable();
        uint256[] memory conf = new uint256[](1);
        conf[0] = 1;

        vm.prank(curator);
        factory.setConfidence(_one(provider), conf);

        conf[0] = 2;
        vm.prank(curator);
        vm.expectRevert(AnchoredPriceProvider.CooldownNotElapsed.selector);
        factory.setConfidence(_one(provider), conf);
    }
}
