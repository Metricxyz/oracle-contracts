// SPDX-License-Identifier: MIT
/**
 * EDUCATIONAL walkthrough — relay ONE Lazer-signed update into PythOracle.
 *
 * The relayer never signs price data: the Lazer signature inside the envelope is the
 * only trust anchor, and ANYONE can push a genuine envelope. The feed-id list in the
 * calldata must match the payload's feed order exactly (FeedIdMismatch otherwise).
 * The 1-wei verification fee is paid from the ORACLE's balance, not by the sender.
 *
 * Input modes:
 *   file  — LAZER_UPDATE_FILE points at a hex envelope (the offline demo path)
 *   https — LAZER_HTTP_URL + LAZER_ACCESS_TOKEN fetch the latest signed update from Lazer
 *
 * What happens: obtains a signed envelope (from a file, or a one-shot HTTPS
 * fetch to the Lazer service); recovers the feed-id list from the payload
 * itself (never from env — the calldata's id order must match the payload's
 * own order exactly); checks the oracle's wei balance can cover the 1-wei
 * verification fee before relaying; relays via `relayUpdate`; then, for
 * every feed in the payload, reads it back through the gated `price()` call
 * and cross-checks the normalized mid/spread/refTime against a local
 * reimplementation of the contract's own normalization math.
 *
 * Env: PYTH_ORACLE_ADDRESS, RPC_URL, PUSHER_PRIVATE_KEY, and either
 * LAZER_UPDATE_FILE (file mode) or LAZER_HTTP_URL + LAZER_ACCESS_TOKEN +
 * [LAZER_FEED_IDS] (https mode)
 * Run: npx tsx scripts/10-pyth-push-once.ts
 *
 * Place in the package: pyth lane, step 0 — the one-shot counterpart to
 * script 11's WS loop; both share `relayUpdate` from `src/pyth/oracle.ts` as
 * their relay core. `demo/anvil-demo.sh` runs this in file mode against a
 * demo-signed envelope from `demo/build-demo-update.ts`.
 */
import { readFileSync } from 'node:fs';
import type { Address, Hex } from '../src/common/types.js';
import { parseEnvelope, parsePayload } from '../src/pyth/lazer.js';
import { getOracleBalance, readPythPrice, relayUpdate } from '../src/pyth/oracle.js';
import { envOr, requireEnv } from '../src/common/env.js';
import { makeClients } from '../src/common/clients.js';

const oracle = requireEnv('PYTH_ORACLE_ADDRESS') as Address;
const clients = await makeClients({
  rpcUrl: requireEnv('RPC_URL'),
  privateKey: requireEnv('PUSHER_PRIVATE_KEY') as Hex,
});

// ── 1. obtain a SIGNED update ──
let signedUpdate: Hex;
const file = envOr('LAZER_UPDATE_FILE', '');
if (file) {
  signedUpdate = readFileSync(file, 'utf8').trim() as Hex;
} else {
  const url = requireEnv('LAZER_HTTP_URL');
  const token = requireEnv('LAZER_ACCESS_TOKEN');
  const ids = envOr('LAZER_FEED_IDS', '1,2').split(',').map(Number);
  // NOTE: verify request shape against pyth lazer docs before production use
  // Request the EXACT property set the deployed oracle expects, evm delivery format.
  const res = await fetch(url, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      priceFeedIds: ids,
      properties: ['price', 'exponent', 'confidence', 'feedUpdateTimestamp'],
      formats: ['evm'],
      // Ask Lazer for the EVM blob as HEX. Without this it defaults evm.encoding to base64,
      // which is not a BytesLike and blows up the relay ("invalid BytesLike value").
      jsonBinaryEncoding: 'hex',
      channel: 'real_time',
    }),
  });
  if (!res.ok) throw new Error(`lazer http ${res.status}: ${await res.text()}`);
  const body = (await res.json()) as { evm?: { data?: string; encoding?: string } };
  if (!body.evm?.data) throw new Error('lazer response carries no evm payload');
  // Honor the encoding Lazer reports: hex -> use directly, base64 -> decode. We request hex above,
  // but decode defensively so a server-side default flip can't silently break the relay again.
  const raw = body.evm.data;
  signedUpdate = (
    body.evm.encoding === 'base64'
      ? `0x${Buffer.from(raw, 'base64').toString('hex')}`
      : raw.startsWith('0x')
        ? raw
        : `0x${raw}`
  ) as Hex;
}

// ── 2. the feed-id list comes FROM the payload itself, in order ──
const parsed = parsePayload(parseEnvelope(signedUpdate).payload);
const feedIds = parsed.feeds.map((f) => f.feedId);
console.log(`relaying feeds [${feedIds}] (payload ts ${parsed.timestampUs}us)`);

// ── 3. fee balance sanity, then relay ──
const balance = await getOracleBalance(clients.provider, oracle);
if (balance < 1n) {
  console.error(
    `ORACLE BALANCE EMPTY (${balance} wei): the 1-wei verification fee cannot be paid. Top up with a plain transfer.`,
  );
  process.exit(1);
}
const receipt = await relayUpdate(clients, oracle, feedIds, signedUpdate);
console.log(`relayed in tx ${receipt.hash} (gas ${receipt.gasUsed})`);

// ── 4. verify through the gated read path (price normalized to 8 decimals) ──
let failed = false;
for (const feed of parsed.feeds) {
  const got = await readPythPrice(clients.provider, oracle, feed.feedId);
  if (!got) {
    console.error(`feed ${feed.feedId}: still FeedNotFound after the push`);
    failed = true;
    continue;
  }
  // normalization mirror of LazerConsumer._normalize: price * 10^(exponent + 8),
  // spread0 = ceil(SPREAD_SCALE * conf / price) saturated at MAX_REAL_SPREAD.
  //
  // SPREAD_SCALE is 1e6 (0.01-bps units), NOT 1e4: a 1e4 (whole-bps) mirror would understate the
  // spread 100x and disagree with any real readback. The cap is 65534 (type(uint16).max - 1),
  // deliberately one below the 65535 stall sentinel so a saturated REAL spread can never be
  // mistaken for "feed inactive".
  const SPREAD_SCALE = 1_000_000n;
  const MAX_REAL_SPREAD = 65_534n;
  const totalExpo = feed.exponent + 8;
  const wantMid =
    totalExpo >= 0 ? feed.price * 10n ** BigInt(totalExpo) : feed.price / 10n ** BigInt(-totalExpo);
  const spreadU = (SPREAD_SCALE * feed.confidence + feed.price - 1n) / feed.price;
  const wantSpread0 = spreadU > MAX_REAL_SPREAD ? MAX_REAL_SPREAD : spreadU;
  const wantRefSec = feed.timestampUs / 1_000_000n;
  const ok =
    got.mid === wantMid &&
    got.spread0 === wantSpread0 &&
    got.spread1 === 0xffff &&
    got.refTimeSec === wantRefSec;
  if (!ok) {
    console.error(`feed ${feed.feedId}: readback mismatch`, {
      want: { wantMid, wantSpread0, wantRefSec },
      got,
    });
    failed = true;
  } else {
    console.log(
      `feed ${feed.feedId} verified: mid ${got.mid}, spread0 ${got.spread0} (0.01-bps), ref ${got.refTimeSec}s`,
    );
  }
}
process.exit(failed ? 1 : 0);
