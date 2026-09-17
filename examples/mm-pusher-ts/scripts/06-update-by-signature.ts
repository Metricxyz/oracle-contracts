// SPDX-License-Identifier: MIT
/**
 * Relay path: the CREATOR signs the slot word offline; ANY key can submit it.
 * The word carries its own timestamp — a stale one makes updateBySignature return
 * false (no revert), so we simulate first and report honestly.
 *
 * Purpose: demonstrate the "creator signs, a relayer submits" alternative to
 * scripts 03/04's direct push — useful when the creator's key must stay
 * offline entirely and only ever produces signatures.
 *
 * What happens: builds a standalone, provider-less `Wallet` for the creator
 * (signs only, never sends) from `CREATOR_PRIVATE_KEY`; packs one lane into a
 * slot word, signs its `slotUpdateDigest`; a SEPARATE `PUSHER_PRIVATE_KEY`-
 * connected `Clients` relays it via `updateBySignature`, which simulates
 * first (a stale word returns `{ accepted: false }` with no gas spent and no
 * revert) and only sends the real transaction if the simulate says it will
 * be accepted; finally reads position 0 back to confirm the timestamp landed.
 *
 * Env: RPC_URL, COMPRESSED_ORACLE_ADDRESS, CREATOR_PRIVATE_KEY, PUSHER_PRIVATE_KEY, SLOT_INDEX
 * Run: npx tsx scripts/06-update-by-signature.ts
 *
 * Place in the package: compressed lane, alternative write path to scripts
 * 03/04 — exercised by `demo/anvil-demo.sh` as its own scenario.
 */
import { Wallet } from 'ethers';
import type { Address, Hex } from '../src/common/types.js';
import { packSlotWord, type Lane } from '../src/compressed/slot.js';
import { feedIdOf } from '../src/compressed/feed-id.js';
import {
  readOracleData,
  signDigest,
  slotUpdateDigest,
  updateBySignature,
} from '../src/compressed/oracle.js';
import { envInt, requireEnv } from '../src/common/env.js';
import { makeClients } from '../src/common/clients.js';

const oracle = requireEnv('COMPRESSED_ORACLE_ADDRESS') as Address;
const slotIndex = envInt('SLOT_INDEX', 0);
const creator = new Wallet(requireEnv('CREATOR_PRIVATE_KEY') as Hex); // signs, does NOT send
const clients = await makeClients({
  rpcUrl: requireEnv('RPC_URL'),
  privateKey: requireEnv('PUSHER_PRIVATE_KEY') as Hex, // the relayer
});

const lanes: [Lane, Lane, Lane, Lane] = [
  { price: 6600000000000n, spread0: 2000, spread1: 2000 }, // 0.01-bps units: 2000 = 20 bp
  'empty',
  'empty',
  'empty',
];
const timestampMs = BigInt(Date.now());
const word = BigInt(packSlotWord(lanes, timestampMs, slotIndex));

const digest = slotUpdateDigest(BigInt(clients.chainId), oracle, creator.address, word);
const signature = await signDigest(creator, digest);

const { accepted, receipt } = await updateBySignature(
  clients,
  oracle,
  creator.address,
  word,
  signature,
);
if (!accepted) {
  console.error('update rejected as stale (on-chain timestamp is newer) — nothing was sent');
  process.exit(1);
}
console.log(`relayed in tx ${receipt!.hash}`);

const feedId = feedIdOf(creator.address, clients.chainId, slotIndex, 0);
const data = await readOracleData(clients.provider, oracle, feedId);
if (data.timestampMs !== timestampMs) {
  console.error(`FAILED: readback ts ${data.timestampMs} != ${timestampMs}`);
  process.exit(1);
}
console.log(`signed update verified: position 0 price ${data.price}, ts ${data.timestampMs}`);
