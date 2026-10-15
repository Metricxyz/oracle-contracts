# Multiplier Oracle — integrator quickstart

Price a pool in a tokenized stock whose redemption ratio is an on-chain **multiplier** (Coinbase B20
Assets on Base, Robinhood Stock Tokens on Robinhood Chain, or any other ERC-8056 "Scaled UI Amount"
token with an adapter). The `MultiplierOracle` returns `share price × multiplier`: the price of the
token as it trades, not of the share behind it. A multiplier change is applied when the issuer
applies it; an announced change of at most 10% is applied at announcement, and a larger one stalls
the feed until it takes effect. Full reference: [`multiplier-oracle.md`](./multiplier-oracle.md).

**Why not price the token off a share feed directly:** the multiplier is the number of shares one
token redeems for. A reinvested dividend nudges it up and an N:1 split multiplies it by N, while raw
ERC-20 balances never change. A pool priced off the share feed drifts below fair value with every
dividend and is off by N× after a split.

Export the oracle, adapter, `PythOracle` and factory addresses from the
[deployment record](DEPLOYMENTS.md#multiplier-lane-base-and-robinhood); the lane exists on base and
robinhood only.

```bash
# ── addresses — from DEPLOYMENTS.md ──
: "${MULTIPLIER_ORACLE:?Set from DEPLOYMENTS.md}"
: "${PYTH:?Set the PythOracle from DEPLOYMENTS.md}"                            # its underlying (share prices)
: "${ANCHORED_PROVIDER_FACTORY:?Set from DEPLOYMENTS.md}"

# base (Coinbase B20 Assets)
export RPC=base                                                                # or https://mainnet.base.org
: "${ADAPTER:?Set B20AssetParams from DEPLOYMENTS.md}"
export TOKEN=0xb200000000000000000000C2e324d24d7eEcd1fb                        # AAPLc
export USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913

# robinhood (Robinhood Stock Tokens) — instead of the base block
# export RPC=robinhood
# : "${ADAPTER:?Set RobinhoodStockTokenParams from DEPLOYMENTS.md}"
# export TOKEN=0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9                      # AAPL
# : "${USDC:?Set the pool's quote token}"
# check that a USDC/USD feed has data on the chain (Step 0) before building a synthetic provider;
# without one, build a single-leg token/USD provider (no QUOTE_FEED_ID)

export ZERO=0x0000000000000000000000000000000000000000
# the SHARE's Pyth Lazer id as bytes32 — the Equity.Index.*/USD feeds, which are the ones the relayer
# publishes (NOT Equity.US.*/USD, e.g. AAPL 922). Step 0 checks that an id has data on the chain.
# TSLA=3185 MSTR=3187 NVDA=3188 AAPL=3191 AMZN=3192 GOOGL=3194 MSFT=3196 META=3262 SNDK=3264
# SPCX=3316; USDC/USD=7
export SHARE=$(cast to-uint256 3191)
: "${CREATOR_KEY:?Set the key that creates the feeds and owns the provider}"
```

Canonical token addresses come from the issuers: Coinbase's tokenized-stocks page for Base,
Robinhood's Token Contracts page or `https://api.robinhood.com/rhj/assets` for Robinhood Chain. Use
the adapter of the token's own family: the B20 adapter refuses non-B20 addresses, and a token
without the Robinhood adapter's getters stalls; a token that answers another family's getters is
not detected.

## Step 0 — check the prerequisites (read-only)

```bash
# the adapter is allow-listed on the oracle                                   need: true
cast call $MULTIPLIER_ORACLE "isParamsAdapter(address)(bool)" $ADAPTER --rpc-url $RPC

# the issuer answers for the token: (multiplier WAD, paused)                    need: > 0, false
cast call $ADAPTER "getOracleParams(address)(uint256,bool)" $TOKEN --rpc-url $RPC

# the share price is published on the underlying oracle
cast call $PYTH "price(bytes32,address)(uint256,uint256,uint16,uint256)" $SHARE $ZERO \
  --from $ZERO --rpc-url $RPC
# FeedNotFound => the PythOracle holds no observation for this id on this chain (check it is the
# Equity.Index id); every read of a feed built on it reverts while it holds none. A stalled or
# saturated share also returns a value: it has usable data only when the mid is positive, refTime is
# recent and not in the future, and spread0 is below 65534 (65534 = saturated, 65535 = stall).

# providers created through the anchored factory: the oracle is allow-listed    need: true
cast call $ANCHORED_PROVIDER_FACTORY "isOracle(address)(bool)" $MULTIPLIER_ORACLE --rpc-url $RPC
```

## Step 1 — create the feeds (anyone)

A feed binds three things: the share's feed on the underlying oracle, the token, and the adapter.
`createFeed` is permissionless and idempotent: an existing feed is returned as is. The feed id is the
hash of the binding, so it can be computed before the feed exists:

```bash
export STOCK_FEED=$(cast call $MULTIPLIER_ORACLE "feedIdOf(bytes32,address,address)(bytes32)" \
  $SHARE $TOKEN $ADAPTER --rpc-url $RPC)
cast send $MULTIPLIER_ORACLE "createFeed(bytes32,address,address)" $SHARE $TOKEN $ADAPTER \
  --private-key $CREATOR_KEY --rpc-url $RPC
```

**Quoting in USDC with a synthetic pair** (token/USD ÷ USDC/USD)? A synthetic provider reads both
legs from one oracle, so the USDC/USD leg must come from this oracle too. Create it as a
**passthrough feed**, with no token and no adapter. It returns the underlying price unchanged:

```bash
export USDC_FEED=$(cast call $MULTIPLIER_ORACLE "feedIdOf(bytes32,address,address)(bytes32)" \
  $(cast to-uint256 7) $ZERO $ZERO --rpc-url $RPC)
cast send $MULTIPLIER_ORACLE "createFeed(bytes32,address,address)" $(cast to-uint256 7) $ZERO $ZERO \
  --private-key $CREATOR_KEY --rpc-url $RPC
```

A single-leg provider (token/USD, USDC taken as $1) needs no passthrough feed. It saves one oracle
read per quote (about 44k gas) but ignores a USDC depeg.

**Never build a passthrough feed over the share.** `createFeed($SHARE, $ZERO, $ZERO)` succeeds, because the
oracle cannot tell a share from a quote currency, and it returns the share price with **no
multiplier**:

- the token is underpriced by every dividend;
- after a split it is priced at a fraction of its value.

The base leg must always be the stock feed, and a passthrough feed only ever serves as the quote leg. To
check an existing provider, read `feeds(feedId)` for each of its feeds:

```bash
cast call $MULTIPLIER_ORACLE "feeds(bytes32)(bytes32,address,address)" $STOCK_FEED --rpc-url $RPC
# (underlying, token, params): the base leg must name the pool's base token and its family's adapter
```

## Step 2 — create the provider (anyone)

This is the normal provider creation of the
[Anchored Price Provider quickstart](./anchored-price-provider-quickstart.md), with the multiplier
oracle as the reference oracle and its feed ids in place of Lazer ids:

```bash
NETWORK=$RPC ANCHORED_PROVIDER_FACTORY=$ANCHORED_PROVIDER_FACTORY REFERENCE_ORACLE=$MULTIPLIER_ORACLE \
  BASE_FEED_ID=$STOCK_FEED QUOTE_FEED_ID=$USDC_FEED \
  BASE_TOKEN=$TOKEN QUOTE_TOKEN=$USDC \
  MIN_MARGIN=100000000000000 MAX_REF_STALENESS=60 \
  PRIVATE_KEY=$CREATOR_KEY BROADCAST=1 ./script/create-anchored-provider.sh
```

- Omit `QUOTE_FEED_ID` for a single-leg provider.
- Omit `BROADCAST=1` for a dry-run.
- Every other parameter is in the APP quickstart; the raw `createAnchoredProvider` call is in the
  [APP reference](./anchored-price-provider.md).
- A feed id with no class assigned (`setFeedClass`) falls into the factory's `DEFAULT_CLASS` envelope.
- A plain `PriceProvider` ([quickstart](./price-provider-quickstart.md)) works the same way. This
  oracle serves the same `price(feedId, pool)` / `priceGuard(feedId)` surface as the other oracles.

**Bind the right token.** Nothing on-chain checks either of these:

- `BASE_TOKEN` must be the token the stock feed was created for;
- the feed's share must be that token's own share.

`createFeed` accepts any combination, including the AAPL share with a TSLA token, or with a token
whose multiplier its creator controls. Whoever reviews a provider (yours or anyone else's) checks two
things:

- with `feeds(baseFeedId)` as in Step 1, that `token` equals the pool's base token;
- that its own staleness bound is short (see below). On an `AnchoredPriceProvider`, read the cap
  `MAX_REF_STALENESS()` and the per-leg bounds actually enforced, `baseMaxStaleness()` /
  `quoteMaxStaleness()`. On a plain `PriceProvider`, read `MAX_TIME_DELTA()`.

**Staleness.** A multiplier change moves the token's price at once. The share price behind it moves
when the share feed updates, and the read's `refTime` is the share feed's. The `Equity.Index` share
feeds update around the clock, weekends included, so the provider's staleness bound halts the pool
only when the relayer stops publishing. It is not a guard around corporate actions.

The deployed `DEFAULT_CLASS` envelope allows up to 60 s, but that is a setting. The factory admin can
widen it (`setEnvelope`) or move a feed to another class (`setFeedClass`), up to the factory's hard
`MAX_STALENESS` of 7 days. A directly deployed `AnchoredPriceProvider`, or a plain `PriceProvider`,
accepts up to 7 days as well, and with that bound the pool would keep quoting a days-old price after a
relayer outage. A factory-created provider is not guaranteed to be under 60 s, so check the provider's
own bound, not how it was created.

**Quoting at all hours.** Outside the regular session the share feeds keep moving with the same
near-zero spread (0.01–0.03 bp), so the pool quotes nights and weekends with a band close to
`minMargin`. Size the margin for overnight and weekend moves, including the gap at the open.

## Step 3 — register the pool (anyone, paid)

The oracle is gated like the Pyth oracle behind it. A pool may read a feed only while it is
mid-swap through the provider, only if it is registered for the feed, and only if it is not
blacklisted. Register the pool once for **every** feed its provider reads. The registration is
forwarded to the underlying oracle together with its fee:

```bash
: "${POOL:?Set the pool address}"
: "${POOL_FACTORY:?Set the pool's AMM factory}"
FEE=$(cast call $PYTH "registrationFee()(uint256)" --rpc-url $RPC | cut -d' ' -f1)
cast send $MULTIPLIER_ORACLE "register(bytes32,address,address)" $STOCK_FEED $POOL $POOL_FACTORY \
  --value $FEE --private-key $CREATOR_KEY --rpc-url $RPC
# synthetic pairs: the same for $USDC_FEED

cast call $MULTIPLIER_ORACLE "registeredPool(bytes32,address)(bool)" $STOCK_FEED $POOL --rpc-url $RPC   # need: true
```

`$POOL_FACTORY` is the pool's AMM factory. It must be approved on the underlying oracle
(`cast call $PYTH "isApprovedFactory(address)(bool)" $POOL_FACTORY --rpc-url $RPC`) and must recognise the pool
(`isPool`). The registration lands on the underlying share feed. A pool registered there directly is
registered for the multiplier feed too.

## Step 4 — read the price (off-chain)

```bash
cast call $MULTIPLIER_ORACLE "price(bytes32,address)(uint256,uint256,uint16,uint256)" $STOCK_FEED $ZERO \
  --from $ZERO --rpc-url $RPC
# (mid, spread, spread1, refTime)
```

The zero `--from` puts `tx.origin == address(0)`, which skips the pool gate. Off-chain monitoring
therefore needs no registration.

| Field | Meaning |
| --- | --- |
| `mid` | USD per whole token, 8 decimals (`decimals() == 8`): the share price × multiplier / 1e18 |
| `spread`, `spread1` | the underlying's spreads, unchanged: they are relative, so they carry over to the scaled price |
| `refTime` | the share price's timestamp on the underlying oracle (seconds) |

**Stall:** `mid = 0` with `spread = 65535`. The provider reverts and the pool cannot swap. A stock
feed stalls when any of these hold:

- the issuer has its pause flag set;
- the share price is 0, stalled, saturated, or outside its price guard on the underlying oracle;
- the adapter is not on the allow-list;
- the adapter cannot answer (wrong token family, missing getter);
- the multiplier is 0.

Quoting resumes by itself when the cause clears.

## What happens on a corporate action

Nothing is required from you. The issuer's procedure is:

1. Set its pause flag. Your pool halts.
2. Update the multiplier.
3. Wait until the market prices the share consistently with it. If the share feed carries a price
   guard on the underlying oracle, the guard's owner retunes it here: a guard sized before a split
   would stall the pool after it.
4. Clear the flag. The pool resumes at `new share price × new multiplier`.

Raw token balances, including the pool's reserves, do not change at any point. To watch it:

- B20: `getOracleParams(token)` on the adapter, or on Coinbase's OracleRegistry
  `0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD`;
- Robinhood: `uiMultiplier()` and `oraclePaused()` on the token;
- either family: a change announced in `newUIMultiplier()` / `effectiveAt()` on the token. While one
  is pending, whatever its lead time, the feed prices a dividend-sized change (at most 10%) at once
  and stalls on a larger one until it takes effect.

## What you are trusting

- **The issuer, outright.** The oracle applies whatever multiplier the issuer publishes. Around a
  corporate action the guards are the issuer's pause flag and, for a change the issuer announces,
  the adapter's schedule handling. Robinhood documents `oraclePaused()` as
  advisory. An issuer key compromise (unbacked mints, a forged multiplier) is outside the oracle's
  reach.
- **The issuer's timing.** A change applied without the pause flag and without an announcement has
  no guard, at any hour. The share feeds never stop, so a multiplier that moves before the share price, or lags it, is
  mispriced by the full ratio on a fresh feed, with no staleness halt. Lagging looks like this: on an
  N:1 split the share reprices to 1/N while the multiplier is still the old one, so the token quotes at
  1/N of its value.
- **The provider's feed bindings and staleness.** The base feed's token must be the pool's base token,
  and the staleness bound must be short enough to halt on a relayer outage (Step 2). The quote leg must
  be a passthrough over a quote currency, never over a share (Step 1).
- **Off-session prices.** The pool quotes around the clock with a band close to `minMargin` (Step 2).
- **The token's own controls.** Transfer pauses, blocklists and seizures act on the pool's balances,
  not on the price.
- **The adapter allow-list and the feed switch.** The oracle's admin can stop one feed
  (`setFeedDisabled`) or remove an adapter found faulty, which stalls every feed built on it. Either
  way, reads stall until the admin undoes it.
- **The underlying oracle's admin.** It can remove this oracle as an integrator or blacklist it.
  Every read then reverts, and the pool cannot swap, as on a stall.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `FeedNotFound(id)` with your multiplier feed id | the feed was never created | Step 1 |
| `FeedNotFound(id)` with the share's Lazer id | the relayer does not publish the share on this chain | ask the Metric team to add it |
| `ParamsAdapterNotAllowed(adapter)` on `createFeed` | adapter not on the allow-list | use the chain's adapter (Step 0) |
| `BadFeedConfig()` on `createFeed` | exactly one of `token` / `params` is zero, or the share id is zero | both set (stock feed) or both zero (passthrough) |
| `InvalidInSwap()` | an on-chain read outside a swap through the provider | read off-chain as in Step 4 |
| `NotRegistered(feedId, pool)` | the pool is not registered for that feed | Step 3, for every feed the provider reads |
| `InsufficientFee(sent, required)` | registration underpaid | `--value` ≥ `registrationFee()` |
| `FactoryNotApproved(factory)` / `NotAPool(pool)` | the pool's factory is not approved on the underlying oracle, or does not know the pool | ask the Metric team to approve the factory |
| `Blacklisted(addr)` | the pool or provider is blacklisted on the underlying oracle | registering again clears a pool's blacklist |
| `NotWhitelisted(oracle)`, or `Blacklisted(oracle)` with the multiplier oracle's address, on every read | the multiplier oracle lost its integrator access on the underlying oracle | ask the Metric team; every feed on the oracle is halted |
| `mid = 0`, `spread = 65535` | a stall (Step 4) | check the issuer flag and multiplier (Step 0), then the share feed |

## Another token family

A family plugs in with its own adapter. It is a stateless contract implementing
`IOracleParams.getOracleParams(token) → (uint256 multiplier, bool paused)`
([`IOracleParams.sol`](../contracts/interfaces/IOracleParams.sol)), with the multiplier as a WAD
(`1e18` = one share per token). The oracle's admin allow-lists it with `addParamsAdapter`. Nothing
else changes.

The adapter must answer with exactly the ABI encoding of `(uint256, bool)`: 64 bytes, with the bool
word 0 or 1, within `ADAPTER_GAS_LIMIT` (200 000 gas). The oracle copies at most 64 bytes of the
output, so a revert, a malformed or oversized answer, or an adapter that runs out of gas stalls the
read rather than reverting it.
