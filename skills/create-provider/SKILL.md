---
name: create-provider
description: Create a price provider (AnchoredPriceProvider or plain PriceProvider) against the deployed oracle suite. Use when asked to "create a price provider", "create an anchored provider", "integrate a pool with the oracle", or "set up a provider for pool X".
---

# Create a price provider

You are orchestrating the provider-creation flow of this repo. The canonical references are
`docs/anchored-price-provider-quickstart.md` (Anchored Price Provider) and `docs/price-provider-quickstart.md`
(plain provider) — follow them; this skill adds the decision gate, the probes, and the guardrails.

Background reading: `docs/mm-operations-guide.md` — how a market maker launches and operates a
metric pool (providers and pool wiring are its section 4).

## Guardrails (non-negotiable)

- Secrets come ONLY from environment variables. Never print, echo, or log a private key.
- Every state-changing command runs as a DRY-RUN first (`BROADCAST` unset). Show the user the
  simulation result and get their explicit confirmation before re-running with `BROADCAST=1`.
- After every step, run the listed verification read and show its output. Do not claim success
  without it.

## Step 1 — decide the provider type

Ask the user (or infer from their request):

- **AnchoredPriceProvider (APP)** — recommended. Deployed on all ten production chains. Quotes are
  clamped to a band derived from a reference oracle's own uncertainty; parameters must sit inside
  an admin-curated envelope. Reference: `docs/anchored-price-provider.md`. Note the reference
  oracle varies per chain: on avalanche the `PythOracle` is deployed and allow-listed but cannot
  ingest until Pyth Lazer ships there, and on megaeth the `ChainlinkOracle` is deployed but kept off
  the allow-list until its verifier is live (`DEPLOYMENTS.md` has the per-chain notes). Check
  `isOracle()` on the target chain, and that the feed actually has data, before relying on a lane.
- **Plain PriceProvider** — deployed on all ten chains; no envelope, thinner construction (single-oracle
  passthrough with three knobs). Reference: `docs/price-provider-quickstart.md`.

## Step 2 — addresses

Take factory and oracle addresses from `DEPLOYMENTS.md` (CREATE3: same address on every deployed
chain). Pass them EXPLICITLY via env (`ANCHORED_PROVIDER_FACTORY`, `REFERENCE_ORACLE`): the
committed `script/config/networks.json` is deploy-script working state and may lag.

## Step 3 — read-only probes (no key needed), per provider type

**AnchoredPriceProvider path** — run the Step 1 checks of `docs/anchored-price-provider-quickstart.md`:

1. `isOracle(referenceOracle)` on the factory must return `true`.
2. Resolve the effective class: `feedClass(baseFeedId)`, falling back to `DEFAULT_CLASS()` only
   when that returns zero. That class's envelope must exist (last tuple field `true`) and your
   intended `MIN_MARGIN` / `MAX_REF_STALENESS` / `MAX_SPREAD_MULT` must sit inside it (the envelope
   fields are `minMarginMin/Max`, `stalenessMin/Max`, `spreadMultMax` — it carries no spread cap).
3. Feed-data probe: `cast call $ORACLE "price(bytes32,address)(uint256,uint256,uint16,uint256)"
   $FEED 0x0000000000000000000000000000000000000000 --from
   0x0000000000000000000000000000000000000000 --rpc-url $RPC`.
   Interpretation (applies to the provider oracles — Pyth/Chainlink references): revert
   `FeedNotFound` = feed has no data YET (creation still succeeds; reads halt until data
   arrives). ANY other outcome (a value, or a different revert) = the feed has data. Never use
   `getOracleData` here — it is disabled (`ReadDisabled`) on the provider oracles.

**Plain PriceProvider path** — `PriceProviderFactory` has NO oracle allow-list and NO parameter
envelope: there is no factory-side setup to verify (see `docs/price-provider-quickstart.md`
Step 0). The feed-data probe depends on the reference oracle family: for `PythOracle` /
`ChainlinkOracle` use the `FeedNotFound`-revert interpretation above; for `CompressedOracleV1`
(the wrapper's default) `price(feedId, 0x0)` does NOT revert for a well-formed feedId — a
never-written slot returns `(0, 0, 0, 0)`; a never-written position in a written slot returns a
zero mid with the slot's timestamp. Only a non-zero mid means the feed has a price.

## Step 4 — dry-run, confirm, broadcast

Use the committed wrappers — `script/create-anchored-provider.sh` (APP) or
`script/create-price-provider.sh` (plain) — with the exact env documented in their headers.
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
| Probe reverts `FeedNotFound` (provider oracles: Pyth/Chainlink) | feed has no data yet | creation is fine; reads start after the first push |
| `price()` returns (0,0,0,0) | CompressedOracleV1 feed has no data yet | creation is fine; reads start after the first push |
| Creation reverts with an envelope error | params outside the admin envelope | re-read the envelope (Step 3.2), adjust params |
| Wrapper uses wrong addresses | `script/config/networks.json` lag | pass the `DEPLOYMENTS.md` addresses via env explicitly |
| `getOracleData` reverts `ReadDisabled` | expected on PythOracle/ChainlinkOracle | use the `price(feedId, 0x0)` probe form above |
