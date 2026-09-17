// SPDX-License-Identifier: MIT
/**
 * ethers v6 client plumbing — the ONE place every script/demo/test builds its
 * provider + (optional) wallet from an RPC URL and an optional private key.
 *
 * Purpose: build the two ethers v6 primitives (`JsonRpcProvider`, `Wallet`)
 * every read/write path in this package needs, from one `{ rpcUrl,
 * privateKey? }` options bag. ethers does not need a `Chain` descriptor the
 * way the previous client-library generation did — `Wallet` signs against
 * whatever `chainId` the provider reports, so there is no synthesized-chain
 * object or `chain` field to carry around (the `Clients` interface here has
 * no `chain` field, only the narrowed `chainId` number).
 *
 * What happens inside `makeClients`: opens a `JsonRpcProvider` against
 * `opts.rpcUrl` with its low-level read-result cache DISABLED
 * (`cacheTimeout: -1` — see note below), awaits `provider.getNetwork()` once
 * (this both confirms the RPC is reachable and forces ethers' lazy network
 * detection to resolve before any caller touches the provider), narrows
 * `chainId` to a plain `number` via `Number()`, and — only if
 * `opts.privateKey` was supplied — constructs a `Wallet` connected to that
 * same provider so every write path (`sendTransaction`,
 * `contract.method(...)`) is chain-aware from the start.
 *
 * WHY `cacheTimeout: -1`: by default ethers v6 caches the result of a
 * low-level provider call (including `getTransactionCount(address,
 * "pending")`, which is how `Wallet.sendTransaction` looks up the nonce
 * when one isn't supplied) for 250ms, to dedupe genuinely-concurrent
 * identical calls. Against a chain that mines instantly (anvil's default),
 * two sequential `pushSlots`/relay calls from the SAME wallet can complete
 * an entire send-then-`wait()` round trip in well under 250ms, so the
 * second call's nonce lookup hits the FIRST call's now-stale cached nonce
 * and the transaction is rejected as `NONCE_EXPIRED`. This surfaced
 * concretely in `demo/assert-stale-ignored.ts` (two back-to-back pushes
 * from one pusher key) during the migration to ethers v6 — it did not
 * exist in the pre-migration client, which had no such cache. Disabling the
 * cache trades a small amount of RPC round-trip efficiency for always
 * reading current on-chain state, which matters far more for a
 * transaction-sequencing example than shaving a few requests.
 *
 * Inputs/outputs/env: takes `{ rpcUrl, privateKey? }`; no env vars are read
 * directly here (callers pass `RPC_URL`/`*_PRIVATE_KEY` in from `env.ts`).
 * Returns a `Clients` object: `provider` (always present), `wallet` (`null`
 * when no private key was given — read-only scripts run this way), and the
 * narrowed `chainId`.
 *
 * Place in the package: every script under `scripts/`, every `demo/*.ts`
 * entry point, and both oracle wrappers (`src/compressed/oracle.ts`,
 * `src/pyth/oracle.ts`) consume `Clients` instead of building an ethers
 * provider/wallet themselves.
 */
import { JsonRpcProvider, Wallet } from 'ethers';
import type { Hex } from './types.js';

export interface Clients {
  provider: JsonRpcProvider;
  wallet: Wallet | null; // connected to provider
  chainId: number;
}

export async function makeClients(opts: { rpcUrl: string; privateKey?: Hex }): Promise<Clients> {
  // cacheTimeout: -1 disables ethers' internal short-lived read-result cache —
  // see the WHY note above (avoids a stale-nonce race on fast-mining chains).
  const provider = new JsonRpcProvider(opts.rpcUrl, undefined, { cacheTimeout: -1 });
  const network = await provider.getNetwork();
  const chainId = Number(network.chainId);
  const wallet = opts.privateKey ? new Wallet(opts.privateKey, provider) : null;
  return { provider, wallet, chainId };
}
