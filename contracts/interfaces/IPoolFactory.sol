// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal view surface of an AMM pool factory, used by the oracle abuse-protection layer to
///         validate a pool at registration time (`register`).
interface IPoolFactory {
    /// @return true if `pool` is a pool deployed/tracked by this factory.
    function isPool(address pool) external view returns (bool);
}

/// @notice Minimal view surface of an AMM pool. The pool marks itself in-swap with its price provider
///         (transiently) immediately before reading; the oracle queries this to bind the read to the
///         calling provider (`pool.inSwap() == msg.sender`).
interface IPool {
    /// @return priceProvider the price provider the pool is currently reading through (0 outside a swap).
    function inSwap() external view returns (address priceProvider);
}
