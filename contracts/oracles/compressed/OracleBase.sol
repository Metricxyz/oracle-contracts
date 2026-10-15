// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IOffchainOracle} from "../../interfaces/IOffchainOracle.sol";
import {Extsload} from "../utils/Extsload.sol";
import {TimeMs} from "../utils/TimeMs.sol";

contract OracleBase is AccessControl, Extsload, IOffchainOracle {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint8 public constant decimals = 8;

    uint256 internal immutable MAX_TIME_DRIFT;

    mapping(bytes32 => PriceGuard) public priceGuard;
    mapping(bytes32 => address) public pendingStateGuard;
    mapping(bytes32 => address) public stateGuard;

    uint16 public constant BPS_BASE = 10_000;
    /// @notice Reserved stall/off-hours sentinel: CompressedOracleV1 returns it in both spread0 and
    ///         spread1 (with price 0 and timestamp 0) for a position holding the 0xff/0xff marker, and
    ///         price providers halt on it.
    ///         Providers also halt on stale, zero or guard-breaching data, and on spreads that codebook
    ///         values (at most 10_000) never reach: APP on the saturated 65_534, the plain
    ///         PriceProvider above 5%. Distinct from BPS_BASE so a genuine wide spread widens the band
    ///         instead of being misread as stalled.
    uint16 public constant STALL_SPREAD = type(uint16).max;

    constructor(address _owner, uint256 maxTimeDrift) {
        _grantRole(ADMIN_ROLE, _owner);
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        MAX_TIME_DRIFT = maxTimeDrift;
    }

    /// Feeds are registrationless: guard authority is the explicit stateGuard when set,
    /// else the feed's default authority resolved from the feedId itself (see _defaultGuard).
    /// A set guard is exclusive for the setters, but the default authority (the feed creator) can
    /// always dissolve it via purgeStateGuardRole (break-glass) — a lost guard key can't freeze it.
    modifier checkRole(bytes32 feedId) {
        address guard = stateGuard[feedId];
        if (guard == address(0)) guard = _defaultGuard(feedId);
        require(guard == msg.sender, InvalidGuard(msg.sender));
        _;
    }

    /// The authority a feed falls back to before an explicit stateGuard is accepted.
    function _defaultGuard(bytes32) internal view virtual returns (address) {
        return address(0);
    }

    /*
     *
     * Service functions
     *
     */

    function setPriceGuard(bytes32 feedId, uint128 minPrice, uint128 maxPrice) external checkRole(feedId) {
        require(minPrice < maxPrice);

        priceGuard[feedId] = PriceGuard({min: minPrice, max: maxPrice});

        emit PriceGuardUpdated(feedId, minPrice, maxPrice);
    }

    function setPendingStateGuardRole(bytes32 feedId, address newGuard) external checkRole(feedId) {
        pendingStateGuard[feedId] = newGuard;

        emit StateGuardPending(feedId, newGuard);
    }

    function purgePendingStateGuardRole(bytes32 feedId) external checkRole(feedId) {
        delete pendingStateGuard[feedId];

        emit PendingStateGuardDeleted(feedId);
    }

    function acceptStateGuardRole(bytes32 feedId) external {
        require(pendingStateGuard[feedId] == msg.sender, InvalidGuard(msg.sender));

        delete pendingStateGuard[feedId];
        stateGuard[feedId] = msg.sender;

        emit StateGuardUpdated(feedId, msg.sender);
    }

    /// Dissolve a feed's delegated state guard, reverting authority to the feed's default authority
    /// (its creator). Callable by the current guard (renounce) OR by that default authority
    /// (break-glass recovery of a lost/compromised guard key). Clears any pending handoff too.
    function purgeStateGuardRole(bytes32 feedId) external {
        require(stateGuard[feedId] == msg.sender || _defaultGuard(feedId) == msg.sender, InvalidGuard(msg.sender));

        delete stateGuard[feedId];
        if (pendingStateGuard[feedId] != address(0)) {
            delete pendingStateGuard[feedId];
            emit PendingStateGuardDeleted(feedId);
        }

        emit StateGuardDeleted(feedId);
    }

    /*
     *
     * Views
     *
     */

    function getOracleDataBulk(bytes32[] calldata feedId) external view override returns (OracleData[] memory res) {
        res = new OracleData[](feedId.length);
        for (uint256 i; i < feedId.length; i++) {
            res[i] = getOracleData(feedId[i]);
        }
    }

    function getOracleData(bytes32 feedId) public view virtual override returns (OracleData memory data) {
        // silence warning
        feedId = feedId;

        data.price = 0;
        data.spread0 = 0;
        data.spread1 = 0;
        data.timestampMs = TimeMs.wrap(0);
    }

    /*
     *
     * Main logic
     *
     */

    function updateBySignature(address, uint256, bytes calldata) external virtual returns (bool) {
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
