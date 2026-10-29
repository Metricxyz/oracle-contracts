// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOnchainOracle {
    function price(address pool) external view returns (uint256 price, uint256 feeBps);
    function priceWithImpact(address pool, uint256 amountIn) external view returns (uint256 price, uint256 feeBps);
    function feeBpsBase() external view returns(uint256);
}
