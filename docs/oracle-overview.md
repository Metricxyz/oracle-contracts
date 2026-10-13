# Oracle overview

A pool asks its Price Provider for three values: `bid`, `ask`, and `referencePrice`.
The standard providers in this repository derive them from an on-chain oracle.
A custom provider may use other on-chain data instead.

```text
Market maker's prices     Pyth Lazer updates     Chainlink Data Streams reports
          |                       |                          |
        pusher                  relayer                    relayer
          |                       |                          |
CompressedOracleV1           PythOracle                ChainlinkOracle
          +-----------------------+--------------------------+
                                  |
                 PriceProvider / AnchoredPriceProvider
                                  |
                    getQuote(): bid, ask, referencePrice
                                  |
                                 pool
```

The oracle authenticates and stores updates. The standard provider checks freshness,
price guards and quote validity. The pool uses the resulting quote according to its
own swap rules. A valid signature proves who supplied a price; it does not prove
that the price is economically correct or that someone will keep publishing it.

## Choose an oracle

| | CompressedOracleV1 | PythOracle | ChainlinkOracle |
| --- | --- | --- | --- |
| Price source | Feed creator | Pyth Lazer | Chainlink Data Streams (v3/v4 and High Frequency Streams) |
| Publisher | Creator, delegated pusher, or relay of a creator-signed word | Anyone forwarding a valid Lazer update | Anyone forwarding a report accepted by the configured verifier |
| Feed identity | Creator + chain ID + slot + position | Lazer `uint32` ID represented as `bytes32` | Full Data Streams `bytes32` ID |
| Feed creation | First accepted slot update; no registry | First accepted verified update | First accepted verified report |
| Storage update | All four positions of a slot, sharing one timestamp | Per feed | Per feed |
| On-chain reads | Open | Registered pool during its swap, or approved integrator | Registered pool during its swap, or approved integrator |

Publishing examples for all three lanes live in the [pusher package](https://github.com/Metricxyz/mm-pusher-ts),
a separate repository.

Pyth and Chainlink separate **publishing** from **read access**. Publishing a feed
does not register a pool to read it. See [read access](oracle-reference.md#read-access).
Their configuration authorities also matter: for example, the Chainlink oracle's
admin controls the verifier routes.

Feed identities carry no token metadata; the feed's economic meaning must match the
provider's declared token pair. The deployer must
ensure that match for the provider's `baseToken` and `quoteToken`. Check the
[deployment record](../DEPLOYMENTS.md) for chain availability and dependencies.

## Choose a price provider

| | Plain PriceProvider | AnchoredPriceProvider (APP) |
| --- | --- | --- |
| Input | One oracle feed | One reference feed, or a ratio of two feeds from the same oracle; optional custom source |
| Quote | Oracle mid shaped by confidence and fixed margin | Configured reference band, optionally widened by a source or confidence shaping |
| Factory creation | Permissionless, subject to constructor bounds | Permissionless within the factory's oracle allowlist and parameter envelope |
| Freshness | Immutable `MAX_TIME_DELTA`, greater than zero | Per-leg limits bounded by immutable `MAX_REF_STALENESS`; zero requires `refTime == block.timestamp` |
| Changes after creation | Owner/updater can change confidence through the factory | Owner can replace the source in both variants; selected knobs are tunable only when `mutableParams = true` |
| Next step | [Create a plain provider](price-provider-quickstart.md) | [Create an APP](anchored-price-provider-quickstart.md) |

The plain provider's default `confidenceParam = 0` ignores oracle spread in quote
shaping. Spread validity checks still apply. Decide the desired quote policy before
deploying; see the [parameter units](oracle-reference.md#units-and-price-direction).

## What anchoring guarantees

APP constructs reference edges from the selected feeds, configured per-leg spread
multipliers and minimum margin. For a custom quote it applies:

```text
final_bid = min(source_bid, reference_bid)
final_ask = max(source_ask, reference_ask)
referencePrice = anchor_mid
```

The result cannot be tighter than the **configured reference band**. This is a
one-directional limit: a source can widen the quote arbitrarily within the output's
numeric bounds, or cause quoting to halt. APP does not impose a maximum execution
distance from the anchor, validate a source's market, or guarantee a profitable fill.
The source's own reference is validated and discarded; it cannot move the reported
`referencePrice`.

Multipliers below 1× are supported, so the configured band need not equal the
upstream oracle's unmodified uncertainty. `minMargin` remains a positive floor.
For exact interval math, source-call constraints and ownership controls, read the
[APP reference](anchored-price-provider.md) and [IAnchorSource](../contracts/interfaces/IAnchorSource.sol).

For a synthetic pair, both feeds must describe prices against the same quote asset,
and their ratio must match the provider's declared token pair. For example,
`BTC/USD ÷ ETH/USD = BTC/ETH`. The contracts do not verify this semantic match or
impose a separate limit on the observation-time difference between the two legs.

## Freshness and delivery

Standard providers reject missing, future-dated, stale or invalid data at quote
time. A failed check makes `getQuote()` revert. An oracle's raw read can still
return old data: raw storage and an executable provider quote are different checks.

Updates can be published continuously or delivered with a trade. These are delivery
policies, not different oracle contracts. An update-with-trade integration must
simulate and execute the update before the swap. Between updates, a direct read of
the provider can legitimately revert once its freshness window expires.

Use the [integration quickstart](integration-quickstart.md) for the full path from
local rehearsal to a registered pool, and the [operations guide](mm-operations-guide.md)
for monitoring, keys and recovery.
