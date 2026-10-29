// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

type TimeMs is uint56;

error TimeMsOverflow(uint256 value);
error FutureTimestamp();
error ZeroTimestamp();

using {isAfter, revertIfAfterBlockTimeWithDrift, toSeconds, isZero, revertIfZero} for TimeMs global;

function toTimeMs(uint256 value) pure returns (TimeMs) {
    if (value > type(uint56).max) {
        revert TimeMsOverflow(value);
    }
    // forge-lint: disable-next-line(unsafe-typecast)
    return TimeMs.wrap(uint56(value));
}

function toSeconds(TimeMs t) pure returns (uint56) {
    return TimeMs.unwrap(t) / 1000;
}

function isAfter(TimeMs t0, TimeMs t1) pure returns (bool) {
    return TimeMs.unwrap(t0) > TimeMs.unwrap(t1);
}

function revertIfAfterBlockTimeWithDrift(TimeMs t0, uint256 drift) view {
    require(t0.toSeconds() <= block.timestamp + drift, FutureTimestamp());
}

function isZero(TimeMs t) pure returns (bool) {
    return TimeMs.unwrap(t) == 0;
}

function revertIfZero(TimeMs t) pure {
    require(!t.isZero(), ZeroTimestamp());
}