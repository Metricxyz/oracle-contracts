// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Codebook256} from "../../../contracts/oracles/utils/Codebook256.sol";

contract Codebook256Test is Test {
    function _expectResult(uint8 index, uint16 res) internal {
        bool ok;
        uint16 val;
        (val, ok) = Codebook256.decode(index);
        assertTrue(ok && val == uint16(res));
    }

    function testDecodeTableIndex() public {
        _expectResult(0, 0);
        _expectResult(1, 1);
        _expectResult(type(uint8).max, 10000);
    }

    function testGetTable() public {
        uint16[] memory table = Codebook256.getTable();
        // 256 entries, not 255: indices are 0..255 inclusive, and entry 255 is the table's
        // saturated maximum.
        assertEq(table.length, uint256(type(uint8).max) + 1);
        assertEq(table[type(uint8).max], Codebook256.MAX_VALUE, "top index is the saturated maximum");
    }
}
