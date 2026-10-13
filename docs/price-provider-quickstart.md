# Create a plain Price Provider

Create one `PriceProvider` through an existing `PriceProviderFactory`. The caller
becomes its owner. Start with the [integration quickstart](integration-quickstart.md)
for local rehearsal, feed checks and the pool registration steps that follow creation.

## Step 0 — prepare inputs

Run from the repository root with Foundry installed. Export the following values
in your shell or supply them through your normal environment tooling:

| Variable | Required value |
| --- | --- |
| `NETWORK` | A configured Foundry RPC alias and network key, such as `base` |
| RPC alias variable | The endpoint variable used by that alias in `foundry.toml`, e.g. `RPC_BASE` |
| `PRICE_PROVIDER_FACTORY` | Explicit address from [DEPLOYMENTS.md](../DEPLOYMENTS.md) |
| `REFERENCE_ORACLE` | Explicit oracle address from the same deployment record |
| `FEED_ID` | Your selected feed ID, decimal or hexadecimal |
| `BASE_TOKEN`, `QUOTE_TOKEN` | Nonzero, distinct addresses matching the feed's actual pair |
| `MARGIN_STEP` | Signed fraction × `1e18`, strictly between `-1e18` and `1e18` |
| `MAX_TIME_DELTA` | Maximum acceptable age in seconds: `1..604800` |
| `PRIVATE_KEY` | Your provider creator's transaction key |

These commands use `--rpc-url "$NETWORK"`; `RPC_URL` alone does not configure that
alias. Explicit factory/oracle values override the script's `networks.json` fallback.

For example, `MARGIN_STEP=100000000000000` means a 1-bp step per side.
Choose `MAX_TIME_DELTA` from your actual observation-to-inclusion delay and price
policy. Zero is **invalid** for this provider. A USD feed used for a USDC quote
implicitly assumes a peg; the plain provider does not perform that conversion.

## Step 1 — verify the feed

Read the selected feed using [the raw-data check](integration-quickstart.md#4-check-the-raw-data).
Require a successful result with the intended mid, spread and observation time.
A revert other than `FeedNotFound` still needs diagnosis.

Creation has no oracle allowlist or envelope check and does not read the feed.
It can therefore succeed while subsequent quotes fail or while the chosen feed
has the wrong economic meaning. Check these inputs before broadcasting.

## Step 2 — simulate, then create

With the table's variables exported:

```bash
: "${NETWORK:?Set the Foundry RPC alias}"
: "${PRICE_PROVIDER_FACTORY:?Set the factory from DEPLOYMENTS.md}"
: "${PRIVATE_KEY:?Set the creator's transaction key}"
forge script script/CreatePriceProvider.s.sol --rpc-url "$NETWORK"
```

Inspect the printed network, factory, oracle, feed, tokens and parameters. Then
send the same configuration when ready:

```bash
forge script script/CreatePriceProvider.s.sol --rpc-url "$NETWORK" --broadcast
```

The executable parameter reference is
[CreatePriceProvider.s.sol](../script/CreatePriceProvider.s.sol).

## Step 3 — verify the deployed provider

Read the `provider` address from the confirmed transaction's `ProviderDeployed`
event. Alternatively, list the creator's providers (paginate beyond 100):

```bash
: "${CREATOR_ADDRESS:?Set the address corresponding to PRIVATE_KEY}"
cast call "$PRICE_PROVIDER_FACTORY" \
  "getProviders(address,uint256,uint256)(address[],uint256[],uint256)" \
  "$CREATOR_ADDRESS" 0 100 --rpc-url "$NETWORK"
```

The results are provider addresses, confidence-update availability timestamps and
the total count. Set `PROVIDER` to the address from your creation receipt and verify:

```bash
: "${PROVIDER:?Set the created provider address}"
cast call "$PRICE_PROVIDER_FACTORY" "isProvider(address)(bool)" "$PROVIDER" --rpc-url "$NETWORK"
cast call "$PROVIDER" "token0()(address)" --rpc-url "$NETWORK"
cast call "$PROVIDER" "token1()(address)" --rpc-url "$NETWORK"
cast call "$PROVIDER" "MAX_TIME_DELTA()(uint256)" --rpc-url "$NETWORK"
cast call "$PROVIDER" "getQuote()(uint128,uint128,uint128)" \
  --from 0x0000000000000000000000000000000000000000 --rpc-url "$NETWORK"
```

Check Q64.64 quote values against the intended pair. `isProvider` confirms factory
tracking; it does not prove liveness, read permission or a pool tier.

## Step 4 — configure confidence and complete pool wiring

`confidenceParam` starts at `0`: oracle spread is ignored for quote shaping while
spread validity checks remain active. `10_000` means 1×; `1_000_000` is the 100×
ceiling. For a deliberate 1× setting:

```bash
cast send "$PRICE_PROVIDER_FACTORY" "setConfidence(address[],uint256[])" \
  "[$PROVIDER]" "[10000]" --private-key "$PRIVATE_KEY" --rpc-url "$NETWORK"
```

The owner or an authorized updater can change confidence through the factory;
a 60-second cooldown applies. Only the owner grants/revokes updaters and transfers
provider ownership. Margin, feed, tokens and freshness are immutable.

Finish [pool wiring and read registration](integration-quickstart.md#6-wire-and-register-the-pool),
then simulate the actual swap path. For error diagnosis and exact bounds, use the
[oracle reference](oracle-reference.md).
