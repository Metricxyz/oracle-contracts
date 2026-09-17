// SPDX-License-Identifier: MIT
/**
 * Pins `src/compressed/slot.ts`'s 32-byte word layout: a hand-computed
 * single-lane word (so the byte OFFSETS of each lane/timestamp/slotId field
 * are pinned, not just the round-trip), plus a round-trip test through
 * realistic multi-lane data (including the 0xFF stall sentinel and the
 * 10000-unit/index-251 spread boundary, 10000 units = 1%) and out-of-range rejection for
 * timestamp/slotId. No client-library dependency — `packSlotWord`/
 * `unpackSlotWord` are pure bigint bit-twiddling, unaffected by the ethers
 * v6 migration.
 */
import { describe, expect, it } from 'vitest';
import { quantizeU64x32 } from '../src/compressed/u64x32.js';
import { decodeSpreadIndex, encodeSpread } from '../src/compressed/codebook.js';
import { packSlotWord, unpackSlotWord, type Lane } from '../src/compressed/slot.js';

describe('slot word', () => {
  // spreads in 0.01-bps units: 1000 = 10 bp, 2000 = 20 bp
  const lane = (price: bigint, s0 = 1000, s1 = 2000): Lane => ({
    price,
    spread0: s0,
    spread1: s1,
  });

  it('hand-computed pin: one lane, three empty', () => {
    // price 1n => u64x32 packed = 0x00000001; spreads 0 units => index 0
    const word = packSlotWord([lane(1n, 0, 0), 'empty', 'empty', 'empty'], 1n, 0x05);
    // lane0 = 0x000000010000 (p=1,s0=0,s1=0); empty = 0x00000000ffff
    expect(word).toBe('0x' + '000000010000' + '00000000ffff'.repeat(3) + '00000000000001' + '05');
  });

  it('round-trips through unpack (quantized values)', () => {
    const lanes: [Lane, Lane, Lane, Lane] = [
      lane(6543212345678n, 1000, 2500),
      lane(99n, 0, 10_000),
      'empty',
      lane(1n << 40n, 118, 118),
    ];
    const ts = 1_768_000_000_123n;
    const word = packSlotWord(lanes, ts, 7);
    const back = unpackSlotWord(word);
    expect(back.timestampMs).toBe(ts);
    expect(back.slotId).toBe(7);
    expect(back.lanes[2].empty).toBe(true);
    expect(back.lanes[2].price).toBe(0n);
    // an empty lane mirrors getOracleData: the STALL sentinel, not the table value at index 255
    expect(back.lanes[2].spread0).toBe(65_535);
    expect(back.lanes[2].spread1).toBe(65_535);
    expect(back.lanes[0].price).toBe(quantizeU64x32(6543212345678n));
    expect(back.lanes[0].spread0).toBe(decodeSpreadIndex(encodeSpread(1000)));
    expect(back.lanes[1].spread1).toBe(10_000);
    expect(back.lanes[1].s1).toBe(251); // 10000 units (= 1%) -> index 251, NOT the 0xFF sentinel
    expect(back.lanes[3].price).toBe(1n << 40n);
  });

  it('rejects out-of-range timestamp and slotId', () => {
    const l: [Lane, Lane, Lane, Lane] = ['empty', 'empty', 'empty', 'empty'];
    expect(() => packSlotWord(l, 1n << 56n, 0)).toThrow(RangeError);
    expect(() => packSlotWord(l, -1n, 0)).toThrow(RangeError);
    expect(() => packSlotWord(l, 1n, 256)).toThrow(RangeError);
  });
});
