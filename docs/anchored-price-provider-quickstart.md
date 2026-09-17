# Anchored Price Provider creation — quickstart (manual)

Create one Anchored Price Provider. Concrete values are for **base**; swap addresses/feed ids for other
networks. Full reference: [`anchored-price-provider.md`](./anchored-price-provider.md).

```bash
# ── base addresses & keys — CANONICAL, kept in sync with ../script/config/networks.json
# (CREATE3: same address on every chain that carries the contract; see ../DEPLOYMENTS.md).
# Do NOT copy addresses out of older docs or git history: every superseded generation is
# still deployed and still accepts transactions, so a stale address fails silently — you
# would bind a provider to an oracle nobody pushes to, or push into one nobody reads. ──
export RPC=base                                                   # or https://mainnet.base.org
export ANCHORED_PROVIDER_FACTORY=0xb0eAE19259500Ac4Ca59b9a5cb8cDB2Da8076F0A   # AnchoredProviderFactory
export PYTH=0x30a88bf894D1b806125a23ebf23D715496fD7102            # reference oracle (Pyth)
export CL=0x810A649974f21bB6D3b2E781597EdBDAabe82228              # reference oracle (Chainlink)
export ADMIN_KEY=0x...     # factory admin (only for one-time factory setup)
export CREATOR_KEY=0x...   # anyone — becomes the provider owner

# feed = Pyth Lazer id as bytes32:  cbBTC=397  ETH=2  USDC=7
export FEED=$(cast to-uint256 397)        # cbBTC  -> 0x..018d
```

## Step 0 — check the factory's on-chain state (read-only)

```bash
cast call $ANCHORED_PROVIDER_FACTORY "isOracle(address)(bool)" $PYTH --rpc-url $RPC          # need: true
cast call $ANCHORED_PROVIDER_FACTORY "envelopes(bytes32)(uint256,uint256,uint256,uint256,uint256,bool)" \
  $(cast call $ANCHORED_PROVIDER_FACTORY "DEFAULT_CLASS()(bytes32)" --rpc-url $RPC) --rpc-url $RPC   # last field must be true
cast call $PYTH "price(bytes32,address)(uint256,uint256,uint16,uint256)" $FEED \
  0x0000000000000000000000000000000000000000 \
  --from 0x0000000000000000000000000000000000000000 --rpc-url $RPC
# reverts FeedNotFound => no data yet. Anything else (a successful return, or a different
# revert such as InvalidInSwap for pool=0x0) => the feed already has data. getOracleData()
# is unconditionally disabled (ReadDisabled) and can never be used for this check — the
# eth_call `--from` zero address puts tx.origin == address(0), which takes the tx.origin == 0
# read path of the access-gated reader.
```

> On **base**, the deployed factory's allow-list contains Pyth and Chainlink and the `DEFAULT_CLASS`
> envelope — identical on all ten chains — is
> `(minMargin 1e11..1e15, staleness 0..60s, spreadMultMax 2e18)` — `minMargin` has a nonzero floor
> (`minMargin == 0` is rejected by the provider) — the Step 0
> reads above verify this. The remaining prerequisite is feed data (Step 1). Steps 0a/0b below
> apply only to a factory whose Step 0 checks fail.

<details><summary>0a/0b — one-time factory setup (skip when the Step 0 checks pass)</summary>

```bash
# allow-list the reference oracle
cast send $ANCHORED_PROVIDER_FACTORY "addOracle(address)" $PYTH --private-key $ADMIN_KEY --rpc-url $RPC
# DEFAULT_CLASS envelope — the production default values:
# (minMarginMin,minMarginMax,stalenessMin,stalenessMax,spreadMultMax,exists)
cast send $ANCHORED_PROVIDER_FACTORY "setEnvelope(bytes32,(uint256,uint256,uint256,uint256,uint256,bool))" \
  $(cast call $ANCHORED_PROVIDER_FACTORY "DEFAULT_CLASS()(bytes32)" --rpc-url $RPC) \
  "(100000000000,1000000000000000,0,60,2000000000000000000,false)" --private-key $ADMIN_KEY --rpc-url $RPC
```
</details>

## Step 1 — make sure the feed has data in the oracle

The oracles are registrationless — there is no feed registration and no registrar role. A feed exists
once its first provider-signed update lands, pushed by the companion off-chain stack (published
separately). Until then oracle reads revert `FeedNotFound`; provider **creation** still succeeds (the
constructor does not read the oracle), but the provider halts at read time until data arrives.

```bash
cast call $PYTH "price(bytes32,address)(uint256,uint256,uint16,uint256)" $FEED \
  0x0000000000000000000000000000000000000000 \
  --from 0x0000000000000000000000000000000000000000 --rpc-url $RPC
# FeedNotFound => still no data; anything else => the feed has data (see Step 0)
```

## Step 2 — create the provider (anyone)

Easiest — the script (`CreateAnchoredProvider.s.sol` via its wrapper). Pass the factory and oracle
explicitly via `ANCHORED_PROVIDER_FACTORY` / `REFERENCE_ORACLE`: left unset, the script falls back to the committed
`script/config/networks.json`, which is deploy-script working state and may lag the canonical
addresses in `DEPLOYMENTS.md`. The caller becomes the provider owner:

```bash
NETWORK=base ANCHORED_PROVIDER_FACTORY=$ANCHORED_PROVIDER_FACTORY REFERENCE_ORACLE=$PYTH BASE_FEED_ID=397 \
  BASE_TOKEN=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
  QUOTE_TOKEN=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  MIN_MARGIN=100000000000000 MAX_REF_STALENESS=60 \
  PRIVATE_KEY=$CREATOR_KEY BROADCAST=1 ./script/create-anchored-provider.sh
```

(Omit `BROADCAST=1` for a dry-run. Optional env: `REFERENCE=pyth|chainlink`, `QUOTE_FEED_ID`,
`MAX_SPREAD_MULT` (default `1e18`), `MUTABLE_PARAMS`, `MARGIN_STEP`, and the initial config applied
at construction — `SOURCE`, `BASE_MAX_STALENESS` / `QUOTE_MAX_STALENESS` (default `MAX_REF_STALENESS`),
`BASE_SPREAD_MULT` / `QUOTE_SPREAD_MULT` (default `1e18`) — see the script header.)

Or the raw call. The last arg is the `InitialConfig` tuple
`(source, baseMaxStaleness, quoteMaxStaleness, baseSpreadMult, quoteSpreadMult)` applied at
construction through the same validation the setters use; pass `(0,<staleness>,<staleness>,1e18,1e18)`
for the plain 1.0× / shared-staleness / reference-mode default:

```bash
# createAnchoredProvider(oracle, baseFeedId, quoteFeedId, minMargin, maxRefStaleness,
#             maxSpreadMult, mutableParams, marginStep, baseToken, quoteToken, InitialConfig)
cast send $ANCHORED_PROVIDER_FACTORY \
  "createAnchoredProvider(address,bytes32,bytes32,uint256,uint256,uint256,bool,int256,address,address,(address,uint256,uint256,uint256,uint256))" \
  $PYTH \
  $FEED \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  100000000000000 \
  60 \
  1000000000000000000 \
  false \
  0 \
  0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  "(0x0000000000000000000000000000000000000000,60,60,1000000000000000000,1000000000000000000)" \
  --private-key $CREATOR_KEY --rpc-url $RPC
```

Param cheatsheet (must sit inside the `DEFAULT_CLASS` envelope above):

| arg | value used | rule |
|---|---|---|
| `quoteFeedId` | `0` | `0` = single feed; non-zero = synthetic `base/quote` |
| `minMargin` | `1e14` | `1e18` scale (1 bps = `1e14`); envelope `1e11..1e15`. **Must be > 0** — `0` reverts `MinMarginZero` |
| `maxRefStaleness` | `60` | seconds; envelope `0..60`. On a **synthetic** pair this also sets how far apart in time the two legs may be — there is no separate cross-leg bound, so tighten it for two-feed providers |
| `maxSpreadMult` | `1e18` | per-leg spread-multiplier ceiling (`1e18` = 1.0×); `>= 1e18`, envelope `spreadMultMax` |
| `mutableParams` | `false` | `true` lets the owner tune `confidenceParam` + the per-leg knobs later |
| `marginStep` | `0` | not envelope-bound; `\|x\| < 1e18` |
| `baseToken` / `quoteToken` | pair addresses | **mandatory**, distinct, non-zero (the oracles are token-free) |

## Step 3 — get the new provider address

```bash
# all providers you created (newest last):
cast call $ANCHORED_PROVIDER_FACTORY "getProviders(address,uint256,uint256)(address[],uint256)" \
  $(cast wallet address --private-key $CREATOR_KEY) 0 100 --rpc-url $RPC
```

(Or read the `provider` field of the `ProviderDeployed` event in the tx receipt.)

## Step 4 — optional curation (owner)

```bash
cast send $ANCHORED_PROVIDER_FACTORY "setSource(address,address)" $PROVIDER $SOURCE --private-key $CREATOR_KEY --rpc-url $RPC
# customizable variant only (mutableParams=true):
cast send $ANCHORED_PROVIDER_FACTORY "setConfidence(address[],uint256[])" "[$PROVIDER]" "[5000]" --private-key $CREATOR_KEY --rpc-url $RPC
```

Done — `factory.isProvider(provider) == true` is the public-pool eligibility check.
