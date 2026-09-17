# mm-pusher-ts — market-maker pusher skeleton

A self-contained, copyable TypeScript skeleton for the two push paths of this repo's oracles:

- **Compressed lane** (`CompressedOracleV1`) — you are the _price source_: derive your
  registrationless feedIds, encode prices/spreads into 32-byte slot words, push them.
- **Pyth lane** (`PythOracle`) — you are a _relayer_: forward Pyth-Lazer-signed updates
  verbatim; the Lazer signature is the only trust anchor.
- **Chainlink lane** (`ChainlinkOracle`) — you are a _relayer_: forward Chainlink Data Streams
  DON-signed reports verbatim; the DON signature (checked via the VerifierProxy) is the anchor.

Only runtime dependency: [ethers](https://docs.ethers.org). Node >= 22. Format references:
[`docs/oracle-packet-structure.md`](../../docs/oracle-packet-structure.md),
[`docs/u64x32.md`](../../docs/u64x32.md), [`docs/codebook.md`](../../docs/codebook.md),
[`docs/slot-structure.md`](../../docs/slot-structure.md). Production addresses:
[`DEPLOYMENTS.md`](../../DEPLOYMENTS.md).

## Quickstart (offline, no keys, no token)

```bash
npm ci
npm test        # unit vectors pinned against this repo's Solidity
npm run demo    # anvil: deploys both oracles locally, runs every scenario, verifies readbacks
```

The demo needs [Foundry](https://book.getfoundry.sh/) (anvil + forge). It is the rehearsal for
everything below — if `npm run demo` passes, your toolchain and the encoding are correct.

## Layout

| Path              | What it is                                                                     |
| ----------------- | ------------------------------------------------------------------------------ |
| `src/compressed/` | encoding libs (u64x32, codebook, slot word, feedId) + oracle wrapper           |
| `src/pyth/`       | Lazer payload/envelope codec + relay core + gated readback                     |
| `src/chainlink/`  | Data Streams client (HMAC auth, REST/WS) + report decode + relay core          |
| `src/common/`     | env/clients/revert-diagnostics plumbing                                        |
| `scripts/0x-*.ts` | compressed lane: derive, delegate, push-once, run-pusher, guard, signed update |
| `scripts/1x-*.ts` | pyth lane: push-once (file/HTTPS), WS relay loop                               |
| `scripts/2x-*.ts` | chainlink lane: push-once (REST), WS relay loop                                |
| `demo/`           | anvil demo, local deploy script, pinned-vector generator                       |

## Compressed lane (publish your own prices)

Copy `.env.example` to `.env` and set `RPC_URL`, `COMPRESSED_ORACLE_ADDRESS`,
`PUSHER_PRIVATE_KEY`, `CREATOR_PRIVATE_KEY`, `SLOT_INDEX`. Then:

```bash
npx tsx scripts/01-derive-feed-id.ts      # your feedIds (no registration step exists)
npx tsx scripts/02-authorize-pusher.ts    # OPTIONAL: delegate a hot pusher key
npx tsx scripts/03-push-once.ts           # one push, verified by readback
npx tsx scripts/05-set-price-guard.ts     # min/max guard (creator key)
npx tsx scripts/04-run-pusher.ts          # production loop — replace PriceSource with your data
```

Four properties of the format you must internalize (script 03 demonstrates all of them):

1. **The slot is overwritten whole** — all 4 positions are re-encoded every push; unused
   positions are `'empty'` (the `0xFF/0xFF` stall sentinel; they read back as price 0, spreads
   65535, timestamp 0 — never-pushed, and every provider halts on them).
2. **Timestamps must strictly increase per slot** — an older word is _silently ignored_ (that is
   the replay protection). Run one pusher per slot; verify by readback when it matters.
3. **Encoding quantizes** — U64x32 rounds prices down; the codebook rounds spreads UP to the
   next table entry (10 000 units encodes as index 251, never the 0xFF sentinel).
4. **Spreads are 0.01-bps units, not whole bps** — 100 = 1 bp, and the table's ceiling of
   10 000 is **1%**, not 100%. This is the unit the whole stack shares (`SPREAD_SCALE = 1e6` on
   the Pyth/Chainlink oracles, `ONE_SPREAD_UNIT_E18 = 1e12` in `AnchoredPriceProvider`). Passing
   whole bps understates every spread 100x and quotes the LP inside the market.

`updateBySignature` (script 06) is the relay variant: the creator signs the word offline, anyone
submits it.

## Pyth lane (relay Lazer updates)

Needs a Lazer access token (issued by Pyth). Set `PYTH_ORACLE_ADDRESS`, `LAZER_WS_URL`,
`LAZER_HTTP_URL`, `LAZER_ACCESS_TOKEN`, `LAZER_FEED_IDS`. Then:

```bash
npx tsx scripts/10-pyth-push-once.ts      # one relay, verified via the gated read
npx tsx scripts/11-pyth-run-pusher.ts     # WS subscribe -> relay loop (run under a supervisor)
```

Two constraints:

1. Subscriptions must request EXACTLY the oracle's property set — price, exponent, confidence,
   feedUpdateTimestamp — in the `evm` format; anything else reverts the whole push.
2. The oracle pays the 1-wei verification fee from its own balance: check
   `cast balance $PYTH_ORACLE_ADDRESS`, top up with a plain transfer when low.

Readback: `getOracleData` is disabled on this oracle (`ReadDisabled`); the scripts read via an
`eth_call` of `price(feedId, address(0))` with no from-account. `refTime` is in seconds.

## Chainlink Data Streams lane (relay DON-signed reports)

Needs Data Streams API credentials (your Streams "User ID" = API key, "Secret" = API secret). Set
`CHAINLINK_ORACLE_ADDRESS`, `DATA_STREAMS_API_KEY`, `DATA_STREAMS_API_SECRET`,
`DATA_STREAMS_REST_URL` / `DATA_STREAMS_WS_URL`, and a feed id. Then:

```bash
npx tsx scripts/20-chainlink-push-once.ts   # fetch latest report (REST) -> relay -> gated read
npx tsx scripts/21-chainlink-run-pusher.ts  # WS subscribe -> relay loop (run under a supervisor)
```

Three things to know:

1. You relay the raw `fullReport`; the oracle verifies the DON signature through the Data Streams
   VerifierProxy. No on-chain fee — the relayer pays only gas.
2. Feed ids encode timestamp resolution in the upper nibble of byte 0: `0x1…` = High Frequency
   Streams ("Streams Ultra", ~40-50 ms, millisecond timestamps, WS-only); `0x0…` = standard (1 s,
   seconds). The oracle normalizes both to the same 8-decimal `OracleData`.
3. Auth is HMAC-SHA256 over `"<METHOD> <path> <sha256(body)> <apiKey> <tsMs>"`, identical for REST
   and WS (`src/chainlink/streams.ts`).

Readback is the same gated `price(feedId, address(0))` call as the Pyth lane; `feedId` here is the
full 32-byte Data Streams id.

## Production notes

- Keys/token only via env; the scripts never print them.
- The loops are skeletons: sequential nonce handling (send → await receipt), exponential backoff,
  graceful shutdown, an alert hook after 5 consecutive failures. Cadence policy is YOUR business
  logic — replace the fixed interval.
- Gas: every push is a storage write; batching N slots into one transaction is native to the
  compressed calldata format (`pushSlots` takes an array of words).
- Stuck transactions: the loops send and await the receipt; a transaction stuck in the mempool
  blocks the loop until the RPC receipt timeout. The skeleton does NOT do same-nonce gas-bump
  replacement — add your own replacement policy for production.

## License

MIT (like all example code in this repo) — see the root `README.md` License section.
