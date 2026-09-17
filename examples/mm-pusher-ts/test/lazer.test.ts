// SPDX-License-Identifier: MIT
/**
 * THE byte-identity pin for the whole ethers v6 migration: builds the exact
 * feed set `LazerTestPayload.defaultUpdate(1769872629000000)` builds in
 * Solidity, signs it with the same demo signer key, and asserts the
 * resulting envelope is byte-for-byte identical to `vectors.lazerEnvelope`
 * (regenerated straight from Solidity by `demo/regen-vectors.sh` — never
 * hand-edited). If this pin passes, `src/pyth/lazer.ts`'s ethers-based
 * `toBeHex`/`concat`/`SigningKey` encoding produces EXACTLY the same wire
 * bytes the previous client library's encoding did — proof the library swap
 * did not move a byte. The other two tests exercise parse/build and
 * parseEnvelope round-trips against the package's own output (defense in
 * depth, not wire-format proof).
 */
import { describe, expect, it } from 'vitest';
import {
  buildPayload,
  DEMO_SIGNER_PRIVATE_KEY,
  parseEnvelope,
  parsePayload,
  signEnvelope,
  type LazerFeed,
} from '../src/pyth/lazer.js';
import vectors from './vectors.json';

// Exactly the feeds of LazerTestPayload.defaultUpdate(1769872629000000)
const TS_US = 1769872629000000n;
const FEEDS: LazerFeed[] = [
  { feedId: 1, price: 20n * 10n ** 8n, exponent: -8, confidence: 200_000n, timestampUs: TS_US },
  { feedId: 2, price: 35n * 10n ** 8n, exponent: -8, confidence: 150_000n, timestampUs: TS_US },
  { feedId: 3, price: 5n * 10n ** 8n, exponent: -8, confidence: 50_000n, timestampUs: TS_US },
  { feedId: 4, price: 1n * 10n ** 8n, exponent: -10, confidence: 10n, timestampUs: TS_US },
];

describe('lazer codec', () => {
  it('builds a byte-identical signed envelope to the Solidity-pinned vector', async () => {
    const payload = buildPayload(TS_US, 1, FEEDS);
    const envelope = await signEnvelope(payload, DEMO_SIGNER_PRIVATE_KEY);
    expect(envelope).toBe(vectors.lazerEnvelope);
  });

  it('parses its own output back', () => {
    const payload = buildPayload(TS_US, 1, FEEDS);
    const parsed = parsePayload(payload);
    expect(parsed.channel).toBe(1);
    expect(parsed.timestampUs).toBe(TS_US);
    expect(parsed.feeds).toEqual(FEEDS);
  });

  it('parseEnvelope round-trips the payload', async () => {
    const payload = buildPayload(TS_US, 1, FEEDS);
    const envelope = await signEnvelope(payload, DEMO_SIGNER_PRIVATE_KEY);
    expect(parseEnvelope(envelope).payload).toBe(payload);
  });
});
