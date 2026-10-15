// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IScaledUIAmountSchedule} from "../../interfaces/IScaledUIAmount.sol";

/// @notice The scheduled-change rule shared by the params adapters of ERC-8056 token families.
///
///         Robinhood Stock Tokens and B20 Assets can announce a multiplier
///         change ahead of time (`newUIMultiplier()`, `effectiveAt()`). Their current multiplier then
///         switches by itself at `effectiveAt`, without a transaction and without the issuer's pause
///         flag. Read as is, the price would step at a publicly known instant. While a change is pending,
///         whatever its lead time, an adapter answers:
///         - a small change (at most SMALL_CHANGE_BPS of the current multiplier: a reinvested dividend)
///           with the announced multiplier at once, so there is no step at `effectiveAt` to time.
///           A change announced before the dividend's ex-date overprices the token by up to the change
///           until the ex-date;
///         - a larger change (a split) with `paused = true` until `effectiveAt`, however early it was
///           announced. From there on the issuer's flag is the guard, as for any corporate action,
///           including a market split that comes after `effectiveAt`.
///         A token without the schedule getters (a plain ERC-8056 token), or one whose getters do not
///         answer a single 32-byte word, gets the issuer's current answer unchanged.
library ScheduledMultiplier {
    /// @notice A pending change of at most this fraction of the current multiplier (in bps) is applied
    ///         at once; anything larger stalls until it takes effect. 10%: well above a single
    ///         reinvested dividend, well below the smallest common split (3:2).
    uint256 internal constant SMALL_CHANGE_BPS = 1_000;

    /// @dev Applies `token`'s pending change, if any, to the issuer's current answer.
    function applyPending(address token, uint256 current, bool paused)
        internal
        view
        returns (uint256 multiplier, bool paused_)
    {
        (bool pending, uint256 next) = _pendingChange(token, current);
        if (!pending) return (current, paused);
        if (_isSmall(current, next)) return (next, paused);
        return (current, true);
    }

    /// @dev Bounded static read of a no-argument uint256 getter. At most 32 bytes are copied, and
    ///      anything but a successful 32-byte answer (no code, a revert, a short or long answer) reads as
    ///      absent rather than reverting the caller.
    function readUint(address token, bytes4 selector) internal view returns (bool ok, uint256 value) {
        uint256 size;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            ok := staticcall(gas(), token, ptr, 0x04, ptr, 0x20)
            size := returndatasize()
            value := mload(ptr)
        }
        ok = ok && size == 32;
    }

    /// @dev The announced multiplier, when one differs from the current value and takes effect later.
    function _pendingChange(address token, uint256 current) private view returns (bool pending, uint256 next) {
        (bool okAt, uint256 at) = readUint(token, IScaledUIAmountSchedule.effectiveAt.selector);
        if (!okAt || at <= block.timestamp) return (false, 0);
        (bool okNext, uint256 announced) = readUint(token, IScaledUIAmountSchedule.newUIMultiplier.selector);
        if (!okNext || announced == 0 || announced == current) return (false, 0);
        return (true, announced);
    }

    /// @dev Overflow-free on token-controlled values: a huge announced multiplier is a large change.
    function _isSmall(uint256 current, uint256 next) private pure returns (bool) {
        uint256 delta = next > current ? next - current : current - next;
        return delta <= Math.mulDiv(current, SMALL_CHANGE_BPS, 10_000);
    }
}
