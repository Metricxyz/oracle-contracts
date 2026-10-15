// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice ERC-8056 (Scaled UI Amount) core read: shares per whole token (10**decimals raw units), WAD.
interface IScaledUIAmount {
    function uiMultiplier() external view returns (uint256);
}

/// @notice ERC-8056 scheduled change: the multiplier `uiMultiplier()` switches to at `effectiveAt`
///         (a unix timestamp). Robinhood Stock Tokens publish their reinvestments this way, less than a
///         day ahead, and B20 Assets expose the same getters (their issuer schedules the change
///         with the setter `updateUIMultiplier`). Either way the current multiplier switches by
///         itself at `effectiveAt`.
interface IScaledUIAmountSchedule {
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
}

/// @notice Issuer-set flag some ERC-8056 tokens expose (Robinhood Stock Tokens): true while a corporate
///         action is being processed and the token's price should not be trusted.
interface IOraclePausable {
    function oraclePaused() external view returns (bool);
}
