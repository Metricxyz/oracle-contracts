// SPDX-License-Identifier: MIT
/**
 * Prints the registrationless feedIds for a creator's slot — one per position (0..3).
 * There is NO registration step: a feed exists once its first update lands.
 * With RPC_URL set, cross-checks every derived id against the on-chain feedIdOf().
 *
 * Purpose: the entry point an integrator runs FIRST — before pushing anything
 * — to learn the exact feedId(s) their (creator, slot) namespace will use,
 * so downstream consumers can be configured with the right id ahead of time.
 *
 * What happens: derives `creator` either from `CREATOR_ADDRESS` directly or
 * from `CREATOR_PRIVATE_KEY` via `new Wallet(pk).address`; if `RPC_URL` is
 * unset, prints the 4 locally-derived feedIds (needs `CHAIN_ID` since there
 * is no chain to ask); if `RPC_URL` IS set, additionally calls the deployed
 * oracle's own `feedIdOf` for each position and exits non-zero on any
 * mismatch (a cheap sanity check that the local codec and the deployed
 * contract agree).
 *
 * Env: CREATOR_PRIVATE_KEY (or CREATOR_ADDRESS), SLOT_INDEX, [RPC_URL, COMPRESSED_ORACLE_ADDRESS, CHAIN_ID]
 * Run: npx tsx scripts/01-derive-feed-id.ts
 *
 * Place in the package: compressed lane, step 0 — read-only, no transaction
 * ever leaves this script.
 */
import { Wallet } from 'ethers';
import type { Address, Hex } from '../src/common/types.js';
import { feedIdOf } from '../src/compressed/feed-id.js';
import { readFeedIdOf } from '../src/compressed/oracle.js';
import { envInt, envOr, requireEnv } from '../src/common/env.js';
import { makeClients } from '../src/common/clients.js';

const creator: Address = process.env.CREATOR_ADDRESS
  ? (process.env.CREATOR_ADDRESS as Address)
  : new Wallet(requireEnv('CREATOR_PRIVATE_KEY') as Hex).address;
const slotIndex = envInt('SLOT_INDEX', 0);
const rpcUrl = envOr('RPC_URL', '');

if (!rpcUrl) {
  console.log(
    `creator ${creator}, slot ${slotIndex} (offline — set RPC_URL to cross-check on-chain):`,
  );
  // chainId must be known to derive an id; offline mode requires CHAIN_ID
  const chainId = envInt('CHAIN_ID', 0);
  if (!chainId) throw new Error('offline mode needs CHAIN_ID');
  for (let pos = 0; pos < 4; pos++)
    console.log(`  position ${pos}: ${feedIdOf(creator, chainId, slotIndex, pos)}`);
} else {
  const clients = await makeClients({ rpcUrl });
  const oracle = requireEnv('COMPRESSED_ORACLE_ADDRESS') as Address;
  console.log(`creator ${creator}, slot ${slotIndex}, chain ${clients.chainId}:`);
  for (let pos = 0; pos < 4; pos++) {
    const local = feedIdOf(creator, clients.chainId, slotIndex, pos);
    const onchain = await readFeedIdOf(clients.provider, oracle, creator, slotIndex, pos);
    if (local.toLowerCase() !== onchain.toLowerCase()) {
      console.error(`MISMATCH at position ${pos}: local ${local} != on-chain ${onchain}`);
      process.exit(1);
    }
    console.log(`  position ${pos}: ${local} (verified on-chain)`);
  }
}
