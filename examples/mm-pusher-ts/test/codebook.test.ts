// SPDX-License-Identifier: MIT
/**
 * Pins `src/compressed/codebook.ts` against two things: (1) the canonical
 * JSON source of truth under `contracts/oracles/compressed/codebook/`, so
 * the committed `codebook.json` copy this package ships cannot silently
 * drift from the Solidity-side table, and (2) a set of hand-derived
 * boundary/rounding pins (shape, decode, encode-rounds-up, the 0xFF
 * sentinel is never returned by the encoder) that mirror
 * `Codebook256.sol`'s behavior. No client-library dependency — this file is
 * unaffected by the ethers v6 migration.
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  CODEBOOK,
  decodeSpreadIndex,
  STALL_SENTINEL_INDEX,
  encodeSpread,
} from '../src/compressed/codebook.js';

const CANONICAL = fileURLToPath(
  new URL(
    '../../../contracts/oracles/compressed/codebook/spread [0 .. 10000].json',
    import.meta.url,
  ),
);

describe('codebook', () => {
  it('guard: local copy is content-equal to the canonical source', () => {
    const canonical = JSON.parse(readFileSync(CANONICAL, 'utf8')) as number[];
    expect([...CODEBOOK]).toEqual(canonical);
  });

  it('shape: 256 non-decreasing entries in [0, 10000], tail 251..255 all 10000', () => {
    expect(CODEBOOK.length).toBe(256);
    for (let i = 1; i < 256; i++) expect(CODEBOOK[i]).toBeGreaterThanOrEqual(CODEBOOK[i - 1]);
    expect(CODEBOOK[0]).toBe(0);
    for (let i = 251; i < 256; i++) expect(CODEBOOK[i]).toBe(10_000);
    expect(CODEBOOK[250]).toBeLessThan(10_000);
  });

  it('decode pins', () => {
    expect(decodeSpreadIndex(0)).toBe(0);
    expect(decodeSpreadIndex(255)).toBe(10_000);
    expect(() => decodeSpreadIndex(256)).toThrow(RangeError);
    expect(() => decodeSpreadIndex(-1)).toThrow(RangeError);
  });

  it('encode: exact hit returns the first matching index', () => {
    for (let i = 0; i <= 250; i++) {
      expect(encodeSpread(CODEBOOK[i])).toBeLessThanOrEqual(i);
      expect(decodeSpreadIndex(encodeSpread(CODEBOOK[i]))).toBe(CODEBOOK[i]);
    }
  });

  it('encode: rounds UP to the next entry, never understates', () => {
    // spreads between table entries must round UP:
    for (const units of [11, 13, 119, 5001, 9999]) {
      const idx = encodeSpread(units);
      expect(decodeSpreadIndex(idx)).toBeGreaterThanOrEqual(units);
      if (idx > 0) expect(decodeSpreadIndex(idx - 1)).toBeLessThan(units);
    }
  });

  it('encode: 10000 returns the FIRST 10000 entry (251), never the 0xFF sentinel', () => {
    expect(encodeSpread(10_000)).toBe(251);
    for (let units = 0; units <= 10_000; units += 7) {
      expect(encodeSpread(units)).not.toBe(STALL_SENTINEL_INDEX);
    }
    expect(encodeSpread(10_000)).not.toBe(255);
  });

  it('encode: rejects out-of-range', () => {
    expect(() => encodeSpread(-1)).toThrow(RangeError);
    expect(() => encodeSpread(10_001)).toThrow(RangeError);
    expect(() => encodeSpread(1.5)).toThrow(RangeError);
  });

  // Units anchor. The table is 0.01 bps (100 = 1 bp, 10000 = 1%), NOT whole bps — pinned in
  // absolute numbers so a rename or a re-scaled table cannot quietly move the unit. See
  // AnchoredPriceProvider.ONE_SPREAD_UNIT_E18.
  it('table values are 0.01-bps units, not whole bps', () => {
    // a 10 bp intent = 1000 units, rounded UP by the codebook to 1008 = 10.08 bp
    expect(encodeSpread(1000)).toBe(184);
    expect(decodeSpreadIndex(184)).toBe(1008);
    expect(decodeSpreadIndex(encodeSpread(1000))).toBeGreaterThanOrEqual(1000);
    // the whole-bps misreading: a "10 bps" label lands at 12 units = 0.12 bp, ~83x too tight,
    // which quotes the LP inside the market. This assertion is the regression guard, not a nicety.
    expect(decodeSpreadIndex(encodeSpread(10))).toBe(12);
    // the ceiling is 1%, not 100%
    expect(CODEBOOK[251]).toBe(10_000);
  });
});
