// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IPriceProviderFactory {
    // ── Events ──────────────────────────────────────────────────────────
    event ProviderDeployed(
        address indexed provider,
        address indexed creator,
        bytes32 indexed feedId,
        address         oracle,
        address         base,
        address         quote,
        int256          cexStep,
        uint256         maxTimeDelta,
        uint16          maxClDeviation
    );

    event ProviderAdded(address indexed provider);
    event ProviderRemoved(address indexed provider);
    event UpdaterGranted(address indexed provider, address indexed updater);
    event UpdaterRevoked(address indexed provider, address indexed updater);
    event ProviderOwnershipTransferred(address indexed provider, address indexed previousOwner, address indexed newOwner);

    // ── Errors ──────────────────────────────────────────────────────────
    error LengthMismatch();
    error ProviderAlreadyTracked();
    error ProviderNotTracked();
    error NotProviderOwner();
    error NotProviderUpdater();

    // ── Functions ───────────────────────────────────────────────────────
    function createPriceProvider(
        address _oracle,
        bytes32 _feedId,
        int256  _cexStep,
        uint256 _maxTimeDelta,
        uint16  _maxClDeviation,
        address _baseTokenOverride,
        address _quoteTokenOverride
    ) external returns (address provider);

    function grantUpdater(address provider, address updater) external;
    function revokeUpdater(address provider, address updater) external;
    function transferProviderOwnership(address provider, address newOwner) external;

    function addProvider(address provider) external;
    function removeProvider(address provider) external;

    function setConfidence(
        address[] calldata providers,
        uint256[] calldata values
    ) external;

    function setMaxClDeviation(
        address[] calldata providers,
        uint16[]  calldata deviations
    ) external;

    /// @dev DEBUG ONLY — will be removed before production deployment
    function setCexStep(
        address[] calldata providers,
        int256[]  calldata steps
    ) external;

    function setClOracle(
        address[] calldata providers,
        address[] calldata tokens,
        address[] calldata oracles,
        uint32[]  calldata heartbeats
    ) external;

    function removeClOracle(
        address[] calldata providers,
        address[] calldata tokens
    ) external;
}
