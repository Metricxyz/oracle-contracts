// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "../../contracts/interfaces/AggregatorV3Interface.sol";

contract MockAggregator is AggregatorV3Interface {
    uint8 private immutable _decimals;
    int256 private _answer;
    uint80 private _roundId;
    uint256 private _updatedAt;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
        _roundId = 1;
    }

    function setLatest(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
        unchecked {
            _roundId += 1;
        }
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "mock-aggregator";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, 0, _updatedAt, _roundId);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, 0, _updatedAt, _roundId);
    }
}
