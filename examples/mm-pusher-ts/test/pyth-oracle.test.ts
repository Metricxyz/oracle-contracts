// SPDX-License-Identifier: MIT
/**
 * Pins the raw calldata layout `src/pyth/oracle.ts`'s `buildPushCalldata`
 * produces: `[feedsLength:2][feedIds:4 each][signed update bytes]`, exactly
 * what `PythOracle`'s fallback() expects (there is no function selector for
 * this push path, same as the compressed lane). Also pins `pythFeedIdToBytes32`
 * (left-padded uint256 encoding of a uint32 Lazer feed id) and the
 * empty-feed-list rejection. `buildPushCalldata`/`pythFeedIdToBytes32` are
 * pure `toBeHex`/`concat` composition — unaffected in shape by the ethers
 * v6 client-library migration.
 */
import { describe, expect, it } from 'vitest';
import { buildPushCalldata, pythFeedIdToBytes32 } from '../src/pyth/oracle.js';

describe('pyth push calldata', () => {
  it('pins the exact layout [len:2][ids:4xN][update]', () => {
    expect(buildPushCalldata([1, 2, 3, 4], '0xdeadbeef')).toBe(
      '0x0004' + '00000001' + '00000002' + '00000003' + '00000004' + 'deadbeef',
    );
  });

  it('feed id as bytes32 is left-padded uint256', () => {
    expect(pythFeedIdToBytes32(397)).toBe(`0x${'0'.repeat(61)}18d`);
  });

  it('rejects an empty feed list', () => {
    expect(() => buildPushCalldata([], '0xdeadbeef')).toThrow(RangeError);
  });
});
