// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IReadableProvider {
    function getBidAndAskPrice() external returns (uint128 bid, uint128 ask);
}

/// @notice Minimal pool that mirrors the real swap-time entry point: it marks ITSELF in-swap with its
///         price provider (transiently), then reads through the provider with no args. The oracle binds
///         the read by querying `pool.inSwap()`. Exercises the full pool → provider → oracle flow.
contract MockPool {
    address public immutable priceProvider;
    address transient private _inSwapPriceProvider;

    constructor(address _priceProvider) {
        priceProvider = _priceProvider;
    }

    /// @notice Queried by the oracle to bind the read to the calling provider (0 outside a swap).
    function inSwap() external view returns (address) {
        return _inSwapPriceProvider;
    }

    /// @notice Forwarded entry point: mark self in-swap with the provider, then read (no args).
    function getBidAndAskPrice() external returns (uint128 bid, uint128 ask) {
        _inSwapPriceProvider = priceProvider;
        return IReadableProvider(priceProvider).getBidAndAskPrice();
    }
}
