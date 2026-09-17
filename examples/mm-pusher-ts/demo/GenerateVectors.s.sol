// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {LazerTestPayload} from "../../../test/utils/LazerTestPayload.sol";

/// Regenerates the pinned vectors consumed by examples/mm-pusher-ts/test/*.test.ts.
/// Run via examples/mm-pusher-ts/demo/regen-vectors.sh (repo root cwd). The constants
/// below are arbitrary but FROZEN: changing any of them invalidates the committed pins.
///
/// Purpose: this contract IS the source of truth the TS package's byte-
/// identity pins (test/vectors.json, consumed by
/// test/lazer.test.ts + test/compressed-oracle.test.ts) are checked against.
/// The TS side must never independently invent expected values — it always
/// re-derives them from here, so "the ethers migration didn't move a byte"
/// is provable rather than assumed.
///
/// What happens: builds the same Lazer envelope
/// `LazerTestPayload.defaultUpdate(TS_MICROS)` produces elsewhere in this
/// repo's own Solidity tests, and computes the two EIP-191
/// (`toEthSignedMessageHash`) digests the compressed oracle's
/// `allowPushers`/`updateBySignature` paths expect, over the SAME frozen
/// (chainId, oracle, deadline/creator, pusher/word) constants
/// `test/compressed-oracle.test.ts` uses; prints all three as one JSON line.
///
/// Inputs/outputs/env: `run()` is `pure` — no env, no broadcast, no state
/// changes. Output: one JSON line on stdout,
/// `{"lazerEnvelope":"0x..","consentDigest":"0x..","slotUpdateDigest":"0x.."}`.
///
/// Place in the package: invoked only via `demo/regen-vectors.sh`, which
/// redirects its stdout straight into `test/vectors.json`. NOT part of the
/// `npm run demo` / `npm test` gate — it is the tool that produces the file
/// those gates then pin against.
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
        bytes32 consentDigest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(CHAIN_ID, ORACLE, DEADLINE, PUSHER, CREATOR))
        );
        bytes32 slotUpdateDigest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(CHAIN_ID, ORACLE, CREATOR, SLOT_WORD))
        );
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
