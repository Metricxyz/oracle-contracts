// SPDX-License-Identifier: MIT
/**
 * DEMO ONLY: builds and signs a synthetic Lazer update with the demo signer key
 * (the same key DeployDemo.s.sol registers as trusted). Production updates come
 * signed from the Pyth Lazer service — never from local code.
 *
 * Purpose: manufacture a self-signed Lazer envelope so `npm run demo` can
 * exercise the pyth-lane relay+readback path (script 10) without a real
 * Lazer subscription — this is the ONLY place in the package that signs
 * Lazer price data locally.
 *
 * What happens: builds one synthetic feed per id in `LAZER_FEED_IDS` (price
 * 2000.0, 2100.0, ... at exponent -8), packs+signs them into an envelope
 * with `DEMO_SIGNER_PRIVATE_KEY` (matching the trusted signer
 * `DeployDemo.s.sol` registers on the local `PythLazer` proxy), and writes
 * the hex envelope (plus a trailing newline) to `LAZER_UPDATE_FILE`.
 *
 * Env: LAZER_UPDATE_FILE (output path), LAZER_FEED_IDS (default "1,2")
 * Run: npx tsx demo/build-demo-update.ts
 *
 * Place in the package: the demo's substitute for a live Lazer feed;
 * `demo/anvil-demo.sh` runs this immediately before
 * `scripts/10-pyth-push-once.ts` (file mode).
 */
import { writeFileSync } from 'node:fs';
import {
  buildPayload,
  DEMO_SIGNER_PRIVATE_KEY,
  signEnvelope,
  type LazerFeed,
} from '../src/pyth/lazer.js';
import { envOr, requireEnv } from '../src/common/env.js';

const outFile = requireEnv('LAZER_UPDATE_FILE');
const feedIds = envOr('LAZER_FEED_IDS', '1,2').split(',').map(Number);
const tsUs = BigInt(Date.now()) * 1000n;

const feeds: LazerFeed[] = feedIds.map((feedId, i) => ({
  feedId,
  price: (2000n + BigInt(i) * 100n) * 10n ** 8n, // 2000.0, 2100.0, ... at expo -8
  exponent: -8,
  confidence: 50_000n + BigInt(i) * 10_000n,
  timestampUs: tsUs,
}));

const envelope = await signEnvelope(buildPayload(tsUs, 1, feeds), DEMO_SIGNER_PRIVATE_KEY);
writeFileSync(outFile, envelope + '\n');
console.log(JSON.stringify({ outFile, feedIds, tsUs: tsUs.toString(), feeds: feeds.length }));
