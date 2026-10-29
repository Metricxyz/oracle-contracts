// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title U64 <-> U32 (27/5) pseudo-float codec
/// @notice Format: [eeeee][mantissa(27b)], decode as v' = m << e
/// @dev maximum input value is (2^MANT_BITS) << EXP_MASK - 1 = 2^27 << 31 = 288230374004228096
///      is less than uint64, but it have more precision and more than enoght to store 8 decimal price
library U64x32 {
    uint256 constant MANT_BITS = 27;
    uint256 constant EXP_BITS = 5;
    uint256 constant MANT_MASK = (uint256(1) << MANT_BITS) - 1;
    uint256 constant EXP_MAX = (uint256(1) << EXP_BITS) - 1; // 31

    function decode(uint32 packed) internal pure returns (uint64 v) {
        uint64 m = uint64(uint32(packed) & uint32(MANT_MASK));
        uint64 e = uint64(uint32(packed) >> uint32(MANT_BITS));
        unchecked {
            v = uint64(uint256(m) << e);
        }
    }

    function decodeTo256(uint32 packed) internal pure returns (uint256 v) {
        uint256 m = uint256(uint32(packed) & uint32(MANT_MASK));
        uint256 e = uint256(uint32(packed) >> uint32(MANT_BITS));
        unchecked {
            v = m << e;
        }
    }
}
