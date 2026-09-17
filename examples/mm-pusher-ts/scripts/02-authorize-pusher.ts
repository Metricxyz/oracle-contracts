// SPDX-License-Identifier: MIT
/**
 * OPTIONAL delegation step: lets a hot PUSHER key push into the CREATOR's namespace.
 * Without it a key simply pushes into its own namespace (zero-setup default).
 * The pusher signs an EIP-191 consent (with a mandatory deadline); the CREATOR sends
 * allowPushers. Verifies namespaceRemapping[pusher] == creator afterwards.
 *
 * Purpose: wire up the "hot pusher key pushes on behalf of a cold creator
 * key" topology used by the rest of the compressed-lane demo (scripts 03/04
 * push AS the pusher, but the words land in the creator's namespace).
 *
 * What happens: builds a standalone, provider-less `Wallet` for the pusher
 * (it only needs to sign, never to send here) from `PUSHER_PRIVATE_KEY`;
 * that wallet signs the `pusherConsentDigest` (EIP-191 personal-sign, so the
 * signature only becomes valid once the on-chain `toEthSignedMessageHash`
 * wrapping is applied); the CREATOR-connected `Clients` then sends
 * `allowPushers` with that signature; finally reads `namespaceRemapping`
 * back to confirm the delegation took effect on-chain.
 *
 * Env: RPC_URL, COMPRESSED_ORACLE_ADDRESS, CREATOR_PRIVATE_KEY, PUSHER_PRIVATE_KEY
 * Run: npx tsx scripts/02-authorize-pusher.ts
 *
 * Place in the package: compressed lane, step 1 (optional) — run once before
 * script 03/04 if you want a separate hot pusher key.
 */
import { Wallet } from 'ethers';
import type { Address, Hex } from '../src/common/types.js';
import {
  allowPushers,
  pusherConsentDigest,
  readNamespaceRemapping,
  signDigest,
} from '../src/compressed/oracle.js';
import { requireEnv } from '../src/common/env.js';
import { makeClients } from '../src/common/clients.js';

const oracle = requireEnv('COMPRESSED_ORACLE_ADDRESS') as Address;
const clients = await makeClients({
  rpcUrl: requireEnv('RPC_URL'),
  privateKey: requireEnv('CREATOR_PRIVATE_KEY') as Hex, // the CREATOR sends the tx
});
const pusher = new Wallet(requireEnv('PUSHER_PRIVATE_KEY') as Hex);
const creator = clients.wallet!.address;
const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600); // consent valid 1h

const digest = pusherConsentDigest(
  BigInt(clients.chainId),
  oracle,
  deadline,
  pusher.address,
  creator,
);
const signature = await signDigest(pusher, digest); // signed by the PUSHER (consent)

console.log(`delegating pusher ${pusher.address} -> creator namespace ${creator} ...`);
await allowPushers(clients, oracle, deadline, [pusher.address], [signature]);

const mapped = await readNamespaceRemapping(clients.provider, oracle, pusher.address);
if (mapped.toLowerCase() !== creator.toLowerCase()) {
  console.error(`FAILED: namespaceRemapping[${pusher.address}] = ${mapped}, expected ${creator}`);
  process.exit(1);
}
console.log('delegation verified on-chain.');
