// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ChainlinkOracle} from "../../contracts/oracles/providers/ChainlinkOracle.sol";
import {ReportV4} from "../../contracts/interfaces/IDataStreams.sol";
import {MockDataStreamsVerifier} from "../mocks/MockDataStreamsVerifier.sol";
import {MockPoolFactory} from "../mocks/MockPoolFactory.sol";
import {IPool} from "../../contracts/interfaces/IPoolFactory.sol";

/// @notice End-to-end decode of REAL Chainlink Data Streams reports (testnet) through ChainlinkOracle:
///  - v3 (Crypto) feed 0x00036fe4… — fetched live from api.testnet-dataengine.chain.link
///    (/api/v1/reports/latest), price 9006632444005376000 (18-dec).
///  - HFS feed 0x1003…4656ed — real report (HFS feeds are WebSocket-only on the REST API), ms timestamps.
/// The full signed reports are fed verbatim; MockDataStreamsVerifier extracts the report blob exactly
/// like the real VerifierProxy. Expected values were decoded off-chain from the same bytes.
contract ChainlinkOracleRealDataTest is Test {
    bytes32 constant V3_FEED  = 0x00036fe43f87884450b4c7e093cd5ed99cac6640d8c2000e6afc02c8838d0265;
    bytes32 constant HFS_FEED = 0x100334677029ff1f94a1b91fe60349e7478275ef38cc988103612e83ae4656ed;
    // No v4 (RWA) feed exists on this testnet account, so the v4 report below is self-constructed.
    // Schema version is the high 2 bytes of the feedId → 0x0004 = v4 (seconds resolution).
    bytes32 constant V4_FEED  = 0x0004000000000000000000000000000000000000000000000000000000000001;

    bytes constant V3_REPORT =
        hex"00090d9e8d96765a0c49e03a6ae05c82e8f8de70cf179baa632f18313e54bd69000000000000000000000000000000000000000000000000000000000685016d000000000000000000000000000000000000000000000000000000030000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000002800001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012000036fe43f87884450b4c7e093cd5ed99cac6640d8c2000e6afc02c8838d0265000000000000000000000000000000000000000000000000000000006a1d4dfd000000000000000000000000000000000000000000000000000000006a1d4dfd000000000000000000000000000000000000000000000000000092b8f685c3b6000000000000000000000000000000000000000000000000007e3b7105ece720000000000000000000000000000000000000000000000000000000006a44dafd0000000000000000000000000000000000000000000000007cfdfc7d1772e0000000000000000000000000000000000000000000000000007cf99ab7177c57d80000000000000000000000000000000000000000000000007d02e7cbf3f67d000000000000000000000000000000000000000000000000000000000000000002cf348db62e5ed3fa3b81f775a43beef3e880a655aca48e245d5784f75819f38f594d8267de35198683aeba503655e32b407a29cd11f2d8f3882a5609ad4cd69800000000000000000000000000000000000000000000000000000000000000023a5e49a226655e0f6d3942933ea4c163c4977b55777e82cdf837936c8ac8e233333f642613d07b203c90d7ac17609d2f53c36a74c66ebee47c9d24ea514d5f77";

    bytes constant HFS_REPORT =
        hex"0009ebc1e33244262d2a8077b6e28bd6f2ccebfe891419a478c395ca74f3424b000000000000000000000000000000000000000000000000000000000d14ae86000000000000000000000000000000000000000000000000000000080000000100000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000220000000000000000000000000000000000000000000000000000000000000028000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000120100334677029ff1f94a1b91fe60349e7478275ef38cc988103612e83ae4656ed0000000000000000000000000000000000000000000000000000019e826aa62c0000000000000000000000000000000000000000000000000000019e826aa654000000000000000000000000000000000000000000000000000092cc485d9023000000000000000000000000000000000000000000000000007e5c120f00ac890000000000000000000000000000000000000000000000000000019f1ce96e5400000000000000000000000000000000000000000000000f6dc54e3812f117c600000000000000000000000000000000000000000000000f6dbac00d00f9886400000000000000000000000000000000000000000000000f6dd8b39574eabd690000000000000000000000000000000000000000000000000000000000000002d8506f6422146a16f99fe517b4a7a870872abf704f5a98f745634bdc2ff77662ffd3ddf01ab3f21fac9fe6b941e76ed548c44aa0f6b2bb9e5a5acbb624f0cf4600000000000000000000000000000000000000000000000000000000000000023aa894e893a9b964938f3858ef27fb159d7c66ce4d00a51db2b6686fcfc4e24e45052ce5ae180bade6210971b7c257eb5f500eaf85d3f1d8b27d3ef181008cac";

    ChainlinkOracle private oracle;
    MockPoolFactory private factory;
    address private pool;

    function setUp() public {
        oracle = new ChainlinkOracle(address(this), 1 hours, address(new MockDataStreamsVerifier()), makeAddr("feeToken"));
        vm.deal(address(oracle), 1 ether); // verification-fee pool

        factory = new MockPoolFactory();
        oracle.addApprovedFactory(address(factory));
        pool = makeAddr("pool");
        factory.setPool(pool, true);
        vm.deal(address(this), 1 ether);

        // Registrationless: no feed setup needed — any DON-verified report is stored.
        vm.warp(1780305500); // after both report observation timestamps
    }

    /// @dev Wrap a report blob into a full DON-signed report shell (context + empty sigs), exactly the
    ///      layout the VerifierProxy decodes. Lets a self-made report flow through the same pipeline.
    function _wrap(bytes memory reportData) internal pure returns (bytes memory) {
        bytes32[3] memory ctx;
        bytes32[] memory empty;
        return abi.encode(ctx, reportData, empty, empty, bytes32(0));
    }

    /// @dev Self-constructed v4 (RWA) report: price (18-dec) + market status, seconds timestamp.
    function _v4Report(int192 price, uint32 marketStatus, uint32 obs) internal pure returns (bytes memory) {
        return _wrap(abi.encode(ReportV4(V4_FEED, obs, obs, 0, 0, obs + 3600, price, marketStatus)));
    }

    function _read(bytes32 feed) internal returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) {
        if (!oracle.registeredPool(feed, pool)) oracle.register{value: 1}(feed, pool, address(factory));
        vm.mockCall(pool, abi.encodeWithSelector(IPool.inSwap.selector), abi.encode(address(this)));
        return oracle.price(feed, pool);
    }

    /// Real v3 report: price 9006632444005376000 → 8-dec mid; spread from bid/ask; seconds timestamp.
    function test_realV3_report() public {
        oracle.updateReport(V3_REPORT);
        (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) = _read(V3_FEED);
        assertEq(mid, 900663244, "v3 mid (price / 1e10)");
        assertEq(spread, 2, "v3 spread = ceil(BPS*(ask-bid)/2 / price) bps");
        assertEq(spread1, 0xFFFF, "spread1 marker");
        assertEq(refTime, 1780305405, "v3 observationsTimestamp (seconds)");
    }

    /// Real HFS report: benchmarkPrice 284610975428932343750; MILLISECOND timestamps.
    function test_realHFS_report() public {
        oracle.updateReport(HFS_REPORT);
        (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) = _read(HFS_FEED);
        assertEq(mid, 28461097542, "hfs mid (benchmarkPrice / 1e10)");
        assertEq(spread, 1, "hfs spread bps");
        assertEq(spread1, 0xFFFF, "spread1 marker");
        assertEq(refTime, 1780304488, "hfs ms timestamp converted to seconds (not double-scaled)");
    }

    /// Self-made v4 report, open market: price 2000e18 → 8-dec mid, no bid/ask so spread = 0.
    function test_mockV4_openMarket() public {
        oracle.updateReport(_v4Report(2000e18, 2 /* OPEN */, 1780305400));
        (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime) = _read(V4_FEED);
        assertEq(mid, 200_000_000_000, "v4 mid (price / 1e10)");
        assertEq(spread, 0, "open market -> no spread");
        assertEq(spread1, 0xFFFF, "spread1 marker");
        assertEq(refTime, 1780305400, "v4 observationsTimestamp (seconds)");
    }

    /// Self-made v4 report, closed market: spread forced to BPS_BASE (stalled marker for PriceProvider).
    function test_mockV4_closedMarket() public {
        oracle.updateReport(_v4Report(2000e18, 1 /* CLOSED */, 1780305401));
        (uint256 mid, uint256 spread,,) = _read(V4_FEED);
        assertEq(mid, 200_000_000_000);
        assertEq(spread, 10_000, "closed market -> stalled marker (BPS_BASE)");
    }
}
