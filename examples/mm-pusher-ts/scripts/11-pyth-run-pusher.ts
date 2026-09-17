// SPDX-License-Identifier: MIT
/**
 * PRODUCTION SKELETON — subscribe to Pyth Lazer over WebSocket and relay every signed
 * update into PythOracle. The relay core (relayUpdate) is exactly what script 10
 * exercises offline; this file only adds the WS shell. The feed-id list passed to
 * relayUpdate is derived from each update's own payload, not from env.
 *
 * On-chain monotonicity (per-feed signed FeedUpdateTimestamp) drops stale/duplicate
 * updates by itself, so the loop forwards everything without bookkeeping.
 * NOTE: verify the subscribe message shape against the current Pyth Lazer docs
 * before production use; the oracle's expected property set is exactly
 * price/exponent/confidence/feedUpdateTimestamp.
 *
 * What happens: opens a WebSocket to `LAZER_WS_URL`, subscribes to
 * `LAZER_FEED_IDS`, and on every message pushes the RAW `evm` payload onto a
 * one-slot queue (only the newest update is kept — the relay loop is
 * sequential and on-chain monotonicity makes skipped intermediates
 * harmless); the loop drains that queue one at a time, deriving each
 * update's own feed-id list from its payload and relaying via the same
 * `relayUpdate` core script 10 exercises offline, with the same exponential
 * backoff + alert-hook-after-5-failures pattern as script 04.
 *
 * Env: PYTH_ORACLE_ADDRESS, LAZER_WS_URL, LAZER_ACCESS_TOKEN, RPC_URL,
 * PUSHER_PRIVATE_KEY, [LAZER_FEED_IDS, MAX_ITERATIONS, MIN_ORACLE_BALANCE_WEI]
 * Run: npx tsx scripts/11-pyth-run-pusher.ts
 *
 * Place in the package: pyth lane, the production-shaped counterpart to
 * script 10's one-shot walkthrough. Not runnable offline (needs a live
 * Lazer WS endpoint) — `demo/anvil-demo.sh` exercises script 10 instead.
 */
import WebSocket from 'ws';
import type { Address, Hex } from '../src/common/types.js';
import { parseEnvelope, parsePayload } from '../src/pyth/lazer.js';
import { getOracleBalance, relayUpdate } from '../src/pyth/oracle.js';
import { envInt, envOr, requireEnv } from '../src/common/env.js';
import { makeClients } from '../src/common/clients.js';
import { describeRevert } from '../src/common/errors.js';

const oracle = requireEnv('PYTH_ORACLE_ADDRESS') as Address;
const wsUrl = requireEnv('LAZER_WS_URL');
const token = requireEnv('LAZER_ACCESS_TOKEN');
const feedIds = envOr('LAZER_FEED_IDS', '1,2').split(',').map(Number);
const maxIterations = envInt('MAX_ITERATIONS', 0);
const minBalance = BigInt(envInt('MIN_ORACLE_BALANCE_WEI', 1000));
const clients = await makeClients({
  rpcUrl: requireEnv('RPC_URL'),
  privateKey: requireEnv('PUSHER_PRIVATE_KEY') as Hex,
});

let stopping = false;
process.on('SIGINT', () => (stopping = true));
process.on('SIGTERM', () => (stopping = true));

const balance = await getOracleBalance(clients.provider, oracle);
if (balance < minBalance) {
  console.error(
    `WARNING: oracle balance ${balance} wei < ${minBalance} — every push burns 1 wei; top up soon.`,
  );
}

const queue: Hex[] = [];
let relayed = 0;
// `ws` lib (not the global WebSocket): the global ignores `headers`, dropping the Bearer token.
const ws = new WebSocket(wsUrl, { headers: { authorization: `Bearer ${token}` } });
ws.addEventListener('open', () => {
  ws.send(
    JSON.stringify({
      type: 'subscribe',
      subscriptionId: 1,
      priceFeedIds: feedIds,
      properties: ['price', 'exponent', 'confidence', 'feedUpdateTimestamp'],
      formats: ['evm'],
      // HEX, not the base64 default — see the note in 10-pyth-push-once.ts.
      jsonBinaryEncoding: 'hex',
      channel: 'real_time',
    }),
  );
  console.log(`subscribed to lazer feeds [${feedIds}]`);
});
ws.addEventListener('message', (ev) => {
  try {
    const msg = JSON.parse(String(ev.data)) as {
      type?: string;
      evm?: { data?: string; encoding?: string };
    };
    const raw = msg.evm?.data;
    if (!raw) return; // heartbeats / acks
    const hex =
      msg.evm?.encoding === 'base64'
        ? `0x${Buffer.from(raw, 'base64').toString('hex')}`
        : raw.startsWith('0x')
          ? raw
          : `0x${raw}`;
    queue.push(hex as Hex);
  } catch {
    /* non-JSON frame — ignore */
  }
});
ws.addEventListener('close', (ev) => {
  console.error(`lazer ws closed (${ev.code}) — exiting; run under a supervisor that restarts`);
  stopping = true;
});
ws.addEventListener('error', (ev) =>
  console.error('lazer ws error:', (ev as { message?: string }).message ?? ev),
);

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
let consecutiveFailures = 0;
// SEQUENTIAL relay: one in-flight tx; the queue keeps only the newest pending update
// (on-chain monotonicity makes skipped intermediates harmless).
while (!stopping && (maxIterations === 0 || relayed < maxIterations)) {
  const update = queue.pop(); // newest
  queue.length = 0; //           drop older ones
  if (!update) {
    await sleep(50);
    continue;
  }
  try {
    const ids = parsePayload(parseEnvelope(update).payload).feeds.map((f) => f.feedId);
    const receipt = await relayUpdate(clients, oracle, ids, update);
    relayed += 1;
    consecutiveFailures = 0;
    console.log(`[${relayed}] relayed tx=${receipt.hash}`);
  } catch (err) {
    consecutiveFailures += 1;
    const backoffMs = Math.min(30_000, 1000 * 2 ** Math.min(consecutiveFailures, 5));
    console.error(
      `relay failed (${consecutiveFailures} in a row), backing off ${backoffMs}ms: ${describeRevert(err)}`,
    );
    if (consecutiveFailures >= 5) console.error('ALERT: pyth relay failing repeatedly'); // HOOK POINT
    await sleep(backoffMs);
  }
}
ws.close();
console.log('relay stopped cleanly.');
