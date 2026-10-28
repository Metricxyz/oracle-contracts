// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolFactory} from "../../contracts/interfaces/IPoolFactory.sol";

/// @notice Test double for IPoolFactory with a settable isPool map (used by the oracle's `register`).
contract MockPoolFactory is IPoolFactory {
    mapping(address => bool) internal _pools;

    function setPool(address pool, bool ok) external {
        _pools[pool] = ok;
    }

    function isPool(address pool) external view returns (bool) {
        return _pools[pool];
    }
}
