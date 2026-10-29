// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IAnchoredProviderFactory {
    // ── Types ───────────────────────────────────────────────────────────

    /// @notice Pair-class parameter envelope (multisig-tuned). Providers can only be created with
    ///         clamp parameters inside the envelope of the class their feed is assigned to.
    struct Envelope {
        uint256 minMarginMin;     // BPS_BASE_U scale (1 bps = 1e14)
        uint256 minMarginMax;
        uint256 stalenessMin; // seconds
        uint256 stalenessMax;
        uint16  maxSpreadMin;      // bps
        uint16  maxSpreadMax;
        bool    exists;
    }

    // ── Events ──────────────────────────────────────────────────────────
    event ProviderDeployed(
        address indexed provider,
        address indexed creator,
        bytes32 indexed baseFeedId,
        bytes32         quoteFeedId,
        bytes32         classId,
        address         base,
        address         quote,
        uint256         minMargin,
        uint256         maxRefStaleness,
        uint16          maxSpreadBps,
        bool            mutableParams,
        int256          marginStep,
        address         oracle
    );

    event EnvelopeSet(
        bytes32 indexed classId,
        uint256 minMarginMin,
        uint256 minMarginMax,
        uint256 stalenessMin,
        uint256 stalenessMax,
        uint16  maxSpreadMin,
        uint16  maxSpreadMax
    );
    event EnvelopeRemoved(bytes32 indexed classId);
    event FeedClassSet(bytes32 indexed feedId, bytes32 indexed classId);

    event SourceSet(address indexed provider, address indexed source);
    event ProviderOwnershipTransferred(address indexed provider, address indexed previousOwner, address indexed newOwner);
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
        uint16  maxSpreadBps,
        bool    mutableParams,
        int256  marginStep,
        address baseToken,
        address quoteToken
    ) external returns (address provider);

    // ── Curator controls ────────────────────────────────────────────────
    function setSource(address provider, address newSource) external;
    function transferProviderOwnership(address provider, address newOwner) external;
    function grantUpdater(address provider, address updater) external;
    function revokeUpdater(address provider, address updater) external;

    // ── Batch knob setters (customizable providers; owner or updater) ──
    function setConfidence(address[] calldata providers, uint256[] calldata values) external;
}
