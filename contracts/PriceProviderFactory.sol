// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {PriceProvider} from "./PriceProvider.sol";
import {IPriceProviderFactory} from "./interfaces/IPriceProviderFactory.sol";

contract PriceProviderFactory is AccessControl, Multicall, IPriceProviderFactory {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ── Roles ───────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ── Storage ─────────────────────────────────────────────────────────
    EnumerableSet.AddressSet private _providers;
    mapping(address creator => EnumerableSet.AddressSet) private _providersByCreator;
    mapping(address provider => address) public providerOwner;
    mapping(address provider => mapping(address updater => bool)) public isUpdater;

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(address _admin) {
        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
    }

    // ── Modifiers ─────────────────────────────────────────────────────
    modifier onlyProviderOwner(address provider) {
        if (msg.sender != providerOwner[provider]) revert NotProviderOwner();
        _;
    }

    function _requireUpdater(address provider) internal view {
        if (msg.sender != providerOwner[provider] && !isUpdater[provider][msg.sender])
            revert NotProviderUpdater();
    }

    // ── Deploy (permissionless) ───────────────────────────────────────

    function createPriceProvider(
        address _oracle,
        bytes32 _feedId,
        int256  _cexStep,
        uint256 _maxTimeDelta,
        uint16  _maxClDeviation,
        address _baseTokenOverride,
        address _quoteTokenOverride
    ) external override returns (address provider) {
        PriceProvider p = new PriceProvider(
            address(this),
            _oracle,
            _feedId,
            _cexStep,
            _maxTimeDelta,
            _maxClDeviation,
            _baseTokenOverride,
            _quoteTokenOverride
        );

        provider = address(p);
        address creator = msg.sender;

        _providers.add(provider);
        _providersByCreator[creator].add(provider);
        providerOwner[provider] = creator;

        emit ProviderDeployed(
            provider,
            creator,
            _feedId,
            _oracle,
            p.baseToken(),
            p.quoteToken(),
            _cexStep,
            _maxTimeDelta,
            _maxClDeviation
        );
    }

    // ── Updater management ────────────────────────────────────────────

    function grantUpdater(address provider, address updater) external override onlyProviderOwner(provider) {
        require(_providers.contains(provider), ProviderNotTracked());
        isUpdater[provider][updater] = true;
        emit UpdaterGranted(provider, updater);
    }

    function revokeUpdater(address provider, address updater) external override onlyProviderOwner(provider) {
        require(_providers.contains(provider), ProviderNotTracked());
        isUpdater[provider][updater] = false;
        emit UpdaterRevoked(provider, updater);
    }

    function transferProviderOwnership(address provider, address newOwner) external override onlyProviderOwner(provider) {
        require(_providers.contains(provider), ProviderNotTracked());
        require(newOwner != address(0));
        address previousOwner = providerOwner[provider];

        providerOwner[provider] = newOwner;
        _providersByCreator[previousOwner].remove(provider);
        _providersByCreator[newOwner].add(provider);

        emit ProviderOwnershipTransferred(provider, previousOwner, newOwner);
    }

    // ── Add / Remove (admin) ──────────────────────────────────────────

    function addProvider(address provider) external override onlyRole(ADMIN_ROLE) {
        require(PriceProvider(provider).factory() == address(this));
        if (!_providers.add(provider)) revert ProviderAlreadyTracked();

        address owner = providerOwner[provider];
        if (owner != address(0)) {
            _providersByCreator[owner].add(provider);
        }

        emit ProviderAdded(provider);
    }

    function removeProvider(address provider) external override onlyRole(ADMIN_ROLE) {
        if (!_providers.remove(provider)) revert ProviderNotTracked();

        address owner = providerOwner[provider];
        if (owner != address(0)) {
            _providersByCreator[owner].remove(provider);
        }

        emit ProviderRemoved(provider);
    }

    // ── Batch setConfidence ──────────────────────────────────────────────
    function setConfidence(
        address[] calldata providers,
        uint256[] calldata values
    ) external override {
        uint256 l = providers.length;
        if (l != values.length) revert LengthMismatch();

        for (uint256 i; i < l; ++i) {
            require(_providers.contains(providers[i]), ProviderNotTracked());
            _requireUpdater(providers[i]);
            PriceProvider(providers[i]).setConfidenceParam(values[i]);
        }
    }

    // ── Batch setCexStep (debug) ────────────────────────────────────────
    /// @dev DEBUG ONLY — will be removed before production deployment
    function setCexStep(
        address[] calldata providers,
        int256[]  calldata steps
    ) external override {
        uint256 l = providers.length;
        if (l != steps.length) revert LengthMismatch();

        for (uint256 i; i < l; ++i) {
            require(_providers.contains(providers[i]), ProviderNotTracked());
            _requireUpdater(providers[i]);
            PriceProvider(providers[i]).setCexStep(steps[i]);
        }
    }

    // ── Batch setMaxClDeviation ────────────────────────────────────────
    function setMaxClDeviation(
        address[] calldata providers,
        uint16[]  calldata deviations
    ) external override {
        uint256 l = providers.length;
        if (l != deviations.length) revert LengthMismatch();

        for (uint256 i; i < l; ++i) {
            require(_providers.contains(providers[i]), ProviderNotTracked());
            _requireUpdater(providers[i]);
            PriceProvider(providers[i]).setMaxClDeviation(deviations[i]);
        }
    }

    // ── Batch setClOracle ─────────────────────────────────────────────
    function setClOracle(
        address[] calldata providers,
        address[] calldata tokens,
        address[] calldata oracles,
        uint32[]  calldata heartbeats
    ) external override {
        uint256 l = providers.length;
        if (l != tokens.length || l != oracles.length || l != heartbeats.length) revert LengthMismatch();

        for (uint256 i; i < l; ++i) {
            require(_providers.contains(providers[i]), ProviderNotTracked());
            _requireUpdater(providers[i]);
            PriceProvider(providers[i]).setClOracle(tokens[i], oracles[i], heartbeats[i]);
        }
    }

    // ── Batch removeClOracle ─────────────────────────────────────────
    function removeClOracle(
        address[] calldata providers,
        address[] calldata tokens
    ) external override {
        uint256 l = providers.length;
        if (l != tokens.length) revert LengthMismatch();

        for (uint256 i; i < l; ++i) {
            require(_providers.contains(providers[i]), ProviderNotTracked());
            _requireUpdater(providers[i]);
            PriceProvider(providers[i]).removeClOracle(tokens[i]);
        }
    }

    // ── Views ───────────────────────────────────────────────────────────

    function isProvider(address provider) external view returns (bool) {
        return _providers.contains(provider);
    }

    function providerCount() external view returns (uint256) {
        return _providers.length();
    }

    function providerAt(uint256 index) external view returns (address) {
        return _providers.at(index);
    }

    function providerCountByCreator(address creator) external view returns (uint256) {
        return _providersByCreator[creator].length();
    }

    /// @notice Paginated provider list filtered by creator.
    function getProviders(
        address creator,
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (address[] memory providers, uint256[] memory updatableAfter, uint256 total)
    {
        EnumerableSet.AddressSet storage set = _providersByCreator[creator];
        total = set.length();

        if (offset >= total) {
            return (new address[](0), new uint256[](0), total);
        }

        uint256 remaining = total - offset;
        uint256 count = limit < remaining ? limit : remaining;

        providers = new address[](count);
        updatableAfter = new uint256[](count);

        for (uint256 i; i < count; ++i) {
            PriceProvider p = PriceProvider(set.at(offset + i));
            providers[i] = address(p);
            updatableAfter[i] = p.lastConfidenceUpdate() + p.CONFIDENCE_COOLDOWN();
        }
    }

    /// @notice Paginated list of ALL providers.
    function getAllProviders(
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (address[] memory providers, uint256[] memory updatableAfter, uint256 total)
    {
        total = _providers.length();

        if (offset >= total) {
            return (new address[](0), new uint256[](0), total);
        }

        uint256 remaining = total - offset;
        uint256 count = limit < remaining ? limit : remaining;

        providers = new address[](count);
        updatableAfter = new uint256[](count);

        for (uint256 i; i < count; ++i) {
            PriceProvider p = PriceProvider(_providers.at(offset + i));
            providers[i] = address(p);
            updatableAfter[i] = p.lastConfidenceUpdate() + p.CONFIDENCE_COOLDOWN();
        }
    }
}
