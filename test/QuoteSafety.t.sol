// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AnchoredPriceProvider} from "../contracts/AnchoredPriceProvider.sol";
import {IAnchoredProviderFactory} from "../contracts/interfaces/IAnchoredProviderFactory.sol";
import {TestOracle} from "./utils/TestOracle.sol";
import {MockPoolFactory} from "./mocks/MockPoolFactory.sol";
import {MockAnchorSource} from "./mocks/MockAnchorSource.sol";

/// @notice Independent containment and failure-boundary checks for AUD-02 and AUD-04.
contract QuoteSafetyTest is Test {
    uint256 private constant Q64 = 1 << 64;
    uint256 private constant MARGIN = 5e13;
    bytes32 private constant BASE = bytes32(uint256(1));
    bytes32 private constant QUOTE = bytes32(uint256(2));
    TestOracle private oracle;
    address private activeProvider;

    function inSwap() external view returns (address) {
        return activeProvider;
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.deal(address(this), 1 ether);
        oracle = new TestOracle(address(this), 60);
        MockPoolFactory pools = new MockPoolFactory();
        pools.setPool(address(this), true);
        oracle.addApprovedFactory(address(pools));
        oracle.register{value: 1}(BASE, address(this), address(pools));
        oracle.register{value: 1}(QUOTE, address(this), address(pools));
        oracle.setData(BASE, 100e8, 10_000, 0, block.timestamp);
        oracle.setData(QUOTE, 100e8, 10_000, 0, block.timestamp);
    }

    function _deploy(bool synthetic, uint8 mode, uint256 baseMult, uint256 quoteMult, uint256 margin)
        private
        returns (AnchoredPriceProvider p)
    {
        // Modes cover both immutable/mutable reference paths and both source variants.
        address source;
        if (mode % 4 >= 2) {
            MockAnchorSource src = new MockAnchorSource();
            src.set(uint128(Q64), uint128(Q64 + 1));
            source = address(src);
        }
        p = new AnchoredPriceProvider(
            address(this),
            address(oracle),
            BASE,
            synthetic ? QUOTE : bytes32(0),
            margin,
            60,
            Math.max(1e18, Math.max(baseMult, quoteMult)),
            mode % 2 == 1,
            0,
            address(0xBEEF),
            address(0xCAFE),
            IAnchoredProviderFactory.InitialConfig(source, 60, 60, baseMult, quoteMult)
        );
        activeProvider = address(p);
    }

    function testFuzzSaturationHaltsBeforeMultipliers(uint16 rawSpread, bool quoteLeg, uint64 rawMult, uint8 mode)
        public
    {
        uint16 spread = 65_534 + rawSpread % 2;
        uint256 mult = bound(rawMult, 0, 2e18);
        oracle.setData(quoteLeg ? QUOTE : BASE, 100e8, spread, 0, block.timestamp);
        AnchoredPriceProvider p = _deploy(quoteLeg, mode, mult, mult, MARGIN);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        p.getQuote();
    }

    function testSaturationHaltsWithZeroMultipliersOnEitherLeg() public {
        AnchoredPriceProvider p = _deploy(true, 0, 0, 0, MARGIN);
        oracle.setData(BASE, 100e8, 65_534, 0, block.timestamp);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        p.getQuote();
        oracle.setData(BASE, 100e8, 0, 0, block.timestamp);
        oracle.setData(QUOTE, 100e8, 65_534, 0, block.timestamp);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        p.getQuote();
    }

    function testLargestAcceptedSpreadSingleAndSynthetic() public {
        oracle.setData(BASE, 100e8, 65_533, 0, block.timestamp);
        oracle.setData(QUOTE, 100e8, 65_533, 0, block.timestamp);
        AnchoredPriceProvider single = _deploy(false, 0, 1e18, 1e18, MARGIN);
        (uint128 bid, uint128 ask,) = single.getQuote();
        assertGt(bid, 0);
        assertGt(ask, bid);
        AnchoredPriceProvider synthetic = _deploy(true, 0, 1e18, 1e18, MARGIN);
        (bid, ask,) = synthetic.getQuote();
        assertGt(bid, 0);
        assertGt(ask, bid);
    }

    function testFuzzSyntheticContainsUnroundedInputIntervals(
        uint64 rawBase,
        uint64 rawQuote,
        uint16 rawBaseSpread,
        uint16 rawQuoteSpread,
        uint32 rawBaseMult,
        uint32 rawQuoteMult,
        uint16 baseFraction,
        uint16 quoteFraction,
        uint8 mode
    ) public {
        uint256 baseMid = bound(rawBase, 1000, 1e15);
        uint256 quoteMid = bound(rawQuote, 1000, 1e15);
        uint16 baseSpread = uint16(bound(rawBaseSpread, 0, 65_533));
        uint16 quoteSpread = uint16(bound(rawQuoteSpread, 0, 65_533));
        // Multipliers use independent millionth units in the expected interval cross-products.
        uint256 bm = bound(rawBaseMult, 0, 2_000_000);
        uint256 qm = bound(rawQuoteMult, 0, 2_000_000);
        oracle.setData(BASE, uint64(baseMid), baseSpread, 0, block.timestamp);
        oracle.setData(QUOTE, uint64(quoteMid), quoteSpread, 0, block.timestamp);
        AnchoredPriceProvider p = _deploy(true, mode, bm * 1e12, qm * 1e12, MARGIN);
        (uint128 bid, uint128 ask, uint128 referencePrice) = p.getQuote();

        // Pick real prices INSIDE their E8 quanta. Check the exact rational interval with integer
        // cross-products, without copying the contract's division or floor/ceil implementation.
        uint256 actualBase = baseMid * 1000 + baseFraction % 1000;
        uint256 actualQuote = quoteMid * 1000 + quoteFraction % 1000;
        uint256 lowerBase = actualBase * (1e12 - uint256(baseSpread) * bm);
        uint256 upperBase = actualBase * (1e12 + uint256(baseSpread) * bm);
        uint256 lowerQuote = actualQuote * (1e12 - uint256(quoteSpread) * qm);
        uint256 upperQuote = actualQuote * (1e12 + uint256(quoteSpread) * qm);
        assertLe(uint256(bid) * upperQuote, lowerBase * Q64, "bid covers the lower ratio edge");
        assertGe(uint256(ask) * lowerQuote, upperBase * Q64, "ask covers the upper ratio edge");
        assertEq(referencePrice, baseMid * Q64 / quoteMid, "reference is independent of shaping");
        assertLe(bid, referencePrice);
        assertGt(ask, referencePrice);
    }

    function testDenominatorUncertaintyIsNotLinearized() public {
        oracle.setData(BASE, 100e8, 0, 0, block.timestamp);
        AnchoredPriceProvider p = _deploy(true, 0, 1e18, 1e18, MARGIN);
        (uint128 bid, uint128 ask,) = p.getQuote();
        assertGe(ask, Math.mulDiv(100, Q64, 99, Math.Rounding.Ceil));
        assertLe(bid, Math.mulDiv(100, Q64, 101));
    }

    function testCheapLegQuantaCompoundWithUncertainty() public {
        oracle.setData(BASE, 100, 10_000, 0, block.timestamp);
        oracle.setData(QUOTE, 100, 10_000, 0, block.timestamp);
        AnchoredPriceProvider p = _deploy(true, 0, 1e18, 1e18, 1);
        (uint128 bid, uint128 ask,) = p.getQuote();
        // True mids may approach 101, so the outer ratio edges are 99/102.01 and 102.01/99.
        assertLe(uint256(bid) * 10_201, 9900 * Q64);
        assertGe(uint256(ask) * 9900, 10_201 * Q64);
    }

    function testNonpositiveDenominatorHalts() public {
        oracle.setData(BASE, 100e8, 0, 0, block.timestamp);
        AnchoredPriceProvider p = _deploy(true, 0, 1e18, 100e18, MARGIN);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        p.getQuote();
    }

    function testUpperRatioDeviationAtOneHundredPercentHalts() public {
        oracle.setData(BASE, 100e8, 0, 0, block.timestamp);
        AnchoredPriceProvider p = _deploy(true, 0, 1e18, 50e18, MARGIN);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        p.getQuote();
    }

    function testNearlyZeroDenominatorHaltsWithoutPanic() public {
        oracle.setData(BASE, 100e8, 0, 0, block.timestamp);
        oracle.setData(QUOTE, 100e8, 1, 0, block.timestamp);
        AnchoredPriceProvider p = _deploy(true, 0, 1e18, (1e18 - 1) * 1e6, 1);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        p.getQuote();
    }

    function testHugeMarginHaltsWithoutPanic() public {
        AnchoredPriceProvider p = _deploy(true, 0, 1e18, 1e18, type(uint256).max);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        p.getQuote();
    }

    function testHugeMultiplierHaltsWithoutPanic() public {
        AnchoredPriceProvider p = _deploy(true, 0, type(uint256).max, type(uint256).max, MARGIN);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        p.getQuote();
    }

    function testSyntheticAskOverflowHalts() public {
        oracle.setData(BASE, type(uint64).max, 0, 0, block.timestamp);
        oracle.setData(QUOTE, 1, 0, 0, block.timestamp);
        AnchoredPriceProvider p = _deploy(true, 0, 1e18, 1e18, 1);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        p.getQuote();
    }
}
