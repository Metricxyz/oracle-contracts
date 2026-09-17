// SPDX-License-Identifier: MIT
/**
 * Negative case: a word with an OLDER timestamp must be SILENTLY ignored by the
 * contract (tx succeeds, storage unchanged). Pushes fresh, then pushes stale,
 * asserts the fresh state survived.
 *
 * Purpose: prove the ONLY replay protection the compressed lane has —
 * strict per-slot timestamp monotonicity — actually holds against a live
 * deployment, not just in the unit-level slot-word tests.
 *
 * What happens: pushes a slot word with `Date.now()` as its timestamp, then
 * pushes a second word with a timestamp 60s in the past; the contract must
 * accept the second transaction (no revert — staleness is not an error
 * condition) but leave storage unchanged; reads position 0 back and fails
 * loudly if the stale price (`1n`) or the older timestamp leaked through.
 *
 * Env: RPC_URL, COMPRESSED_ORACLE_ADDRESS, PUSHER_PRIVATE_KEY, SLOT_INDEX, [CREATOR_ADDRESS]
 * Run: npx tsx demo/assert-stale-ignored.ts
 *
 * Place in the package: run by `demo/anvil-demo.sh` right after script 03,
 * against the same slot script 03 just populated.
 */
import type { Address, Hex } from '../src/common/types.js';
import { packSlotWord, type Lane } from '../src/compressed/slot.js';
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
const creator = envOr('CREATOR_ADDRESS', clients.wallet!.address) as Address;

const fresh: [Lane, Lane, Lane, Lane] = [
  { price: 7000000000000n, spread0: 1000, spread1: 1000 }, // 0.01-bps units: 1000 = 10 bp
  'empty',
  'empty',
  'empty',
];
const stale: [Lane, Lane, Lane, Lane] = [
  { price: 1n, spread0: 0, spread1: 0 },
  'empty',
  'empty',
  'empty',
];
const tFresh = BigInt(Date.now());
const tStale = tFresh - 60_000n;

await pushSlots(clients, oracle, [packSlotWord(fresh, tFresh, slotIndex)]);
const staleReceipt = await pushSlots(clients, oracle, [packSlotWord(stale, tStale, slotIndex)]);
console.log(`stale push tx ${staleReceipt.hash} succeeded (as expected — silently ignored)`);

const feedId = feedIdOf(creator, clients.chainId, slotIndex, 0);
const data = await readOracleData(clients.provider, oracle, feedId);
if (data.timestampMs !== tFresh || data.price === 1n) {
  console.error('FAILED: stale word was NOT ignored', data);
  process.exit(1);
}
console.log(`stale-ignore semantics verified: on-chain ts ${data.timestampMs} == fresh ${tFresh}`);
