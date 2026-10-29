// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Codebook16
/// @notice Utility for mapping values in [0, 10_000] to 8-bit indices and back with higher density near zero.
library Codebook256 {
    uint16 internal constant MAX_VALUE = 10_000;
    uint8 internal constant MAX_INDEX = type(uint8).max; // 255
    // populated via codebook generator
    bytes internal constant TABLE =
        hex"0000000100020003000400050006000700080009000c000e00100012001400160018001a001c001e00200022002400260028002a002c002e00300032003400360038003a003c003e00400042004400460048004a004c004e00500052005400560058005a005c005e00600062006400660068006a006c006e0070007200740076007b00800085008a008f00940099009e00a300a800ad00b200b700bc00c100c600cb00d000d500da00df00e400e900ee00f300f800fd01020107010c01110116011b01200125012a012f01340139013e01430148014d01520157015c01610166016b01700175017a017f01840189018e01930198019d01a201a701ac01b101b601c001ca01d401de01e801f201fc02060210021a0224022e02380242024c02560260026a0274027e02880292029c02a602b002ba02c402ce02d802e202ec02f60300030a0314031e03280332033c03460350035a0364036e03780382038c039603a003aa03b403be03c803d203dc03e603f003fa0404040e04180422042c043604cc056205f8068e072407ba085008e6097c0a120aa80b3e0bd40c6a0d000d960e2c0ec20f580fee1084111a11b0124612dc13721408149e153415ca166016f6178c182218b8194e19e41a7a1b101ba61c3c1cd21d681dfe1e941f2a1fc0205620ec2182221822ae234423da24702506259c263226c8275e27f4288a29202710";

    function getTable() external pure returns (uint16[] memory t) {
        t = new uint16[](MAX_INDEX);
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
