// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IPriceProvider {

    function setConfidenceParam(uint256 newValue) external;

    /// @dev DEBUG ONLY — will be removed before production deployment
    function setCexStep(int256 newCexStep) external;

    function setClOracle(address token, address oracle, uint32 heartbeat) external;
    function removeClOracle(address token) external;
    function setMaxClDeviation(uint16 newMaxDeviation) external;

    function getTokens() external view returns (address baseToken, address quoteToken);

    /**
     * @notice Get bid and ask prices for a token pair
     * @return bidPrice The bid price in Q128.128 format
     */
    function getBidPrice() external view returns (uint256 bidPrice);

    function getBidPriceUi() external view returns (uint256 bidPrice);

    /**
     * @notice Get the ask price for a token pair
     * @return askPrice The ask price in Q128.128 format
     */
    function getAskPrice() external view returns (uint256 askPrice);

    function getAskPriceUi() external view returns (uint256 askPrice);

    function getBidAndAskPrice() external view returns (uint128 bidPrice, uint128 askPrice);

    function getBidAndAskPriceUi() external view returns (uint128 bidPrice, uint128 askPrice);
}
