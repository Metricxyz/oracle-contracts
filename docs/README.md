# Oracle contracts

On-chain price oracle suite for EVM chains: three oracle implementations that ingest signed or
compressed off-chain price updates, a multiplier oracle that turns a share feed into a
tokenized-stock feed, plus standard price providers that shape those raw oracle reads into the
bid/ask/reference quotes a pool or protocol consumes.

- **`CompressedOracleV1`** — a registrationless, multi-feed oracle. Up to 4 feeds are packed into a
  single 256-bit storage slot; each feed's spread is compressed to one byte via a 256-entry lookup
  table (`Codebook256`). A feed's storage location *is* its identity: the feedId is a
  self-describing, packed value (`creator << 96 | chainid << 16 | slotIndex << 8 | positionIndex`),
  so there is no feed registry and no creation step.
- **`PythOracle`** — consumes Pyth Lazer signed price-update payloads. Any feed id carried inside a
  Lazer-signed payload is stored on push, subject to the oracle's timestamp and value checks; the
  signature check is the only trust anchor.
- **`ChainlinkOracle`** — consumes Chainlink Data Streams reports (v3/v4 + High Frequency Streams),
  verified through a Chainlink `VerifierProxy`, and normalizes them to the same on-chain format the
  Pyth path uses.
- **`MultiplierOracle`** — prices tokenized stocks whose redemption ratio is an on-chain multiplier
  (ERC-8056 "Scaled UI Amount": Coinbase B20 Assets, Robinhood Stock Tokens) as
  `share price × multiplier` over a share feed on a `PythOracle` or `ChainlinkOracle` (the deployed
  instances read the chain's `PythOracle`). It ingests no updates of its own; the
  multiplier and the issuer's corporate-action pause flag come from an allow-listed params adapter
  per token family (`B20AssetParams`, `RobinhoodStockTokenParams`).

Both `PythOracle` and `ChainlinkOracle` are registrationless and token-free: a feed exists once its
first verified update lands, and token metadata lives on the price providers (as constructor
immutables), not on the oracles.

On top of the oracles sit the **price providers**: `PriceProvider` (attributed, access-gated reads,
deployed through `PriceProviderFactory`) and `AnchoredPriceProvider` (quotes clamped to a band derived
from a reference oracle's uncertainty and configured multipliers/margin, deployed through
`AnchoredProviderFactory`, which keeps an admin-curated allow-list of reference oracles and
per-pair-class parameter envelopes). The APP band bounds a custom source in **one** direction only —
never tighter than the live band, with no bound on how far it may widen. What a source can never
move is the `referencePrice` the APP reports: that is the anchor's own mid.

This repository holds the on-chain side only. Publishing and relaying prices is the
[pusher package](https://github.com/Metricxyz/mm-pusher-ts), a separate repository.

## Architecture

```text
off-chain publishers (see the pusher package)
        │  signed payload (Pyth/Chainlink) or compressed slot word (32B)
        ▼
On-chain oracles
  ├─ CompressedOracleV1   codebook-compressed, packed feedId, no registry
  ├─ PythOracle           Pyth Lazer signed payloads
  ├─ ChainlinkOracle      Chainlink Data Streams verified reports
  └─ MultiplierOracle     share feed × issuer multiplier (tokenized stocks; deployed over PythOracle)
        │  price(feedId, pool)
        ▼
Price providers
  ├─ PriceProvider           (attributed, access-gated reads)
  └─ AnchoredPriceProvider   (band-clamped to a configured reference band, via AnchoredProviderFactory)
        │  getQuote() → (bid, ask, referencePrice)
        ▼
Consumer (pool / protocol)
```

## Quickstart

```bash
git clone --recurse-submodules git@github.com:Metricxyz/oracle-contracts.git
cd oracle-contracts
forge build
forge test
```

Requires [Foundry](https://book.getfoundry.sh/); solc is pinned to `0.8.33` in `foundry.toml`, with
`via_ir` enabled.

## Choose a starting point

| You want to… | Start here | Then read |
| --- | --- | --- |
| Understand where a pool's quote comes from | [Overview and choices](oracle-overview.md) | [Units, interfaces and failure behavior](oracle-reference.md) |
| Connect a feed to a provider and pool | [Integration quickstart](integration-quickstart.md) | The linked provider creation guide |
| Publish or relay prices | [Pusher package](https://github.com/Metricxyz/mm-pusher-ts) (separate repository) | [Integration quickstart](integration-quickstart.md#3-publish-or-arrange-delivery) |
| Diagnose a missing or rejected quote | [Failure reference](oracle-reference.md#failure-reference) | [Operating checks](integration-quickstart.md#7-establish-operating-checks) |
| Implement a codec | [Slot and namespace layout](slot-structure.md) | [Packet format](oracle-packet-structure.md), [U64x32](u64x32.md), [codebook](codebook.md) |
| Relay Pyth or Chainlink updates | [Relay format](relay-payload-format.md) | [Failure reference](oracle-reference.md#failure-reference) |
| Configure an anchored provider | [APP creation](anchored-price-provider-quickstart.md) | [APP reference](anchored-price-provider.md) |
| Configure a plain provider | [Plain provider creation](price-provider-quickstart.md) | [PriceProvider.sol](../contracts/PriceProvider.sol) |
| Price a tokenized stock | [Multiplier oracle quickstart](multiplier-oracle-quickstart.md) | [Multiplier oracle reference](multiplier-oracle.md) |

## Sources of truth

| Information | Maintained in |
| --- | --- |
| Production addresses and recorded chain availability | [DEPLOYMENTS.md](DEPLOYMENTS.md); confirm the target deployment before sending transactions |
| Contract behavior | [Solidity sources](../contracts/) and [tests](../test/) from the same revision |
| Script arguments and environment variables | Headers of the [provider scripts](../script/); for publishing, the [pusher package](https://github.com/Metricxyz/mm-pusher-ts) |
| Quote units and read semantics | [Oracle reference](oracle-reference.md) |
| Factory allowlists, envelopes, pool registrations and live feed data | The selected contracts on the selected chain |

The five core contracts are deployed on ten production chains at the same address on every chain;
two lanes are deployed but cannot ingest updates (avalanche's Pyth lane and megaeth's Chainlink lane).
The multiplier oracle and its adapters are deployed on base and robinhood. See
[DEPLOYMENTS.md](DEPLOYMENTS.md) for the matrix and per-chain notes.

The provider-creation scripts take the factory and oracle addresses explicitly, from
the deployment record. The production instances are the addresses in DEPLOYMENTS.md; code at an address or a
matching `version()` does not identify one.

The docs describe the checked-in implementation. Deployment records are not live
health checks.

## Repository layout

| Path | Contents |
| --- | --- |
| `contracts/` | Oracle and price-provider implementations and interfaces (`contracts/interfaces/`) |
| `contracts/oracles/` | `CompressedOracleV1`, `PythOracle`, `ChainlinkOracle`, `MultiplierOracle` with its params adapters (`contracts/oracles/multiplier/`), and shared bases/utilities (`Codebook256`, `U64x32`, `TimeMs`, `LazerConsumer`, `Extsload`) |
| `script/` | The provider-creation paths: `CreateAnchoredProvider.s.sol` and `CreatePriceProvider.s.sol`, and their shell wrappers |
| `test/` | Foundry test suites per contract and per behavior (e.g. `QuoteSafety`, `OracleBaseReadAccess`): provider and factory suites at the top level, `PythOracle`/`ChainlinkOracle` suites in `test/oracles/`, and `test/oracles/{compressed,multiplier,utils}/` for those oracle directories |
| `docs/` | This documentation, the deployment record and the security policy |
| `skills/` | An agent-executable runbook (Agent Skills format) for provider creation |
| `licenses/` | Full text of the two licenses used in this repository |

`Codebook256.sol` embeds a 256-entry `[0, 10_000]` lookup table; the committed file is canonical.
Its JSON source is under `contracts/oracles/compressed/codebook/` — see [codebook.md](codebook.md).

## License

This repository uses a mixed license, matching each file's own `SPDX-License-Identifier` header:

- **BUSL-1.1** ([`licenses/BUSL_LICENSE`](../licenses/BUSL_LICENSE)) — the core oracle and
  price-provider-factory implementations:
  `contracts/AnchoredPriceProvider.sol`, `contracts/AnchoredProviderFactory.sol`,
  `contracts/PriceProviderFactory.sol`,
  `contracts/oracles/compressed/CompressedOracle.sol`, `contracts/oracles/compressed/OracleBase.sol`,
  `contracts/oracles/providers/OracleBase.sol`, `contracts/oracles/utils/LazerConsumer.sol`
  (original parser code; it imports `PythLazer`/`PythLazerStructs` from Pyth's `pyth-lazer-sdk` and
  `Math`/`SafeCast` from OpenZeppelin, which keep their own licenses under `lib/`).
- **MIT** ([`licenses/MIT_LICENSE`](../licenses/MIT_LICENSE)) — everything else: interfaces,
  `PythOracle`/`ChainlinkOracle`, `MultiplierOracle` and its adapters, the plain price provider
  (`PriceProvider`), utilities, mocks,
  scripts, and tests.

The BUSL-1.1 grant permits production use of those seven files as long as it does not constitute a
"Competing Use" as defined in `licenses/BUSL_LICENSE` (broadly: don't resell the licensed
functionality itself as a competing product or service). The license sets one Change Date for the
whole Licensed Work, 2029-07-03, or the third anniversary of a version's first public distribution
under the license if that comes first; on it those files convert to MIT. The file headers carry no
date of their own. This is not a plain-MIT repository — check the header of any file you reuse.

## Security

Report vulnerabilities as described in [SECURITY.md](SECURITY.md). Audit reports are published at [docs.metric.xyz — Security and audits](https://docs.metric.xyz/reference/security-and-audits).

### Audited code

These contracts were developed and audited in a private repository. Each commit named in the audit reports is published here as a tag named `audit-<commit>`. A tag publishes the contracts, tests and documentation from that commit; deployment scripts and internal tooling were left out. Its `contracts/` folder is identical to the audited commit's, and the tag's `VERIFY.md` proves that from the commit hash printed in the report, without access to the private repository.

| Tag | Audits | `contracts/` hash | Proof |
| --- | --- | --- | --- |
| [`audit-eda97bb`](https://github.com/Metricxyz/oracle-contracts/tree/audit-eda97bb) | Zellic audit (Jun 2026), audited | `b5ae57073381fae094398b12affcbe8b5012520b` | [VERIFY.md](https://github.com/Metricxyz/oracle-contracts/blob/audit-eda97bb/VERIFY.md) |
| [`audit-a7644f6`](https://github.com/Metricxyz/oracle-contracts/tree/audit-a7644f6) | Sherlock collaborative audit (May–Jun 2026), audited | `bdc761ae585ed9f27569b79ca564537820502705` | [VERIFY.md](https://github.com/Metricxyz/oracle-contracts/blob/audit-a7644f6/VERIFY.md) |
| [`audit-056c204`](https://github.com/Metricxyz/oracle-contracts/tree/audit-056c204) | Sherlock collaborative audit, fixes. Sherlock bug bounty contest (Jul 2026), audited | `0fb82d4cc7ebdba126ca9bc866dd85da1c7908da` | [VERIFY.md](https://github.com/Metricxyz/oracle-contracts/blob/audit-056c204/VERIFY.md) |
| [`audit-8b72555`](https://github.com/Metricxyz/oracle-contracts/tree/audit-8b72555) | Sherlock bug bounty contest, fixes. Zellic re-audit (Sep 2026), final | `f2fd9c61adb7d3931a47f5f48718ca1e387afa2b` | [VERIFY.md](https://github.com/Metricxyz/oracle-contracts/blob/audit-8b72555/VERIFY.md) |
| [`audit-edbc5f0`](https://github.com/Metricxyz/oracle-contracts/tree/audit-edbc5f0) | Zellic re-audit (Sep 2026), starting point: the re-audit reviewed the changes from here to `8b72555` | `5ace29538dea65022bcf781a992498d476bf5114` | [VERIFY.md](https://github.com/Metricxyz/oracle-contracts/blob/audit-edbc5f0/VERIFY.md) |

In `audit-056c204`, the RPC API key in `foundry.toml` was replaced with `${ALCHEMY_API_KEY}`.

To verify a tag, clone it and run its check script (Python 3 and git only):

```bash
git clone --branch audit-8b72555 https://github.com/Metricxyz/oracle-contracts.git
cd oracle-contracts
python verify/verify.py .
```

It ends with `OK: contracts/ at this tag is identical to contracts/ in audited commit …`. Each tag's `VERIFY.md` explains the check step by step. For a quick look, compare the hash directly:

```bash
git rev-parse audit-8b72555:contracts   # f2fd9c61adb7d3931a47f5f48718ca1e387afa2b
```

### Changes since the last audit

Since `8b72555`:

- **New contracts, not covered by the audits above:** the multiplier oracle for tokenized stocks (`MultiplierOracle`, `ScheduledMultiplier`, and the `B20AssetParams` and `RobinhoodStockTokenParams` adapters, with the `IOracleParams` and `IScaledUIAmount` interfaces). It is deployed on Base and Robinhood only; see [DEPLOYMENTS.md](DEPLOYMENTS.md#multiplier-lane-base-and-robinhood).
- **Quote changes:** `PriceProvider` now includes the confidence spread in its minimum ask, and `AnchoredPriceProvider` (direct, non-synthetic feeds) includes the half-spread and minimum margin in its minimum ask.

Every other change is to comments and documentation.
