// SPDX-License-Identifier: MIT
/**
 * PRODUCTION SKELETON — subscribe to Chainlink Data Streams over WebSocket and relay every
 * signed report into ChainlinkOracle. The relay core (`relayReport`) is exactly what script
 * 20 exercises against a single REST-fetched report; this file only adds the WS shell.
 *
 * High Frequency Streams ("Streams Ultra") push a report every ~40-50ms with millisecond
 * timestamps — WS only. The oracle stores the newest report per feed, so a sequential relay
 * that keeps only the latest queued report per feed is safe (skipped intermediates are
 * harmless). NOTE: verify the subscribe/frame shape against the current Data Streams docs
 * before production use; HA/v2 accounts use the `/api/v2/ws` endpoint.
 *
 * Env: CHAINLINK_ORACLE_ADDRESS, RPC_URL, PUSHER_PRIVATE_KEY, DATA_STREAMS_WS_URL,
 * DATA_STREAMS_API_KEY, DATA_STREAMS_API_SECRET, CHAINLINK_FEED_IDS, [MAX_ITERATIONS]
 * Run: npx tsx scripts/21-chainlink-run-pusher.ts
 *
 * Place in the package: chainlink lane, the production-shaped counterpart to script 20's
 * one-shot walkthrough. Not runnable offline (needs a live Data Streams WS endpoint).
 */
import type { Address, Hex } from '../src/common/types.js';
import { makeClients } from '../src/common/clients.js';
import { describeRevert } from '../src/common/errors.js';
import { envInt, requireEnv } from '../src/common/env.js';
import { decodeReport, streamReports, type StreamsConfig } from '../src/chainlink/streams.js';
import { relayReport, TAG_V050 } from '../src/chainlink/oracle.js';

const oracle = requireEnv('CHAINLINK_ORACLE_ADDRESS') as Address;
const feedIds = requireEnv('CHAINLINK_FEED_IDS')
  .split(',')
  .map((s) => s.trim() as Hex);
const maxIterations = envInt('MAX_ITERATIONS', 0);
// VerifierProxy version tag (hex byte) the oracle routes on; default v0.5.0. If feeds in this run
// span multiple verifier versions, split them into separate pushers each with its own tag.
const verifierTag = process.env.CL_VERIFIER_TAG
  ? Number.parseInt(process.env.CL_VERIFIER_TAG, 16)
  : TAG_V050;
const streams: StreamsConfig = {
  apiKey: requireEnv('DATA_STREAMS_API_KEY'),
  apiSecret: requireEnv('DATA_STREAMS_API_SECRET'),
  restUrl: '', // unused in the WS loop
  wsUrl: requireEnv('DATA_STREAMS_WS_URL'),
};
const clients = await makeClients({
  rpcUrl: requireEnv('RPC_URL'),
  privateKey: requireEnv('PUSHER_PRIVATE_KEY') as Hex,
});

let stopping = false;
process.on('SIGINT', () => (stopping = true));
process.on('SIGTERM', () => (stopping = true));

// Newest pending report per feed id (skipped intermediates are harmless — the oracle keeps
// only the latest per feed).
const latest = new Map<string, Hex>();
const stop = streamReports(
  streams,
  feedIds,
  (fullReport) => {
    try {
      latest.set(decodeReport(fullReport).feedId.toLowerCase(), fullReport);
    } catch {
      /* undecodable frame — ignore */
    }
  },
  (code) => {
    console.error(
      `data streams ws closed (${code}) — exiting; run under a supervisor that restarts`,
    );
    stopping = true;
  },
);

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
let relayed = 0;
let consecutiveFailures = 0;
// SEQUENTIAL relay: one in-flight tx at a time; drain the newest report per feed.
while (!stopping && (maxIterations === 0 || relayed < maxIterations)) {
  const entry = latest.entries().next();
  if (entry.done) {
    await sleep(20);
    continue;
  }
  const [key, fullReport] = entry.value;
  latest.delete(key);
  try {
    const receipt = await relayReport(clients, oracle, fullReport, verifierTag);
    relayed += 1;
    consecutiveFailures = 0;
    console.log(`[${relayed}] relayed ${key} tx=${receipt.hash}`);
  } catch (err) {
    consecutiveFailures += 1;
    const backoffMs = Math.min(30_000, 1000 * 2 ** Math.min(consecutiveFailures, 5));
    console.error(
      `relay failed (${consecutiveFailures} in a row), backing off ${backoffMs}ms: ${describeRevert(err)}`,
    );
    if (consecutiveFailures >= 5) console.error('ALERT: chainlink relay failing repeatedly'); // HOOK POINT
    await sleep(backoffMs);
  }
}
stop();
console.log('relay stopped cleanly.');
