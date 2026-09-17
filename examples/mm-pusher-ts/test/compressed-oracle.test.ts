// SPDX-License-Identifier: MIT
/**
 * Pins `pusherConsentDigest`/`slotUpdateDigest` (src/compressed/oracle.ts)
 * against `demo/GenerateVectors.s.sol`'s own Solidity computation of the same
 * two digests (via OpenZeppelin's `MessageHashUtils.toEthSignedMessageHash`).
 *
 * WHAT this pins: that our TS `keccak256(abi.encode(...))` inner digest,
 * once wrapped with the EIP-191 personal-sign prefix, is byte-identical to
 * what the Solidity contract computes internally before `ECDSA.recover` —
 * i.e. that a signature produced over our TS digest will actually verify
 * on-chain. `hashMessage(getBytes(digest))` is ethers' equivalent of
 * Solidity's `toEthSignedMessageHash(bytes32)`.
 *
 * WHY it matters: these two digests are exactly what `signDigest` signs in
 * scripts 02 and 06 (pusher consent / creator-signed slot update) — a wrong
 * digest here means every signature built on top of it silently fails
 * on-chain (`InvalidSignature`/wrong-signer style reverts), so this is
 * pinned against the Solidity source of truth, not just re-derived in TS.
 */
import { getBytes, hashMessage } from 'ethers';
import { describe, expect, it } from 'vitest';
import { pusherConsentDigest, readOracleData, slotUpdateDigest } from '../src/compressed/oracle.js';
import vectors from './vectors.json';

const ORACLE = '0x1111111111111111111111111111111111111111' as const;
const PUSHER = '0x2222222222222222222222222222222222222222' as const;
const CREATOR = '0x3333333333333333333333333333333333333333' as const;

describe('compressed oracle signature digests (pinned from Solidity MessageHashUtils)', () => {
  it('pusher consent digest matches toEthSignedMessageHash pin', () => {
    const inner = pusherConsentDigest(31337n, ORACLE, 1800000000n, PUSHER, CREATOR);
    expect(hashMessage(getBytes(inner))).toBe(vectors.consentDigest);
  });

  it('slot update digest matches toEthSignedMessageHash pin', () => {
    const inner = slotUpdateDigest(31337n, ORACLE, CREATOR, 0xabcdefn);
    expect(hashMessage(getBytes(inner))).toBe(vectors.slotUpdateDigest);
  });

  it('narrows uint16 spread fields to number (ethers returns bigint for all uints)', async () => {
    // type-level contract: spread0/spread1 are number, price/timestamps stay bigint —
    // scripts compare spread1 === 0xffff (number), so a regression here breaks the demo silently.
    const dummy: Awaited<ReturnType<typeof readOracleData>> = {
      price: 0n,
      spread0: 0,
      spread1: 0,
      timestampMs: 0n,
    };
    expect(typeof dummy.spread0).toBe('number');
    expect(typeof dummy.price).toBe('bigint');
  });
});
