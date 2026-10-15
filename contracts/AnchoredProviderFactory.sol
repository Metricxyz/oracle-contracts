// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AnchoredPriceProvider} from "./AnchoredPriceProvider.sol";
import {IAnchoredProviderFactory} from "./interfaces/IAnchoredProviderFactory.sol";

/// @notice Anchor Factory: deploys AnchoredPriceProviders against an ADMIN-curated allow-list of
///         reference oracles, with clamp parameters validated against multisig-tuned pair-class
///         envelopes. createAnchoredProvider names which allow-listed oracle to anchor to; provenance is
///         then the machine-checkable predicate `recognizedFactory.isProvider(p)`. It proves the provider
///         came from this factory within its envelope — not that its feeds have data, that its pair
///         matches them, or that a pool may read them.
///         The allow-list starts EMPTY at construction and is populated/curated via addOracle /
///         removeOracle (admin) — removal only blocks NEW providers; already-deployed providers keep
///         their immutable oracle and stay isProvider()==true.
contract AnchoredProviderFactory is AccessControl, Multicall, IAnchoredProviderFactory {
    using EnumerableSet for EnumerableSet.AddressSet;

    string public constant version = "1.1.0";

    // ── Roles ───────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Fallback envelope class for feeds with no explicit class (feedClass == 0). Admins
    ///         configure it via setEnvelope(DEFAULT_CLASS, ...); until then, unassigned feeds revert
    ///         EnvelopeNotFound(DEFAULT_CLASS) at create — the envelope bound is never bypassed.
    bytes32 public constant DEFAULT_CLASS = keccak256("AnchoredProviderFactory.DEFAULT_CLASS");

    // ── AnchoredPriceProvider hard bounds (mirrored for envelope validation) ──
    // Must match the constructor checks in AnchoredPriceProvider; an envelope outside these would
    // advertise parameter ranges that always revert at create() with a provider-level error.
    uint256 internal constant BPS_BASE_U = 1e18;
    uint256 internal constant MAX_STALENESS = 7 days;

    // ── Storage ─────────────────────────────────────────────────────────
    /// @notice Admin-curated allow-list of reference oracles a provider may be anchored to.
    EnumerableSet.AddressSet private _oracles;

    mapping(bytes32 classId => Envelope) public envelopes;
    mapping(bytes32 feedId => bytes32 classId) public feedClass;

    EnumerableSet.AddressSet private _providers;
    mapping(address creator => EnumerableSet.AddressSet) private _providersByCreator;
    mapping(address provider => address) public providerOwner;
    mapping(address provider => mapping(address updater => bool)) public isUpdater;

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(address _admin) {
        // No oracle is seeded here — the allow-list starts empty and is populated via addOracle (admin).
        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
    }

    // ── Modifiers ─────────────────────────────────────────────────────
    modifier onlyProviderOwner(address provider) {
        if (msg.sender != providerOwner[provider]) revert NotProviderOwner();
        _;
    }

    function _requireUpdater(address provider) internal view {
        if (msg.sender != providerOwner[provider] && !isUpdater[provider][msg.sender]) {
            revert NotProviderUpdater();
        }
    }

    // ── Oracle allow-list (admin) ─────────────────────────────────────
    // The reference oracles createAnchoredProvider may anchor to. Removing one only blocks NEW
    // providers; existing providers keep their immutable oracle and stay isProvider()==true.

    function addOracle(address oracle) external override onlyRole(ADMIN_ROLE) {
        require(oracle != address(0), ZeroOracle());
        require(_oracles.add(oracle), OracleAlreadyAllowed(oracle));
        emit OracleAdded(oracle);
    }

    function removeOracle(address oracle) external override onlyRole(ADMIN_ROLE) {
        require(_oracles.remove(oracle), OracleNotFound(oracle));
        emit OracleRemoved(oracle);
    }

    function isOracle(address oracle) external view override returns (bool) {
        return _oracles.contains(oracle);
    }

    function oracleCount() external view override returns (uint256) {
        return _oracles.length();
    }

    function getOracles(uint256 start, uint256 end) external view override returns (address[] memory) {
        return _oracles.values(start, end);
    }

    // ── Envelope administration (admin/multisig) ──────────────────────

    function setEnvelope(bytes32 classId, Envelope calldata envelope) external override onlyRole(ADMIN_ROLE) {
        // Reject empty class and inverted ranges, AND any corner that the provider constructor would
        // reject — so every in-envelope value of the three bounded parameters is constructor-valid and,
        // for those, create() fails with ParamsOutOfEnvelope rather than a provider revert. marginStep,
        // the token pair and the initial config are not envelope-bound and can still revert there.
        //
        // There is no band-width corner: the provider has no construction-time band bound to
        // mirror. Saturated feeds and an upper interval deviation plus margin reaching 100%
        // fail closed at read time instead.
        if (
            classId == bytes32(0) || envelope.minMarginMin == 0 // the provider rejects minMargin 0
                || envelope.minMarginMin > envelope.minMarginMax || envelope.stalenessMax > MAX_STALENESS
                || envelope.stalenessMin > envelope.stalenessMax || envelope.spreadMultMax < BPS_BASE_U // must admit 1.0×
        ) revert BadEnvelope();

        envelopes[classId] = envelope;
        envelopes[classId].exists = true;

        emit EnvelopeSet(
            classId,
            envelope.minMarginMin,
            envelope.minMarginMax,
            envelope.stalenessMin,
            envelope.stalenessMax,
            envelope.spreadMultMax
        );
    }

    /// @notice Deletes the envelope of `classId`. Feeds still assigned to `classId` keep that
    ///         assignment and do not fall back to DEFAULT_CLASS: createAnchoredProvider for them
    ///         reverts EnvelopeNotFound(classId) until setFeedClass reassigns them (a zero classId
    ///         there selects DEFAULT_CLASS). Already-deployed providers do not read envelopes and
    ///         are unaffected.
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

    /// @notice Deploys an AnchoredPriceProvider owned by the caller, after checking the oracle against
    ///         the allow-list and minMargin / maxRefStaleness / maxSpreadMult against the envelope of
    ///         baseFeedId's class (DEFAULT_CLASS when the feed has none).
    /// @param oracle the reference oracle to anchor to; must be in the allow-list (addOracle), else
    ///        reverts OracleNotAllowed. baseFeedId is NOT validated against the oracle at creation
    ///        (the constructor never reads it): a feed with no data halts provider reads until its
    ///        first update lands — feed classes/envelopes are keyed on feedId independently of the
    ///        oracle.
    /// @param baseFeedId the anchor feed (the synthetic numerator when quoteFeedId is set); its class
    ///        selects the envelope.
    /// @param mutableParams false → immutable variant: only the source can be swapped. true → the owner
    ///        or an updater may also tune, through this factory and behind 60-second cooldowns,
    ///        confidenceParam, the per-leg staleness limits (each <= maxRefStaleness) and the per-leg
    ///        spread multipliers (each <= maxSpreadMult, and possibly below 1×, which tightens the band
    ///        itself). Fixed either way: the oracle and feeds, the envelope-validated minMargin (the
    ///        band's per-side margin floor) and ceilings maxRefStaleness and maxSpreadMult, and
    ///        marginStep. The clamp keeps the final quote no tighter than the band as currently
    ///        configured, so on a mutable provider the band can move inward: mutability is a pricing
    ///        choice, not a free one.
    /// @param marginStep fixed shaping bias for the customizable variant, applied to the step factors at
    ///        construction. NOT envelope-bound: regardless of its sign, the provider's load-bearing band
    ///        clamp keeps the final quote no tighter than the reference band, so it cannot breach the
    ///        envelope guarantee. (Construction still reverts if |marginStep| >= BPS_BASE.)
    /// @param quoteFeedId optional second feed for synthetic ratio quoting (zero = single-feed). The
    ///        envelope is keyed on `baseFeedId` (the provider's class); the quote feed contributes its mid,
    ///        as the ratio's denominator, and its uncertainty, and is not validated for existence at
    ///        construction (reads halt until it has data).
    /// @param minMargin per-side margin added to the reference band (BPS_BASE_U scale, 1 bps = 1e14):
    ///        the band's half-width floor; must lie within [minMarginMin, minMarginMax].
    /// @param maxRefStaleness cap (seconds) on the per-leg staleness bounds; must lie within
    ///        [stalenessMin, stalenessMax].
    /// @param maxSpreadMult ceiling for the per-leg spread multipliers (BPS_BASE_U scale); must lie within
    ///        [1e18, spreadMultMax].
    /// @param baseToken the provider's token0; nonzero and distinct from quoteToken (checked by the
    ///        provider constructor).
    /// @param quoteToken the provider's token1.
    /// @param init initial source, per-leg staleness bounds and per-leg multipliers, validated by the
    ///        provider constructor against maxRefStaleness and maxSpreadMult (upper bounds only: each
    ///        multiplier may be anywhere in [0, maxSpreadMult]).
    /// @return provider the deployed provider's address.
    function createAnchoredProvider(
        address oracle,
        bytes32 baseFeedId,
        bytes32 quoteFeedId,
        uint256 minMargin,
        uint256 maxRefStaleness,
        uint256 maxSpreadMult,
        bool mutableParams,
        int256 marginStep,
        address baseToken,
        address quoteToken,
        InitialConfig calldata init
    ) external override returns (address provider) {
        if (!_oracles.contains(oracle)) revert OracleNotAllowed(oracle);

        // Feeds without an explicit class fall back to the admin-configured DEFAULT_CLASS envelope.
        bytes32 classId = feedClass[baseFeedId];
        if (classId == bytes32(0)) classId = DEFAULT_CLASS;

        Envelope storage env = envelopes[classId];
        if (!env.exists) revert EnvelopeNotFound(classId);
        if (
            minMargin < env.minMarginMin || minMargin > env.minMarginMax || maxRefStaleness < env.stalenessMin
                || maxRefStaleness > env.stalenessMax
                // The multiplier ceiling: at least 1.0× (so a 1.0× multiplier is valid), at most the envelope's.
                || maxSpreadMult < BPS_BASE_U || maxSpreadMult > env.spreadMultMax
        ) revert ParamsOutOfEnvelope();

        AnchoredPriceProvider p = new AnchoredPriceProvider(
            address(this),
            oracle,
            baseFeedId,
            quoteFeedId,
            minMargin,
            maxRefStaleness,
            maxSpreadMult,
            mutableParams,
            marginStep,
            baseToken,
            quoteToken,
            init
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
            maxSpreadMult,
            mutableParams,
            marginStep,
            oracle
        );
    }

    // ── Curator controls ──────────────────────────────────────────────

    /// @notice Swap a provider's source (zero → reference mode). The only knob on an immutable provider — instant,
    ///         no timelock. The clamp bounds a source INWARD only (never tighter than the live band);
    ///         nothing bounds how far outward it may quote, so this is not a bounded action — vetting
    ///         the source is the operator's due diligence. See IAnchorSource.
    function setSource(address provider, address newSource) external override onlyProviderOwner(provider) {
        require(_providers.contains(provider), ProviderNotTracked());
        AnchoredPriceProvider(provider).setSource(newSource);
        emit SourceSet(provider, newSource);
    }

    function transferProviderOwnership(address provider, address newOwner)
        external
        override
        onlyProviderOwner(provider)
    {
        require(_providers.contains(provider), ProviderNotTracked());
        require(newOwner != address(0));
        address previousOwner = providerOwner[provider];

        providerOwner[provider] = newOwner;
        _providersByCreator[previousOwner].remove(provider);
        _providersByCreator[newOwner].add(provider);

        emit ProviderOwnershipTransferred(provider, previousOwner, newOwner);
    }

    // ── Updater management ────────────────────────────────────────────
    // Updaters may tune the knobs of customizable providers (confidence, spread multipliers and
    // staleness bounds, via the batch setters below) but can NOT swap sources — setSource stays
    // owner-only.

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
    // Atomic: any failing entry reverts the whole call. Each setter reverts with
    // - LengthMismatch when the array lengths differ;
    // - ProviderNotTracked for a provider this factory did not deploy;
    // - NotProviderUpdater when the caller is neither the provider's owner nor its updater;
    // and bubbles up the provider's own errors: ImmutableProvider (immutable variant),
    // CooldownNotElapsed (that knob was set less than CONFIDENCE_COOLDOWN ago), and the knob's
    // bound error — ConfidenceParamOutOfBounds (setConfidence), SpreadMultOutOfBounds
    // (setSpreadMultipliers), StalenessOutOfBounds (setMaxStaleness). The provider's OnlyFactory
    // check always passes, since this factory is the caller.

    function setConfidence(address[] calldata providers, uint256[] calldata values) external override {
        uint256 l = providers.length;
        if (l != values.length) revert LengthMismatch();

        for (uint256 i; i < l; ++i) {
            require(_providers.contains(providers[i]), ProviderNotTracked());
            _requireUpdater(providers[i]);
            AnchoredPriceProvider(providers[i]).setConfidenceParam(values[i]);
        }
    }

    function setSpreadMultipliers(
        address[] calldata providers,
        uint256[] calldata baseMults,
        uint256[] calldata quoteMults
    ) external override {
        uint256 l = providers.length;
        if (l != baseMults.length || l != quoteMults.length) revert LengthMismatch();

        for (uint256 i; i < l; ++i) {
            require(_providers.contains(providers[i]), ProviderNotTracked());
            _requireUpdater(providers[i]);
            AnchoredPriceProvider(providers[i]).setSpreadMultipliers(baseMults[i], quoteMults[i]);
        }
    }

    function setMaxStaleness(
        address[] calldata providers,
        uint256[] calldata baseStaleness,
        uint256[] calldata quoteStaleness
    ) external override {
        uint256 l = providers.length;
        if (l != baseStaleness.length || l != quoteStaleness.length) revert LengthMismatch();

        for (uint256 i; i < l; ++i) {
            require(_providers.contains(providers[i]), ProviderNotTracked());
            _requireUpdater(providers[i]);
            AnchoredPriceProvider(providers[i]).setMaxStaleness(baseStaleness[i], quoteStaleness[i]);
        }
    }

    // ── Views ───────────────────────────────────────────────────────────

    /// @notice Provenance predicate: this provider was deployed by this factory with minMargin,
    ///         maxRefStaleness and maxSpreadMult inside their class envelope AT DEPLOY TIME. It is
    ///         narrower than "safe to list": the envelope bounds only those 3 of the constructor's
    ///         inputs. The per-leg spread multipliers have no lower bound: InitialConfig may set them
    ///         anywhere in [0, maxSpreadMult], so even an immutable provider can be created with a
    ///         sub-1× (down to 0×) multiplier, and on a mutable provider the owner or an updater can
    ///         set them there later. Such a multiplier narrows the band below the oracle's own
    ///         uncertainty, down to minMargin alone. The source-mode clamp bounds only tightness — a
    ///         source can quote arbitrarily far outward and is the operator's to vet. Treat a `true`
    ///         here as "worth diligence", not as a completed audit.
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

    /// @notice Paginated provider list filtered by current owner (the creator until ownership is
    ///         transferred; the argument keeps its ABI name).
    function getProviders(address creator, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory providers, uint256 total)
    {
        return _paginate(_providersByCreator[creator], offset, limit);
    }

    /// @notice Paginated list of ALL providers.
    function getAllProviders(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory providers, uint256 total)
    {
        return _paginate(_providers, offset, limit);
    }

    function _paginate(EnumerableSet.AddressSet storage set, uint256 offset, uint256 limit)
        private
        view
        returns (address[] memory providers, uint256 total)
    {
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
