// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IChainlinkVerifier {
    struct ClOracleInfo {
        address oracle;
        uint8 decimals;
        uint32 heartbeat;
    }

    event ClOracleSet(address indexed token, address indexed oracle, uint32 heartbeat);
    event ClOracleStateSet(address indexed token, address indexed oracle);
    event ClOracleRemoved(address indexed token);

    error ClOracleNotFound();
}