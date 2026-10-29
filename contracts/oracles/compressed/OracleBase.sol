// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IOffchainOracle } from "../../interfaces/IOffchainOracle.sol";
import {Extsload} from "../utils/Extsload.sol";
import {TimeMs} from "../utils/TimeMs.sol";

contract OracleBase is AccessControl, Extsload, IOffchainOracle {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint8 public constant decimals = 8;

    uint256 internal immutable MAX_TIME_DRIFT;

    EnumerableSet.Bytes32Set internal feedIds;

    mapping(bytes32 => OracleInfo) public oracleInfo;
    mapping(bytes32 => PriceGuard) public priceGuard;
    mapping(bytes32 => address) public pendingStateGuard;
    mapping(bytes32 => address) public stateGuard;

    uint16 public constant BPS_BASE = 10_000;

    constructor(address _owner, uint256 maxTimeDrift) {
        _grantRole(ADMIN_ROLE, _owner);
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        MAX_TIME_DRIFT = maxTimeDrift;
    }

    modifier feedExists(bytes32 feedId) {
        require(feedIds.contains(feedId), FeedNotFound(feedId));

        _;
    }

    modifier checkRole(bytes32 feedId) {
        require(stateGuard[feedId] == msg.sender, InvalidGuard(msg.sender));
        _;
    }

    /*
     *
     * Service functions
     * 
     */

    function setBaseAndQuoteTokens(bytes32 feedId, address baseToken, address quoteToken) external feedExists(feedId) checkRole(feedId) {
        require(baseToken != address(0) && quoteToken != address(0) && baseToken != quoteToken);
        oracleInfo[feedId].baseToken = baseToken;
        oracleInfo[feedId].quoteToken = quoteToken;

        emit FeedTokensUpdated(
            feedId,
            baseToken,
            quoteToken
        );
    }

    function setPriceGuard(bytes32 feedId, uint128 minPrice, uint128 maxPrice)
        external
        feedExists(feedId)
        checkRole(feedId)
    {
        require(minPrice < maxPrice);

        priceGuard[feedId] = PriceGuard({min: minPrice, max: maxPrice});

        emit PriceGuardUpdated(feedId, minPrice, maxPrice);
    }

    function setPendingStateGuardRole(bytes32 feedId, address newGuard) external feedExists(feedId) checkRole(feedId) {
        pendingStateGuard[feedId] = newGuard;

        emit StateGuardPending(feedId, newGuard);
    }

    function purgePendingStateGuardRole(bytes32 feedId) external feedExists(feedId) checkRole(feedId) {
        delete pendingStateGuard[feedId];

        emit PendingStateGuardDeleted(feedId);
    }

    function acceptStateGuardRole(bytes32 feedId) external feedExists(feedId) {
        require(pendingStateGuard[feedId] == msg.sender, InvalidGuard(msg.sender));

        delete pendingStateGuard[feedId];
        stateGuard[feedId] = msg.sender;

        emit StateGuardUpdated(feedId, msg.sender);
    }

    /*
     *
     * Views
     * 
     */

    function getOracleCount() external view override returns (uint256) {
        return feedIds.length();
    }

    function getOracleIds(uint256 start, uint256 end) external view override returns (bytes32[] memory) {
        return feedIds.values(start, end);
    }
    
    function getOracleDataBulk(bytes32[] calldata feedId) external view override returns (OracleData[] memory res) {
        res = new OracleData[](feedId.length);
        for (uint256 i; i < feedId.length; i++) {
            res[i] = getOracleData(feedId[i]);
        }
    }

    function getOracleData(bytes32 feedId) public view override returns (OracleData memory data) {
        OracleInfo memory info = getOracleInfo(feedId);
        return _getOracleData(info);
    }

    function _getOracleData(OracleInfo memory info) internal virtual view returns (OracleData memory data) {
        // silence warning
        info = info;

        data.price = 0;
        data.spread = 0;
        data.volatility = 0;
        data.timestampMs = TimeMs.wrap(0);
    }


    function getOracleInfo(bytes32 feedId) public view override feedExists(feedId) returns (OracleInfo memory info) {
        info = oracleInfo[feedId];
    }


    /*
     *
     * Main logic
     * 
     */

    function createOracles(CreationRequest[] calldata) external virtual returns (CreationResponse[] memory) {
        revert("not implemented");
    }

    function updateBySignature(address, uint256, uint256, bytes calldata) external virtual returns (bool) {
        revert("not implemented");
    }

    fallback() external virtual {
        revert("not implemented");
    }

    /*
     *
     * Internals
     * 
     */

    function _ensureDeadline(uint256 deadline) internal view virtual {
        require(block.timestamp <= deadline, DeadlineExceeded());
    }
}
