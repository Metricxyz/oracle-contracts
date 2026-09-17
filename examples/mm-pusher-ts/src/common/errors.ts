// SPDX-License-Identifier: MIT
/**
 * Maps known custom-error selectors of the oracles to actionable diagnostics.
 *
 * Purpose: turn an opaque revert (`0x1234abcd`) surfaced by a failed push or
 * simulate call into a human-readable hint, so operators of the pusher loops
 * (`scripts/04-run-pusher.ts`, `scripts/11-pyth-run-pusher.ts`) get something
 * actionable in their logs instead of a raw ethers error dump.
 *
 * What happens inside: builds a `selector -> hint` table once at module load
 * by keccak256-hashing each known Solidity custom-error signature (same
 * derivation the EVM itself uses for the selector, `keccak256(sig)[:4]`).
 * `describeRevert` then walks the error object handed to it looking for a
 * hex revert-data string it can match against that table.
 *
 * ethers v6's error shapes need their own walk (different from the previous
 * client library's): a `CallExceptionError` normally carries the revert data
 * directly on `.data`, but some paths (raw JSON-RPC failures ethers could
 * not fully decode into a `CallExceptionError`, e.g. during gas estimation)
 * instead nest it under `.info.error.data`. Some wrapped errors expose the
 * underlying cause via `.cause`, others via `.error` — this walk checks both
 * chain links at each step so it does not matter which ethers happened to
 * use for a given failure mode.
 *
 * Inputs/outputs/env: `describeRevert(err: unknown): string` — no env, pure
 * function of the caught error. Falls back to `err.message` (or `String(err)`
 * for non-Error throws) when no known selector is found anywhere in the
 * chain.
 *
 * Place in the package: consumed by both production-skeleton loops
 * (`scripts/04-run-pusher.ts`, `scripts/11-pyth-run-pusher.ts`) to annotate
 * retry-loop failure logs.
 */
import { keccak256, toUtf8Bytes } from 'ethers';

const KNOWN: Record<string, string> = {};
for (const [sig, hint] of [
  [
    'FutureTimestamp()',
    'timestamp ahead of chain time beyond the allowed drift — check NTP, retry',
  ],
  [
    'BadCalldataLength()',
    'push calldata must be one leading zero byte followed by N x 32-byte slot words (total 1 + 32N) — a payload without the zero-byte prefix hits this',
  ],
  ['FeedNotFound(bytes32)', 'feed has no data yet (or wrong chain / feedId)'],
  ['FeedIdMismatch(uint256,uint32,uint32)', 'calldata feed-id order != payload feed order'],
  ['FeedsLengthMismatch(uint256,uint256)', 'feed-id count != payload feed count'],
  ['UnexpectedPropsCount(uint256,uint256)', 'payload property set != the set the oracle expects'],
  ['UnknownProperty(uint8)', 'payload carries a property this oracle deployment does not accept'],
  ['InvalidMagic()', 'payload is not a Lazer-signed update'],
  ['NoSelfRemapping()', 'a key cannot delegate to itself'],
  ['InvalidGuard(address)', 'sender is not the guard authority for this feed'],
] as const) {
  KNOWN[keccak256(toUtf8Bytes(sig)).slice(0, 10)] = `${sig} — ${hint}`;
}

interface ErrLike {
  data?: unknown;
  info?: { error?: { data?: unknown } };
  cause?: unknown;
  error?: unknown;
}

export function describeRevert(err: unknown): string {
  for (let e = err as ErrLike | null; e; e = (e.cause ?? e.error) as ErrLike | null) {
    const candidates = [e.data, e.info?.error?.data];
    for (const c of candidates) {
      if (typeof c === 'string' && c.startsWith('0x') && c.length >= 10) {
        const known = KNOWN[c.slice(0, 10)];
        if (known) return known;
      }
    }
  }
  return err instanceof Error ? err.message : String(err);
}
