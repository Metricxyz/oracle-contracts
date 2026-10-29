// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TimeMs} from "../oracles/utils/TimeMs.sol";

interface IOffchainOracle {
    struct PriceGuard {
        uint128 min;
        uint128 max;
    } // 128+128 = 256

    struct OracleInfo {
        address baseToken;
        address quoteToken;
        bytes misc;
    }
    // N = 0 for 0-31 bytes length;
    // N = 256 + ceil(length / 32)*256

    struct OracleData {
        uint64 price;
        uint16 spread;
        uint16 volatility;
        TimeMs timestampMs;
    } // 64+16+16+56=152

    struct CreationRequest {
        address baseToken;
        address quoteToken;
        uint128 minPrice;
        uint128 maxPrice;
        address stateGuard;
        bytes misc;
    } // memory

    struct CreationResponse {
        bytes32 feedId;
        bytes misc;
    } // memory

    function getOracleCount() external view returns (uint256);
    function getOracleIds(uint256 start, uint256 end) external view returns (bytes32[] memory);
    function getOracleInfo(bytes32 feedId) external view returns (OracleInfo memory);

    function getOracleData(bytes32 feedId) external view returns (OracleData memory data);
    function getOracleDataBulk(bytes32[] calldata feedId) external view returns (OracleData[] memory data);

    function priceGuard(bytes32 feedId) external view returns (uint128 min, uint128 max);

    event FeedRegistered(
        bytes32 indexed feedId,
        address indexed baseToken,
        address indexed quoteToken,
        address stateGuard,
        uint128 minPrice,
        uint128 maxPrice,
        bytes misc
    );

    event FeedTokensUpdated(
        bytes32 indexed feedId,
        address indexed baseToken,
        address indexed quoteToken
    );

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

    error BadCreationRequest();
    error BadCalldataLength();
    error DeadlineExceeded();
    error FeedAlreadyExists(bytes32 feedId);
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
