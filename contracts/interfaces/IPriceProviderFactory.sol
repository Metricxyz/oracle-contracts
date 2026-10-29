// SPDX-License-Identifier: MIT
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
        int256          marginStep,
        uint256         maxTimeDelta
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
        int256  _marginStep,
        uint256 _maxTimeDelta,
        address _baseToken,
        address _quoteToken
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

}
