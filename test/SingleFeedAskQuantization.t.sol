// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PythLazer} from "pyth-lazer-sdk/PythLazer.sol";
import {AnchoredPriceProvider} from "../contracts/AnchoredPriceProvider.sol";
import {IAnchoredProviderFactory} from "../contracts/interfaces/IAnchoredProviderFactory.sol";
import {ReportV3} from "../contracts/interfaces/IDataStreams.sol";
import {OracleBase} from "../contracts/oracles/providers/OracleBase.sol";
import {PythOracle} from "../contracts/oracles/providers/PythOracle.sol";
import {ChainlinkOracle} from "../contracts/oracles/providers/ChainlinkOracle.sol";
import {MockPoolFactory} from "./mocks/MockPoolFactory.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";
import {LazerTestPayload} from "./utils/LazerTestPayload.sol";

/// @notice A single-feed ask must cover the upstream interval through both oracles. A $0.000001009
/// price at 1% confidence stores mid = 100 (floored from 100.9) with a 1% spread; the upstream upper
/// edge is 100.9·1.01 = 101.909e-8. A `max(mid·(1+u+m), mid+1)` ask (101.01e-8) falls below it, so
/// the ask compounds the E8 quantum with the uncertainty: (mid+1)·(1+u+m) = 102.0201e-8.
/// Pyth uses a locally signed payload and the real verifier; only Chainlink verification is mocked.
contract SingleFeedAskQuantizationTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant MARGIN = 1e14; // 1 bps in 1e18 units.
    address private activeProvider;

    function inSwap() external view returns (address) {
        return activeProvider;
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.deal(address(this), 1 ether);
    }

    function testPythSingleFeedAskCoversUpstream() public {
        PythLazer implementation = new PythLazer();
        PythLazer lazer = PythLazer(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation), address(this), abi.encodeCall(PythLazer.initialize, (address(this)))
                )
            )
        );
        lazer.updateTrustedSigner(LazerTestPayload.signer(), 3_000_000_000_000_000);
        uint8[] memory props = new uint8[](4);
        props[0] = 0;
        props[1] = 4;
        props[2] = 5;
        props[3] = 12;
        PythOracle oracle = new PythOracle(address(this), address(lazer), 60, props);
        vm.deal(address(oracle), 1 ether);
        bytes[] memory feeds = new bytes[](1);
        uint64 tsMicros = uint64(block.timestamp * 1_000_000);
        // $0.000001009, confidence $0.00000001009: exactly 1%, E8 mid 100.9.
        feeds[0] = LazerTestPayload.buildFeed(1, 100_900, -11, 1009, tsMicros);
        bytes memory update = LazerTestPayload.signAndWrap(LazerTestPayload.buildPayload(tsMicros, 1, feeds));
        (bool success,) = address(oracle).call(abi.encodePacked(uint16(1), uint32(1), update));
        assertTrue(success, "signed update accepted");
        _check(oracle, bytes32(uint256(1)));
    }

    function testChainlinkSingleFeedAskCoversUpstream() public {
        ChainlinkOracle.VerifierRoute[] memory routes = new ChainlinkOracle.VerifierRoute[](1);
        routes[0] = ChainlinkOracle.VerifierRoute(0x51, address(new MockVerifierProxy()), true);
        ChainlinkOracle oracle = new ChainlinkOracle(address(this), 60, routes, address(0));
        bytes32 feedId = bytes32((uint256(3) << 240) | 1);
        uint32 ts = uint32(block.timestamp);
        ReportV3 memory report =
            ReportV3(feedId, ts, ts, 0, 0, ts + 60, 1_009_000_000_000, 998_910_000_000, 1_019_090_000_000);
        oracle.updateReport(abi.encodePacked(uint8(0x51), abi.encode(report)));
        _check(oracle, feedId);
    }

    function _check(OracleBase oracle, bytes32 feedId) private {
        MockPoolFactory pools = new MockPoolFactory();
        pools.setPool(address(this), true);
        oracle.addApprovedFactory(address(pools));
        oracle.register{value: 1}(feedId, address(this), address(pools));
        activeProvider = address(this);
        (uint256 mid, uint256 spread,,) = oracle.price(feedId, address(this));
        assertEq(mid, 100, "normalization floors 100.9 to 100");
        assertEq(spread, 10_000, "1% uncertainty is preserved in spread units");
        AnchoredPriceProvider provider = new AnchoredPriceProvider(
            address(this),
            address(oracle),
            feedId,
            bytes32(0),
            MARGIN,
            60,
            1e18,
            false,
            0,
            address(0xBEEF),
            address(0xCAFE),
            IAnchoredProviderFactory.InitialConfig(address(0), 60, 60, 1e18, 1e18)
        );
        activeProvider = address(provider);
        (uint128 bid, uint128 ask, uint128 referencePrice) = provider.getQuote();

        // Compare exact rational upstream bounds by cross multiplication, independently of APP.
        assertGe(uint256(ask) * 1e11, uint256(101_909) * Q64, "ask covers upstream 101.909 E8");
        assertGe(uint256(ask) * 1e13, uint256(10_191_909) * Q64, "ask covers upstream plus the 1 bps margin");
        assertEq(
            ask,
            Math.mulDiv(mid + 1, Q64 * (1e18 + spread * 1e12 + MARGIN), 1e26, Math.Rounding.Ceil),
            "APP ask = (mid+1)*(1 + 1% + 1 bps)"
        );
        assertEq(ask, Math.mulDiv(1_020_201, Q64, 1e12, Math.Rounding.Ceil), "APP ask is 102.0201 E8");
        assertEq(referencePrice, uint256(100) * Q64 / 1e8, "reference stays at stored mid");
        assertLe(uint256(bid) * 1e11, uint256(99_891) * Q64, "bid covers upstream lower bound");

        // The max(mid·(1+u+m), mid+1) form lands at 101.01 E8, below the upstream edge.
        uint256 maxFormAsk = Math.max(
            Math.mulDiv(mid, Q64 * (1e18 + spread * 1e12 + MARGIN), 1e26, Math.Rounding.Ceil),
            Math.mulDiv(mid + 1, Q64, 1e8, Math.Rounding.Ceil)
        );
        assertEq(maxFormAsk, Math.mulDiv(10_101, Q64, 1e10, Math.Rounding.Ceil), "max-form ask is 101.01 E8");
        assertLt(maxFormAsk * 1e11, uint256(101_909) * Q64, "max-form ask is below upstream 101.909 E8");
    }
}
