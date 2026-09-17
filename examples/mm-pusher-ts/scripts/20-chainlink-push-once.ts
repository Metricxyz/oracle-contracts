// SPDX-License-Identifier: MIT
/**
 * EDUCATIONAL walkthrough — relay ONE Chainlink Data Streams report into ChainlinkOracle.
 *
 * The relayer never signs price data: the DON signature inside `fullReport` is the only
 * trust anchor, and ANYONE can relay a genuine report. There is no on-chain fee — the
 * oracle verifies the report through the Data Streams VerifierProxy.
 *
 * What happens: fetches the latest signed report for one feed from the Data Streams REST
 * API (HMAC auth); relays it via `relayReport`; then reads the feed back through the gated
 * from-less `price()` call and cross-checks the on-chain mid/refTime against the report's
 * own decoded benchmark price and observation time.
 *
 * Env: CHAINLINK_ORACLE_ADDRESS, RPC_URL, PUSHER_PRIVATE_KEY, DATA_STREAMS_REST_URL,
 * DATA_STREAMS_API_KEY, DATA_STREAMS_API_SECRET, CHAINLINK_FEED_ID
 * Run: npx tsx scripts/20-chainlink-push-once.ts
 *
 * Place in the package: chainlink lane, the one-shot counterpart to script 21's WS loop;
 * both share `relayReport` from `src/chainlink/oracle.ts` as their relay core.
 */
import type { Address, Hex } from '../src/common/types.js';
import { makeClients } from '../src/common/clients.js';
import { requireEnv } from '../src/common/env.js';
import {
  decodeReport,
  fetchLatestReport,
  refTimeSecondsOf,
  type StreamsConfig,
} from '../src/chainlink/streams.js';
import { readChainlinkPrice, relayReport, TAG_V050 } from '../src/chainlink/oracle.js';

const PRICE_SCALE = 10n ** 10n; // Data Streams 18-dec → oracle 8-dec

const oracle = requireEnv('CHAINLINK_ORACLE_ADDRESS') as Address;
const feedId = requireEnv('CHAINLINK_FEED_ID') as Hex;
// VerifierProxy version tag (hex byte) the oracle routes on; default v0.5.0. Detected off-chain
// per feed/deployment — set CL_VERIFIER_TAG=51 for a v0.5.1 (verifyView) proxy.
const verifierTag = process.env.CL_VERIFIER_TAG
  ? Number.parseInt(process.env.CL_VERIFIER_TAG, 16)
  : TAG_V050;
const streams: StreamsConfig = {
  apiKey: requireEnv('DATA_STREAMS_API_KEY'),
  apiSecret: requireEnv('DATA_STREAMS_API_SECRET'),
  restUrl: requireEnv('DATA_STREAMS_REST_URL'),
  wsUrl: '', // unused in push-once
};
const clients = await makeClients({
  rpcUrl: requireEnv('RPC_URL'),
  privateKey: requireEnv('PUSHER_PRIVATE_KEY') as Hex,
});

// ── 1. fetch the latest SIGNED report ──
const report = await fetchLatestReport(streams, feedId);
const decoded = decodeReport(report.fullReport);
console.log(
  `fetched ${decoded.resolution} report for ${decoded.feedId} ` +
    `(obs ${decoded.observationsTimestamp}, benchmark ${decoded.benchmarkPrice})`,
);

// ── 2. relay ──
const receipt = await relayReport(clients, oracle, report.fullReport, verifierTag);
console.log(`relayed in tx ${receipt.hash} (gas ${receipt.gasUsed})`);

// ── 3. verify through the gated read path (price normalized to 8 decimals) ──
const got = await readChainlinkPrice(clients.provider, oracle, decoded.feedId);
if (!got) {
  console.error(`feed ${decoded.feedId}: still FeedNotFound after the push`);
  process.exit(1);
}
const wantMid = decoded.benchmarkPrice / PRICE_SCALE; // 18-dec → 8-dec
const wantRefSec = refTimeSecondsOf(decoded);
const ok = got.mid === wantMid && got.refTimeSec === wantRefSec;
if (!ok) {
  console.error(`feed ${decoded.feedId}: readback mismatch`, {
    want: { wantMid, wantRefSec },
    got,
  });
  process.exit(1);
}
console.log(
  `feed ${decoded.feedId} verified: mid ${got.mid}, spread0 ${got.spread0} (0.01-bps), ref ${got.refTimeSec}s`,
);
process.exit(0);
