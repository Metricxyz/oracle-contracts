// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IPriceProvider} from "../interfaces/IPriceProvider.sol";

/// @title MockPriceProvider
/// @notice Simple in-memory price provider for tests, returns bid/ask in Q64.64 format
contract MockPriceProvider is IPriceProvider {
    struct Quote {
        uint256 bid;
        uint256 ask;
        uint16 volatility;
        uint16 feeBps;
    }

    mapping(bytes32 => Quote) private quotes;
    bytes32 public currentPair;
    address public activeBaseToken;
    address public activeQuoteToken;

    error QuoteNotSet();

    function setConfidenceParam(uint256) external override {}
    function setCexStep(int256) external override {}
    function setClOracle(address, address, uint32) external override {}
    function removeClOracle(address) external override {}
    function setMaxClDeviation(uint16) external override {}


    function setActivePair(address base, address quote) external {
        currentPair = _pairKey(base, quote);
        activeBaseToken = base;
        activeQuoteToken = quote;
    }

    function _pairKey(address base, address quote) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(base, quote));
    }

    function setQuote(
        address baseToken,
        address quoteToken,
        uint256 bidPrice,
        uint256 askPrice,
        uint16 volatility,
        uint16 feeBps
    ) public {
        quotes[_pairKey(baseToken, quoteToken)] = Quote({
            bid: bidPrice,
            ask: askPrice,
            volatility: volatility,
            feeBps: feeBps
        });
    }

    function setSymmetricPrice(address token0, address token1, uint256 priceX64, uint16 volatility, uint16 feeBps)
        external
    {
        setQuote(token0, token1, priceX64, priceX64, volatility, feeBps);
        setQuote(token1, token0, priceX64, priceX64, volatility, feeBps);
        currentPair = _pairKey(token0, token1);
        activeBaseToken = token0;
        activeQuoteToken = token1;
    }

    function getTokens() external view override returns (address baseToken, address quoteToken) {
        return (activeBaseToken, activeQuoteToken);
    }

    function getBidPrice() external view override returns (uint256 bidPrice) {
        Quote memory quote = quotes[currentPair];
        if (quote.bid == 0) revert QuoteNotSet();
        return quote.bid;
    }

    function getBidPriceUi() external view override returns (uint256 bidPrice) {
        return this.getBidPrice();
    }

    function getAskPrice() external view override returns (uint256 askPrice) {
        Quote memory quote = quotes[currentPair];
        if (quote.ask == 0) revert QuoteNotSet();
        return quote.ask;
    }

    function getAskPriceUi() external view override returns (uint256 askPrice) {
        return this.getAskPrice();
    }

    function getBidAndAskPrice() external view override returns (uint128 bidPrice, uint128 askPrice) {
        Quote memory quote = quotes[currentPair];
        if (quote.bid == 0 || quote.ask == 0) revert QuoteNotSet();
        return (uint128(quote.bid), uint128(quote.ask));
    }

    function getBidAndAskPriceUi() external view override returns (uint128 bidPrice, uint128 askPrice) {
        return this.getBidAndAskPrice();
    }
}
