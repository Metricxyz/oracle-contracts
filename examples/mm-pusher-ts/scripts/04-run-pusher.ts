// SPDX-License-Identifier: MIT
/**
 * PRODUCTION SKELETON — continuous compressed-lane pusher.
 *
 * Replace SyntheticRandomWalk with your market-data source: implement PriceSource.
 * The loop owns the non-negotiable mechanics: full-slot state (the slot is always
 * overwritten whole), strictly monotonic timestamps, sequential nonce handling
 * (send -> await receipt -> next), retry with exponential backoff, graceful shutdown.
 *
 * CADENCE IS YOUR BUSINESS LOGIC: this skeleton pushes every PUSH_INTERVAL_MS.
 * Replace the fixed interval with your own deviation/cadence policy.
 *
 * What happens: on every tick, pulls the full 4-lane state from `PriceSource`,
 * computes a strictly-increasing `timestampMs` (never reusing or rewinding
 * the last one), packs+pushes it, and — optionally (`VERIFY_READBACK=1`) —
 * reads position 0 back to catch a silently-ignored stale push. On failure,
 * backs off exponentially (capped at 30s) and logs `describeRevert(err)`
 * for a human-readable diagnosis; after 5 consecutive failures it hits the
 * alert hook point (wire your own paging here).
 *
 * Env: RPC_URL, COMPRESSED_ORACLE_ADDRESS, PUSHER_PRIVATE_KEY, SLOT_INDEX,
 * [CREATOR_ADDRESS, PUSH_INTERVAL_MS, MAX_ITERATIONS, VERIFY_READBACK]
 * Run: npx tsx scripts/04-run-pusher.ts
 *
 * Place in the package: compressed lane, the production-shaped counterpart
 * to script 03's one-shot walkthrough; `demo/anvil-demo.sh` runs it bounded
 * (`MAX_ITERATIONS=2`) as part of the offline demo.
 */
import type { Address, Hex } from '../src/common/types.js';
import { packSlotWord, type Lane } from '../src/compressed/slot.js';
import { feedIdOf } from '../src/compressed/feed-id.js';
import { pushSlots, readOracleData } from '../src/compressed/oracle.js';
import { envInt, envOr, requireEnv } from '../src/common/env.js';
import { makeClients } from '../src/common/clients.js';
import { describeRevert } from '../src/common/errors.js';

/** Implement this with your market data. Return the full 4-lane state of the slot. */
export interface PriceSource {
  next(): Promise<[Lane, Lane, Lane, Lane]>;
}

/** Demo source: a random walk around two synthetic pairs. REPLACE IN PRODUCTION. */
class SyntheticRandomWalk implements PriceSource {
  private p0 = 6543212345678n;
  private p1 = 350012345678n;
  async next(): Promise<[Lane, Lane, Lane, Lane]> {
    const drift = () => BigInt(Math.floor((Math.random() - 0.5) * 1e6));
    this.p0 += drift();
    this.p1 += drift();
    return [
      // 0.01-bps units: 1000 = 10 bp, 2500 = 25 bp (see src/compressed/codebook.ts)
      { price: this.p0, spread0: 1000, spread1: 2500 },
      { price: this.p1, spread0: 1500, spread1: 3000 },
      'empty',
      'empty',
    ];
  }
}

const oracle = requireEnv('COMPRESSED_ORACLE_ADDRESS') as Address;
const slotIndex = envInt('SLOT_INDEX', 0);
const intervalMs = envInt('PUSH_INTERVAL_MS', 5000);
const maxIterations = envInt('MAX_ITERATIONS', 0);
const verifyReadback = envOr('VERIFY_READBACK', '0') === '1';
const clients = await makeClients({
  rpcUrl: requireEnv('RPC_URL'),
  privateKey: requireEnv('PUSHER_PRIVATE_KEY') as Hex,
});
const creator = envOr('CREATOR_ADDRESS', clients.wallet!.address) as Address;
const source: PriceSource = new SyntheticRandomWalk();

let stopping = false;
process.on('SIGINT', () => (stopping = true));
process.on('SIGTERM', () => (stopping = true));

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
let lastTimestampMs = 0n;
let consecutiveFailures = 0;
let iteration = 0;

console.log(
  `pushing slot ${slotIndex} of namespace ${creator} every ${intervalMs}ms (chain ${clients.chainId})`,
);
while (!stopping && (maxIterations === 0 || iteration < maxIterations)) {
  iteration += 1;
  try {
    const lanes = await source.next();
    // strictly monotonic: never reuse or decrease the slot timestamp
    const now = BigInt(Date.now());
    const timestampMs = now > lastTimestampMs ? now : lastTimestampMs + 1n;
    const word = packSlotWord(lanes, timestampMs, slotIndex);
    const receipt = await pushSlots(clients, oracle, [word]); // sequential: awaits the receipt
    lastTimestampMs = timestampMs;
    consecutiveFailures = 0;
    console.log(`[${iteration}] pushed ts=${timestampMs} tx=${receipt.hash}`);

    if (verifyReadback) {
      const feedId = feedIdOf(creator, clients.chainId, slotIndex, 0);
      const data = await readOracleData(clients.provider, oracle, feedId);
      if (data.timestampMs !== timestampMs) {
        // an older word is silently ignored on-chain — surface it here
        console.error(
          `[${iteration}] READBACK STALE: on-chain ts ${data.timestampMs} != pushed ${timestampMs}`,
        );
      }
    }
    await sleep(intervalMs);
  } catch (err) {
    consecutiveFailures += 1;
    const backoffMs = Math.min(30_000, 1000 * 2 ** Math.min(consecutiveFailures, 5));
    console.error(
      `[${iteration}] push failed (${consecutiveFailures} in a row), retrying in ${backoffMs}ms: ${describeRevert(err)}`,
    );
    if (consecutiveFailures >= 5) {
      // HOOK POINT: wire your alerting here (pager, telegram, ...)
      console.error('ALERT: compressed pusher failing repeatedly');
    }
    await sleep(backoffMs);
  }
}
console.log('pusher stopped cleanly.');
