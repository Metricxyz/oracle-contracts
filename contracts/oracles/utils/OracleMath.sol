// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library OracleMath {
    uint256 internal constant Q96 = 1 << 96;
    uint8 internal constant MAX_DECIMALS_DIFF = 36;

    error Pow10ExponentTooLarge();

    function pow10(uint8 exp) internal pure returns (uint256) {
        if (exp > MAX_DECIMALS_DIFF) revert Pow10ExponentTooLarge();
        if (exp == 0) return 1;
        if (exp == 1) return 10;
        if (exp == 2) return 100;
        if (exp == 3) return 1_000;
        if (exp == 4) return 10_000;
        if (exp == 5) return 100_000;
        if (exp == 6) return 1_000_000;
        if (exp == 7) return 10_000_000;
        if (exp == 8) return 100_000_000;
        if (exp == 9) return 1_000_000_000;
        if (exp == 10) return 10_000_000_000;
        if (exp == 11) return 100_000_000_000;
        if (exp == 12) return 1_000_000_000_000;
        if (exp == 13) return 10_000_000_000_000;
        if (exp == 14) return 100_000_000_000_000;
        if (exp == 15) return 1_000_000_000_000_000;
        if (exp == 16) return 10_000_000_000_000_000;
        if (exp == 17) return 100_000_000_000_000_000;
        if (exp == 18) return 1_000_000_000_000_000_000;
        if (exp == 19) return 10_000_000_000_000_000_000;
        if (exp == 20) return 100_000_000_000_000_000_000;
        if (exp == 21) return 1_000_000_000_000_000_000_000;
        if (exp == 22) return 10_000_000_000_000_000_000_000;
        if (exp == 23) return 100_000_000_000_000_000_000_000;
        if (exp == 24) return 1_000_000_000_000_000_000_000_000;
        if (exp == 25) return 10_000_000_000_000_000_000_000_000;
        if (exp == 26) return 100_000_000_000_000_000_000_000_000;
        if (exp == 27) return 1_000_000_000_000_000_000_000_000_000;
        if (exp == 28) return 10_000_000_000_000_000_000_000_000_000;
        if (exp == 29) return 100_000_000_000_000_000_000_000_000_000;
        if (exp == 30) return 1_000_000_000_000_000_000_000_000_000_000;
        if (exp == 31) return 10_000_000_000_000_000_000_000_000_000_000;
        if (exp == 32) return 100_000_000_000_000_000_000_000_000_000_000;
        if (exp == 33) return 1_000_000_000_000_000_000_000_000_000_000_000;
        if (exp == 34) return 10_000_000_000_000_000_000_000_000_000_000_000;
        if (exp == 35) return 100_000_000_000_000_000_000_000_000_000_000_000;
        return 1_000_000_000_000_000_000_000_000_000_000_000_000;
    }

    function q96() internal pure returns (uint256) {
        return Q96;
    }
}
