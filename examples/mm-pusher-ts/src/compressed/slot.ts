// SPDX-License-Identifier: MIT
/**
 * 32-byte slot word codec for CompressedOracleV1 — see docs/oracle-packet-structure.md.
 * Layout: [lane0:48b][lane1:48b][lane2:48b][lane3:48b][timestampMs:56b][slotId:8b],
 * lane = (u64x32 price:32b | spread0 index:8b | spread1 index:8b).
 *
 * THE SLOT IS OVERWRITTEN WHOLE on every push: callers must supply all four lanes
 * every time, using 'empty' for unused positions. An 'empty' lane packs s0=s1=0xFF —
 * the contract's stall sentinel: getOracleData() reports such a lane as stalled/
 * never-pushed (price 0, spreads 0xFFFF, timestamp 0), which every consumer rejects.
 *
 * Purpose: this is the ONE encoder that produces the raw calldata word the
 * compressed oracle's `fallback()` accepts — there is no Solidity function
 * selector for pushing, so getting this byte layout exactly right IS the
 * integration contract with `CompressedOracleV1`.
 *
 * What happens inside: `packSlotWord` composes the 256-bit word with plain
 * bigint shifts/ORs (calling out to `u64x32.ts` for the per-lane price and
 * `codebook.ts` for the per-lane spread bytes), left-to-right lane0..lane3
 * then timestamp then slotId, matching the contract's storage layout bit for
 * bit; `unpackSlotWord` is its exact inverse, used by tests and by anything
 * that wants to inspect a word before pushing it.
 *
 * Inputs/outputs/env: `packSlotWord(lanes, timestampMs, slotId): Hex`,
 * `unpackSlotWord(word: Hex): { lanes, timestampMs, slotId }`. Both validate
 * their numeric ranges and throw `RangeError` on overflow. No env vars, no
 * network I/O — pure encoding.
 *
 * Place in the package: consumed by every compressed-lane script (03, 04, 06,
 * `demo/assert-stale-ignored.ts`) to build the words `pushSlots`/
 * `updateBySignature` in `oracle.ts` send on-chain.
 */
import type { Hex } from '../common/types.js';
import { decodeU64x32, encodeU64x32 } from './u64x32.js';
import { decodeSpreadIndex, STALL_SENTINEL_INDEX, encodeSpread } from './codebook.js';

/** Spreads are in 0.01-bps units (100 = 1 bp, 10000 = 1%) — see `codebook.ts`, NOT whole bps. */
export type Lane = { price: bigint; spread0: number; spread1: number } | 'empty';

export interface UnpackedLane {
  empty: boolean;
  pRaw: number;
  s0: number;
  s1: number;
  price: bigint;
  spread0: number;
  spread1: number;
}

const TS_MAX = (1n << 56n) - 1n;
const SENTINEL = BigInt(STALL_SENTINEL_INDEX);
/** What getOracleData() reports for a 0xFF/0xFF lane — the value is NOT in the slot word. */
const STALL_SPREAD = 65_535;

export function packSlotWord(
  lanes: readonly [Lane, Lane, Lane, Lane],
  timestampMs: bigint,
  slotId: number,
): Hex {
  if (timestampMs < 0n || timestampMs > TS_MAX) {
    throw new RangeError(`slot: timestampMs ${timestampMs} out of uint56`);
  }
  if (!Number.isInteger(slotId) || slotId < 0 || slotId > 255) {
    throw new RangeError(`slot: slotId ${slotId} out of [0, 255]`);
  }
  let word = (timestampMs << 8n) | BigInt(slotId);
  lanes.forEach((lane, i) => {
    let bits: bigint;
    if (lane === 'empty') {
      bits = (SENTINEL << 8n) | SENTINEL; // p = 0, s0 = s1 = 0xFF
    } else {
      const p = BigInt(encodeU64x32(lane.price));
      const s0 = BigInt(encodeSpread(lane.spread0));
      const s1 = BigInt(encodeSpread(lane.spread1));
      bits = (p << 16n) | (s0 << 8n) | s1;
    }
    word |= bits << BigInt(208 - 48 * i);
  });
  return `0x${word.toString(16).padStart(64, '0')}`;
}

export function unpackSlotWord(word: Hex): {
  lanes: UnpackedLane[];
  timestampMs: bigint;
  slotId: number;
} {
  const raw = BigInt(word);
  const lanes: UnpackedLane[] = [];
  for (let i = 0; i < 4; i++) {
    const bits = (raw >> BigInt(208 - 48 * i)) & ((1n << 48n) - 1n);
    const pRaw = Number(bits >> 16n);
    const s0 = Number((bits >> 8n) & 0xffn);
    const s1 = Number(bits & 0xffn);
    const empty = s0 === STALL_SENTINEL_INDEX && s1 === STALL_SENTINEL_INDEX;
    lanes.push(
      empty
        ? // Mirror getOracleData: a 0xFF/0xFF lane reports the STALL sentinel, not the table
          // value at index 255. Decoding it as 10000 (= 1%) would read as a live, wide feed.
          { empty, pRaw, s0, s1, price: 0n, spread0: STALL_SPREAD, spread1: STALL_SPREAD }
        : {
            empty,
            pRaw,
            s0,
            s1,
            price: decodeU64x32(pRaw),
            spread0: decodeSpreadIndex(s0),
            spread1: decodeSpreadIndex(s1),
          },
    );
  }
  return { lanes, timestampMs: (raw >> 8n) & TS_MAX, slotId: Number(raw & 0xffn) };
}
