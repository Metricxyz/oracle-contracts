// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChainlinkVerifierL2} from "../../contracts/oracles/utils/ChainlinkVerifierL2.sol";
import {IChainlinkVerifier} from "../../contracts/interfaces/IChainlinkVerifier.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

contract ChainlinkVerifierHarness is ChainlinkVerifierL2 {
    constructor(address sequencerUptimeFeed) ChainlinkVerifierL2(sequencerUptimeFeed) {}

    function setOracle(address token, address oracle, uint32 heartbeat) external {
        _setClOracle(token, oracle, heartbeat);
    }

    function removeOracle(address token) external {
        _removeClOracle(token);
    }

    function price(address baseToken, address quoteToken)
        external
        view
        returns (bool oracleFound, uint256 refPrice, uint256 refTime, uint256 heartbeat)
    {
        return _cloPriceInQuote(baseToken, quoteToken);
    }

    function getOracle(address token) external view returns (IChainlinkVerifier.ClOracleInfo memory) {
        return clOracles[token];
    }
}

contract ChainlinkVerifierTest is Test {
    uint32 private constant HEARTBEAT = 1 hours;

    ChainlinkVerifierHarness private verifier;
    MockAggregator private sequencerFeed;

    address private constant BASE_TOKEN = address(0xAAA1);
    address private constant QUOTE_TOKEN = address(0xBBB2);
    address private constant OTHER_TOKEN = address(0xCCC3);

    function setUp() public {
        vm.warp(10_000);
        sequencerFeed = new MockAggregator(0);
        sequencerFeed.setLatest(0, 1);
        verifier = new ChainlinkVerifierHarness(address(sequencerFeed));
    }

    function testSetClOracleStoresInfo() public {
        MockAggregator aggregator = new MockAggregator(8);
        aggregator.setLatest(int256(2_000 * 1e8), block.timestamp);

        vm.expectEmit(true, true, false, true, address(verifier));
        emit IChainlinkVerifier.ClOracleSet(BASE_TOKEN, address(aggregator), HEARTBEAT);
        verifier.setOracle(BASE_TOKEN, address(aggregator), HEARTBEAT);

        IChainlinkVerifier.ClOracleInfo memory info = verifier.getOracle(BASE_TOKEN);
        assertEq(info.oracle, address(aggregator), "oracle mismatch");
        assertEq(info.decimals, 8, "decimals mismatch");
        assertEq(info.heartbeat, HEARTBEAT, "heartbeat mismatch");
    }

    function testRemoveClOracleClearsMapping() public {
        MockAggregator aggregator = new MockAggregator(8);
        aggregator.setLatest(int256(1_000 * 1e8), block.timestamp);
        verifier.setOracle(BASE_TOKEN, address(aggregator), HEARTBEAT);

        vm.expectEmit(true, false, false, false, address(verifier));
        emit IChainlinkVerifier.ClOracleRemoved(BASE_TOKEN);
        verifier.removeOracle(BASE_TOKEN);

        IChainlinkVerifier.ClOracleInfo memory info = verifier.getOracle(BASE_TOKEN);
        assertEq(info.oracle, address(0), "oracle should clear");
        assertEq(info.decimals, 0, "decimals should clear");
        assertEq(info.heartbeat, 0, "heartbeat should clear");
    }

    function testCloPriceInQuoteComputesRatio() public {
        MockAggregator baseAgg = new MockAggregator(8);
        MockAggregator quoteAgg = new MockAggregator(8);

        baseAgg.setLatest(int256(2_000 * 1e8), block.timestamp);
        quoteAgg.setLatest(int256(2 * 1e8), block.timestamp);

        verifier.setOracle(BASE_TOKEN, address(baseAgg), HEARTBEAT);
        verifier.setOracle(QUOTE_TOKEN, address(quoteAgg), HEARTBEAT);

        (bool found, uint256 refPrice, uint256 refTime, uint256 heartbeat) = verifier.price(BASE_TOKEN, QUOTE_TOKEN);

        assertTrue(found, "oracle should be found");
        assertEq(refPrice, 1_000 * 1e8, "reference price mismatch");
        assertEq(refTime, block.timestamp, "reference timestamp mismatch");
        assertEq(heartbeat, HEARTBEAT, "heartbeat mismatch");
    }

    function testCloPriceInQuoteReturnsFalseWithoutBaseOracle() public {
        (bool found,,, ) = verifier.price(BASE_TOKEN, QUOTE_TOKEN);
        assertFalse(found, "oracle should not be found when base missing");
    }

    function testQuoteOraclePresenceRequired() public {
        MockAggregator baseAgg = new MockAggregator(8);
        baseAgg.setLatest(int256(1_000 * 1e8), block.timestamp);
        verifier.setOracle(BASE_TOKEN, address(baseAgg), HEARTBEAT);

        MockAggregator quoteAgg = new MockAggregator(8);
        quoteAgg.setLatest(0, block.timestamp);
        verifier.setOracle(OTHER_TOKEN, address(quoteAgg), HEARTBEAT);

        (bool found,,, ) = verifier.price(BASE_TOKEN, QUOTE_TOKEN);
        assertFalse(found, "oracle should not be found when quote missing");
    }
}
