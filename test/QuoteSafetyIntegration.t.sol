// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PythLazer} from "pyth-lazer-sdk/PythLazer.sol";
import {PythOracle} from "../contracts/oracles/providers/PythOracle.sol";
import {ChainlinkOracle} from "../contracts/oracles/providers/ChainlinkOracle.sol";
import {OracleBase} from "../contracts/oracles/providers/OracleBase.sol";
import {ReportV3} from "../contracts/interfaces/IDataStreams.sol";
import {AnchoredPriceProvider} from "../contracts/AnchoredPriceProvider.sol";
import {IAnchoredProviderFactory} from "../contracts/interfaces/IAnchoredProviderFactory.sol";
import {MockPoolFactory} from "./mocks/MockPoolFactory.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";
import {LazerTestPayload} from "./utils/LazerTestPayload.sol";
import {TestOracle} from "./utils/TestOracle.sol";

/// @notice End-to-end regressions for saturation, asymmetric reports, and synthetic interval quoting.
/// @dev No external RPC, production signer, or live deployment is used.
contract QuoteSafetyIntegrationTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant T0 = 1_800_000_000;
    uint256 private constant MARGIN = 5e13; // 0.5 bps per side.
    address private activeProvider;
    MockPoolFactory private poolFactory;

    function setUp() public {
        vm.warp(T0);
        vm.deal(address(this), 1 ether);
        poolFactory = new MockPoolFactory();
        poolFactory.setPool(address(this), true);
    }

    function inSwap() external view returns (address) {
        return activeProvider;
    }

    function _init() private pure returns (IAnchoredProviderFactory.InitialConfig memory) {
        return IAnchoredProviderFactory.InitialConfig(address(0), 60, 60, 1e18, 1e18);
    }

    function _register(OracleBase oracle, bytes32 feed) private {
        if (!oracle.isApprovedFactory(address(poolFactory))) oracle.addApprovedFactory(address(poolFactory));
        oracle.register{value: 1}(feed, address(this), address(poolFactory));
    }

    function _provider(OracleBase oracle, bytes32 base, bytes32 quote) private returns (AnchoredPriceProvider p) {
        p = new AnchoredPriceProvider(
            address(this),
            address(oracle),
            base,
            quote,
            MARGIN,
            60,
            1e18,
            false,
            0,
            address(0xBEEF),
            address(0xCAFE),
            _init()
        );
        _register(oracle, base);
        if (quote != bytes32(0)) _register(oracle, quote);
        activeProvider = address(p);
    }

    function _chainlink() private returns (ChainlinkOracle oracle) {
        ChainlinkOracle.VerifierRoute[] memory routes = new ChainlinkOracle.VerifierRoute[](1);
        routes[0] = ChainlinkOracle.VerifierRoute(0x51, address(new MockVerifierProxy()), true);
        oracle = new ChainlinkOracle(address(this), 60, routes, address(0));
    }

    function _report(bytes32 feed, int192 price, int192 bid, int192 ask) private pure returns (bytes memory) {
        return abi.encodePacked(
            uint8(0x51), abi.encode(ReportV3(feed, uint32(T0), uint32(T0), 0, 0, uint32(T0 + 3600), price, bid, ask))
        );
    }

    function testAuditChainlinkSaturationHaltsTwentyPercentBand() public {
        ChainlinkOracle oracle = _chainlink();
        bytes32 feed = bytes32((uint256(3) << 240) | 1);
        oracle.updateReport(_report(feed, 100e18, 80e18, 120e18));
        AnchoredPriceProvider p = _provider(oracle, feed, bytes32(0));
        oracle.addIntegrator(address(this));
        (, uint256 storedSpread,,) = oracle.integratorPrice(feed);
        assertEq(storedSpread, 65534);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        p.getQuote();
    }

    function testAuditPythSaturationHaltsSignedTwentyPercentConfidence() public {
        PythLazer implementation = new PythLazer();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation), address(this), abi.encodeCall(PythLazer.initialize, (address(this)))
        );
        PythLazer lazer = PythLazer(address(proxy));
        lazer.updateTrustedSigner(LazerTestPayload.signer(), 3_000_000_000_000_000);
        uint8[] memory props = new uint8[](4);
        props[0] = 0;
        props[1] = 4;
        props[2] = 5;
        props[3] = 12;
        PythOracle oracle = new PythOracle(address(this), address(lazer), 60, props);
        bytes[] memory feeds = new bytes[](1);
        feeds[0] = LazerTestPayload.buildFeed(1, 100e8, -8, 20e8, uint64(T0 * 1e6));
        bytes memory signed = LazerTestPayload.signAndWrap(LazerTestPayload.buildPayload(uint64(T0 * 1e6), 1, feeds));
        (bool ok,) = address(oracle).call{value: 1}(abi.encodePacked(uint16(1), uint32(1), signed));
        assertTrue(ok, "real local Pyth verification succeeds");
        AnchoredPriceProvider p = _provider(oracle, bytes32(uint256(1)), bytes32(0));
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        p.getQuote();
    }

    function testAuditSyntheticQuoteCoversRatioOfConfidenceEdges() public {
        TestOracle oracle = new TestOracle(address(this), 60);
        bytes32 base = bytes32(uint256(1));
        bytes32 quote = bytes32(uint256(2));
        oracle.setData(base, 100e8, 10000, 0, T0); // 100 +/- 1%.
        oracle.setData(quote, 100e8, 10000, 0, T0);
        AnchoredPriceProvider p = _provider(oracle, base, quote);
        (uint128 bid, uint128 ask,) = p.getQuote();
        uint256 conservativeAsk = Math.mulDiv(101, Q64, 99, Math.Rounding.Ceil);
        assertGe(ask, conservativeAsk, "ask covers the ratio of opposing confidence edges");
        assertLe(bid, Math.mulDiv(99, Q64, 101), "bid covers the opposite edges");
        emit log_named_uint("actual_ask_e12", uint256(ask) * 1e12 / Q64);
        emit log_named_uint("confidence_edge_ratio_e12", conservativeAsk * 1e12 / Q64);
    }

    function testAuditAsymmetricChainlinkSpreadCoversUpperEdge() public {
        ChainlinkOracle oracle = _chainlink();
        bytes32 feed = bytes32((uint256(3) << 240) | 1);
        oracle.updateReport(_report(feed, 100e18, 99e18, 103e18));
        AnchoredPriceProvider p = _provider(oracle, feed, bytes32(0));
        (, uint128 ask,) = p.getQuote();
        assertGe(ask, 103 * Q64, "maximum deviation covers the reported ask");
        emit log_named_uint("ask_e8", uint256(ask) * 1e8 / Q64);
    }
}
