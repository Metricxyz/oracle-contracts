# Oracle documentation

This documentation covers the EVM oracle contracts and their standard price providers.
Publishing and relaying prices is the [pusher package](https://github.com/Metricxyz/mm-pusher-ts),
a separate repository. These pages do not cover the Solana implementation or the deployment of
Metric's off-chain services.

## Choose a starting point

| You want to… | Start here | Then read |
| --- | --- | --- |
| Understand where a pool's quote comes from | [Overview and choices](oracle-overview.md) | [Units, interfaces and failure behavior](oracle-reference.md) |
| Connect a feed to a provider and pool | [Integration quickstart](integration-quickstart.md) | The linked provider creation guide |
| Publish or relay prices | [Pusher package](https://github.com/Metricxyz/mm-pusher-ts) (separate repository) | [Operations guide](mm-operations-guide.md) |
| Diagnose a missing or rejected quote | [Failure reference](oracle-reference.md#failure-reference) | [Operations guide](mm-operations-guide.md#5-operations) |
| Implement a codec | [Slot and namespace layout](slot-structure.md) | [Packet format](oracle-packet-structure.md), [U64x32](u64x32.md), [codebook](codebook.md) |
| Configure an anchored provider | [APP creation](anchored-price-provider-quickstart.md) | [APP reference](anchored-price-provider.md) |
| Configure a plain provider | [Plain provider creation](price-provider-quickstart.md) | [PriceProvider.sol](../contracts/PriceProvider.sol) |

## Sources of truth

| Information | Maintained in |
| --- | --- |
| Production addresses and recorded chain availability | [DEPLOYMENTS.md](../DEPLOYMENTS.md); confirm the target deployment before sending transactions |
| Contract behavior | [Solidity sources](../contracts/) and [tests](../test/) from the same revision |
| Script arguments and environment variables | Headers of the [provider scripts](../script/); for publishing, the [pusher package](https://github.com/Metricxyz/mm-pusher-ts) |
| Quote units and read semantics | [Oracle reference](oracle-reference.md) |
| Factory allowlists, envelopes, pool registrations and live feed data | The selected contracts on the selected chain |

`script/config/networks.json` is working configuration for the scripts. It can lag
the deployment record; supply explicit factory and oracle addresses when integrating.
An address containing code or a matching `version()` is not enough to identify an
active deployment: older instances can still accept transactions.

The docs describe the checked-in implementation. Deployment records are not live
health checks. Pool tiers, UI behavior and API submission workflows belong to the
Metric product documentation; factory membership alone is not a pool-tier decision.

## Maintaining these pages

[CONTRIBUTING.md](CONTRIBUTING.md) holds the requirements these pages are written and
reviewed against: which layer owns which fact, the invariants that must be worded
identically everywhere, and the checks a documentation change passes before it ships.
