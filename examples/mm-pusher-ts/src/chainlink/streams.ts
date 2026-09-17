// SPDX-License-Identifier: MIT
/**
 * Chainlink Data Streams client — HMAC auth + the two ways to obtain a
 * DON-signed report blob (`fullReport`) to relay into `ChainlinkOracle`.
 *
 * Auth: Data Streams uses the same HMAC-SHA256 scheme for REST and WebSocket.
 * The signature is taken over `"<METHOD> <path> <sha256(body)> <apiKey> <tsMs>"`
 * and sent in three headers (`Authorization`, `X-Authorization-Timestamp`,
 * `X-Authorization-Signature-SHA256`). Your Streams "User ID" is the apiKey and
 * your Streams "Secret" is the apiSecret.
 *
 * Two report sources, mirroring the Pyth lane's file/HTTPS split:
 *   - `fetchLatestReport(cfg, feedId)` — one-shot REST GET of the latest report
 *     (used by `scripts/20-chainlink-push-once.ts`).
 *   - `streamReports(cfg, feedIds, onReport)` — WebSocket subscription that calls
 *     `onReport(fullReport)` for every frame (used by the run-pusher skeleton).
 *     HFS ("Streams Ultra", ms cadence) feeds are WS-only; standard feeds work on
 *     both. NOTE: the WS frame shape can differ by API version — verify against the
 *     current Data Streams docs before production use.
 *
 * `fullReport` is exactly the blob `ChainlinkOracle.updateReport` forwards to the
 * VerifierProxy — the DON signature inside it is the only trust anchor, so ANYONE
 * can relay it. `decodeReport` peeks the same fields the contract decodes so a
 * caller can cross-check the on-chain read-back.
 *
 * No env vars are read here — callers pass a `StreamsConfig` built from env.
 */
import { createHash, createHmac } from 'node:crypto';
import WebSocket from 'ws';
import { AbiCoder } from 'ethers';
import type { Hex } from '../common/types.js';

export interface StreamsConfig {
  apiKey: string; // Streams "User ID"
  apiSecret: string; // Streams "Secret"
  restUrl: string; // e.g. https://api.dataengine.chain.link
  wsUrl: string; // e.g. wss://ws.dataengine.chain.link
}

const abi = AbiCoder.defaultAbiCoder();

/** HMAC-SHA256 auth headers for a Data Streams REST/WS request (empty body for GET/upgrade). */
export function authHeaders(
  method: string,
  path: string,
  cfg: Pick<StreamsConfig, 'apiKey' | 'apiSecret'>,
  body = '',
  timestampMs = Date.now(),
): Record<string, string> {
  const bodyHash = createHash('sha256').update(body).digest('hex');
  const toSign = `${method} ${path} ${bodyHash} ${cfg.apiKey} ${timestampMs}`;
  const signature = createHmac('sha256', cfg.apiSecret).update(toSign).digest('hex');
  return {
    Authorization: cfg.apiKey,
    'X-Authorization-Timestamp': String(timestampMs),
    'X-Authorization-Signature-SHA256': signature,
  };
}

function hex0x(s: string): Hex {
  return (s.startsWith('0x') ? s : `0x${s}`) as Hex;
}

export interface LatestReport {
  feedId: Hex;
  fullReport: Hex;
  validFromTimestamp: number;
  observationsTimestamp: number;
}

/** REST: fetch the single latest report for one feed. */
export async function fetchLatestReport(cfg: StreamsConfig, feedId: Hex): Promise<LatestReport> {
  const path = `/api/v1/reports/latest?feedID=${feedId}`;
  const res = await fetch(`${cfg.restUrl}${path}`, { headers: authHeaders('GET', path, cfg) });
  if (!res.ok) throw new Error(`data streams ${res.status}: ${await res.text()}`);
  const body = (await res.json()) as {
    report?: {
      feedID: string;
      fullReport: string;
      validFromTimestamp: number;
      observationsTimestamp: number;
    };
  };
  if (!body.report?.fullReport) throw new Error('data streams response carries no report');
  const r = body.report;
  return {
    feedId: hex0x(r.feedID),
    fullReport: hex0x(r.fullReport),
    validFromTimestamp: r.validFromTimestamp,
    observationsTimestamp: r.observationsTimestamp,
  };
}

/** REST: list the feed ids this account is entitled to. */
export async function listFeeds(cfg: StreamsConfig): Promise<Hex[]> {
  const path = '/api/v1/feeds';
  const res = await fetch(`${cfg.restUrl}${path}`, { headers: authHeaders('GET', path, cfg) });
  if (!res.ok) throw new Error(`data streams ${res.status}: ${await res.text()}`);
  const body = (await res.json()) as { feeds?: Array<{ feedID: string }> };
  return (body.feeds ?? []).map((f) => hex0x(f.feedID));
}

/**
 * WebSocket: subscribe to `feedIds` and invoke `onReport(fullReport)` per frame.
 * Returns a stop() that closes the socket. HA/v2 endpoints (`/api/v2/ws`) work the
 * same way — point `wsUrl` at them and adjust the path if your account requires v2.
 */
export function streamReports(
  cfg: StreamsConfig,
  feedIds: Hex[],
  onReport: (fullReport: Hex) => void,
  onClose?: (code: number) => void,
): () => void {
  // v1 by default; HA / High Frequency Streams ("Streams Ultra") accounts use /api/v2/ws —
  // override via DATA_STREAMS_WS_PATH. The HMAC signature below is taken over whatever path is set.
  const wsPath = process.env.DATA_STREAMS_WS_PATH ?? '/api/v1/ws';
  const path = `${wsPath}?feedIDs=${feedIds.join(',')}`;
  const headers = authHeaders('GET', path, cfg);
  // NB: use the `ws` library (not Node's global WebSocket) — the global/undici WebSocket ignores
  // the `headers` option, which would drop the HMAC auth headers and hang on an unauthenticated socket.
  const ws = new WebSocket(`${cfg.wsUrl}${path}`, { headers });
  ws.addEventListener('open', () => console.log(`data streams ws open, feeds [${feedIds.length}]`));
  ws.addEventListener('message', (ev) => {
    // NOTE: verify the frame shape against current docs. Observed shape:
    // { report: { feedID, fullReport, observationsTimestamp, ... } }
    try {
      const msg = JSON.parse(String(ev.data)) as { report?: { fullReport?: string } };
      const full = msg.report?.fullReport;
      if (full) onReport(hex0x(full));
    } catch {
      /* heartbeat / non-JSON frame — ignore */
    }
  });
  ws.addEventListener('close', (ev) => onClose?.((ev as { code?: number }).code ?? 0));
  ws.addEventListener('error', (ev) =>
    console.error('data streams ws error:', (ev as { message?: string }).message ?? ev),
  );
  return () => ws.close();
}

export type Resolution = 'seconds' | 'milliseconds';

/** Timestamp resolution from the feed id (upper nibble of byte 0): 0x1… = HFS/ms, 0x0… = seconds. */
export function feedResolution(feedId: Hex): Resolution {
  const byte0 = parseInt(feedId.slice(2, 4), 16);
  return byte0 >> 4 === 1 ? 'milliseconds' : 'seconds';
}

export interface DecodedReport {
  feedId: Hex;
  benchmarkPrice: bigint; // 18-decimal Data Streams price
  observationsTimestamp: bigint; // seconds (standard) or ms (HFS) — see resolution
  resolution: Resolution;
}

/**
 * Decode the fields the on-chain oracle reads, WITHOUT verifying signatures (that
 * is the VerifierProxy's job on-chain). `fullReport` wraps the report blob:
 *   abi.encode(bytes32[3] context, bytes reportBlob, bytes32[] rs, bytes32[] ss, bytes32 rawVs)
 * The v3 (crypto) and HFS blobs share a field order; standard uint32 vs HFS uint64
 * timestamps both occupy a full ABI word, so one uint64-typed layout decodes both.
 */
export function decodeReport(fullReport: Hex): DecodedReport {
  const [, reportBlob] = abi.decode(
    ['bytes32[3]', 'bytes', 'bytes32[]', 'bytes32[]', 'bytes32'],
    fullReport,
  ) as unknown as [unknown, Hex];
  const [feedId, , observationsTimestamp, , , , benchmarkPrice] = abi.decode(
    ['bytes32', 'uint64', 'uint64', 'uint192', 'uint192', 'uint64', 'int192', 'int192', 'int192'],
    reportBlob,
  ) as unknown as [Hex, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint];
  return {
    feedId,
    benchmarkPrice,
    observationsTimestamp,
    resolution: feedResolution(feedId),
  };
}

/** The report's observation time in whole seconds, matching `price()`'s `refTime`. */
export function refTimeSecondsOf(r: DecodedReport): bigint {
  return r.resolution === 'milliseconds'
    ? r.observationsTimestamp / 1000n
    : r.observationsTimestamp;
}
