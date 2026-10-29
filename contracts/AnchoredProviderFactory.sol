// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AnchoredPriceProvider} from "./AnchoredPriceProvider.sol";
import {IAnchoredProviderFactory} from "./interfaces/IAnchoredProviderFactory.sol";

/// @notice Anchor Factory: deploys AnchoredPriceProviders against ONE reference oracle, with clamp
///         parameters validated against multisig-tuned pair-class envelopes. One factory instance per
///         reference (a ChainlinkOracle deployment, a PythOracle deployment, …) — public-pool
///         eligibility is then the machine-checkable predicate `recognizedFactory.isProvider(p)`.
contract AnchoredProviderFactory is AccessControl, Multicall, IAnchoredProviderFactory {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ── Roles ───────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ── AnchoredPriceProvider hard bounds (mirrored for envelope validation) ──
    // Must match the constructor checks in AnchoredPriceProvider; an envelope outside these would
    // advertise parameter ranges that always revert at create() with a provider-level error.
    uint256 internal constant BPS_BASE_U  = 1e18;
    uint256 internal constant ONE_BPS_E18 = 1e14;
    uint16  internal constant ORACLE_BPS  = 10_000;
    uint256 internal constant MAX_STALENESS = 7 days;

    // ── Immutables ──────────────────────────────────────────────────────
    /// @notice The reference oracle every provider from this factory is anchored to.
    address public immutable oracle;

    // ── Storage ─────────────────────────────────────────────────────────
    mapping(bytes32 classId => Envelope) public envelopes;
    mapping(bytes32 feedId => bytes32 classId) public feedClass;

    EnumerableSet.AddressSet private _providers;
    mapping(address creator => EnumerableSet.AddressSet) private _providersByCreator;
    mapping(address provider => address) public providerOwner;
    mapping(address provider => mapping(address updater => bool)) public isUpdater;

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(address _admin, address _oracle) {
        require(_oracle != address(0));
        oracle = _oracle;

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

    // ── Envelope administration (admin/multisig) ──────────────────────

    function setEnvelope(bytes32 classId, Envelope calldata envelope) external override onlyRole(ADMIN_ROLE) {
        // Reject empty class and inverted ranges, AND any envelope whose corners fall outside the
        // provider's hard bounds — so every point inside an accepted envelope is constructor-valid
        // and create() can only fail with ParamsOutOfEnvelope, never a confusing provider revert.
        // Constructor checks are monotone over the box: zero/min checks bind at the low corner, the
        // band-width check binds at the high corner (maxSpreadMax, minMarginMax).
        if (
            classId == bytes32(0)
            || envelope.minMarginMin == 0
            || envelope.minMarginMin > envelope.minMarginMax
            || envelope.stalenessMin == 0
            || envelope.stalenessMax > MAX_STALENESS
            || envelope.stalenessMin > envelope.stalenessMax
            || envelope.maxSpreadMin == 0
            || envelope.maxSpreadMax >= ORACLE_BPS
            || envelope.maxSpreadMin > envelope.maxSpreadMax
            || uint256(envelope.maxSpreadMax) * ONE_BPS_E18 + envelope.minMarginMax >= BPS_BASE_U
        ) revert BadEnvelope();

        envelopes[classId] = envelope;
        envelopes[classId].exists = true;

        emit EnvelopeSet(
            classId,
            envelope.minMarginMin,
            envelope.minMarginMax,
            envelope.stalenessMin,
            envelope.stalenessMax,
            envelope.maxSpreadMin,
            envelope.maxSpreadMax
        );
    }

    function removeEnvelope(bytes32 classId) external override onlyRole(ADMIN_ROLE) {
        if (!envelopes[classId].exists) revert EnvelopeNotFound(classId);
        delete envelopes[classId];
        emit EnvelopeRemoved(classId);
    }

    /// @notice Assign a feed to a pair class (zero classId unassigns the feed).
    function setFeedClass(bytes32 feedId, bytes32 classId) external override onlyRole(ADMIN_ROLE) {
        if (classId != bytes32(0) && !envelopes[classId].exists) revert EnvelopeNotFound(classId);
        feedClass[feedId] = classId;
        emit FeedClassSet(feedId, classId);
    }

    // ── Deploy (permissionless, envelope-bound) ───────────────────────

    /// @param mutableParams false → fully immutable variant (source swap only); true → the curator
    ///        may tune marginStep / confidenceParam / local Chainlink references through this factory.
    ///        The band params are envelope-validated and immutable either way (the knobs only shape
    ///        the quote inside the band), so mutability is a free curator choice.
    /// @param quoteFeedId optional second feed for synthetic ratio quoting (zero = single-feed). The
    ///        envelope is keyed on `baseFeedId` (the provider's class); the ref feed only contributes its
    ///        uncertainty and is validated for existence at provider construction.
    function createAnchoredProvider(
        bytes32 baseFeedId,
        bytes32 quoteFeedId,
        uint256 minMargin,
        uint256 maxRefStaleness,
        uint16  maxSpreadBps,
        bool    mutableParams,
        address baseTokenOverride,
        address quoteTokenOverride
    ) external override returns (address provider) {
        bytes32 classId = feedClass[baseFeedId];
        if (classId == bytes32(0)) revert FeedClassNotAssigned(baseFeedId);

        Envelope storage env = envelopes[classId];
        if (!env.exists) revert EnvelopeNotFound(classId);
        if (
            minMargin < env.minMarginMin || minMargin > env.minMarginMax
            || maxRefStaleness < env.stalenessMin || maxRefStaleness > env.stalenessMax
            || maxSpreadBps < env.maxSpreadMin || maxSpreadBps > env.maxSpreadMax
        ) revert ParamsOutOfEnvelope();

        AnchoredPriceProvider p = new AnchoredPriceProvider(
            address(this),
            oracle,
            baseFeedId,
            quoteFeedId,
            minMargin,
            maxRefStaleness,
            maxSpreadBps,
            mutableParams,
            baseTokenOverride,
            quoteTokenOverride
        );

        provider = address(p);
        address creator = msg.sender;

        _providers.add(provider);
        _providersByCreator[creator].add(provider);
        providerOwner[provider] = creator;

        emit ProviderDeployed(
            provider,
            creator,
            baseFeedId,
            quoteFeedId,
            classId,
            p.baseToken(),
            p.quoteToken(),
            minMargin,
            maxRefStaleness,
            maxSpreadBps,
            mutableParams
        );
    }

    // ── Curator controls ──────────────────────────────────────────────

    /// @notice Swap a provider's source (zero → reference mode). The curator's only knob — instant,
    ///         no timelock: any source is clamp-bounded by the provider at all times.
    function setSource(address provider, address newSource) external override onlyProviderOwner(provider) {
        require(_providers.contains(provider), ProviderNotTracked());
        AnchoredPriceProvider(provider).setSource(newSource);
        emit SourceSet(provider, newSource);
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

    // ── Updater management ────────────────────────────────────────────
    // Updaters may tune the quote-shaping knobs of customizable providers (batch setters below)
    // but can NOT swap sources — setSource stays owner-only.

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

    // ── Batch knob setters (customizable providers; owner or updater) ──
    // Atomic: an immutable provider anywhere in the batch reverts the whole call with
    // ImmutableProvider (as does any out-of-bounds value or an active confidence cooldown).

    function setConfidence(
        address[] calldata providers,
        uint256[] calldata values
    ) external override {
        uint256 l = providers.length;
        if (l != values.length) revert LengthMismatch();

        for (uint256 i; i < l; ++i) {
            require(_providers.contains(providers[i]), ProviderNotTracked());
            _requireUpdater(providers[i]);
            AnchoredPriceProvider(providers[i]).setConfidenceParam(values[i]);
        }
    }

    /// @dev DEBUG ONLY — will be removed before production deployment
    function setMarginStep(
        address[] calldata providers,
        int256[]  calldata steps
    ) external override {
        uint256 l = providers.length;
        if (l != steps.length) revert LengthMismatch();

        for (uint256 i; i < l; ++i) {
            require(_providers.contains(providers[i]), ProviderNotTracked());
            _requireUpdater(providers[i]);
            AnchoredPriceProvider(providers[i]).setMarginStep(steps[i]);
        }
    }

    // ── Views ───────────────────────────────────────────────────────────

    /// @notice The public-pool eligibility predicate: deployed by this factory ⇒ clamp-bounded quotes
    ///         with parameters that were inside the envelope at deploy time.
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
    ) external view returns (address[] memory providers, uint256 total) {
        return _paginate(_providersByCreator[creator], offset, limit);
    }

    /// @notice Paginated list of ALL providers.
    function getAllProviders(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory providers, uint256 total) {
        return _paginate(_providers, offset, limit);
    }

    function _paginate(
        EnumerableSet.AddressSet storage set,
        uint256 offset,
        uint256 limit
    ) private view returns (address[] memory providers, uint256 total) {
        total = set.length();

        if (offset >= total) {
            return (new address[](0), total);
        }

        uint256 remaining = total - offset;
        uint256 count = limit < remaining ? limit : remaining;

        providers = new address[](count);
        for (uint256 i; i < count; ++i) {
            providers[i] = set.at(offset + i);
        }
    }
}
