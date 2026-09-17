// SPDX-License-Identifier: MIT
/**
 * ethers v6 wrapper around PythOracle.
 *
 * Push: raw calldata [feedsLength:2][feedIds:4 each][lazer signed update] to the
 * contract's fallback(); the feed-id list MUST match the payload's feed order
 * (FeedIdMismatch otherwise). value = 0 — the 1-wei Lazer verification fee is paid
 * from the ORACLE's own balance (top up with a plain transfer; receive() is payable).
 *
 * Readback: PythOracle's public getters revert ReadDisabled(). The supported
 * off-chain read is an eth_call of price(feedId, address(0)) with NO from account:
 * under eth_call defaults tx.origin == address(0), which skips the pool gating.
 * price() is NON-view (it emits PriceRead), so this must stay a raw call — a
 * `Contract` bound to a `Wallet` (or one that lets ethers populate a `from`)
 * would break the from-less invariant, so this file never constructs one for
 * `price()`. refTime comes back in SECONDS.
 *
 * Purpose: mirror `src/compressed/oracle.ts`'s role but for the Pyth Lazer
 * relay lane — build the push calldata, relay it, and read the price back
 * through the one gated, from-less call path the contract allows.
 *
 * What happens inside: `buildPushCalldata` concatenates the fixed-width
 * feed-id-count/feed-id-list header in front of the already-signed envelope
 * (no ABI encoding — this, like the Lazer envelope itself, is a raw
 * concatenation format, not calldata for a named Solidity function);
 * `relayUpdate` sends that calldata as a plain value-less transaction via
 * `wallet.sendTransaction` (there is no function selector, same as the
 * compressed lane's push); `readPythPrice` manually
 * `Interface.encodeFunctionData`s the `price(feedId, address(0))` call,
 * issues it through `provider.call({ to, data })` (deliberately NOT a
 * `Contract` instance — that keeps the call provider-level with no `from`,
 * satisfying the tx.origin==0 gate), and `Interface.decodeFunctionResult`s
 * the raw return bytes; a `FeedNotFound` revert is caught and mapped to
 * `null` via `findRevertData`'s selector match, everything else rethrows.
 *
 * ethers-specific note: `spread1` is uint16 on the wire; ethers decodes ALL
 * ABI int/uint widths as `bigint` (there is no automatic narrowing to
 * `number` for small widths), so `readPythPrice` explicitly `Number()`-
 * narrows it to match the return type callers (scripts/10, scripts/11)
 * already expect.
 *
 * Inputs/outputs/env: every exported function takes `Clients` (or, for pure
 * reads, a `Provider`) plus the oracle address and function-specific
 * arguments. No env vars are read directly here — callers own env parsing.
 *
 * Place in the package: consumed by `scripts/10-pyth-push-once.ts` and
 * `scripts/11-pyth-run-pusher.ts` (both share `relayUpdate` as their common
 * relay core) and by the demo's live FeedNotFound verification.
 */
import {
  concat,
  Interface,
  keccak256,
  toBeHex,
  toUtf8Bytes,
  ZeroAddress,
  type Provider,
  type TransactionReceipt,
} from 'ethers';
import type { Clients } from '../common/clients.js';
import type { Address, Hex } from '../common/types.js';

export const PYTH_PRICE_ABI = [
  'function price(bytes32 feedId, address pool) returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime)',
] as const;

const priceInterface = new Interface(PYTH_PRICE_ABI);
const FEED_NOT_FOUND_SELECTOR = keccak256(toUtf8Bytes('FeedNotFound(bytes32)')).slice(0, 10);

export function pythFeedIdToBytes32(feedId: number): Hex {
  if (!Number.isInteger(feedId) || feedId < 0 || feedId > 0xffffffff) {
    throw new RangeError(`pyth: feed id ${feedId} is not a uint32`);
  }
  return toBeHex(feedId, 32) as Hex;
}

export function buildPushCalldata(feedIds: number[], signedUpdate: Hex): Hex {
  if (feedIds.length === 0 || feedIds.length > 0xffff)
    throw new RangeError('pyth: 1..65535 feed ids');
  return concat([
    toBeHex(feedIds.length, 2),
    ...feedIds.map((id) => toBeHex(id, 4)),
    signedUpdate,
  ]) as Hex;
}

/** The shared relay core used by both 10-pyth-push-once and 11-pyth-run-pusher. */
export async function relayUpdate(
  clients: Clients,
  oracle: Address,
  feedIds: number[],
  signedUpdate: Hex,
): Promise<TransactionReceipt> {
  if (!clients.wallet) throw new Error('a private key is required to relay');
  const tx = await clients.wallet.sendTransaction({
    to: oracle,
    data: buildPushCalldata(feedIds, signedUpdate),
  });
  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`relay transaction ${tx.hash} reverted`);
  return receipt;
}

export async function readPythPrice(
  provider: Provider,
  oracle: Address,
  feedId: number,
): Promise<{ mid: bigint; spread0: bigint; spread1: number; refTimeSec: bigint } | null> {
  const data = priceInterface.encodeFunctionData('price', [
    pythFeedIdToBytes32(feedId),
    ZeroAddress,
  ]);
  try {
    const out = await provider.call({ to: oracle, data }); // NOTE: no `from` — provider-level call
    if (!out || out === '0x') throw new Error('pyth: empty result from price()');
    const [mid, spread, spread1, refTime] = priceInterface.decodeFunctionResult('price', out);
    return {
      mid: mid as bigint,
      spread0: spread as bigint,
      // uint16 on the wire: ethers decodes as bigint, narrow to number to match
      // the <=48-bit behavior the callers of this function expect.
      spread1: Number(spread1),
      refTimeSec: refTime as bigint,
    };
  } catch (err) {
    if (findRevertData(err)?.startsWith(FEED_NOT_FOUND_SELECTOR)) return null; // feed has no data yet
    throw err;
  }
}

interface ErrLike {
  data?: unknown;
  info?: { error?: { data?: unknown } };
  cause?: unknown;
  error?: unknown;
}

function findRevertData(err: unknown): string | null {
  for (let e = err as ErrLike | null; e; e = (e.cause ?? e.error) as ErrLike | null) {
    if (typeof e.data === 'string' && e.data.startsWith('0x')) return e.data;
    const nested = e.info?.error?.data;
    if (typeof nested === 'string' && nested.startsWith('0x')) return nested;
  }
  return null;
}

export function getOracleBalance(provider: Provider, oracle: Address): Promise<bigint> {
  return provider.getBalance(oracle);
}
