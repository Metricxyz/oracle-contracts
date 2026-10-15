# Create a plain Price Provider

Create one `PriceProvider` through an existing `PriceProviderFactory`. The caller
becomes its owner. Start with the [integration quickstart](integration-quickstart.md)
for local rehearsal, feed checks and the pool registration steps that follow creation.

## Step 0 — prepare inputs

Run from the repository root with Foundry installed. Export the following values
in your shell or supply them through your normal environment tooling:

| Variable | Required value |
| --- | --- |
| `NETWORK` | A configured Foundry RPC alias, such as `base` |
| RPC alias variable | The endpoint variable used by that alias in `foundry.toml`, e.g. `RPC_BASE` |
| `PRICE_PROVIDER_FACTORY` | Explicit address from [DEPLOYMENTS.md](DEPLOYMENTS.md) |
| `REFERENCE_ORACLE` | Explicit oracle address from the same deployment record |
| `FEED_ID` | Your selected feed ID, decimal or hexadecimal |
| `BASE_TOKEN`, `QUOTE_TOKEN` | Nonzero, distinct addresses matching the feed's actual pair |
| `MARGIN_STEP` | Signed fraction × `1e18`, strictly between `-1e18` and `1e18` |
| `MAX_TIME_DELTA` | Maximum acceptable age in seconds: `1..604800` |
| `PRIVATE_KEY` | Your provider creator's transaction key |

These commands use `--rpc-url "$NETWORK"`; `RPC_URL` alone does not configure that
alias.

For example, `MARGIN_STEP=100000000000000` means a 1-bp step per side.
Choose `MAX_TIME_DELTA` from your actual observation-to-inclusion delay and price
policy. Zero is **invalid** for this provider. A USD feed used for a USDC quote
implicitly assumes a peg; the plain provider does not perform that conversion.

## Step 1 — verify the feed

Read the selected feed using [the raw-data check](integration-quickstart.md#4-check-the-raw-data).
Require a successful result with the intended mid, spread and observation time.
On a Pyth, Chainlink or MultiplierOracle feed, `FeedNotFound` means the feed holds no
observation (on a MultiplierOracle, also that the feed ID was not created there): provider
creation still succeeds, but the provider does not quote until data lands. A compressed feed
without data does not revert: it returns mid `0`. Any other revert needs diagnosis.

Creation has no oracle allowlist or envelope check and does not read the feed.
It can therefore succeed while subsequent quotes fail or while the chosen feed
has the wrong economic meaning. Check these inputs before broadcasting.

## Step 2 — simulate, then create

With the table's variables exported:

```bash
: "${NETWORK:?Set the Foundry RPC alias}"
: "${PRICE_PROVIDER_FACTORY:?Set the factory from DEPLOYMENTS.md}"
: "${REFERENCE_ORACLE:?Set the reference oracle from DEPLOYMENTS.md}"
: "${FEED_ID:?Set the feed ID}"
: "${BASE_TOKEN:?Set the base token address}"
: "${QUOTE_TOKEN:?Set the quote token address}"
: "${MARGIN_STEP:?Set the margin step}"
: "${MAX_TIME_DELTA:?Set the maximum observation age in seconds}"
: "${PRIVATE_KEY:?Set the creator's transaction key}"
forge script script/CreatePriceProvider.s.sol --rpc-url "$NETWORK"
```

Inspect the printed factory, oracle, feed ID, `marginStep`, `maxTimeDelta` and tokens.
Then send the same configuration when ready:

```bash
forge script script/CreatePriceProvider.s.sol --rpc-url "$NETWORK" --broadcast
```

After creating, in the simulation and the broadcast run alike, the script reads `getQuote()`
once as a test. On a Pyth, Chainlink or MultiplierOracle provider that read is expected to
revert: these oracles serve only a registered pool during its swap. It prints `FeedNotFound`
while the feed holds no observation (or the MultiplierOracle feed ID was not created), and
an empty revert otherwise. A compressed oracle serves any caller, so on a compressed provider
the read prints the bid, ask and reference, or reverts `FeedStalled` while the feed holds no
fresh, nonzero price within its price guard (`FeedNotFound` for a malformed feed ID).
Step 3 reads the quote with the zero sender, which all oracle families serve.

The executable parameter reference is
[CreatePriceProvider.s.sol](../script/CreatePriceProvider.s.sol).

## Step 3 — verify the deployed provider

Read the `provider` address from the confirmed transaction's `ProviderDeployed`
event. Alternatively, list the providers owned by the creator (paginate beyond 100):

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
tracking; it does not prove liveness or read permission.

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
