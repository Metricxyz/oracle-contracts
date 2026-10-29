// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";

/// @dev Builds dynamically-signed Pyth Lazer updates for tests.
///
/// Every feed carries the 4-prop schema expected by the oracles under test:
/// Price (0), Exponent (4), Confidence (5), FeedUpdateTimestamp (12).
/// The update envelope matches `PythLazer.verifyUpdate`:
///   [evmMagic:4][r:32][s:32][v-27:1][payloadLen:2][payload]
/// with the signature taken over keccak256(payload). Register `signer()` via
/// `pythLazer.updateTrustedSigner` before pushing.
library LazerTestPayload {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint32 internal constant FORMAT_MAGIC = 0x93c7d375; // Lazer payload magic
    uint32 internal constant EVM_FORMAT_MAGIC = 706910618; // PythLazer envelope magic
    uint256 internal constant SIGNER_PK = uint256(keccak256("lazer-test-signer"));

    function signer() internal pure returns (address) {
        return vm.addr(SIGNER_PK);
    }

    function buildFeed(uint32 feedId, int64 price, int16 expo, uint64 conf, uint64 tsMicros)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            feedId,
            uint8(4),
            uint8(0), bytes8(uint64(price)),
            uint8(4), bytes2(uint16(expo)),
            uint8(5), bytes8(conf),
            uint8(12), uint8(1), bytes8(tsMicros)
        );
    }

    function buildPayload(uint64 headerTsMicros, uint8 channel, bytes[] memory feeds)
        internal
        pure
        returns (bytes memory out)
    {
        out = abi.encodePacked(FORMAT_MAGIC, headerTsMicros, channel, uint8(feeds.length));
        for (uint256 i; i < feeds.length; ++i) {
            out = bytes.concat(out, feeds[i]);
        }
    }

    function signAndWrap(bytes memory payload) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, keccak256(payload));
        return abi.encodePacked(EVM_FORMAT_MAGIC, r, s, uint8(v - 27), uint16(payload.length), payload);
    }

    /// @dev Standard 4-feed update (feeds 1..4) with every FeedUpdateTimestamp
    /// equal to the header timestamp.
    function defaultUpdate(uint64 tsMicros) internal pure returns (bytes memory) {
        bytes[] memory feeds = new bytes[](4);
        feeds[0] = buildFeed(1, int64(20 * 1e8), -8, 200_000, tsMicros);
        feeds[1] = buildFeed(2, int64(35 * 1e8), -8, 150_000, tsMicros);
        feeds[2] = buildFeed(3, int64(5 * 1e8), -8, 50_000, tsMicros);
        feeds[3] = buildFeed(4, int64(1 * 1e8), -10, 10, tsMicros);
        return signAndWrap(buildPayload(tsMicros, 1, feeds));
    }
}
