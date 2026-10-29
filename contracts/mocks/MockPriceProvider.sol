// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceProvider} from "../interfaces/IPriceProvider.sol";

/// @title MockPriceProvider
/// @notice Simple in-memory price provider for tests, returns bid/ask in Q64.64 format
contract MockPriceProvider is IPriceProvider {
    struct Quote {
        uint256 bid;
        uint256 ask;
        uint16 spread1;
        uint16 feeBps;
    }

    mapping(bytes32 => Quote) private quotes;
    bytes32 public currentPair;
    address public activeBaseToken;
    address public activeQuoteToken;

    error QuoteNotSet();

    function setConfidenceParam(uint256) external override {}


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
        uint16 spread1,
        uint16 feeBps
    ) public {
        quotes[_pairKey(baseToken, quoteToken)] = Quote({
            bid: bidPrice,
            ask: askPrice,
            spread1: spread1,
            feeBps: feeBps
        });
    }

    function setSymmetricPrice(address base, address quote, uint256 priceX64, uint16 spread1, uint16 feeBps)
        external
    {
        setQuote(base, quote, priceX64, priceX64, spread1, feeBps);
        setQuote(quote, base, priceX64, priceX64, spread1, feeBps);
        currentPair = _pairKey(base, quote);
        activeBaseToken = base;
        activeQuoteToken = quote;
    }

    function token0() external view override returns (address) {
        return activeBaseToken;
    }

    function token1() external view override returns (address) {
        return activeQuoteToken;
    }

    function getBidAndAskPrice() external override returns (uint128 bidPrice, uint128 askPrice) {
        Quote memory quote = quotes[currentPair];
        if (quote.bid == 0 || quote.ask == 0) revert QuoteNotSet();
        return (uint128(quote.bid), uint128(quote.ask));
    }
}
