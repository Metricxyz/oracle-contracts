// SPDX-License-Identifier: UNLICENSED
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

/// @notice Coverage for the read-access / abuse-protection layer added to providers/OracleBase.
contract OracleBaseAbuseProtectionTest is Test {
    PythOracle oracle;
    MockPoolFactory factory;

    address owner; // ADMIN_ROLE
    PythLazer pythLazer;
    bytes32 constant FEED = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    uint256 constant maxTimeDrift = 60;

    // Pyth push harness (same signed payload as PythOracle.t.sol) for real-data assertions
    address constant trustedSigner = 0x26FB61A864c758AE9fBA027a96010480658385B9;
    uint256 constant updateTime = 1769872629;
    bytes constant PRICE_UPDATE =
        hex"2a22999a4f8a1051529ed15c4ca7a8ea5b531f4fc6edb741f073509daf358191e0621d78357213f8d597d6af0116106183372228abe47a782779d9ebc335ed9e707cc64800009093c7d375000649b0955d37d001050000000803000000000005f3616b04fff80500000000000053a80000000103000000075e3567d42804fff80500000001f5be184c0000000203000000003b166f293f04fff80500000000050fdac5000000030300000000000052553704fff8050000000000000d6f000000040300000000000000a64504fff605000000000000001f";

    function setUp() public {
        owner = address(this); // test contract is ADMIN + REGISTRAR
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
        pythLazer.updateTrustedSigner(trustedSigner, 3000000000000000);

        uint8[] memory expectedProps = new uint8[](3);
        expectedProps[0] = 0;
        expectedProps[1] = 4;
        expectedProps[2] = 5;
        oracle = new PythOracle(owner, address(proxy), maxTimeDrift, 8, expectedProps);

        oracle.registerFeed(FEED, makeAddr("base"), makeAddr("quote"));

        factory = new MockPoolFactory();
        oracle.addApprovedFactory(address(factory));

        vm.warp(updateTime);
    }

    // ─── Pyth push helpers (real-data) ────────────────────────────────

    function _fundOracle() internal {
        (bool ok, ) = address(oracle).call{value: 2}("");
        require(ok);
    }

    function _buildCalldata() internal view returns (bytes memory) {
        return abi.encodePacked(
            uint32(block.timestamp),
            uint16(5),
            uint32(8), uint32(1), uint32(2), uint32(3), uint32(4),
            PRICE_UPDATE
        );
    }

    function _isRegistered(bytes32 feedId) internal view returns (bool) {
        try oracle.getOracleInfo(feedId) returns (IOffchainOracle.OracleInfo memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _pushUpdate() internal {
        _fundOracle();
        for (uint256 i = 1; i <= 4; i++) {
            bytes32 feedId = bytes32(uint256(i));
            if (!_isRegistered(feedId)) {
                oracle.registerFeed(
                    feedId,
                    makeAddr(string(abi.encodePacked("base-", i))),
                    makeAddr(string(abi.encodePacked("quote-", i)))
                );
            }
        }
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

        vm.expectEmit(true, true, true, true);
        emit IOffchainOracle.PoolRegistered(FEED, pool, owner, 1);
        oracle.register{value: 1}(FEED, pool, address(factory));

        assertTrue(oracle.registeredPool(FEED, pool));
        assertEq(address(oracle).balance, 1);
    }

    function test_register_acceptsExcessFee() public {
        address pool = makeAddr("pool");
        factory.setPool(pool, true);
        oracle.register{value: 5}(FEED, pool, address(factory));
        assertEq(address(oracle).balance, 5);
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

    function test_register_unknownFeed_reverts() public {
        bytes32 missing = bytes32(uint256(999));
        address pool = makeAddr("pool");
        factory.setPool(pool, true);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, missing));
        oracle.register{value: 1}(missing, pool, address(factory));
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

    function test_viewPrice_disabled() public {
        // feedExists passes (FEED registered) then the getter reverts ReadDisabled for everyone.
        vm.expectRevert(OracleBase.ReadDisabled.selector);
        oracle.price(FEED);
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
        address pool = makeAddr("pool");
        factory.setPool(pool, true);
        oracle.register{value: 3}(FEED, pool, address(factory));

        address admin2 = makeAddr("admin2");
        oracle.grantRole(oracle.ADMIN_ROLE(), admin2);

        vm.expectEmit(true, false, false, true);
        emit IOffchainOracle.EthWithdrawn(admin2, 3);
        vm.prank(admin2);
        oracle.withdrawEth();

        assertEq(admin2.balance, 3);
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
        _pushUpdate();

        address pool = makeAddr("pool");
        address pp = makeAddr("priceProvider");
        factory.setPool(pool, true);
        oracle.register{value: 1}(FEED, pool, address(factory));
        _mockInSwap(pool, pp);

        vm.prank(pp);
        (uint256 mid, uint256 spread, uint16 vol, uint256 refTime) = oracle.price(FEED, pool);
        assertGt(mid, 0); // real pushed data, not the all-zero stub

        // Integrator path returns identical raw data.
        address intg = makeAddr("integrator2");
        oracle.addIntegrator(intg);
        vm.prank(intg);
        (uint256 mid2, uint256 spread2, uint16 vol2, uint256 refTime2) = oracle.integratorPrice(FEED);
        assertEq(mid, mid2);
        assertEq(spread, spread2);
        assertEq(vol, vol2);
        assertEq(refTime, refTime2);
    }

    /// Registration is per-(feedId,pool): registered for FEED must not read FEED_B.
    function test_priceWithFactory_crossFeed_notRegistered_reverts() public {
        oracle.registerFeed(FEED_B, makeAddr("baseB"), makeAddr("quoteB"));
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

    /// Metadata getters are intentionally NOT blacklist-gated.
    function test_blacklisted_metadataGetters_open() public {
        address reader = makeAddr("reader");
        oracle.setBlacklist(reader, true);
        vm.startPrank(reader);
        oracle.getOracleInfo(FEED);
        oracle.getOracleCount();
        oracle.getOracleIds(0, 1);
        vm.stopPrank();
        assertEq(oracle.getOracleCount(), 1);
    }

    function test_register_zeroFee() public {
        oracle.setRegistrationFee(0);
        address pool = makeAddr("pool");
        factory.setPool(pool, true);
        oracle.register{value: 0}(FEED, pool, address(factory));
        assertTrue(oracle.registeredPool(FEED, pool));
    }

    function test_withdrawEth_zeroBalance() public {
        address admin2 = makeAddr("admin2");
        oracle.grantRole(oracle.ADMIN_ROLE(), admin2);
        assertEq(address(oracle).balance, 0);
        vm.expectEmit(true, false, false, true);
        emit IOffchainOracle.EthWithdrawn(admin2, 0);
        vm.prank(admin2);
        oracle.withdrawEth();
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

    /// A bare ChainlinkOracle (skeleton) reverts FeedNotFound on reads (no feeds registrable).
    function test_chainlink_unknownFeed_reverts() public {
        ChainlinkOracle cl = new ChainlinkOracle(owner, maxTimeDrift, makeAddr("clVerifier"), makeAddr("clFee"));
        bytes32 missing = bytes32(uint256(123));
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, missing));
        cl.price(missing);
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
