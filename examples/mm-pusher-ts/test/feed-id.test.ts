// SPDX-License-Identifier: MIT
/**
 * Pins `src/compressed/feed-id.ts`'s bit layout — a hand-computed feedId
 * literal (creator | chainid 8453 | slot 7 | position 2) that anyone can
 * re-derive by hand from the doc comment in feed-id.ts, plus round-trip and
 * out-of-range-rejection checks. WHY a hand-computed literal instead of just
 * round-tripping: round-tripping alone cannot catch a consistent
 * shift/order bug (encode and decode could agree with each other while both
 * disagreeing with the contract's actual on-chain layout); the literal pins
 * the WIRE layout itself. No client-library dependency — unaffected by the
 * ethers v6 migration.
 */
import { describe, expect, it } from 'vitest';
import { feedIdOf, parseFeedId } from '../src/compressed/feed-id.js';

describe('feed-id', () => {
  const creator = '0x1111111111111111111111111111111111111111' as const;

  it('pinned literal (creator | chainid 8453 | slot 7 | position 2)', () => {
    // 8453 = 0x2105; slot 7 = 0x07; position 2 = 0x02
    expect(feedIdOf(creator, 8453, 7, 2)).toBe(
      '0x1111111111111111111111111111111111111111000000000000000021050702',
    );
  });

  it('round-trips', () => {
    const id = feedIdOf(creator, 1n, 255, 3);
    expect(parseFeedId(id)).toEqual({
      creator,
      chainId: 1n,
      slotIndex: 255,
      positionIndex: 3,
    });
  });

  it('rejects invalid coordinates', () => {
    expect(() => feedIdOf(creator, 1, 0, 4)).toThrow(RangeError); // position < 4
    expect(() => feedIdOf(creator, 1, 256, 0)).toThrow(RangeError);
    expect(() => feedIdOf(creator, 1n << 80n, 0, 0)).toThrow(RangeError); // chainid is 80 bits
    expect(() => parseFeedId(`0x${'00'.repeat(32)}`)).toThrow(RangeError); // zero creator
    // non-zero creator, positionIndex byte = 0xff (> 3) — must hit the position guard, not the creator guard
    const valid = feedIdOf(creator, 1, 0, 0);
    expect(() => parseFeedId(`${valid.slice(0, -2)}ff` as `0x${string}`)).toThrow(RangeError);
  });
});
