# Create an Anchored Price Provider

Create an APP through an existing `AnchoredProviderFactory`. The caller becomes its
owner. APP prevents a quote from being tighter than its configured reference band;
it does not cap outward widening. Read [the overview](oracle-overview.md#what-anchoring-guarantees)
and rehearse the [integration quickstart](integration-quickstart.md) first.

## Step 0 — prepare inputs

Run from the repository root with Foundry installed. Export these values in your
shell or supply them through your normal environment tooling:

| Variable | Value and constraints |
| --- | --- |
| `NETWORK` | A configured Foundry RPC alias/network key; configure its endpoint variable from `foundry.toml`, e.g. `RPC_BASE` for `base` |
| `ANCHORED_PROVIDER_FACTORY` | Explicit factory address from [DEPLOYMENTS.md](../DEPLOYMENTS.md) |
| `REFERENCE_ORACLE` | Explicit address of an allowed reference oracle |
| `BASE_FEED_ID` | Reference feed, decimal or hexadecimal |
| `QUOTE_FEED_ID` | `0` for a direct pair; otherwise a second feed from the same oracle |
| `BASE_TOKEN`, `QUOTE_TOKEN` | Nonzero, distinct addresses matching the direct feed or synthetic ratio |
| `MIN_MARGIN` | Positive fraction × `1e18`, within the effective envelope; `1e14` = 1 bp |
| `MAX_REF_STALENESS` | Hard age ceiling in seconds, `0..604800`, within the effective envelope |
| `MAX_SPREAD_MULT` | Per-leg multiplier ceiling, at least `1e18`, within the envelope |
| `MUTABLE_PARAMS` | `false` fixes the initial knobs; `true` allows bounded, cooldown-limited updates |
| `MARGIN_STEP` | Fixed shaping bias, strictly between `-1e18` and `1e18`; default `0` |
| `PRIVATE_KEY` | Your provider creator's transaction key |

These commands use `--rpc-url "$NETWORK"`; set that alias's endpoint rather than only
`RPC_URL`. Supplying explicit factory/oracle addresses avoids stale script defaults.

For a synthetic pair, match both denomination and token identity. For example,
`cbBTC/USD ÷ USDC/USD` yields `cbBTC/USDC`; a single `cbBTC/USD` feed is not that
conversion. The contracts do not validate the economic match. Both legs need fresh
data, and on a Pyth or Chainlink oracle both need pool read registration.

Initial configuration is optional:

| Variable | Default | Rule |
| --- | --- | --- |
| `SOURCE` | Zero address (reference mode) | Nonzero source must satisfy [IAnchorSource](../contracts/interfaces/IAnchorSource.sol) |
| `BASE_MAX_STALENESS`, `QUOTE_MAX_STALENESS` | `MAX_REF_STALENESS` | Each must be at most the hard ceiling |
| `BASE_SPREAD_MULT`, `QUOTE_SPREAD_MULT` | `1e18` | Each must be at most `MAX_SPREAD_MULT`; values below 1× are supported |

A zero leg age limit means its observation time must equal `block.timestamp`, in whole seconds. There is
no separate cross-leg timestamp-skew limit. Pick these values from the intended
freshness policy and delivery path, not from a generic cadence recommendation.

## Step 1 — inspect the effective factory policy

Convert the base ID to a 32-byte value for ABI reads, then resolve its class:

```bash
: "${NETWORK:?Set the Foundry RPC alias}"
: "${ANCHORED_PROVIDER_FACTORY:?Set the factory from DEPLOYMENTS.md}"
: "${REFERENCE_ORACLE:?Set the reference oracle from DEPLOYMENTS.md}"
: "${BASE_FEED_ID:?Set the base feed ID}"
BASE_FEED_BYTES32=$(cast to-uint256 "$BASE_FEED_ID")
cast call "$ANCHORED_PROVIDER_FACTORY" "isOracle(address)(bool)" \
  "$REFERENCE_ORACLE" --rpc-url "$NETWORK"
CLASS_ID=$(cast call "$ANCHORED_PROVIDER_FACTORY" "feedClass(bytes32)(bytes32)" \
  "$BASE_FEED_BYTES32" --rpc-url "$NETWORK")
if [ "$CLASS_ID" = "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
  CLASS_ID=$(cast call "$ANCHORED_PROVIDER_FACTORY" "DEFAULT_CLASS()(bytes32)" --rpc-url "$NETWORK")
fi
cast call "$ANCHORED_PROVIDER_FACTORY" \
  "envelopes(bytes32)(uint256,uint256,uint256,uint256,uint256,bool)" \
  "$CLASS_ID" --rpc-url "$NETWORK"
```

Require `isOracle == true` and the envelope's last field `exists == true`. Its
fields are `(minMarginMin, minMarginMax, stalenessMin, stalenessMax, spreadMultMax,
exists)`. Check your requested parameters against the returned bounds. The class
is selected by `baseFeedId`, not by `quoteFeedId`.

If these checks fail, select supported inputs or coordinate with the factory
administrator. Factory setup is a separate administrator workflow described in
[the APP reference](anchored-price-provider.md#step-1--curate-the-oracle-allow-list-admin).

## Step 2 — verify each reference feed

Run [the raw-data check](integration-quickstart.md#4-check-the-raw-data) for the base
and, when configured, quote feed. Require successful reads with the intended price,
spread and observation time. Provider creation does not read these feeds: it can
succeed even when subsequent quotes halt.

## Step 3 — simulate, then create

With your chosen variables exported:

```bash
forge script script/CreateAnchoredProvider.s.sol --rpc-url "$NETWORK"
```

Check the printed configuration. Broadcast the same inputs when ready:

```bash
forge script script/CreateAnchoredProvider.s.sol --rpc-url "$NETWORK" --broadcast
```

The complete creation ABI, including the five-field `InitialConfig` tuple, is in
[IAnchoredProviderFactory](../contracts/interfaces/IAnchoredProviderFactory.sol).
The executable environment reference is
[CreateAnchoredProvider.s.sol](../script/CreateAnchoredProvider.s.sol).

## Step 4 — verify the provider

Read the address from the confirmed `ProviderDeployed` event, or list the creator's
providers (paginate beyond 100):

```bash
: "${CREATOR_ADDRESS:?Set the address corresponding to PRIVATE_KEY}"
cast call "$ANCHORED_PROVIDER_FACTORY" \
  "getProviders(address,uint256,uint256)(address[],uint256)" \
  "$CREATOR_ADDRESS" 0 100 --rpc-url "$NETWORK"
```

Set `PROVIDER` to your created address and inspect its effective configuration:

```bash
: "${PROVIDER:?Set the created provider address}"
cast call "$ANCHORED_PROVIDER_FACTORY" "isProvider(address)(bool)" "$PROVIDER" --rpc-url "$NETWORK"
cast call "$PROVIDER" "baseFeedId()(bytes32)" --rpc-url "$NETWORK"
cast call "$PROVIDER" "quoteFeedId()(bytes32)" --rpc-url "$NETWORK"
cast call "$PROVIDER" "source()(address)" --rpc-url "$NETWORK"
cast call "$PROVIDER" "baseMaxStaleness()(uint256)" --rpc-url "$NETWORK"
cast call "$PROVIDER" "quoteMaxStaleness()(uint256)" --rpc-url "$NETWORK"
cast call "$PROVIDER" "getQuote()(uint128,uint128,uint128)" \
  --from 0x0000000000000000000000000000000000000000 --rpc-url "$NETWORK"
```

Also verify `token0()`, `token1()` and the configured margins/multipliers. The quote
must match the intended pair and satisfy the Q64.64 invariants in the
[integration quickstart](integration-quickstart.md#5-create-the-provider).

## Step 5 — understand ownership and finish wiring

In **both** variants, the owner can replace `source` through the factory. With
`MUTABLE_PARAMS = true`, owner/updater can also tune confidence and per-leg freshness
and spread multipliers within the immutable bounds and 60-second cooldowns.
`mutableParams = false` does not freeze source replacement or the pool's provider slot.

Invalid custom-source output halts quoting; APP does not automatically fall back
to its reference. See [provider controls](oracle-reference.md#provider-controls).

Complete [pool wiring and read registration](integration-quickstart.md#6-wire-and-register-the-pool)
for every reference leg and simulate the real swap path. Factory membership proves
that the provider was created under factory constraints; pool tiers require
additional product-level checks.
