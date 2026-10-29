// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {PythLazer} from "pyth-lazer-sdk/PythLazer.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PythOracle} from "../../contracts/oracles/providers/PythOracle.sol";
import {OracleBase} from "../../contracts/oracles/providers/OracleBase.sol";
import {ChainlinkOracle} from "../../contracts/oracles/providers/ChainlinkOracle.sol";
import {IOffchainOracle} from "../../contracts/interfaces/IOffchainOracle.sol";
import {IPool} from "../../contracts/interfaces/IPoolFactory.sol";
import {MockPoolFactory} from "../mocks/MockPoolFactory.sol";
import {LazerTestPayload} from "../utils/LazerTestPayload.sol";

/// @notice Coverage for the read-access / abuse-protection layer added to providers/OracleBase.
///         Registrationless: feeds "exist" once their first verified push stores data — setUp
///         pushes a signed 4-feed update so FEED/FEED_B are readable through the gated paths.
contract OracleBaseAbuseProtectionTest is Test {
    PythOracle oracle;
    MockPoolFactory factory;

    address owner; // ADMIN_ROLE
    PythLazer pythLazer;
    bytes32 constant FEED = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    uint256 constant maxTimeDrift = 60;

    // Pyth push harness (same dynamically-signed payload as PythOracle.t.sol) for real-data assertions
    uint256 constant updateTime = 1769872629;

    function _priceUpdate() internal pure returns (bytes memory) {
        return LazerTestPayload.defaultUpdate(uint64(updateTime) * 1_000_000);
    }

    function setUp() public {
        owner = address(this); // test contract is ADMIN
        vm.deal(owner, 100 ether);

        address proxyAdmin = makeAddr("proxyAdmin");
        PythLazer pythLazerImpl = new PythLazer();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(pythLazerImpl),
            proxyAdmin,
            abi.encodeWithSelector(PythLazer.initialize.selector, proxyAdmin)
        );
        pythLazer = PythLazer(address(proxy));

        vm.prank(proxyAdmin);
        pythLazer.updateTrustedSigner(LazerTestPayload.signer(), 3000000000000000);

        uint8[] memory expectedProps = new uint8[](4);
        expectedProps[0] = 0;
        expectedProps[1] = 4;
        expectedProps[2] = 5;
        expectedProps[3] = 12;
        oracle = new PythOracle(owner, address(proxy), maxTimeDrift, expectedProps);

        factory = new MockPoolFactory();
        oracle.addApprovedFactory(address(factory));

        vm.warp(updateTime);

        // First verified push makes feeds 1..4 exist (real data behind every gated read below).
        _pushUpdate();
    }

    // ─── Pyth push helpers (real-data) ────────────────────────────────

    function _fundOracle() internal {
        (bool ok, ) = address(oracle).call{value: 2}("");
        require(ok);
    }

    /// calldata format: [feedsLength:2][feedIds:4 bytes each][lazer priceUpdate] — no deadline prefix.
    function _buildCalldata() internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint16(4),
            uint32(1), uint32(2), uint32(3), uint32(4),
            _priceUpdate()
        );
    }

    function _pushUpdate() internal {
        _fundOracle();
        (bool ok, ) = address(oracle).call(_buildCalldata());
        require(ok, "push update failed");
    }

    /// @dev Make `pool.inSwap()` report `pp` (the pool attests its in-swap provider to the oracle).
    function _mockInSwap(address pool, address pp) internal {
        vm.mockCall(pool, abi.encodeWithSelector(IPool.inSwap.selector), abi.encode(pp));
    }

    // ─── register ─────────────────────────────────────────────────────

    function test_register_success() public {
        address pool = makeAddr("pool");
        factory.setPool(pool, true);
        uint256 balBefore = address(oracle).balance; // push leftover from setUp

        vm.expectEmit(true, true, true, true);
        emit IOffchainOracle.PoolRegistered(FEED, pool, owner, 1);
        oracle.register{value: 1}(FEED, pool, address(factory));

        assertTrue(oracle.registeredPool(FEED, pool));
        assertEq(address(oracle).balance, balBefore + 1);
    }

    function test_register_acceptsExcessFee() public {
        address pool = makeAddr("pool");
        factory.setPool(pool, true);
        uint256 balBefore = address(oracle).balance;
        oracle.register{value: 5}(FEED, pool, address(factory));
        assertEq(address(oracle).balance, balBefore + 5);
    }

    function test_register_insufficientFee_reverts() public {
        address pool = makeAddr("pool");
        factory.setPool(pool, true);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.InsufficientFee.selector, 0, 1));
        oracle.register{value: 0}(FEED, pool, address(factory));
    }

    function test_register_notAPool_reverts() public {
        address pool = makeAddr("pool"); // not set in factory
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.NotAPool.selector, pool));
        oracle.register{value: 1}(FEED, pool, address(factory));
    }

    function test_register_factoryNotApproved_reverts() public {
        address pool = makeAddr("pool");
        address rogue = makeAddr("rogueFactory");
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FactoryNotApproved.selector, rogue));
        oracle.register{value: 1}(FEED, pool, rogue);
    }

    /// Registrationless: registering a pool for a feed with NO data yet is allowed —
    /// the gated read still reverts FeedNotFound until the first verified push lands.
    function test_register_beforeFeedExists_allowed() public {
        bytes32 unseen = bytes32(uint256(999));
        address pool = makeAddr("pool");
        address pp = makeAddr("priceProvider");
        factory.setPool(pool, true);

        oracle.register{value: 1}(unseen, pool, address(factory));
        assertTrue(oracle.registeredPool(unseen, pool));

        _mockInSwap(pool, pp);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, unseen));
        vm.prank(pp);
        oracle.price(unseen, pool);
    }

    function test_register_clearsBlacklist_redemption() public {
        address pool = makeAddr("pool");
        factory.setPool(pool, true);
        oracle.setBlacklist(pool, true);
        assertTrue(oracle.blacklisted(pool));

        vm.expectEmit(true, false, false, true);
        emit IOffchainOracle.BlacklistUpdated(pool, false);
        oracle.register{value: 1}(FEED, pool, address(factory));

        assertFalse(oracle.blacklisted(pool));
        assertTrue(oracle.registeredPool(FEED, pool));
    }

    // ─── price(feedId, factory) ───────────────────────────────────────

    function test_priceWithPool_success_emits() public {
        address pool = makeAddr("pool");
        address pp = makeAddr("priceProvider");
        factory.setPool(pool, true);
        oracle.register{value: 1}(FEED, pool, address(factory));
        _mockInSwap(pool, pp);

        vm.expectEmit(true, true, false, true);
        emit IOffchainOracle.PriceRead(pool, FEED);

        vm.prank(pp);
        oracle.price(FEED, pool);
    }

    function test_priceWithPool_notRegistered_reverts() public {
        address pool = makeAddr("pool");
        address pp = makeAddr("priceProvider");
        _mockInSwap(pool, pp); // in-swap, but pool never registered for FEED

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.NotRegistered.selector, FEED, pool));
        vm.prank(pp);
        oracle.price(FEED, pool);
    }

    function test_priceWithPool_callerNotInSwapPP_reverts() public {
        address pool = makeAddr("pool");
        address pp = makeAddr("priceProvider");
        _mockInSwap(pool, pp);

        address impostor = makeAddr("impostor");
        vm.expectRevert(IOffchainOracle.InvalidInSwap.selector);
        vm.prank(impostor);
        oracle.price(FEED, pool); // pool.inSwap() == pp != impostor
    }

    function test_priceWithPool_noActiveSwap_reverts() public {
        address pool = makeAddr("pool");
        address pp = makeAddr("priceProvider");
        _mockInSwap(pool, address(0)); // pool not in-swap
        vm.expectRevert(IOffchainOracle.InvalidInSwap.selector);
        vm.prank(pp);
        oracle.price(FEED, pool);
    }

    function test_priceWithPool_blacklistedPool_reverts() public {
        address pool = makeAddr("pool");
        address pp = makeAddr("priceProvider");
        _mockInSwap(pool, pp);
        oracle.setBlacklist(pool, true);

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.Blacklisted.selector, pool));
        vm.prank(pp);
        oracle.price(FEED, pool);
    }

    // ─── integratorPrice ──────────────────────────────────────────────

    function test_integratorPrice_success_emits() public {
        address intg = makeAddr("integrator");
        oracle.addIntegrator(intg);

        vm.expectEmit(true, true, false, true);
        emit IOffchainOracle.PriceRead(intg, FEED);

        vm.prank(intg);
        oracle.integratorPrice(FEED);
    }

    function test_integratorPrice_notWhitelisted_reverts() public {
        address rando = makeAddr("rando");
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.NotWhitelisted.selector, rando));
        vm.prank(rando);
        oracle.integratorPrice(FEED);
    }

    // ─── public price getters are disabled (read only via the attributed path) ────

    function test_getOracleData_disabled() public {
        vm.expectRevert(OracleBase.ReadDisabled.selector);
        oracle.getOracleData(FEED);
    }

    function test_blacklisted_integratorPrice_reverts() public {
        address intg = makeAddr("integrator");
        oracle.addIntegrator(intg);
        oracle.setBlacklist(intg, true);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.Blacklisted.selector, intg));
        vm.prank(intg);
        oracle.integratorPrice(FEED);
    }

    // ─── integrator CRUD ──────────────────────────────────────────────

    function test_integrator_crud() public {
        address a = makeAddr("a");
        address b = makeAddr("b");

        oracle.addIntegrator(a);
        assertTrue(oracle.isIntegrator(a));
        assertEq(oracle.integratorCount(), 1);

        // batch add/remove (the "update" surface)
        address[] memory accs = new address[](2);
        accs[0] = a; // already present
        accs[1] = b;
        oracle.setIntegrators(accs, true);
        assertEq(oracle.integratorCount(), 2);

        address[] memory list = oracle.getIntegrators(0, 2);
        assertEq(list.length, 2);

        oracle.removeIntegrator(a);
        assertFalse(oracle.isIntegrator(a));
        assertEq(oracle.integratorCount(), 1);

        oracle.setIntegrators(accs, false);
        assertEq(oracle.integratorCount(), 0);
    }

    function test_addIntegrator_duplicate_reverts() public {
        address a = makeAddr("a");
        oracle.addIntegrator(a);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.AlreadyIntegrator.selector, a));
        oracle.addIntegrator(a);
    }

    function test_removeIntegrator_absent_reverts() public {
        address ghost = makeAddr("ghost");
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.NotIntegrator.selector, ghost));
        oracle.removeIntegrator(ghost);
    }

    // ─── factory management ───────────────────────────────────────────

    function test_factory_management() public {
        address f2 = makeAddr("factoryV2");
        oracle.addApprovedFactory(f2);
        assertTrue(oracle.isApprovedFactory(f2));
        assertEq(oracle.approvedFactoryCount(), 2); // setUp added one
        address[] memory list = oracle.getApprovedFactories(0, 2);
        assertEq(list.length, 2);

        oracle.removeApprovedFactory(f2);
        assertFalse(oracle.isApprovedFactory(f2));
    }

    function test_removeApprovedFactory_unknown_reverts() public {
        address unknown = makeAddr("unknown");
        vm.expectRevert(
            abi.encodeWithSelector(IOffchainOracle.FactoryNotApproved.selector, unknown)
        );
        oracle.removeApprovedFactory(unknown);
    }

    function test_addApprovedFactory_duplicate_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IOffchainOracle.FactoryAlreadyApproved.selector, address(factory))
        );
        oracle.addApprovedFactory(address(factory)); // already approved in setUp
    }

    // ─── registration fee ─────────────────────────────────────────────

    function test_setRegistrationFee_appliesToRegister() public {
        vm.expectEmit(false, false, false, true);
        emit IOffchainOracle.RegistrationFeeUpdated(1, 1 ether);
        oracle.setRegistrationFee(1 ether);
        assertEq(oracle.registrationFee(), 1 ether);

        address pool = makeAddr("pool");
        factory.setPool(pool, true);

        vm.expectRevert(
            abi.encodeWithSelector(IOffchainOracle.InsufficientFee.selector, 1, 1 ether)
        );
        oracle.register{value: 1}(FEED, pool, address(factory));

        oracle.register{value: 1 ether}(FEED, pool, address(factory));
        assertTrue(oracle.registeredPool(FEED, pool));
    }

    // ─── withdraw ─────────────────────────────────────────────────────

    function test_withdrawEth() public {
        // setUp pushed one update: the oracle balance = funding (2) - verification fee (1) = 1 wei.
        uint256 pushLeftover = address(oracle).balance;

        address pool = makeAddr("pool");
        factory.setPool(pool, true);
        oracle.register{value: 3}(FEED, pool, address(factory));

        address admin2 = makeAddr("admin2");
        oracle.grantRole(oracle.ADMIN_ROLE(), admin2);

        vm.expectEmit(true, false, false, true);
        emit IOffchainOracle.EthWithdrawn(admin2, pushLeftover + 3);
        vm.prank(admin2);
        oracle.withdrawEth();

        assertEq(admin2.balance, pushLeftover + 3);
        assertEq(address(oracle).balance, 0);
    }

    // ─── access control (only ADMIN) ──────────────────────────────────

    function test_onlyAdmin_setRegistrationFee() public {
        _expectNotAdmin(makeAddr("rando"));
        vm.prank(makeAddr("rando"));
        oracle.setRegistrationFee(5);
    }

    function test_onlyAdmin_setBlacklist() public {
        _expectNotAdmin(makeAddr("rando"));
        vm.prank(makeAddr("rando"));
        oracle.setBlacklist(makeAddr("x"), true);
    }

    function test_onlyAdmin_addIntegrator() public {
        _expectNotAdmin(makeAddr("rando"));
        vm.prank(makeAddr("rando"));
        oracle.addIntegrator(makeAddr("x"));
    }

    function test_onlyAdmin_addApprovedFactory() public {
        _expectNotAdmin(makeAddr("rando"));
        vm.prank(makeAddr("rando"));
        oracle.addApprovedFactory(makeAddr("x"));
    }

    function test_onlyAdmin_withdrawEth() public {
        _expectNotAdmin(makeAddr("rando"));
        vm.prank(makeAddr("rando"));
        oracle.withdrawEth();
    }

    function test_onlyAdmin_removeIntegrator() public {
        _expectNotAdmin(makeAddr("rando"));
        vm.prank(makeAddr("rando"));
        oracle.removeIntegrator(makeAddr("x"));
    }

    function test_onlyAdmin_removeApprovedFactory() public {
        _expectNotAdmin(makeAddr("rando"));
        vm.prank(makeAddr("rando"));
        oracle.removeApprovedFactory(address(factory));
    }

    function test_onlyAdmin_setIntegrators() public {
        address[] memory accs = new address[](1);
        accs[0] = makeAddr("x");
        _expectNotAdmin(makeAddr("rando"));
        vm.prank(makeAddr("rando"));
        oracle.setIntegrators(accs, true);
    }

    // ─── added coverage (audit gaps) ──────────────────────────────────

    /// Real pushed price flows through price(feedId,factory) and integratorPrice unchanged.
    function test_priceWithFactory_realData_parity() public {
        address pool = makeAddr("pool");
        address pp = makeAddr("priceProvider");
        factory.setPool(pool, true);
        oracle.register{value: 1}(FEED, pool, address(factory));
        _mockInSwap(pool, pp);

        vm.prank(pp);
        (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) = oracle.price(FEED, pool);
        assertGt(mid, 0); // real pushed data, not the all-zero stub

        // Integrator path returns identical raw data.
        address intg = makeAddr("integrator2");
        oracle.addIntegrator(intg);
        vm.prank(intg);
        (uint256 mid2, uint256 spread2, uint16 spread1_2, uint256 refTime2) = oracle.integratorPrice(FEED);
        assertEq(mid, mid2);
        assertEq(spread, spread2);
        assertEq(spread1, spread1_2);
        assertEq(refTime, refTime2);
    }

    /// Registration is per-(feedId,pool): registered for FEED must not read FEED_B.
    function test_priceWithFactory_crossFeed_notRegistered_reverts() public {
        address pool = makeAddr("pool");
        address pp = makeAddr("priceProvider");
        factory.setPool(pool, true);
        oracle.register{value: 1}(FEED, pool, address(factory)); // registered for FEED only
        _mockInSwap(pool, pp);

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.NotRegistered.selector, FEED_B, pool));
        vm.prank(pp);
        oracle.price(FEED_B, pool);
    }

    /// A third party (non-admin, non-pool) can pay register to clear blacklist AND re-enable reads.
    function test_register_thirdParty_redeems_andEnablesRead() public {
        address pool = makeAddr("pool");
        address pp = makeAddr("priceProvider");
        factory.setPool(pool, true);
        oracle.setBlacklist(pool, true);

        address thirdParty = makeAddr("thirdParty");
        vm.deal(thirdParty, 1 ether);
        vm.prank(thirdParty);
        oracle.register{value: 1}(FEED, pool, address(factory));

        assertFalse(oracle.blacklisted(pool));
        assertTrue(oracle.registeredPool(FEED, pool));

        _mockInSwap(pool, pp);
        vm.expectEmit(true, true, false, true);
        emit IOffchainOracle.PriceRead(pool, FEED);
        vm.prank(pp);
        oracle.price(FEED, pool);
    }

    /// Blacklisting the calling price provider (msg.sender), not the pool, also reverts.
    function test_priceWithFactory_blacklistedCaller_reverts() public {
        address pool = makeAddr("pool");
        address pp = makeAddr("priceProvider");
        factory.setPool(pool, true);
        oracle.register{value: 1}(FEED, pool, address(factory));
        _mockInSwap(pool, pp);
        oracle.setBlacklist(pp, true); // caller, not pool

        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.Blacklisted.selector, pp));
        vm.prank(pp);
        oracle.price(FEED, pool);
    }

    function test_getOracleDataBulk_disabled() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = FEED;
        vm.expectRevert(OracleBase.ReadDisabled.selector);
        oracle.getOracleDataBulk(ids);
    }

    /// Metadata/config getters are intentionally NOT blacklist-gated.
    function test_blacklisted_metadataGetters_open() public {
        address reader = makeAddr("reader");
        oracle.setBlacklist(reader, true);
        vm.startPrank(reader);
        oracle.priceGuard(FEED);
        oracle.stateGuard(FEED);
        oracle.registeredPool(FEED, reader);
        oracle.isApprovedFactory(address(factory));
        oracle.isIntegrator(reader);
        vm.stopPrank();
        assertTrue(oracle.isApprovedFactory(address(factory)));
    }

    function test_register_zeroFee() public {
        oracle.setRegistrationFee(0);
        address pool = makeAddr("pool");
        factory.setPool(pool, true);
        oracle.register{value: 0}(FEED, pool, address(factory));
        assertTrue(oracle.registeredPool(FEED, pool));
    }

    function test_withdrawEth_pushLeftoverOnly() public {
        // setUp funded 2 wei and the push spent 1 wei on Lazer verification → 1 wei leftover.
        address admin2 = makeAddr("admin2");
        oracle.grantRole(oracle.ADMIN_ROLE(), admin2);
        uint256 bal = address(oracle).balance;
        vm.expectEmit(true, false, false, true);
        emit IOffchainOracle.EthWithdrawn(admin2, bal);
        vm.prank(admin2);
        oracle.withdrawEth();
        assertEq(address(oracle).balance, 0);
        assertEq(admin2.balance, bal);
    }

    function test_setBlacklist_noop_noEvent() public {
        address x = makeAddr("x");
        oracle.setBlacklist(x, true); // real change
        vm.recordLogs();
        oracle.setBlacklist(x, true); // no-op → must not emit
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
    }

    function test_setIntegrators_zeroAddress_reverts() public {
        address[] memory accs = new address[](2);
        accs[0] = makeAddr("ok");
        accs[1] = address(0);
        vm.expectRevert();
        oracle.setIntegrators(accs, true);
        assertEq(oracle.integratorCount(), 0); // whole batch reverted
        assertFalse(oracle.isIntegrator(makeAddr("ok"))); // first element rolled back
    }

    // ─── added coverage (re-audit, round 2) ───────────────────────────

    /// A zero pool address is rejected before any inSwap query.
    function test_priceWithPool_zeroPool_reverts() public {
        address pp = makeAddr("priceProvider");
        vm.expectRevert(IOffchainOracle.InvalidInSwap.selector);
        vm.prank(pp);
        oracle.price(FEED, address(0));
    }

    /// A bare ChainlinkOracle (nothing ever pushed) reverts FeedNotFound on reads.
    function test_chainlink_unknownFeed_reverts() public {
        ChainlinkOracle cl = new ChainlinkOracle(owner, maxTimeDrift, makeAddr("clVerifier"), makeAddr("clFee"));
        bytes32 missing = bytes32(uint256(123));
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, missing));
        cl.price(missing, address(0));
    }

    function test_register_zeroPool_reverts() public {
        vm.expectRevert(); // bare require(pool != address(0))
        oracle.register{value: 1}(FEED, address(0), address(factory));
    }

    /// Registering a non-blacklisted pool emits only PoolRegistered (no BlacklistUpdated).
    function test_register_nonBlacklisted_noBlacklistEvent() public {
        address pool = makeAddr("pool");
        factory.setPool(pool, true);
        vm.recordLogs();
        oracle.register{value: 1}(FEED, pool, address(factory));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1); // only PoolRegistered
    }

    /// Re-adding an already-present integrator via batch emits nothing.
    function test_setIntegrators_reAddPresent_noEvent() public {
        address a = makeAddr("a");
        oracle.addIntegrator(a);
        address[] memory accs = new address[](1);
        accs[0] = a; // already present
        vm.recordLogs();
        oracle.setIntegrators(accs, true);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_addIntegrator_zeroAddress_reverts() public {
        vm.expectRevert();
        oracle.addIntegrator(address(0));
    }

    function test_addApprovedFactory_zeroAddress_reverts() public {
        vm.expectRevert();
        oracle.addApprovedFactory(address(0));
    }

    function test_setBlacklist_zeroAddress_reverts() public {
        vm.expectRevert();
        oracle.setBlacklist(address(0), true);
    }

    /// A pool registered via a SECOND approved factory can read (the factory only matters at register).
    function test_priceWithPool_registeredViaSecondFactory_success() public {
        MockPoolFactory f2 = new MockPoolFactory();
        oracle.addApprovedFactory(address(f2));
        address pool = makeAddr("pool");
        address pp = makeAddr("priceProvider");
        f2.setPool(pool, true);
        oracle.register{value: 1}(FEED, pool, address(f2));
        _mockInSwap(pool, pp);

        vm.expectEmit(true, true, false, true);
        emit IOffchainOracle.PriceRead(pool, FEED);
        vm.prank(pp);
        oracle.price(FEED, pool);
    }

    function _expectNotAdmin(address caller) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                caller,
                oracle.ADMIN_ROLE()
            )
        );
    }
}
