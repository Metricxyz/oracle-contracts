// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Codebook256} from "../../../contracts/oracles/utils/Codebook256.sol";

contract CodebookTest is Test {
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
        assertEq(table.length, type(uint8).max);
    }
}
