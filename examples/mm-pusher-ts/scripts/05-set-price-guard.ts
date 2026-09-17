// SPDX-License-Identifier: MIT
/**
 * Sets the [min, max] price guard for one feed. Guard authority defaults to the feed's
 * CREATOR (decoded from the feedId) until an explicit state guard is accepted, so this
 * is signed with CREATOR_PRIVATE_KEY.
 *
 * Purpose: demonstrate the price-guard admin op — an optional on-chain
 * bound that makes the oracle revert reads/writes outside [min, max] for a
 * given feed (defense against a compromised or misbehaving pusher key).
 *
 * What happens: derives the target feedId for the creator's own (slot,
 * position) coordinate, sends `setPriceGuard`, then reads the guard back and
 * exits non-zero if it does not match what was just set.
 *
 * Env: RPC_URL, COMPRESSED_ORACLE_ADDRESS, CREATOR_PRIVATE_KEY, GUARD_MIN,
 * GUARD_MAX, [SLOT_INDEX, POSITION_INDEX]
 * Run: GUARD_MIN=5000000000000 GUARD_MAX=8000000000000 npx tsx scripts/05-set-price-guard.ts
 *
 * Place in the package: compressed lane, optional admin step — independent
 * of scripts 03/04/06, can be run before or after any push.
 */
import type { Address, Hex } from '../src/common/types.js';
import { feedIdOf } from '../src/compressed/feed-id.js';
import { readPriceGuard, setPriceGuard } from '../src/compressed/oracle.js';
import { envInt, requireEnv } from '../src/common/env.js';
import { makeClients } from '../src/common/clients.js';

const oracle = requireEnv('COMPRESSED_ORACLE_ADDRESS') as Address;
const clients = await makeClients({
  rpcUrl: requireEnv('RPC_URL'),
  privateKey: requireEnv('CREATOR_PRIVATE_KEY') as Hex,
});
const feedId = feedIdOf(
  clients.wallet!.address,
  clients.chainId,
  envInt('SLOT_INDEX', 0),
  envInt('POSITION_INDEX', 0),
);
const min = BigInt(requireEnv('GUARD_MIN'));
const max = BigInt(requireEnv('GUARD_MAX'));

await setPriceGuard(clients, oracle, feedId, min, max);
const guard = await readPriceGuard(clients.provider, oracle, feedId);
if (guard.min !== min || guard.max !== max) {
  console.error('FAILED: guard readback mismatch', guard);
  process.exit(1);
}
console.log(`price guard verified for ${feedId}: [${min}, ${max}]`);
