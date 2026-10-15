// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracleParams} from "../../interfaces/IOracleParams.sol";
import {ScheduledMultiplier} from "./ScheduledMultiplier.sol";

/// @notice Oracle params for B20 Asset tokens (Base's native RWA standard) whose issuer runs an
///         OracleRegistry — Coinbase's tokenized stocks, with the registry at
///         0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD. The registry answers both values in one call: the
///         multiplier, read live from the token's own `multiplier()`, and the issuer's corporate-action
///         pause flag. This adapter binds that registry to B20 Assets only: any other address reverts,
///         which MultiplierOracle turns into a stall. Stateless and ownerless; one deployment per
///         registry serves every token of that issuer.
///
///         A B20 Asset can also announce a multiplier change
///         (`updateUIMultiplier`: `newUIMultiplier()`, `effectiveAt()`), and `multiplier()` flips on read
///         at `effectiveAt` with no transaction; the registry passes that flip straight through. A pending
///         change is handled by ScheduledMultiplier exactly as for Robinhood, read from the token itself.
///         The registry has no override: its only admin setter is the pause flag, and its multiplier is the
///         token's `multiplier()`. The schedule therefore applies to the same value the registry answers.
contract B20AssetParams is IOracleParams {
    string public constant version = "1.2.0";

    /// @notice See ScheduledMultiplier.SMALL_CHANGE_BPS.
    uint256 public constant SMALL_CHANGE_BPS = ScheduledMultiplier.SMALL_CHANGE_BPS;

    /// @dev B20 address layout: [10-byte B20 prefix][1-byte variant][9-byte hash]. The top 11 bytes of
    ///      every ASSET token (variant 0x00) are 0xb2 followed by ten zero bytes.
    uint256 internal constant B20_ASSET_PREFIX = 0xb200000000000000000000;

    /// @notice The issuer's OracleRegistry.
    IOracleParams public immutable REGISTRY;

    error ZeroAddress();
    error NotB20Asset(address token);

    constructor(IOracleParams registry) {
        require(address(registry) != address(0), ZeroAddress());
        REGISTRY = registry;
    }

    function getOracleParams(address token) external view returns (uint256 multiplier, bool paused) {
        require(uint160(token) >> 72 == B20_ASSET_PREFIX, NotB20Asset(token));
        (multiplier, paused) = REGISTRY.getOracleParams(token);
        return ScheduledMultiplier.applyPending(token, multiplier, paused);
    }
}
