// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title CodebookDull
/// @notice Utility for mapping values in [0, 10_000] to 8-bit indices and back.
library CodebookDull {
    uint16 internal constant MAX_VALUE = 10_000;
    uint8 internal constant MAX_INDEX = type(uint8).max; // 255
    bytes internal constant TABLE = hex"";

    function getTable() external view returns (uint16[256] memory t) {
        for (uint256 i; i < MAX_INDEX; i++) {
            t[i] = _valueAt(i);
        }
    }

    function decode(uint8 index) internal pure returns (uint16 value, bool ok) {
        uint256 entryCount = TABLE.length / 2;
        if (entryCount == 0 || index > MAX_INDEX || index >= entryCount) return (0, false);
        return (_valueAt(index), true);
    }

    function _valueAt(uint256 index) private pure returns (uint16) {
        unchecked {
            uint256 offset = index * 2;
            uint16 msb = uint16(uint8(TABLE[offset])) << 8;
            uint16 lsb = uint16(uint8(TABLE[offset + 1]));
            return msb | lsb;
        }
    }
}
