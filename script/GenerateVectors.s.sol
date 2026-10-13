// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {LazerTestPayload} from "../test/utils/LazerTestPayload.sol";

/// Regenerates the pinned vectors the market-maker pusher package checks itself against.
///
/// The pusher lives in its own repository (`Metricxyz/mm-pusher-ts`), which commits the output of
/// this script as `test/vectors.json` and pins its encoder tests to it byte for byte. The TS side
/// never invents an expected value; it re-derives every one of them from this contract, so "the
/// encoder still agrees with the contracts" is provable rather than assumed. The constants below
/// are arbitrary but FROZEN: changing any of them invalidates the committed pins.
///
/// What happens: builds the Lazer envelope `LazerTestPayload.defaultUpdate(TS_MICROS)` that this
/// repository's own Solidity tests produce, and computes the two EIP-191
/// (`toEthSignedMessageHash`) digests the compressed oracle's `allowPushers` / `updateBySignature`
/// paths expect, over the same frozen (chainId, oracle, deadline/creator, pusher/word) constants.
///
/// Inputs/outputs/env: `run()` is `pure` — no env, no broadcast, no state changes. It prints one
/// JSON line, `{"lazerEnvelope":"0x..","consentDigest":"0x..","slotUpdateDigest":"0x.."}`:
///
///     forge script script/GenerateVectors.s.sol -vv | grep -o '{"lazerEnvelope".*}'
///
/// Redirect that line into the pusher repository's `test/vectors.json`, then run its `npm test`.
/// Nothing in this repository's own build or test gate runs this script.
contract GenerateVectors is Script {
    uint256 constant CHAIN_ID = 31337;
    address constant ORACLE = 0x1111111111111111111111111111111111111111;
    address constant PUSHER = 0x2222222222222222222222222222222222222222;
    address constant CREATOR = 0x3333333333333333333333333333333333333333;
    uint256 constant DEADLINE = 1800000000;
    uint256 constant SLOT_WORD = 0xabcdef;
    uint64 constant TS_MICROS = 1769872629000000;

    function run() external pure {
        bytes memory envelope = LazerTestPayload.defaultUpdate(TS_MICROS);
        bytes32 consentDigest =
            MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(CHAIN_ID, ORACLE, DEADLINE, PUSHER, CREATOR)));
        bytes32 slotUpdateDigest =
            MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(CHAIN_ID, ORACLE, CREATOR, SLOT_WORD)));
        console2.log(
            string.concat(
                '{"lazerEnvelope":"',
                vm.toString(envelope),
                '","consentDigest":"',
                vm.toString(consentDigest),
                '","slotUpdateDigest":"',
                vm.toString(slotUpdateDigest),
                '"}'
            )
        );
    }
}
