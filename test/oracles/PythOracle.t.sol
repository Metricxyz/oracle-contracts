// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {PythLazer} from "pyth-lazer-sdk/PythLazer.sol";

import {PythOracle} from "../../contracts/oracles/providers/PythOracle.sol";
import {OracleBase} from "../../contracts/oracles/providers/OracleBase.sol";
import {IOffchainOracle} from "../../contracts/interfaces/IOffchainOracle.sol";
import {MockPoolFactory} from "../mocks/MockPoolFactory.sol";
import {IPool} from "../../contracts/interfaces/IPoolFactory.sol";
import {toTimeMs} from "../../contracts/oracles/utils/TimeMs.sol";
import {LazerTestPayload} from "../utils/LazerTestPayload.sol";

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice PythOracle is REGISTRATIONLESS: any feed id in a Lazer-signed payload is stored
///         on push (the signature is the trust anchor). A feed "exists" for readers once its
///         first verified update lands (timestampMs != 0).
contract PythOracleTest is Test {
    PythOracle oracle;
    address owner;
    address trustedSigner;
    PythLazer pythLazer;

    // Attributed-read harness: public getters are disabled, reads go via price(feedId, factory).
    MockPoolFactory factory;
    address pool;

    // Update signed on the fly by the LazerTestPayload test key
    uint256 constant updateTime = 1769872629;
    uint256 constant maxTimeDrift = 60;

    function _priceUpdate() internal pure returns (bytes memory) {
        return LazerTestPayload.defaultUpdate(uint64(updateTime) * 1_000_000);
    }

    function setUp() public {
        trustedSigner = LazerTestPayload.signer();
        owner = makeAddr("owner");

        PythLazer pythLazerImpl = new PythLazer();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(pythLazerImpl), owner, abi.encodeWithSelector(PythLazer.initialize.selector, owner)
        );
        pythLazer = PythLazer(address(proxy));

        vm.prank(owner);
        pythLazer.updateTrustedSigner(trustedSigner, 3000000000000000);

        uint8[] memory expectedProps = new uint8[](4);
        expectedProps[0] = 0;
        expectedProps[1] = 4;
        expectedProps[2] = 5;
        expectedProps[3] = 12;
        oracle = new PythOracle(address(this), address(pythLazer), maxTimeDrift, expectedProps);

        factory = new MockPoolFactory();
        oracle.addApprovedFactory(address(factory));
        pool = makeAddr("pool");
        factory.setPool(pool, true);
        vm.deal(address(this), 1 ether);

        vm.warp(updateTime);
    }

    // ─── Helpers ──────────────────────────────────────────────────────

    function _fundOracle() internal {
        // forge-lint: disable-next-line(unchecked-call)
        address(oracle).call{value: 2}("");
    }

    /// calldata format: [feedsLength:2][feedIds:4 bytes each][lazer priceUpdate] — no deadline prefix.
    function _buildCalldata() internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint16(4),
            uint32(1), uint32(2), uint32(3), uint32(4),
            _priceUpdate()
        );
    }

    /// @dev Registrationless push: fund the verification fee and feed the raw calldata to the fallback.
    function _pushUpdate() internal {
        _fundOracle();
        (bool ok,) = address(oracle).call(_buildCalldata());
        require(ok, "push update failed");
    }

    /// @dev Read oracle data via the attributed pool path (public getters are disabled).
    function _read(bytes32 feedId) internal returns (IOffchainOracle.OracleData memory d) {
        if (!oracle.registeredPool(feedId, pool)) {
            oracle.register{value: 1}(feedId, pool, address(factory));
        }
        vm.mockCall(pool, abi.encodeWithSelector(IPool.inSwap.selector), abi.encode(address(this)));
        (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) = oracle.price(feedId, pool);
        d.price = uint64(mid);
        d.spread0 = uint16(spread);
        d.spread1 = spread1;
        d.timestampMs = toTimeMs(refTime * 1000);
    }

    /// @dev Push a single-feed update with a chosen price/timestamp (for monotonicity tests).
    function _pushSingleFeed(uint32 feedId, int64 price, uint64 tsMicros) internal returns (bool ok) {
        bytes[] memory feeds = new bytes[](1);
        feeds[0] = LazerTestPayload.buildFeed(feedId, price, -8, 100_000, tsMicros);
        bytes memory update = LazerTestPayload.signAndWrap(LazerTestPayload.buildPayload(tsMicros, 1, feeds));

        _fundOracle();
        (ok,) = address(oracle).call(abi.encodePacked(uint16(1), feedId, update));
    }

    // ─── setUp / basic ───────────────────────────────────────────────

    function test_setUp() public view {
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.BPS_BASE(), 10_000);
        assertEq(oracle.version(), "0.0.10");
        assertEq(oracle.kind(), "pyth-lazer");
    }

    // ─── registrationless storage ────────────────────────────────────

    /// A verified payload carrying a feed id NEVER seen before is stored and readable.
    function test_push_unseenFeedId_storedAndReadable() public {
        bytes32 feedId = bytes32(uint256(1));

        // Never pushed → does not exist yet.
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, feedId));
        oracle.price(feedId, pool);

        _pushUpdate();

        // Readable via the whitelisted-integrator path with real data.
        oracle.addIntegrator(address(this));
        (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) = oracle.integratorPrice(feedId);
        assertEq(mid, 20 * 1e8, "feed 1 mid from the signed payload");
        assertGt(spread, 0);
        assertEq(spread1, 0xFFFF);
        assertEq(refTime, updateTime);
    }

    /// Reading a feed id that never received a verified push reverts FeedNotFound.
    function test_read_revertsForNeverPushedFeed() public {
        _pushUpdate(); // feeds 1..4 exist, 999 does not

        bytes32 feedId = bytes32(uint256(999));
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, feedId));
        oracle.price(feedId, pool);

        oracle.addIntegrator(address(this));
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, feedId));
        oracle.integratorPrice(feedId);
    }

    function test_read_multipleFeeds() public {
        _pushUpdate();
        assertGt(_read(bytes32(uint256(1))).price, 0);
        assertGt(_read(bytes32(uint256(2))).price, 0);
    }

    // ─── getOracleData (disabled) ────────────────────────────────────

    function test_getOracleData_disabled() public {
        // The public getter is removed: it reverts for everyone (on-chain reads go via the pool path).
        vm.expectRevert(OracleBase.ReadDisabled.selector);
        oracle.getOracleData(bytes32(uint256(1)));
    }

    // ─── fallback (price update) ─────────────────────────────────────

    function test_fallback_updatesAllFeeds() public {
        _pushUpdate();

        // All 4 feeds in the payload should have data
        for (uint256 i = 1; i <= 4; i++) {
            IOffchainOracle.OracleData memory d = _read(bytes32(uint256(i)));
            assertGt(d.price, 0, "feed price should be > 0 after update");
            // After _verifyAndStore, spread1 is set to 0xFFFF
            assertEq(d.spread1, 0xFFFF, "spread1 should be 0xFFFF from LazerConsumer");
        }
    }

    function test_fallback_reverts_timestampDrift() public {
        _fundOracle();
        // Block time far behind the per-feed FeedUpdateTimestamp → FutureTimestamp inside the consumer
        vm.warp(updateTime - maxTimeDrift - 1);
        (bool ok,) = address(oracle).call(_buildCalldata());
        assertFalse(ok, "should revert on future feed timestamps beyond drift");
    }

    function test_fallback_reverts_feedsLengthMismatch() public {
        _fundOracle();
        // Declare 3 ids while the signed payload carries 4 feeds
        bytes memory cd = abi.encodePacked(
            uint16(3),
            uint32(1), uint32(2), uint32(3),
            _priceUpdate()
        );
        (bool ok,) = address(oracle).call(cd);
        assertFalse(ok, "should revert on feeds-length mismatch");
    }

    function test_fallback_reverts_feedIdMismatch() public {
        _fundOracle();
        // Declared ids don't match the ids inside the signed payload (1..4)
        bytes memory cd = abi.encodePacked(
            uint16(4),
            uint32(9), uint32(2), uint32(3), uint32(4),
            _priceUpdate()
        );
        (bool ok,) = address(oracle).call(cd);
        assertFalse(ok, "should revert on feed-id mismatch");
    }

    function test_fallback_canBeCalledTwice() public {
        _pushUpdate();

        IOffchainOracle.OracleData memory d1 = _read(bytes32(uint256(1)));

        // Fund again and push same update — same feed ts is not overwritten, read is stable
        _fundOracle();
        (bool ok,) = address(oracle).call(_buildCalldata());
        require(ok, "second push failed");

        IOffchainOracle.OracleData memory d2 = _read(bytes32(uint256(1)));
        assertEq(d1.price, d2.price, "same update should yield same price");
    }

    // ─── monotonicity (per-feed FeedUpdateTimestamp) ─────────────────

    function test_push_olderTimestamp_doesNotOverwrite() public {
        _pushUpdate(); // feed 1 = 20e8 @ updateTime

        // Signed update with an OLDER per-feed timestamp and a different price → ignored
        bool ok = _pushSingleFeed(1, int64(99 * 1e8), uint64(updateTime - 1) * 1_000_000);
        assertTrue(ok, "older push itself must not revert");

        IOffchainOracle.OracleData memory d = _read(bytes32(uint256(1)));
        assertEq(d.price, 20 * 1e8, "older feed timestamp must not overwrite");
    }

    function test_push_newerTimestamp_overwrites() public {
        _pushUpdate(); // feed 1 = 20e8 @ updateTime

        vm.warp(updateTime + 1);
        bool ok = _pushSingleFeed(1, int64(21 * 1e8), uint64(updateTime + 1) * 1_000_000);
        assertTrue(ok, "newer push failed");

        IOffchainOracle.OracleData memory d = _read(bytes32(uint256(1)));
        assertEq(d.price, 21 * 1e8, "newer feed timestamp must overwrite");
    }

    function test_receive_acceptsEther() public {
        (bool ok,) = address(oracle).call{value: 1 ether}("");
        assertTrue(ok, "receive should accept ether");
    }

    // ─── price() attributed path ─────────────────────────────────────

    function test_price_reverts_feedNotFound() public {
        bytes32 feedId = bytes32(uint256(999));
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, feedId));
        oracle.price(feedId, address(0));
    }

    function test_price_returnsRawData_regardlessOfGuards() public {
        bytes32 feedId = bytes32(uint256(1));

        _pushUpdate();

        IOffchainOracle.OracleData memory d = _read(feedId);
        assertGt(d.price, 0, "feed 1 has real data after push");

        // Guards are stored but NOT enforced at the oracle (they live in the price provider):
        // min above the actual price still returns raw data.
        oracle.setPriceGuard(feedId, uint128(uint256(d.price)) + 1, type(uint128).max);
        IOffchainOracle.OracleData memory d2 = _read(feedId);
        assertEq(d2.price, d.price, "mid should be raw price");
        assertEq(d2.spread0, d.spread0, "spread should be raw spread");

        // max below the actual price still returns raw data.
        oracle.setPriceGuard(feedId, 0, uint128(uint256(d.price)) - 1);
        IOffchainOracle.OracleData memory d3 = _read(feedId);
        assertEq(d3.price, d.price, "mid should be raw price");
    }

    function test_price_spread1EqualsMarker_afterUpdate() public {
        bytes32 feedId = bytes32(uint256(1));

        // After _verifyAndStore, spread1 is always 0xFFFF (65535) != BPS_BASE (10000)
        _pushUpdate();

        IOffchainOracle.OracleData memory d = _read(feedId);
        assertEq(d.spread1, 0xFFFF);
    }

    // ─── guards (configurable BEFORE the first push) ─────────────────

    /// Guard setters are not existence-gated: ADMIN configures a guard before the first push.
    function test_setPriceGuard_beforeFirstPush() public {
        bytes32 feedId = bytes32(uint256(1));

        // No data yet for feedId — the setter still works (auth = ADMIN, no stateGuard set)
        oracle.setPriceGuard(feedId, 10, 200);
        (uint128 min, uint128 max) = oracle.priceGuard(feedId);
        assertEq(min, 10);
        assertEq(max, 200);

        // First push later does not disturb the pre-configured guard
        _pushUpdate();
        (min, max) = oracle.priceGuard(feedId);
        assertEq(min, 10);
        assertEq(max, 200);
        assertGt(_read(feedId).price, 0);
    }

    function test_setPriceGuard_reverts_minGteMax() public {
        vm.expectRevert();
        oracle.setPriceGuard(bytes32(uint256(1)), 200, 100);
    }

    function test_stateGuard_beforeFirstPush() public {
        bytes32 feedId = bytes32(uint256(7)); // never pushed
        address guard = makeAddr("guard");

        oracle.setStateGuardRole(feedId, guard);
        vm.prank(guard);
        oracle.acceptStateGuardRole(feedId);
        assertEq(oracle.stateGuard(feedId), guard);

        // Once a guard is set, ADMIN loses guard-setter authority for that feed
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.InvalidGuard.selector, address(this)));
        oracle.setPriceGuard(feedId, 1, 100);

        vm.prank(guard);
        oracle.setPriceGuard(feedId, 1, 100);
        (uint128 min, uint128 max) = oracle.priceGuard(feedId);
        assertEq(min, 1);
        assertEq(max, 100);
    }

    function test_stateGuard_roleTransfer() public {
        bytes32 feedId = bytes32(uint256(1));
        address guard1 = makeAddr("guard1");
        address guard2 = makeAddr("guard2");

        oracle.setStateGuardRole(feedId, guard1);
        vm.prank(guard1);
        oracle.acceptStateGuardRole(feedId);

        // guard1 initiates transfer to guard2
        vm.prank(guard1);
        oracle.setStateGuardRole(feedId, guard2);
        assertEq(oracle.pendingStateGuard(feedId), guard2);

        // guard2 accepts
        vm.prank(guard2);
        oracle.acceptStateGuardRole(feedId);
        assertEq(oracle.stateGuard(feedId), guard2);
        assertEq(oracle.pendingStateGuard(feedId), address(0));
    }

    function test_acceptStateGuardRole_reverts_wrongCaller() public {
        bytes32 feedId = bytes32(uint256(1));
        address guard1 = makeAddr("guard1");
        address guard2 = makeAddr("guard2");

        oracle.setStateGuardRole(feedId, guard1);
        vm.prank(guard1);
        oracle.acceptStateGuardRole(feedId);

        vm.prank(guard1);
        oracle.setStateGuardRole(feedId, guard2);

        // Wrong person tries to accept
        vm.prank(makeAddr("rando"));
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.InvalidGuard.selector, makeAddr("rando")));
        oracle.acceptStateGuardRole(feedId);
    }

    function test_purgeStateGuardRole() public {
        bytes32 feedId = bytes32(uint256(1));
        address guard = makeAddr("guard");

        oracle.setStateGuardRole(feedId, guard);
        vm.prank(guard);
        oracle.acceptStateGuardRole(feedId);

        vm.prank(guard);
        oracle.purgeStateGuardRole(feedId);
        assertEq(oracle.stateGuard(feedId), address(0));
    }

    function test_checkRole_blocksUnauthorized() public {
        bytes32 feedId = bytes32(uint256(1));
        address guard = makeAddr("guard");

        oracle.setStateGuardRole(feedId, guard);
        vm.prank(guard);
        oracle.acceptStateGuardRole(feedId);

        // Non-guard tries to setPriceGuard (guarded by checkRole)
        vm.prank(makeAddr("rando"));
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.InvalidGuard.selector, makeAddr("rando")));
        oracle.setPriceGuard(feedId, 1, 100);
    }
}
