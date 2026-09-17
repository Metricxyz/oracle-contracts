// SPDX-License-Identifier: MIT
/**
 * ethers v6 wrapper around `ChainlinkOracle` (Data Streams lane).
 *
 * Push: `updateReport(bytes taggedReport)` — a normal Solidity call (unlike the
 * compressed/pyth lanes' selector-less fallback pushes, this one IS ABI-encoded
 * against a named function). The `bytes` argument is a ONE-BYTE version tag followed
 * by the DON `fullReport`: `taggedReport = <tag> || <fullReport>`. The tag selects
 * which Chainlink VerifierProxy version the oracle routes the payload to (v0.5.0 vs
 * v0.5.1); it is detected off-chain (per feed / per deployment) and prepended here.
 * The DON signature inside `fullReport` is the only trust anchor (the oracle verifies
 * it via the routed VerifierProxy), so ANYONE can relay a genuine report. value = 0 —
 * the on-chain verification fee is a `0` constant on this deployment.
 *
 * Readback: like the other lanes, `ChainlinkOracle`'s public getters revert
 * `ReadDisabled()`; the supported off-chain read is a from-less `eth_call` of
 * `price(feedId, address(0))` — under eth_call defaults `tx.origin == address(0)`,
 * which skips the pool gating. `price()` is NON-view (it emits `PriceRead`), so
 * this stays a raw `provider.call` and never binds a `Contract`/`Wallet` that
 * would let ethers populate a `from`. `refTime` comes back in SECONDS; `mid` is
 * the 8-decimal price (Data Streams' 18-decimal benchmark ÷ 1e10).
 *
 * Purpose: mirror `src/pyth/oracle.ts`'s role for the Chainlink lane — build the
 * push calldata, relay it, and read the price back through the one gated,
 * from-less call path the contract allows. `feedId` here is the full 32-byte Data
 * Streams feed id (not a uint32 like the Pyth lane).
 *
 * Inputs/outputs/env: every exported function takes `Clients` (or a `Provider`
 * for pure reads) plus the oracle address; no env vars are read here.
 *
 * Place in the package: consumed by `scripts/20-chainlink-push-once.ts` and
 * `scripts/21-chainlink-run-pusher.ts`, which share `relayReport` as their relay
 * core (exactly as the Pyth scripts share `relayUpdate`).
 */
import {
  Interface,
  keccak256,
  toUtf8Bytes,
  ZeroAddress,
  type Provider,
  type TransactionReceipt,
} from 'ethers';
import type { Clients } from '../common/clients.js';
import type { Address, Hex } from '../common/types.js';

export const CHAINLINK_ORACLE_ABI = [
  'function updateReport(bytes fullReport)',
  'function price(bytes32 feedId, address pool) returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime)',
] as const;

const oracleInterface = new Interface(CHAINLINK_ORACLE_ABI);
const FEED_NOT_FOUND_SELECTOR = keccak256(toUtf8Bytes('FeedNotFound(bytes32)')).slice(0, 10);

/** Default VerifierProxy version tag (v0.5.0 payable path). Mirrors ChainlinkOracle.TAG_V050. */
export const TAG_V050 = 0x50;
/** v0.5.1 gasless verifyView path. Mirrors ChainlinkOracle.TAG_V051. */
export const TAG_V051 = 0x51;

/** Prefix a full report with a one-byte version tag → the `bytes` the oracle routes on. */
export function tagReport(fullReport: Hex, tag: number = TAG_V050): Hex {
  const tagHex = (tag & 0xff).toString(16).padStart(2, '0');
  return `0x${tagHex}${fullReport.slice(2)}` as Hex;
}

/** ABI-encoded `updateReport(<tag> || fullReport)` calldata. */
export function buildUpdateCalldata(fullReport: Hex, tag: number = TAG_V050): Hex {
  return oracleInterface.encodeFunctionData('updateReport', [tagReport(fullReport, tag)]) as Hex;
}

/** The shared relay core used by both 20-chainlink-push-once and 21-chainlink-run-pusher. */
export async function relayReport(
  clients: Clients,
  oracle: Address,
  fullReport: Hex,
  tag: number = TAG_V050,
): Promise<TransactionReceipt> {
  if (!clients.wallet) throw new Error('a private key is required to relay');
  const tx = await clients.wallet.sendTransaction({
    to: oracle,
    data: buildUpdateCalldata(fullReport, tag),
  });
  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`relay transaction ${tx.hash} reverted`);
  return receipt;
}

export async function readChainlinkPrice(
  provider: Provider,
  oracle: Address,
  feedId: Hex,
): Promise<{ mid: bigint; spread0: bigint; spread1: number; refTimeSec: bigint } | null> {
  const data = oracleInterface.encodeFunctionData('price', [feedId, ZeroAddress]);
  try {
    const out = await provider.call({ to: oracle, data }); // NOTE: no `from` — provider-level call
    if (!out || out === '0x') throw new Error('chainlink: empty result from price()');
    const [mid, spread, spread1, refTime] = oracleInterface.decodeFunctionResult('price', out);
    return {
      mid: mid as bigint,
      spread0: spread as bigint,
      // uint16 on the wire: ethers decodes as bigint, narrow to number to match callers.
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
