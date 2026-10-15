// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracleParams} from "../../interfaces/IOracleParams.sol";
import {IOraclePausable, IScaledUIAmount} from "../../interfaces/IScaledUIAmount.sol";
import {ScheduledMultiplier} from "./ScheduledMultiplier.sol";

/// @notice Oracle params for Robinhood Stock Tokens (Robinhood Chain), which report both values on the
///         token itself: the ERC-8056 multiplier (`uiMultiplier()`) and the issuer's corporate-action
///         pause flag (`oraclePaused()`). A token missing either getter makes the read revert, which
///         MultiplierOracle turns into a stall. Stateless and ownerless; one deployment per chain serves
///         every such token.
///
///         A change announced through `newUIMultiplier()` / `effectiveAt()` switches `uiMultiplier()` by
///         itself at `effectiveAt` with the pause flag clear; a pending change is handled by
///         ScheduledMultiplier.
contract RobinhoodStockTokenParams is IOracleParams {
    string public constant version = "1.2.0";

    /// @notice See ScheduledMultiplier.SMALL_CHANGE_BPS.
    uint256 public constant SMALL_CHANGE_BPS = ScheduledMultiplier.SMALL_CHANGE_BPS;

    function getOracleParams(address token) external view returns (uint256 multiplier, bool paused) {
        return ScheduledMultiplier.applyPending(
            token, IScaledUIAmount(token).uiMultiplier(), IOraclePausable(token).oraclePaused()
        );
    }
}
