// SPDX-License-Identifier: MIT
/**
 * EDUCATIONAL walkthrough — one full compressed-lane push, verified end to end.
 *
 * The slot word (32 bytes) packs FOUR positions at once and the slot is always
 * overwritten WHOLE, so unused positions are encoded as 'empty' (the 0xFF/0xFF
 * sentinel — they read back as never-pushed). The word carries its own timestamp;
 * strict per-slot monotonicity is the only replay protection: a word with an older
 * timestamp is SILENTLY ignored, which is why this script reads everything back.
 *
 * What happens: encodes two live lanes + two empty ones into a single slot
 * word (`packSlotWord`), pushes it as raw calldata (`pushSlots`), then reads
 * every one of the 4 positions back and asserts they decode to exactly what
 * was pushed (accounting for U64x32's price quantization and the codebook's
 * spread rounding) — this is the reference implementation every other
 * compressed-lane script builds on.
 *
 * Env: RPC_URL, COMPRESSED_ORACLE_ADDRESS, PUSHER_PRIVATE_KEY, SLOT_INDEX, [CREATOR_ADDRESS]
 * Run: npx tsx scripts/03-push-once.ts
 *
 * Place in the package: compressed lane, step 2 — the one-shot counterpart
 * to script 04's continuous loop; this is what `npm run demo` exercises to
 * prove the push+readback round-trip works end to end against a live chain.
 */
import type { Address, Hex } from '../src/common/types.js';
import { packSlotWord, type Lane } from '../src/compressed/slot.js';
import { quantizeU64x32 } from '../src/compressed/u64x32.js';
import { decodeSpreadIndex, encodeSpread } from '../src/compressed/codebook.js';
import { feedIdOf } from '../src/compressed/feed-id.js';
import { pushSlots, readOracleData } from '../src/compressed/oracle.js';
import { envInt, envOr, requireEnv } from '../src/common/env.js';
import { makeClients } from '../src/common/clients.js';

const oracle = requireEnv('COMPRESSED_ORACLE_ADDRESS') as Address;
const slotIndex = envInt('SLOT_INDEX', 0);
const clients = await makeClients({
  rpcUrl: requireEnv('RPC_URL'),
  privateKey: requireEnv('PUSHER_PRIVATE_KEY') as Hex,
});
// Whose namespace do the words land in? The creator's, if this key was delegated
// via allowPushers (script 02); otherwise the pusher's own address.
const creator = envOr('CREATOR_ADDRESS', clients.wallet!.address) as Address;

// ── 1. the prices this MM wants to publish (1e8-scaled integers + spreads in 0.01-bps
//       units: 100 = 1 bp, 10000 = 1%. These are NOT whole bps — see src/compressed/codebook.ts) ──
const lanes: [Lane, Lane, Lane, Lane] = [
  { price: 6543212345678n, spread0: 1000, spread1: 2500 }, // position 0, BTC/USD ~65432.12, 10/25 bp
  { price: 350012345678n, spread0: 1500, spread1: 3000 }, //  position 1, ETH/USD ~3500.12, 15/30 bp
  'empty', //                                                    position 2 unused
  'empty', //                                                    position 3 unused
];
const timestampMs = BigInt(Date.now());

// Absolute, hand-checked expectations: what the CHAIN must report for the lanes above (the codebook
// rounds UP to the next entry, so these sit just above the requested value — a spread is never
// understated). Deliberately NOT derived from encodeSpread(): a readback that recomputes the
// expectation with the same codec cannot catch a UNITS regression, which is exactly how the 100x
// bps/0.01-bps mix-up survived here undetected.
const EXPECTED = [
  { spread0: 1008, spread1: 2578 }, // 10.08 bp / 25.78 bp
  { spread0: 1528, spread1: 3028 }, // 15.28 bp / 30.28 bp
];

// ── 2. encode: U64x32 quantizes the price (round-down), the codebook rounds spreads UP ──
const word = packSlotWord(lanes, timestampMs, slotIndex);
console.log(`slot word: ${word}`);

// ── 3. push: raw calldata straight to the oracle address (its fallback() is the entry point) ──
const receipt = await pushSlots(clients, oracle, [word]);
console.log(`pushed in tx ${receipt.hash} (gas ${receipt.gasUsed})`);

// ── 4. read back and verify EXACTLY what a consumer will see ──
let failed = false;
for (let pos = 0; pos < 4; pos++) {
  const lane = lanes[pos];
  const feedId = feedIdOf(creator, clients.chainId, slotIndex, pos);
  const data = await readOracleData(clients.provider, oracle, feedId);
  if (lane === 'empty') {
    // empty sentinel (0xFF/0xFF) reads as the stall marker: price 0 / spreads 0xFFFF
    // (STALL_SPREAD) / timestamp 0 — every consumer rejects it as stalled/never-pushed.
    if (
      data.price !== 0n ||
      data.timestampMs !== 0n ||
      data.spread0 !== 0xffff ||
      data.spread1 !== 0xffff
    ) {
      console.error(`position ${pos}: expected empty-sentinel readback, got`, data);
      failed = true;
    }
    continue;
  }
  const wantPrice = quantizeU64x32(lane.price);
  // Two independent expectations, both must hold: the round-trip through our own codec (catches a
  // table drift) AND the absolute pin above (catches a units drift, which the round-trip cannot).
  const wantS0 = decodeSpreadIndex(encodeSpread(lane.spread0));
  const wantS1 = decodeSpreadIndex(encodeSpread(lane.spread1));
  if (wantS0 !== EXPECTED[pos].spread0 || wantS1 !== EXPECTED[pos].spread1) {
    console.error(`position ${pos}: codec disagrees with the absolute pin — spread units drifted`, {
      codec: { wantS0, wantS1 },
      pinned: EXPECTED[pos],
    });
    failed = true;
    continue;
  }
  const ok =
    data.price === wantPrice &&
    data.spread0 === wantS0 &&
    data.spread1 === wantS1 &&
    data.timestampMs === timestampMs;
  if (!ok) {
    console.error(`position ${pos}: readback mismatch`, {
      want: { wantPrice, wantS0, wantS1, timestampMs },
      got: data,
    });
    failed = true;
  } else {
    console.log(
      `position ${pos} verified: price ${data.price} (quantization error ${lane.price - wantPrice}), ` +
        `spreads ${data.spread0}/${data.spread1} (0.01-bps), ts ${data.timestampMs}`,
    );
  }
}
process.exit(failed ? 1 : 0);
