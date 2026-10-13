// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAnchoredProviderFactory {
    // ── Types ───────────────────────────────────────────────────────────

    /// @notice Pair-class parameter envelope (multisig-tuned). Providers can only be created with
    ///         clamp parameters inside the envelope of the class their feed is assigned to.
    /// @notice Initial provider config applied AT CONSTRUCTION through the same validation the
    ///         post-deploy setters use (source swap + per-leg staleness + per-leg multipliers), so a
    ///         provider can be born fully configured in one tx. For the immutable variant these become
    ///         the permanent values (no setters) except `source`, which the owner can replace on either
    ///         variant; for the customizable variant they are the starting
    ///         point. Bounds: each staleness <= maxRefStaleness, each multiplier <= maxSpreadMult.
    struct InitialConfig {
        address source; // custom quote source (0 = reference mode)
        uint256 baseMaxStaleness; // per-leg reference staleness (seconds)
        uint256 quoteMaxStaleness;
        uint256 baseSpreadMult; // per-leg spread multiplier (BPS_BASE_U scale, 1e18 = 1.0×)
        uint256 quoteSpreadMult;
    }

    /// @dev No configurable spread cap: APP rejects each raw spread >= 65534 at read time.
    ///      Invalid interval bounds and an upper relative deviation plus margin reaching 100%
    ///      also halt at read time; envelopes only constrain the configuration below.
    struct Envelope {
        uint256 minMarginMin; // BPS_BASE_U scale (1 bps = 1e14)
        uint256 minMarginMax;
        uint256 stalenessMin; // seconds
        uint256 stalenessMax;
        uint256 spreadMultMax; // BPS_BASE_U scale (1e18 = 1.0×); ceiling for maxSpreadMult, >= 1e18
        bool exists;
    }

    // ── Events ──────────────────────────────────────────────────────────
    event ProviderDeployed(
        address indexed provider,
        address indexed creator,
        bytes32 indexed baseFeedId,
        bytes32 quoteFeedId,
        bytes32 classId,
        address base,
        address quote,
        uint256 minMargin,
        uint256 maxRefStaleness,
        uint256 maxSpreadMult,
        bool mutableParams,
        int256 marginStep,
        address oracle
    );

    event EnvelopeSet(
        bytes32 indexed classId,
        uint256 minMarginMin,
        uint256 minMarginMax,
        uint256 stalenessMin,
        uint256 stalenessMax,
        uint256 spreadMultMax
    );
    event EnvelopeRemoved(bytes32 indexed classId);
    event FeedClassSet(bytes32 indexed feedId, bytes32 indexed classId);

    event SourceSet(address indexed provider, address indexed source);
    event ProviderOwnershipTransferred(
        address indexed provider, address indexed previousOwner, address indexed newOwner
    );
    event UpdaterGranted(address indexed provider, address indexed updater);
    event UpdaterRevoked(address indexed provider, address indexed updater);
    event OracleAdded(address indexed oracle);
    event OracleRemoved(address indexed oracle);

    // ── Errors ──────────────────────────────────────────────────────────
    error BadEnvelope();
    error EnvelopeNotFound(bytes32 classId);
    error ParamsOutOfEnvelope();
    error ProviderNotTracked();
    error NotProviderOwner();
    error NotProviderUpdater();
    error LengthMismatch();
    error ZeroOracle();
    error OracleNotAllowed(address oracle);
    error OracleAlreadyAllowed(address oracle);
    error OracleNotFound(address oracle);

    // ── Envelope administration ─────────────────────────────────────────
    function setEnvelope(bytes32 classId, Envelope calldata envelope) external;
    function removeEnvelope(bytes32 classId) external;
    function setFeedClass(bytes32 feedId, bytes32 classId) external;

    // ── Oracle allow-list (admin) ───────────────────────────────────────
    function addOracle(address oracle) external;
    function removeOracle(address oracle) external;
    function isOracle(address oracle) external view returns (bool);
    function oracleCount() external view returns (uint256);
    function getOracles(uint256 start, uint256 end) external view returns (address[] memory);

    // ── Deploy (permissionless, envelope-bound) ─────────────────────────
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
    ) external returns (address provider);

    // ── Curator controls ────────────────────────────────────────────────
    function setSource(address provider, address newSource) external;
    function transferProviderOwnership(address provider, address newOwner) external;
    function grantUpdater(address provider, address updater) external;
    function revokeUpdater(address provider, address updater) external;

    // ── Batch knob setters (customizable providers; owner or updater) ──
    function setConfidence(address[] calldata providers, uint256[] calldata values) external;
    /// @notice Set per-leg spread multipliers (BPS_BASE_U scale) on customizable providers.
    function setSpreadMultipliers(
        address[] calldata providers,
        uint256[] calldata baseMults,
        uint256[] calldata quoteMults
    ) external;
    /// @notice Set per-leg reference staleness bounds (seconds) on customizable providers.
    function setMaxStaleness(
        address[] calldata providers,
        uint256[] calldata baseStaleness,
        uint256[] calldata quoteStaleness
    ) external;
}
