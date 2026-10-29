// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TimeMs} from "../oracles/utils/TimeMs.sol";

interface IOffchainOracle {
    struct PriceGuard {
        uint128 min;
        uint128 max;
    } // 128+128 = 256

    struct OracleData {
        uint64 price;
        uint16 spread0;
        uint16 spread1;
        TimeMs timestampMs;
    } // 64+16+16+56=152

    function getOracleData(bytes32 feedId) external view returns (OracleData memory data);
    function getOracleDataBulk(bytes32[] calldata feedId) external view returns (OracleData[] memory data);

    function priceGuard(bytes32 feedId) external view returns (uint128 min, uint128 max);

    event PriceGuardUpdated(bytes32 indexed feedId, uint128 minPrice, uint128 maxPrice);
    event StateGuardUpdated(bytes32 indexed feedId, address indexed stateGuard);
    event StateGuardPending(bytes32 indexed feedId, address indexed stateGuard);
    event PendingStateGuardDeleted(bytes32 indexed feedId);
    event StateGuardDeleted(bytes32 indexed feedId);

    // Read-access / abuse protection
    event PriceRead(address indexed reader, bytes32 indexed feedId);
    event PoolRegistered(bytes32 indexed feedId, address indexed pool, address indexed payer, uint256 fee);
    event RegistrationFeeUpdated(uint256 oldFee, uint256 newFee);
    event ApprovedFactoryAdded(address indexed factory);
    event ApprovedFactoryRemoved(address indexed factory);
    event BlacklistUpdated(address indexed account, bool blacklisted);
    event IntegratorUpdated(address indexed integrator, bool approved);
    event EthWithdrawn(address indexed to, uint256 amount);

    error BadCalldataLength();
    error DeadlineExceeded();
    error FeedNotFound(bytes32 feedId);
    error InvalidAuthority(address authority);
    error InvalidGuard(address guard);

    // Read-access / abuse protection
    error Blacklisted(address account);
    error InsufficientFee(uint256 sent, uint256 required);
    error NotAPool(address pool);
    error NotRegistered(bytes32 feedId, address pool);
    error FactoryNotApproved(address factory);
    error FactoryAlreadyApproved(address factory);
    error InvalidInSwap();
    error NotWhitelisted(address account);
    error AlreadyIntegrator(address integrator);
    error NotIntegrator(address integrator);
}
