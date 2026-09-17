// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {U64x32} from "../../../contracts/oracles/utils/U64x32.sol";

contract U64x32Test is Test {
    uint256 constant MANT_BITS = 27;
    uint256 constant EXP_BITS = 5;
    uint256 constant MANT_MASK = (uint256(1) << MANT_BITS) - 1;
    uint256 constant EXP_MAX = (uint256(1) << EXP_BITS) - 1; // 31
    uint64 constant MAX_SAFE_U64 = 28823037400422809;

    function _encode(uint64 v) internal pure returns (uint32 out32) {
        if (v == 0) return 0;

        // msb index in [0..63]
        uint256 msb = __msb64(v);
        uint256 e = msb > (MANT_BITS - 1) ? (msb - (MANT_BITS - 1)) : 0;

        // add = 1<<(e-1) for round-to-nearest; zero when e==0
        uint256 add = e == 0 ? 0 : (uint256(1) << (e - 1));
        uint256 m = (uint256(v) + add) >> e;

        // If rounding produced m == 2^M, shift it and bump exponent
        if (m > MANT_MASK) {
            m >>= 1;
            unchecked {
                e += 1;
            }
        }

        // Saturate if exponent overflowed 5 bits
        if (e > EXP_MAX) {
            e = EXP_MAX;
            m = MANT_MASK;
        }

        out32 = uint32((e << MANT_BITS) | m);
    }

    /// @dev msb index of non-zero 64-bit value (0..63)
    function __msb64(uint64 x) private pure returns (uint256 n) {
        // Branchless-ish binary search on bit width
        uint64 y = x;
        if (y >= 0x1_0000_0000) {
            y >>= 32;
            n += 32;
        }
        if (y >= 0x1_0000) {
            y >>= 16;
            n += 16;
        }
        if (y >= 0x100) {
            y >>= 8;
            n += 8;
        }
        if (y >= 0x10) {
            y >>= 4;
            n += 4;
        }
        if (y >= 0x4) {
            y >>= 2;
            n += 2;
        }
        if (y >= 0x2) n += 1;
        // if y in {0,1}: n is correct (0 for 1, unreachable for 0 due to early check)
    }

    function testFuzzDecode(uint64 value) public pure {
        vm.assume(value <= MAX_SAFE_U64);
        uint32 encodedValue = _encode(value);
        assertApproxEqAbs(value, U64x32.decode(encodedValue), 1e9);
    }

    function testFuzzFailIfValueOverflow(uint64 value) public {
        vm.assume(value >= MAX_SAFE_U64 * 100);
        uint32 encodedValue = _encode(value);
        uint64 decodedValue = U64x32.decode(encodedValue);
        assertTrue(value / U64x32.decode(encodedValue) > 1);
        assertTrue(value / 1e18 * 1e18 != decodedValue / 1e18 * 1e18);
    }
}
