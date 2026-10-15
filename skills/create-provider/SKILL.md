---
name: create-provider
description: Create a price provider (AnchoredPriceProvider or plain PriceProvider) against the deployed oracle suite. Use when asked to "create a price provider", "create an anchored provider", "integrate a pool with the oracle", or "set up a provider for pool X".
---

# Create a price provider

You are orchestrating the provider-creation flow of this repo. The canonical references are
`docs/anchored-price-provider-quickstart.md` (Anchored Price Provider) and `docs/price-provider-quickstart.md`
(plain provider) — follow them; this skill adds the decision gate, the probes, and the guardrails.

Background reading: `docs/oracle-overview.md` — where a pool's quote comes from and how to choose an
oracle and a provider.

## Guardrails (non-negotiable)

- Secrets come ONLY from environment variables. Never print, echo, or log a private key.
- Every state-changing command runs as a DRY-RUN first (`BROADCAST` unset). Show the user the
  simulation result and get their explicit confirmation before re-running with `BROADCAST=1`.
- After every step, run the listed verification read and show its output. Do not claim success
  without it.

## Step 1 — decide the provider type

Ask the user (or infer from their request):

- **AnchoredPriceProvider (APP)** — deployed on all ten production chains. Quotes are
  clamped to a band derived from a reference oracle's own uncertainty; parameters must sit inside
  an admin-curated envelope. Reference: `docs/anchored-price-provider.md`. Note the reference
  oracle varies per chain: on avalanche the `PythOracle` is allow-listed but cannot ingest (Pyth
  Lazer has no code there), and on megaeth the `ChainlinkOracle` is not on the allow-list (its
  verifier has no code there); `docs/DEPLOYMENTS.md` has the per-chain notes. Check
  `isOracle()` on the target chain, and that the feed actually has data, before relying on a lane.
- **Plain PriceProvider** — deployed on all ten chains; no envelope; a single-oracle passthrough with three
  knobs. Reference: `docs/price-provider-quickstart.md`.

If the base token is a tokenized stock with an on-chain multiplier (Coinbase B20 Assets on base,
Robinhood Stock Tokens on robinhood), the reference oracle is the `MultiplierOracle`, and its feeds
must be created before the provider: run Steps 0–1 of `docs/multiplier-oracle-quickstart.md` first,
then continue here with the multiplier feed ids. Never anchor such a token to the raw share feed.

## Step 2 — addresses

Take factory and oracle addresses from `docs/DEPLOYMENTS.md` (CREATE3: same address on every deployed
chain) and pass them via env: `ANCHORED_PROVIDER_FACTORY` or `PRICE_PROVIDER_FACTORY`, and
`REFERENCE_ORACLE`. The scripts require them.

## Step 3 — read-only probes (no key needed), per provider type

Use the env names the scripts read: `REFERENCE_ORACLE`, `NETWORK` (the Foundry RPC alias),
`BASE_FEED_ID` / `QUOTE_FEED_ID` (APP) or `FEED_ID` (plain).

**AnchoredPriceProvider path** — run the Steps 1–2 checks of `docs/anchored-price-provider-quickstart.md`:

1. `isOracle(referenceOracle)` on the factory must return `true`.
2. Resolve the effective class: `feedClass(baseFeedId)`, falling back to `DEFAULT_CLASS()` only
   when that returns zero. That class's envelope must exist (last tuple field `true`) and your
   intended `MIN_MARGIN` / `MAX_REF_STALENESS` / `MAX_SPREAD_MULT` must sit inside it (the envelope
   fields are `minMarginMin/Max`, `stalenessMin/Max`, `spreadMultMax` — it carries no spread cap).
3. Feed-data probe, for `BASE_FEED_ID` and, when set, `QUOTE_FEED_ID`:

   ```bash
   cast call "$REFERENCE_ORACLE" "price(bytes32,address)(uint256,uint256,uint16,uint256)" \
     "$(cast to-uint256 "$BASE_FEED_ID")" 0x0000000000000000000000000000000000000000 \
     --from 0x0000000000000000000000000000000000000000 --rpc-url "$NETWORK"
   ```

   It returns `(mid, spread0, spread1, refTime)`, `refTime` in seconds.
   Interpretation (applies to the provider oracles — Pyth/Chainlink references): revert
   `FeedNotFound` = the feed holds no observation (creation succeeds; reads halt while it holds
   none). A stalled or saturated feed also returns a value, so a returned value is usable data only
   when the mid is positive, `refTime` is not in the future and within the leg's staleness limit
   (`BASE_MAX_STALENESS` / `QUOTE_MAX_STALENESS`, default `MAX_REF_STALENESS`) of the current block time, and
   `spread0` is below `65534` (`65534` = saturated uncertainty, `65535` = stall sentinel; the APP
   halts on both). Any other revert: read the error before creating
   (a wrong address, chain or ABI, or on a `MultiplierOracle` feed an access error from its
   underlying oracle such as `NotWhitelisted`). Never use `getOracleData` here — it is disabled
   (`ReadDisabled`) on the provider oracles.

**Plain PriceProvider path** — `PriceProviderFactory` has NO oracle allow-list and NO parameter
envelope: there is no factory-side setup to verify (see `docs/price-provider-quickstart.md`). Run
the feed-data probe above with `FEED_ID` in place of `BASE_FEED_ID`; the interpretation depends on
the reference oracle family: for `PythOracle` / `ChainlinkOracle` use the `FeedNotFound`-revert
interpretation above, with `refTime` not in the future and within `MAX_TIME_DELTA`, and `spread0` at most `50_000` (the
plain provider halts above 5% and on the stall sentinel); for `CompressedOracleV1`
`price(feedId, 0x0)` does NOT revert for a well-formed feedId — a
never-written slot returns `(0, 0, 0, 0)`; a never-written position in a written slot returns a
zero mid with the slot's timestamp. Only a non-zero mid means the feed has a price.

## Step 4 — dry-run, confirm, broadcast

Use the committed wrappers — `script/create-anchored-provider.sh` (APP) or
`script/create-price-provider.sh` (plain) — with the env documented in the headers of `script/CreateAnchoredProvider.s.sol` and
`script/CreatePriceProvider.s.sol`.
First WITHOUT `BROADCAST` (simulation), show the user the result, then with `BROADCAST=1` after
they confirm. The caller key (`PRIVATE_KEY`) becomes the provider owner.

## Step 5 — verify

1. Extract the provider address from the factory's creation event in the broadcast output.
2. Read back the owner from the factory (`providerOwner(address)(address)`), then the provider's
   `token0()`, `token1()` and its immutable params; show them.
3. If the feed already has data: `cast call` the provider's
   `getQuote()(uint128,uint128,uint128)` with `--from 0x0000000000000000000000000000000000000000`.
   That zero-sender `eth_call` checks the data and the quote math, but it skips the pool gate
   (in-swap binding, pool blacklist, registration), so test read access separately by simulating
   the real swap. Three values come back: bid, ask, and the reference price, which must sit
   between them (it is the oracle/anchor mid, and the consumer rejects a quote where it does not).

## Troubleshooting

| Symptom | Meaning | Action |
| --- | --- | --- |
| Probe reverts `FeedNotFound` (provider oracles: Pyth/Chainlink) | the feed holds no observation | creation succeeds; reads halt while it holds none |
| `price()` returns (0,0,0,0) | the CompressedOracleV1 feed holds no price | creation succeeds; reads halt while it holds none |
| Creation reverts with an envelope error | params outside the admin envelope | re-read the envelope (Step 3.2), adjust params |
| `getOracleData` reverts `ReadDisabled` | expected on PythOracle/ChainlinkOracle | use the `price(feedId, 0x0)` probe form above |
