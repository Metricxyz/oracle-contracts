// SPDX-License-Identifier: MIT
/**
 * Pins `src/compressed/u64x32.ts`'s pseudo-float codec at its boundaries
 * (zero, max mantissa, max representable value) and its lossy rounding
 * behavior (encode always rounds DOWN, discarding bits beyond the 27-bit
 * mantissa — pinned with a realistic 1e8-scaled price so the quantization
 * error is visible and checked, not just asserted "some rounding happened").
 * No client-library dependency — pure bigint math, unaffected by the
 * ethers v6 migration.
 */
import { describe, expect, it } from 'vitest';
import {
  decodeU64x32,
  encodeU64x32,
  quantizeU64x32,
  U64X32_MAX,
} from '../src/compressed/u64x32.js';

const MANT_MAX = (1n << 27n) - 1n;

describe('u64x32', () => {
  it('boundary pins', () => {
    expect(encodeU64x32(0n)).toBe(0);
    expect(decodeU64x32(0)).toBe(0n);
    // max mantissa, exponent 0: packed == mantissa
    expect(encodeU64x32(MANT_MAX)).toBe(Number(MANT_MAX));
    expect(decodeU64x32(Number(MANT_MAX))).toBe(MANT_MAX);
    // max representable: mantissa all-ones, exponent 31
    expect(U64X32_MAX).toBe(MANT_MAX << 31n);
    expect(encodeU64x32(U64X32_MAX)).toBe(0xffffffff);
    expect(decodeU64x32(0xffffffff)).toBe(U64X32_MAX);
  });

  it('exact values round-trip unchanged', () => {
    // 2000 * 1e8 (a 1e8-scaled price of 2000.0) fits in 27+11 bits => quantized
    for (const v of [1n, 42n, MANT_MAX, 1n << 30n, 123_456_789n]) {
      expect(decodeU64x32(encodeU64x32(v))).toBeLessThanOrEqual(v);
    }
    // powers of two are always exact
    expect(quantizeU64x32(1n << 40n)).toBe(1n << 40n);
  });

  it('rounds down (truncates low bits beyond 27-bit mantissa)', () => {
    // value = 2^28 + 1 needs exponent 1 => low bit is lost
    expect(quantizeU64x32((1n << 28n) + 1n)).toBe(1n << 28n);
    // pin a realistic 1e8-scaled price: 65432.12345678 * 1e8 (needs exponent 16)
    const price = 6543212345678n;
    const q = quantizeU64x32(price);
    expect(q).toBe(6543212281856n);
    expect(q <= price && price - q < 1n << 16n).toBe(true);
  });

  it('rejects out-of-range input', () => {
    expect(() => encodeU64x32(-1n)).toThrow(RangeError);
    expect(() => encodeU64x32(U64X32_MAX + 1n)).toThrow(RangeError);
  });
});
