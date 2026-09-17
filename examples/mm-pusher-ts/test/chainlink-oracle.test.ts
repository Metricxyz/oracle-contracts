// SPDX-License-Identifier: MIT
/**
 * Pins the pure Chainlink-lane helpers:
 *  - `buildUpdateCalldata` ABI-encodes `updateReport(bytes)` (a real selector call,
 *    unlike the compressed/pyth fallback pushes) and round-trips the report bytes.
 *  - `feedResolution` reads the upper nibble of feed-id byte 0 (0x1… = HFS/ms).
 *  - `decodeReport` peeks the fields the on-chain oracle decodes from a `fullReport`
 *    envelope, and `refTimeSecondsOf` matches `price()`'s seconds `refTime`.
 */
import { describe, expect, it } from 'vitest';
import { AbiCoder, Interface } from 'ethers';
import { buildUpdateCalldata, tagReport, TAG_V050, TAG_V051 } from '../src/chainlink/oracle.js';
import { decodeReport, feedResolution, refTimeSecondsOf } from '../src/chainlink/streams.js';
import type { Hex } from '../src/common/types.js';

const abi = AbiCoder.defaultAbiCoder();
const HFS_ETH = '0x1003cb4fbeae929ce9f9ae53e45d35095be85ae614c02f1d4e36f3e8ad9ed18c' as Hex;

/** Wrap a report blob the way the Data Streams API / VerifierProxy expect. */
function wrapFullReport(reportBlob: Hex): Hex {
  const z = '0x' + '00'.repeat(32);
  return abi.encode(
    ['bytes32[3]', 'bytes', 'bytes32[]', 'bytes32[]', 'bytes32'],
    [[z, z, z], reportBlob, [], [], z],
  ) as Hex;
}

function hfsBlob(feedId: Hex, price: bigint, obsMs: bigint): Hex {
  return abi.encode(
    ['bytes32', 'uint64', 'uint64', 'uint192', 'uint192', 'uint64', 'int192', 'int192', 'int192'],
    [feedId, obsMs, obsMs, 0, 0, obsMs + 3_600_000n, price, price, price],
  ) as Hex;
}

describe('chainlink updateReport calldata', () => {
  const iface = new Interface(['function updateReport(bytes taggedReport)']);

  it('is a real selector call that round-trips the tagged report bytes', () => {
    const report = '0xdeadbeef' as Hex;
    const calldata = buildUpdateCalldata(report); // default tag = v0.5.0 (0x50)
    expect(calldata.slice(0, 10)).toBe(iface.getFunction('updateReport')!.selector);
    const [decoded] = iface.decodeFunctionData('updateReport', calldata);
    expect(decoded).toBe('0x50deadbeef'); // <tag> || report
  });

  it('prepends the given version tag byte', () => {
    const report = '0xdeadbeef' as Hex;
    expect(tagReport(report, TAG_V050)).toBe('0x50deadbeef');
    expect(tagReport(report, TAG_V051)).toBe('0x51deadbeef');
    const [decoded] = iface.decodeFunctionData(
      'updateReport',
      buildUpdateCalldata(report, TAG_V051),
    );
    expect(decoded).toBe('0x51deadbeef');
  });
});

describe('feed resolution', () => {
  it('0x1… feeds are millisecond (HFS)', () => {
    expect(feedResolution(HFS_ETH)).toBe('milliseconds');
  });
  it('0x0… feeds are seconds (standard)', () => {
    expect(feedResolution(('0x0003' + '11'.repeat(30)) as Hex)).toBe('seconds');
  });
});

describe('decodeReport', () => {
  it('peeks feedId / benchmark / timestamp and derives seconds refTime', () => {
    const price = 3000n * 10n ** 18n;
    const obsMs = 1_700_000_000_000n;
    const decoded = decodeReport(wrapFullReport(hfsBlob(HFS_ETH, price, obsMs)));
    expect(decoded.feedId.toLowerCase()).toBe(HFS_ETH);
    expect(decoded.benchmarkPrice).toBe(price);
    expect(decoded.observationsTimestamp).toBe(obsMs);
    expect(decoded.resolution).toBe('milliseconds');
    expect(refTimeSecondsOf(decoded)).toBe(1_700_000_000n);
  });
});
