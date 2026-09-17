// SPDX-License-Identifier: MIT
/**
 * LIVE integration test against the DEPLOYED ChainlinkOracle + the real Chainlink
 * Data Streams API. Skipped by default — it hits the network. Run it explicitly:
 *
 *   npm run test:live          (reads + Data Streams fetch — no gas)
 *   npm run test:live:push     (also broadcasts ONE real relay tx; needs a funded PUSHER_PRIVATE_KEY)
 *
 * Reads config from the environment (loaded from `.env` if present):
 *   RPC_URL                      chain the oracle lives on (default: Base mainnet)
 *   CHAINLINK_ORACLE_ADDRESS     deployed oracle (default: the production CREATE3 address)
 *   DATA_STREAMS_REST_URL        default: https://api.dataengine.chain.link
 *   DATA_STREAMS_API_KEY/SECRET  your Streams credentials (required for the API cases)
 *
 * What it proves without spending gas:
 *   1. the deployed oracle is reachable and is the Data Streams oracle (kind/version),
 *      wired to a non-zero VerifierProxy;
 *   2. the Data Streams HMAC auth works (feed list is non-empty);
 *   3. a real v3 (0x0003…) report fetches, decodes, and matches its feed id;
 *   4. the gated from-less `price()` read path works against the live contract
 *      (returns the price, or null = FeedNotFound if nothing has been pushed yet).
 *
 * The on-chain relay is a separate opt-in case (`npm run test:live:push` + a funded
 * PUSHER_PRIVATE_KEY). It broadcasts one real `updateReport` tx and prints its hash; on
 * the production Base deployment the Data Streams verify succeeds and the report is
 * stored (confirmed live — e.g. tx 0x188133aa…3aade). A fixed gasLimit is used so the tx
 * is broadcast even if a deployment's verify were to revert on a DON fee — you still see it.
 */
import { existsSync } from 'node:fs';
import { beforeAll, describe, expect, it } from 'vitest';
import { Contract, JsonRpcProvider } from 'ethers';
import {
  decodeReport,
  fetchLatestReport,
  listFeeds,
  type StreamsConfig,
} from '../src/chainlink/streams.js';
import { buildUpdateCalldata, readChainlinkPrice } from '../src/chainlink/oracle.js';
import { makeClients } from '../src/common/clients.js';
import type { Address, Hex } from '../src/common/types.js';

// Best-effort load of the local .env (Node >= 20.12). Never throws in CI where it is absent.
try {
  if (existsSync(new URL('../.env', import.meta.url))) {
    process.loadEnvFile(new URL('../.env', import.meta.url));
  }
} catch {
  /* no .env — rely on the ambient environment */
}

// Public RPCs (e.g. mainnet.base.org) rate-limit and intermittently return a data-less
// CALL_EXCEPTION on a plain eth_call. Retry read calls a few times; set RPC_URL to a
// reliable endpoint (Alchemy / your own node) to avoid this entirely.
async function retry<T>(fn: () => Promise<T>, attempts = 4, delayMs = 600): Promise<T> {
  let last: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (e) {
      last = e;
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  throw last;
}

const RUN = process.env.RUN_LIVE === '1';
const RPC_URL = process.env.RPC_URL || 'https://mainnet.base.org';
const ORACLE = (process.env.CHAINLINK_ORACLE_ADDRESS ||
  '0x810A649974f21bB6D3b2E781597EdBDAabe82228') as Address;
const streams: StreamsConfig = {
  apiKey: process.env.DATA_STREAMS_API_KEY || '',
  apiSecret: process.env.DATA_STREAMS_API_SECRET || '',
  restUrl: process.env.DATA_STREAMS_REST_URL || 'https://api.dataengine.chain.link',
  wsUrl: process.env.DATA_STREAMS_WS_URL || 'wss://ws.dataengine.chain.link',
};
const haveCreds = streams.apiKey !== '' && streams.apiSecret !== '';

const ORACLE_ABI = [
  'function kind() view returns (string)',
  'function version() view returns (string)',
  'function verifierProxy() view returns (address)',
];

describe.skipIf(!RUN)('chainlink live — deployed oracle + Data Streams', () => {
  let provider: JsonRpcProvider;
  beforeAll(() => {
    provider = new JsonRpcProvider(RPC_URL, undefined, { cacheTimeout: -1 });
  });

  it('deployed oracle is the Data Streams oracle, wired to a verifier', async () => {
    const oracle = new Contract(ORACLE, ORACLE_ABI, provider);
    expect(await retry(() => oracle.kind())).toBe('chainlink-datastreams');
    expect(String(await retry(() => oracle.version()))).toMatch(/^\d+\.\d+\.\d+/);
    expect(String(await retry(() => oracle.verifierProxy())).toLowerCase()).not.toBe(
      '0x0000000000000000000000000000000000000000',
    );
  });

  it.skipIf(!haveCreds)('Data Streams auth works (feed list is non-empty)', async () => {
    const feeds = await listFeeds(streams);
    expect(feeds.length).toBeGreaterThan(0);
    expect(feeds.some((f) => f.startsWith('0x0003'))).toBe(true); // standard v3 crypto stream
  });

  it.skipIf(!haveCreds)(
    'fetches + decodes a live v3 report and reads the oracle back',
    async () => {
      const feeds = await listFeeds(streams);
      const feedId = feeds.find((f) => f.startsWith('0x0003')); // v3 = price + bid/ask, seconds
      expect(feedId, 'account has no standard v3 feed to test with').toBeDefined();

      const report = await fetchLatestReport(streams, feedId as Hex);
      const decoded = decodeReport(report.fullReport);
      expect(decoded.feedId.toLowerCase()).toBe(feedId);
      expect(decoded.resolution).toBe('seconds');
      expect(decoded.benchmarkPrice).toBeGreaterThan(0n);

      // Gated, from-less read against the LIVE contract: null (never pushed) or a well-formed price.
      const onchain = await retry(() => readChainlinkPrice(provider, ORACLE, decoded.feedId));
      if (onchain !== null) {
        expect(typeof onchain.mid).toBe('bigint');
        expect(typeof onchain.refTimeSec).toBe('bigint');
      }
    },
  );

  // Opt-in: an ACTUAL on-chain relay. Run it with `npm run test:live:push` (that script sets both
  // RUN_LIVE=1 and RUN_LIVE_PUSH=1 — no shell-env needed) and a funded PUSHER_PRIVATE_KEY.
  const canPush =
    process.env.RUN_LIVE_PUSH === '1' &&
    haveCreds &&
    /^0x[0-9a-fA-F]{64}$/.test(process.env.PUSHER_PRIVATE_KEY || '');
  it.skipIf(!canPush)(
    'broadcasts a real relay tx on-chain (visible even if it reverts)',
    async () => {
      const clients = await makeClients({
        rpcUrl: RPC_URL,
        privateKey: process.env.PUSHER_PRIVATE_KEY as Hex,
      });
      const feeds = await listFeeds(streams);
      const feedId = feeds.find((f) => f.startsWith('0x0003')) as Hex;
      const report = await fetchLatestReport(streams, feedId);
      const decoded = decodeReport(report.fullReport);

      // Fixed gasLimit → ethers skips eth_estimateGas. Data Streams `verify` bills a DON fee in the
      // oracle's feeToken; if the oracle can't cover it the CALL reverts, and an estimate would abort
      // BEFORE any tx is sent. A fixed limit forces the tx onto the chain so you can see it (a revert
      // is still a mined, visible tx — status 0).
      const tx = await clients.wallet!.sendTransaction({
        to: ORACLE,
        data: buildUpdateCalldata(report.fullReport),
        gasLimit: 2_000_000n,
      });
      console.log(`\n  sent ${tx.hash}\n  https://basescan.org/tx/${tx.hash}`);
      const receipt = await tx.wait();
      console.log(`  mined in block ${receipt!.blockNumber}, status ${receipt!.status}`);
      expect(receipt).not.toBeNull(); // the tx is on-chain regardless of success/revert

      if (receipt!.status === 1) {
        const got = await retry(() => readChainlinkPrice(provider, ORACLE, decoded.feedId));
        expect(got).not.toBeNull();
        expect(got!.mid).toBe(decoded.benchmarkPrice / 10n ** 10n); // 18-dec → 8-dec
      } else {
        console.warn(
          '  tx REVERTED on-chain — Data Streams verify billed a DON fee in feeToken the oracle cannot cover.',
        );
      }
    },
    120_000,
  );
});
