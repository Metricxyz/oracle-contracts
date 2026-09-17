// SPDX-License-Identifier: MIT
/**
 * Pyth Lazer wire-format codec for the subset PythOracle consumes (LazerConsumer.sol):
 * strict 4-property schema Price(0) / Exponent(4) / Confidence(5) / FeedUpdateTimestamp(12).
 * build+sign exist for the OFFLINE DEMO ONLY — in production the signed envelope comes
 * from the Pyth Lazer service verbatim and is never constructed locally.
 *
 * Purpose: encode/decode the exact byte layout `PythLazer.verifyUpdate` (and,
 * inside it, `LazerConsumer`) expects, so the offline demo can manufacture a
 * self-signed envelope that is byte-for-byte indistinguishable from a real
 * one, and so `scripts/10-pyth-push-once.ts` can pull the feed-id list back
 * out of a real envelope before relaying it.
 *
 * What happens inside: `buildFeed`/`buildPayload` concatenate fixed-width
 * big-endian hex chunks with `toBeHex`/`concat` (no ABI encoding — this is
 * Lazer's own compact binary format, not Solidity calldata); `signEnvelope`
 * hashes the payload with `keccak256` and signs that hash RAW — no EIP-191
 * prefix — via `SigningKey.sign`, matching what `PythLazer.verifyUpdate`
 * recovers against; `parseEnvelope`/`parsePayload` are the exact inverse,
 * the latter walking the payload with a `DataView` since it is a
 * heterogeneous property list, not a fixed struct.
 *
 * ethers-specific note: `SigningKey.sign()` is synchronous and returns a
 * `Signature` with `.r`/`.s`/`.yParity` directly (no async signing helper
 * needed); `signEnvelope` stays `async`/`Promise`-typed only to keep its
 * call signature stable for existing callers.
 *
 * Inputs/outputs/env: `buildFeed(LazerFeed): Hex`, `buildPayload(tsUs,
 * channel, feeds): Hex`, `signEnvelope(payload, privateKey): Promise<Hex>`,
 * `parseEnvelope(update): {payload,r,s,yParity}`, `parsePayload(payload):
 * {timestampUs,channel,feeds}`. No env vars are read here — callers
 * (`demo/build-demo-update.ts`, `scripts/10-pyth-push-once.ts`) supply file
 * paths / feed ids from their own env reads.
 *
 * Place in the package: `DEMO_SIGNER_PRIVATE_KEY` here matches the trusted
 * signer `demo/DeployDemo.s.sol` registers on the local `PythLazer` proxy —
 * changing one without the other breaks `npm run demo`. Consumed by
 * `demo/build-demo-update.ts` (build+sign) and `src/pyth/oracle.ts` /
 * `scripts/10-11-*.ts` (parse, to recover the feed-id list from a payload).
 */
import { concat, getBytes, keccak256, dataSlice, toBeHex, toUtf8Bytes, SigningKey } from 'ethers';
import type { Hex } from '../common/types.js';

export const LAZER_MAGIC = 0x93c7d375;
export const EVM_ENVELOPE_MAGIC = 706910618; // 0x2a22999a
/** Same derivation as test/utils/LazerTestPayload.sol: keccak256("lazer-test-signer"). */
export const DEMO_SIGNER_PRIVATE_KEY: Hex = keccak256(toUtf8Bytes('lazer-test-signer')) as Hex;

export interface LazerFeed {
  feedId: number;
  price: bigint; // int64, two's complement on the wire
  exponent: number; // int16
  confidence: bigint; // uint64
  timestampUs: bigint; // uint64 microseconds
}

const int64 = (v: bigint): Hex => toBeHex(BigInt.asUintN(64, v), 8) as Hex;
const int16 = (v: number): Hex => toBeHex(BigInt.asUintN(16, BigInt(v)), 2) as Hex;

export function buildFeed(f: LazerFeed): Hex {
  return concat([
    toBeHex(f.feedId, 4),
    toBeHex(4, 1), // numProps
    toBeHex(0, 1),
    int64(f.price),
    toBeHex(4, 1),
    int16(f.exponent),
    toBeHex(5, 1),
    toBeHex(f.confidence, 8),
    toBeHex(12, 1),
    toBeHex(1, 1), // exists flag
    toBeHex(f.timestampUs, 8),
  ]) as Hex;
}

export function buildPayload(headerTimestampUs: bigint, channel: number, feeds: LazerFeed[]): Hex {
  if (feeds.length === 0 || feeds.length > 255) throw new RangeError('lazer: 1..255 feeds');
  return concat([
    toBeHex(LAZER_MAGIC, 4),
    toBeHex(headerTimestampUs, 8),
    toBeHex(channel, 1),
    toBeHex(feeds.length, 1),
    ...feeds.map(buildFeed),
  ]) as Hex;
}

/** DEMO ONLY: signs keccak256(payload) RAW (no EIP-191 prefix), like PythLazer.verifyUpdate expects. */
export async function signEnvelope(payload: Hex, privateKey: Hex): Promise<Hex> {
  const sig = new SigningKey(privateKey).sign(keccak256(payload));
  const payloadLen = (payload.length - 2) / 2;
  return concat([
    toBeHex(EVM_ENVELOPE_MAGIC, 4),
    sig.r,
    sig.s,
    toBeHex(sig.yParity, 1), // envelope stores v - 27 == yParity
    toBeHex(payloadLen, 2),
    payload,
  ]) as Hex;
}

export function parseEnvelope(update: Hex): { payload: Hex; r: Hex; s: Hex; yParity: number } {
  const bytes = getBytes(update);
  if (bytes.length < 71) throw new RangeError('lazer: envelope too short');
  const magic = Number(BigInt(dataSlice(update, 0, 4)));
  if (magic !== EVM_ENVELOPE_MAGIC) throw new RangeError('lazer: bad envelope magic');
  const payloadLen = Number(BigInt(dataSlice(update, 69, 71)));
  if (bytes.length < 71 + payloadLen) throw new RangeError('lazer: envelope truncated');
  return {
    r: dataSlice(update, 4, 36) as Hex,
    s: dataSlice(update, 36, 68) as Hex,
    yParity: bytes[68],
    payload: dataSlice(update, 71, 71 + payloadLen) as Hex,
  };
}

export function parsePayload(payload: Hex): {
  timestampUs: bigint;
  channel: number;
  feeds: LazerFeed[];
} {
  const bytes = getBytes(payload);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.getUint32(0) !== LAZER_MAGIC) throw new RangeError('lazer: bad payload magic');
  const timestampUs = view.getBigUint64(4);
  const channel = view.getUint8(12);
  const feedsLen = view.getUint8(13);
  let pos = 14;
  const feeds: LazerFeed[] = [];
  for (let i = 0; i < feedsLen; i++) {
    const feedId = view.getUint32(pos);
    const numProps = view.getUint8(pos + 4);
    pos += 5;
    if (numProps !== 4) throw new RangeError(`lazer: expected 4 props, got ${numProps}`);
    let price = 0n;
    let exponent = 0;
    let confidence = 0n;
    let tsUs = 0n;
    for (let p = 0; p < numProps; p++) {
      const pid = view.getUint8(pos);
      pos += 1;
      switch (pid) {
        case 0:
          price = view.getBigInt64(pos);
          pos += 8;
          break;
        case 4:
          exponent = view.getInt16(pos);
          pos += 2;
          break;
        case 5:
          confidence = view.getBigUint64(pos);
          pos += 8;
          break;
        case 12: {
          const exists = view.getUint8(pos);
          pos += 1;
          if (exists !== 0) {
            tsUs = view.getBigUint64(pos);
            pos += 8;
          }
          break;
        }
        default:
          throw new RangeError(`lazer: unsupported property ${pid}`);
      }
    }
    feeds.push({ feedId, price, exponent, confidence, timestampUs: tsUs });
  }
  if (pos !== bytes.length) throw new RangeError('lazer: trailing bytes in payload');
  return { timestampUs, channel, feeds };
}
