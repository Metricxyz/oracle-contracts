# Plain Price Provider creation — quickstart (manual)

Create one plain `PriceProvider` through the deployed `PriceProviderFactory`. Concrete values below
are for **ethereum** — `PriceProviderFactory` is deployed on all ten production chains at the same
address (see [`../DEPLOYMENTS.md`](../DEPLOYMENTS.md)). When you need the
reference-anchored safety band, prefer the Anchored Price Provider — see
[`anchored-price-provider-quickstart.md`](./anchored-price-provider-quickstart.md).

A plain `PriceProvider` reports three values — `bid`, `ask`, and the `referencePrice` the consumer
charges its fee against (the oracle's own mid, converted to Q64; it always sits inside the quote). It
is a thin, single-oracle passthrough shaped by exactly three inputs: the
oracle's own reported spread multiplied by `confidenceParam` (owner/updater-settable through the
factory, default `0` = the oracle spread is ignored, up to the 100x `CONFIDENCE_MAX` ceiling — see
Step 4), then a fixed per-side `marginStep` (bid/ask step, immutable at construction), all under a
staleness bound (`maxTimeDelta`, also immutable) — and there is no admin allow-list or parameter
envelope to satisfy (`createPriceProvider` is unconditionally permissionless). An
`AnchoredPriceProvider` is a different, stronger construction: it derives its own bid/ask band from
a *reference* oracle's uncertainty and clamps any custom source or confidence widening to never go
tighter than that band — see [`anchored-price-provider.md`](./anchored-price-provider.md). Pick the
plain provider when a single oracle's quote (shaped only by the three knobs above) is enough; pick
the APP when you need the reference-anchored safety band.

Full reference: [`../contracts/PriceProvider.sol`](../contracts/PriceProvider.sol),
[`../contracts/PriceProviderFactory.sol`](../contracts/PriceProviderFactory.sol).

```bash
# ── ethereum addresses & keys — CANONICAL, kept in sync with ../script/config/networks.json
# (CREATE3: same address on every chain that carries the contract; see ../DEPLOYMENTS.md).
# Do NOT copy addresses out of older docs or git history: every superseded generation is
# still deployed and still accepts transactions, so a stale address fails silently — you
# would bind a provider to an oracle nobody pushes to, or push into one nobody reads. ──
export RPC=ethereum                                               # or https://ethereum-rpc.publicnode.com
export PRICE_PROVIDER_FACTORY=0x313E90693849884Ab88e750a51227ae7e391b5F0   # PriceProviderFactory
export COMPRESSED=0xADDfc3a4c50E99BC0eF418696573DCffeE2EA8B4       # reference oracle (CompressedOracleV1)
export PYTH=0x4ACDAF5429AeeF693b8804948d2Fd8FD1e64558a            # reference oracle (Pyth)
export CL=0x1E4a892698BAcb395F61B5d42Db93264b300770f              # reference oracle (Chainlink)
export CREATOR_KEY=0x...   # anyone — becomes the provider owner

# feed id — meaning depends on which oracle you point at:
# CompressedOracleV1: there is no shared registry, you own your own namespace. Derive your feedId
# from your own address + a slot/position you pick (0/0 below is just the first slot):
export FEED=$(cast call $COMPRESSED "feedIdOf(address,uint8,uint8)(bytes32)" \
  $(cast wallet address --private-key $CREATOR_KEY) 0 0 --rpc-url $RPC)
# Pyth/Chainlink: FEED is the provider-assigned feed id instead, e.g. cbBTC=397 on Pyth Lazer:
#   export FEED=$(cast to-uint256 397)
```

## Step 0 — nothing to check up front

Unlike `AnchoredProviderFactory`, `PriceProviderFactory` has no oracle allow-list and no parameter
envelope: `createPriceProvider` is unconditionally permissionless for any oracle address, feed id,
`marginStep`, and `maxTimeDelta` the caller chooses (the constructor only checks its own local bounds —
see the cheatsheet in Step 2). There is no factory-side setup step to verify before creating — go
straight to checking the feed has data.

## Step 1 — make sure the feed has data in the oracle

The oracles are registrationless — there is no feed registration and no registrar role. A feed exists
once its first provider-signed (Pyth/Chainlink) or pushed (compressed) update lands, published by the
companion off-chain stack (published separately). The exact "has data" check differs by oracle family:

**`CompressedOracleV1`** — a feed's storage location *is* its identity; there is no missing-feed
revert for a syntactically valid feedId. A never-pushed position just reads back all zeros:

```bash
cast call $COMPRESSED "price(bytes32,address)(uint256,uint256,uint16,uint256)" $FEED \
  0x0000000000000000000000000000000000000000 \
  --from 0x0000000000000000000000000000000000000000 --rpc-url $RPC
# (0, 0, 0, 0) => no data yet; any non-zero mid/refTime => the feed already has data
```

**`PythOracle` / `ChainlinkOracle`** — these revert `FeedNotFound` until the first verified push:

```bash
cast call $PYTH "price(bytes32,address)(uint256,uint256,uint16,uint256)" $FEED \
  0x0000000000000000000000000000000000000000 \
  --from 0x0000000000000000000000000000000000000000 --rpc-url $RPC
# reverts FeedNotFound => still no data; anything else => the feed has data. getOracleData()
# is unconditionally disabled (ReadDisabled) and can never be used for this check — the
# eth_call `--from` zero address puts tx.origin == address(0), which takes the tx.origin == 0
# read path of the access-gated reader.
```

Provider **creation** still succeeds against a feed with no data yet (the constructor does not read
the oracle); the provider simply reverts at read time until data arrives — `getQuote()`
surfaces `FeedStalled` for a compressed-oracle reference and `FeedNotFound` for a
Pyth/Chainlink-backed one.

## Step 2 — create the provider (anyone)

Easiest — the script (`CreatePriceProvider.s.sol` via its wrapper). Pass the factory and oracle
explicitly via `PRICE_PROVIDER_FACTORY` / `REFERENCE_ORACLE`: left unset, the script falls back to the committed
`script/config/networks.json`, which is deploy-script working state and may lag the canonical
addresses in [`../DEPLOYMENTS.md`](../DEPLOYMENTS.md).
The caller becomes the provider owner:

```bash
NETWORK=ethereum PRICE_PROVIDER_FACTORY=$PRICE_PROVIDER_FACTORY REFERENCE_ORACLE=$COMPRESSED FEED_ID=$FEED \
  BASE_TOKEN=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
  QUOTE_TOKEN=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
  MARGIN_STEP=0 MAX_TIME_DELTA=60 \
  PRIVATE_KEY=$CREATOR_KEY BROADCAST=1 ./script/create-price-provider.sh
```

(Omit `BROADCAST=1` for a dry-run. Optional env: `REFERENCE=compressed|pyth|chainlink` — default
`compressed`, ignored when `REFERENCE_ORACLE` is set explicitly — see the script header.)

Or the raw call:

```bash
# createPriceProvider(oracle, feedId, marginStep, maxTimeDelta, baseToken, quoteToken)
cast send $PRICE_PROVIDER_FACTORY \
  "createPriceProvider(address,bytes32,int256,uint256,address,address)" \
  $COMPRESSED \
  $FEED \
  0 \
  60 \
  0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
  --private-key $CREATOR_KEY --rpc-url $RPC
```

Param cheatsheet (constructor-local bounds only — no factory allow-list or envelope):

| arg | value used | rule |
|---|---|---|
| `oracle` | any already-deployed oracle | `CompressedOracleV1`, `PythOracle`, or `ChainlinkOracle` — no allow-list |
| `feedId` | depends on `oracle` | packed `CompressedOracleV1` feedId, or the Pyth Lazer / Chainlink Data Streams feed id |
| `marginStep` | `0` | `1e18` scale (`100%`); strictly `-1e18 < x < 1e18` (constructor reverts `MarginStepOutOfBounds` otherwise); `0` = no step |
| `maxTimeDelta` | `60` | seconds; `0 < x <= 7 days` (constructor reverts `MaxTimeDeltaOutOfBounds` otherwise) |
| `baseToken` / `quoteToken` | pair addresses | **mandatory**, distinct, non-zero (the oracles are token-free) |

## Step 3 — get the new provider address

```bash
# all providers you created (newest last):
cast call $PRICE_PROVIDER_FACTORY "getProviders(address,uint256,uint256)(address[],uint256[],uint256)" \
  $(cast wallet address --private-key $CREATOR_KEY) 0 100 --rpc-url $RPC
```

(Or read the `provider` field of the `ProviderDeployed` event in the tx receipt.)

## Step 4 — optional curation (owner)

```bash
cast send $PRICE_PROVIDER_FACTORY "setConfidence(address[],uint256[])" "[$PROVIDER]" "[5000]" --private-key $CREATOR_KEY --rpc-url $RPC
cast send $PRICE_PROVIDER_FACTORY "grantUpdater(address,address)" $PROVIDER $UPDATER --private-key $CREATOR_KEY --rpc-url $RPC
cast send $PRICE_PROVIDER_FACTORY "transferProviderOwnership(address,address)" $PROVIDER $NEW_OWNER --private-key $CREATOR_KEY --rpc-url $RPC
```

`confidenceParam` multiplies the oracle's own spread (`0` = no widening beyond `marginStep`;
`1_000_000` = the 100x ceiling); it is rate-limited to one update per `CONFIDENCE_COOLDOWN` (1
minute). `grantUpdater` lets a delegate call `setConfidence` without transferring ownership; only the
owner can `setConfidence`, `grantUpdater`/`revokeUpdater`, or `transferProviderOwnership`.

Done — `factory.isProvider(provider) == true` is the tracked-provider check (used by
`getAllProviders`/`getProviders`); there is no separate public-pool eligibility gate to satisfy the
way there is for the APP factory's envelope.
