// SPDX-License-Identifier: MIT
/**
 * Codebook256 spread table — TS mirror of contracts/oracles/utils/Codebook256.sol.
 * codebook.json is a committed copy of the canonical source
 * contracts/oracles/compressed/codebook/'spread [0 .. 10000].json'; a vitest guard
 * asserts content equality, so the two cannot drift.
 *
 * UNITS: table values — and therefore the on-chain `spread0`/`spread1` fields they
 * decode into — are in **0.01-bps units** (100 = 1 bp), i.e. a fraction scaled by
 * 1e6. The table's maximum, 10000, is therefore **1%**, NOT 100%. This is the
 * canonical unit of the whole stack, not a compressed-lane quirk: PythOracle and
 * ChainlinkOracle share it (`SPREAD_SCALE = 1e6`) — the codebook is
 * consensus-critical and cannot be rescaled — and
 * `AnchoredPriceProvider` pins it in `ONE_SPREAD_UNIT_E18 = 1e12` (one unit = 1e12
 * on the 1e18 = 100% scale). Reading these as whole bps understates every spread
 * 100x, which quotes the LP inside the market — see the same warning
 * in `scripts/10-pyth-push-once.ts`.
 *
 * The table is NON-decreasing: strictly increasing up to index 251, then constant
 * 10000 for indices 251..255. Index 255 (0xFF) is reserved: a lane whose BOTH
 * spread bytes are 0xFF is the contract's STALL marker — `getOracleData` short-
 * circuits on it and reports `spread0 = spread1 = 65535` (STALL_SPREAD) with price
 * and timestamp zeroed, which halts every provider. It is not "a lane with a 10000
 * spread", so the encoder NEVER returns index 255 — 10000 encodes as index 251.
 *
 * Purpose: encode/decode the one-byte spread fields packed into each slot lane
 * (see `slot.ts`), using the same 256-entry lookup table the on-chain contract
 * uses, so a locally-encoded spread decodes to the exact value the contract will
 * report back.
 *
 * What happens inside: `codebook.json` is imported as a plain JS array (via
 * `resolveJsonModule`) and re-exported as `CODEBOOK`; `decodeSpreadIndex` is
 * a direct table lookup, `encodeSpread` is a binary search for the smallest
 * index whose table value is >= the requested value (a spread must never be
 * UNDERSTATED, so encoding always rounds up to the next entry).
 *
 * Inputs/outputs/env: `decodeSpreadIndex(index: number): number`,
 * `encodeSpread(units: number): number` (both throw `RangeError` on
 * out-of-domain input); `CODEBOOK` (readonly number[]) and
 * `STALL_SENTINEL_INDEX` (255) are exported for callers that need the raw
 * table or the sentinel value directly (e.g. `slot.ts`'s empty-lane packing).
 * No env vars, no network I/O — purely local table lookups.
 *
 * Place in the package: no client/RPC/ABI dependency, unaffected by the
 * ethers v6 client-library migration (header doc expanded here only);
 * consumed by `slot.ts` for lane packing/unpacking and directly by scripts
 * that display or validate spreads (e.g. `scripts/03-push-once.ts`).
 */
import table from './codebook.json';

export const CODEBOOK: readonly number[] = table as number[];
/** Index 255 (0xFF). Paired on BOTH lane bytes it is the contract's stall marker. */
export const STALL_SENTINEL_INDEX = 255;

export function decodeSpreadIndex(index: number): number {
  if (!Number.isInteger(index) || index < 0 || index > 255) {
    throw new RangeError(`codebook: index ${index} out of [0, 255]`);
  }
  return CODEBOOK[index];
}

/**
 * Smallest index whose table value is >= `units` (a spread is never understated).
 * `units` are 0.01 bps — 100 = 1 bp, 10000 = 1% (the table's ceiling), NOT whole bps.
 */
export function encodeSpread(units: number): number {
  if (!Number.isInteger(units) || units < 0 || units > 10_000) {
    throw new RangeError(`codebook: spread ${units} (0.01-bps units) out of [0, 10000]`);
  }
  let lo = 0;
  let hi = CODEBOOK.length - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (CODEBOOK[mid] < units) lo = mid + 1;
    else hi = mid;
  }
  return lo; // lower-bound: for units == 10000 this is 251, never the 255 stall sentinel
}
