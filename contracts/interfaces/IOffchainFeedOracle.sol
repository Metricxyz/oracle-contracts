// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOffchainFeedOracle {
    struct AuxInfo {
        uint96 lastRoundId;
        uint32 volatility;
        uint64 lastUpdateBlock;
        uint64 lastUpdateAt;
    }

    error NotFeeder();
    error DeadlineExpired();

    function update(uint128 bid, uint128 ask, uint32 volatility, uint256 deadline, uint96 roundId) external;

    function token0() external view returns (address);
    function token1() external view returns (address);

    function lastRoundId() external view returns (uint96);

    function PRECISION_SCALE() external view returns (uint256);
    function isStale() external view returns (bool);
    function ageInBlocks() external view returns (uint256);
    function getFeedData() external view returns (uint128 bidEff, uint128 askEff, uint32 volatility, bool stale);
}
