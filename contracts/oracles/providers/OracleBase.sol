// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Multicall } from "@openzeppelin/contracts/utils/Multicall.sol";

import { IOffchainOracle } from "../../interfaces/IOffchainOracle.sol";
import { IPoolFactory, IPool } from "../../interfaces/IPoolFactory.sol";
import { TimeMs, toTimeMs } from "../utils/TimeMs.sol";

contract OracleBase is AccessControl, Multicall, IOffchainOracle {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    bytes32 public constant ADMIN_ROLE     = keccak256("ADMIN_ROLE");
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    uint8 public constant decimals = 8;

    uint256 internal immutable MAX_TIME_DRIFT;

    EnumerableSet.Bytes32Set internal feedIds;

    mapping(bytes32 => OracleInfo) public oracleInfo;
    // internal: raw price is only readable via the blacklist-gated getOracleData/price
    // (Extsload removed, so there is no raw storage-slot bypass of the blacklist).
    mapping(bytes32 => OracleData) internal oracleData;
    mapping(bytes32 => PriceGuard) public priceGuard;
    mapping(bytes32 => address) public pendingStateGuard;
    mapping(bytes32 => address) public stateGuard;

    // ── Read-access / abuse protection ──
    uint256 public registrationFee;
    EnumerableSet.AddressSet internal approvedFactories;
    EnumerableSet.AddressSet internal integrators;
    mapping(address => bool) public blacklisted;
    mapping(bytes32 => mapping(address => bool)) public registeredPool;

    uint16 public constant BPS_BASE = 10_000;

    error NotImplemented();
    /// @notice Public price getters are disabled: on-chain consumption must go through the
    ///         abuse-protected attributed path `price(feedId, factory)` (pools) or `integratorPrice`
    ///         (whitelisted integrators). Off-chain consumers read raw storage / events.
    error ReadDisabled();

    constructor(address _owner, uint256 maxTimeDrift) {
        _grantRole(ADMIN_ROLE, _owner);
        _grantRole(REGISTRAR_ROLE, _owner);
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REGISTRAR_ROLE, ADMIN_ROLE);
        MAX_TIME_DRIFT = maxTimeDrift;
        registrationFee = 1 wei; // very cheap default; ADMIN tunes via setRegistrationFee
    }

    modifier feedExists(bytes32 feedId) {
        require(feedIds.contains(feedId), FeedNotFound(feedId));

        _;
    }

    modifier checkRole(bytes32 feedId) {
        address _guard = stateGuard[feedId];
        if (_guard != address(0)) {
            require(_guard == msg.sender, InvalidGuard(msg.sender));
        } else {
            _checkRole(ADMIN_ROLE);
        }

        _;
    }

    modifier notBlacklisted() {
        require(!blacklisted[msg.sender], Blacklisted(msg.sender));

        _;
    }

    /*
     *
     * Service functions
     * 
     */

    function setBaseAndQuoteTokens(bytes32 feedId, address baseToken, address quoteToken) external feedExists(feedId) checkRole(feedId) {
        _setBaseAndQuoteTokens(feedId, baseToken, quoteToken);
    }

    function _setBaseAndQuoteTokens(bytes32 feedId, address baseToken, address quoteToken) internal {
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

    function setStateGuardRole(bytes32 feedId, address newGuard) external feedExists(feedId) checkRole(feedId) {
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

    function purgeStateGuardRole(bytes32 feedId) external feedExists(feedId) checkRole(feedId) {
        delete stateGuard[feedId];

        emit StateGuardDeleted(feedId);
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
    
    /// @dev DISABLED. Reading is only allowed via the attributed path price(feedId, factory).
    function getOracleDataBulk(bytes32[] calldata) external view override returns (OracleData[] memory) {
        revert ReadDisabled();
    }

    /// @dev DISABLED. Reading is only allowed via the attributed path price(feedId, factory).
    function getOracleData(bytes32) public view virtual override returns (OracleData memory) {
        revert ReadDisabled();
    }

    function _getOracleData(OracleInfo memory info) internal virtual view returns (OracleData memory data) {
        // silence warning
        info = info;

        data.price = 0;
        data.spread = 0;
        data.volatility = 0;
        data.timestampMs = TimeMs.wrap(0);
    }

    /// @dev Raw oracle data for the gated on-chain read paths only (price(feedId, factory),
    ///      integratorPrice). The public getters are disabled, so this is the single internal source.
    function _oracleDataRaw(bytes32 feedId) internal view virtual returns (OracleData memory) {
        return _getOracleData(getOracleInfo(feedId));
    }


    function getOracleInfo(bytes32 feedId) public view override feedExists(feedId) returns (OracleInfo memory info) {
        info = oracleInfo[feedId];
    }

    /// @dev DISABLED. Reading is only allowed via the attributed path price(feedId, factory).
    function price(bytes32 feedId)
        external
        virtual
        view
        feedExists(feedId)
        returns (uint256 /* mid */, uint256 /* spread */, uint16 /* volatility */, uint256 /* refTime */)
    {
        revert ReadDisabled();
    }

    /*
     *
     * Read-access / abuse protection
     *
     */

    /// @notice On-chain read for pools (abuse-protected). The caller (`msg.sender`) is the pool's price
    ///         provider; the pool address is forwarded by that provider. The pool must report
    ///         `inSwap() == msg.sender`, be registered for `feedId` and not blacklisted.
    /// @dev    The pool forwards its real caller from the provider, so it cannot frame another pool;
    ///         `pool.inSwap() == msg.sender` binds the read to a pool that authorized this provider.
    ///         The approved-factory check lives at registration (`register` validates via isPool), not here.
    function price(bytes32 feedId, address pool)
        external
        feedExists(feedId)
        notBlacklisted
        returns (uint256 mid, uint256 spread, uint16 volatility, uint256 refTime)
    {
        require(pool != address(0) && IPool(pool).inSwap() == msg.sender, InvalidInSwap());
        require(!blacklisted[pool], Blacklisted(pool));
        require(registeredPool[feedId][pool], NotRegistered(feedId, pool));

        (mid, spread, volatility, refTime) = _readPrice(feedId);
        emit PriceRead(pool, feedId);
    }

    /// @notice Read for whitelisted external integrators.
    function integratorPrice(bytes32 feedId)
        external
        feedExists(feedId)
        notBlacklisted
        returns (uint256 mid, uint256 spread, uint16 volatility, uint256 refTime)
    {
        require(integrators.contains(msg.sender), NotWhitelisted(msg.sender));

        (mid, spread, volatility, refTime) = _readPrice(feedId);
        emit PriceRead(msg.sender, feedId);
    }

    function _readPrice(bytes32 feedId)
        internal
        view
        returns (uint256 mid, uint256 spread, uint16 volatility, uint256 refTime)
    {
        OracleData memory data = _oracleDataRaw(feedId);
        return (uint256(data.price), uint256(data.spread), data.volatility, data.timestampMs.toSeconds());
    }

    /// @notice Permissionless paid registration: whitelist `pool` for `feedId` (required to use the
    ///         on-chain price(feedId, factory) path). `factory` must be approved and recognize `pool`
    ///         via isPool. Paying also clears any blacklist on the pool.
    /// @dev    Overpayment is NOT refunded: any msg.value above registrationFee is kept and is
    ///         withdrawable by ADMIN via withdrawEth. This is intentional.
    function register(bytes32 feedId, address pool, address factory) external payable feedExists(feedId) {
        require(msg.value >= registrationFee, InsufficientFee(msg.value, registrationFee));
        require(pool != address(0));
        require(approvedFactories.contains(factory), FactoryNotApproved(factory));
        require(IPoolFactory(factory).isPool(pool), NotAPool(pool));

        if (blacklisted[pool]) {
            blacklisted[pool] = false;
            emit BlacklistUpdated(pool, false);
        }

        registeredPool[feedId][pool] = true;
        emit PoolRegistered(feedId, pool, msg.sender, msg.value);
    }

    /* Integrator whitelist (CRUD, ADMIN_ROLE) */

    function addIntegrator(address integrator) external onlyRole(ADMIN_ROLE) {
        require(integrator != address(0));
        require(integrators.add(integrator), AlreadyIntegrator(integrator));
        emit IntegratorUpdated(integrator, true);
    }

    function removeIntegrator(address integrator) external onlyRole(ADMIN_ROLE) {
        require(integrators.remove(integrator), NotIntegrator(integrator));
        emit IntegratorUpdated(integrator, false);
    }

    function setIntegrators(address[] calldata accounts, bool approved) external onlyRole(ADMIN_ROLE) {
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            require(account != address(0));
            bool changed = approved ? integrators.add(account) : integrators.remove(account);
            if (changed) {
                emit IntegratorUpdated(account, approved);
            }
        }
    }

    function isIntegrator(address account) external view returns (bool) {
        return integrators.contains(account);
    }

    function integratorCount() external view returns (uint256) {
        return integrators.length();
    }

    function getIntegrators(uint256 start, uint256 end) external view returns (address[] memory) {
        return integrators.values(start, end);
    }

    /* Maintainer (ADMIN_ROLE) */

    function setRegistrationFee(uint256 newFee) external onlyRole(ADMIN_ROLE) {
        uint256 oldFee = registrationFee;
        registrationFee = newFee;
        emit RegistrationFeeUpdated(oldFee, newFee);
    }

    function addApprovedFactory(address factory) external onlyRole(ADMIN_ROLE) {
        require(factory != address(0));
        require(approvedFactories.add(factory), FactoryAlreadyApproved(factory));
        emit ApprovedFactoryAdded(factory);
    }

    function removeApprovedFactory(address factory) external onlyRole(ADMIN_ROLE) {
        require(approvedFactories.remove(factory), FactoryNotApproved(factory));
        emit ApprovedFactoryRemoved(factory);
    }

    function setBlacklist(address account, bool value) external onlyRole(ADMIN_ROLE) {
        require(account != address(0));
        if (blacklisted[account] == value) return;
        blacklisted[account] = value;
        emit BlacklistUpdated(account, value);
    }

    function isApprovedFactory(address factory) external view returns (bool) {
        return approvedFactories.contains(factory);
    }

    function approvedFactoryCount() external view returns (uint256) {
        return approvedFactories.length();
    }

    function getApprovedFactories(uint256 start, uint256 end) external view returns (address[] memory) {
        return approvedFactories.values(start, end);
    }

    /// @notice ADMIN sweeps the FULL contract balance (registration fees plus any other ETH held,
    ///         including any operational reserve) to the caller. Sweeping everything is intentional.
    function withdrawEth() external onlyRole(ADMIN_ROLE) {
        uint256 amount = address(this).balance;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok);
        emit EthWithdrawn(msg.sender, amount);
    }

    /*
     *
     * Main logic
     *
     */

    function createOracles(CreationRequest[] calldata) external virtual returns (CreationResponse[] memory) {
        revert NotImplemented();
    }

    function updateBySignature(address, uint256, uint256, bytes calldata) external virtual returns (bool) {
        revert NotImplemented();
    }

    fallback() payable external virtual {
        revert NotImplemented();
    }

    receive() payable external virtual {
        revert NotImplemented();
    }

    /*
     *
     * Internals
     * 
     */

    function _ensureDeadline(uint256 deadline) internal view virtual {
        require(block.timestamp <= deadline, DeadlineExceeded());
    }

    function _addFeedId(bytes32 feedId) internal returns (bool) {
        bool ok = feedIds.add(feedId);
        if (ok){
            // mark feed as created
            oracleData[feedId].timestampMs = toTimeMs(1);
        }

        return ok;
    }
}
