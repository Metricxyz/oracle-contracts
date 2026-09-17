# Oracle contracts

On-chain price oracle suite for EVM chains: three oracle implementations that ingest signed or
compressed off-chain price updates, plus a family of price providers that shape those raw oracle
reads into the bid/ask/reference quotes a pool or protocol consumes.

- **`CompressedOracleV1`** — a registrationless, multi-feed oracle. Up to 4 feeds are packed into a
  single 256-bit storage slot; each feed's spread is compressed to one byte via a 256-entry lookup
  table (`Codebook256`). A feed's storage location *is* its identity: the feedId is a
  self-describing, packed value (`creator << 96 | chainid << 16 | slotIndex << 8 | positionIndex`),
  so there is no feed registry and no creation step.
- **`PythOracle`** — consumes Pyth Lazer signed price-update payloads. Any feed id carried inside a
  Lazer-signed payload is stored on push; the signature check is the only trust anchor.
- **`ChainlinkOracle`** — consumes Chainlink Data Streams reports (v3/v4 + High Frequency Streams),
  verified through a Chainlink `VerifierProxy`, and normalizes them to the same on-chain format the
  Pyth path uses.

Both `PythOracle` and `ChainlinkOracle` are registrationless and token-free: a feed exists once its
first verified update lands, and token metadata lives on the price providers (as constructor
immutables), not on the oracles.

On top of the oracles sit the **price providers**: `PriceProvider` (attributed, access-gated
reads) and `AnchoredPriceProvider` (quotes clamped to a band derived from a reference oracle's own
uncertainty — deployed through `AnchoredProviderFactory`, which maintains an admin-curated
allow-list of reference oracles and per-pair-class parameter envelopes). The APP band bounds a custom
source in **one** direction only — never tighter than the live band, with no bound on how far it may
widen — see `IAnchorSource`. What a source can never move is the `referencePrice` the APP reports:
that is the anchor's own mid, so a widened quote costs whoever trades against it a worse price but
cannot inflate the consumer's fee base. `PriceProviderFactory` deploys the plain provider.

The off-chain half — a price feed that aggregates market data and pushers that publish signed or
compressed updates into these oracles — is the companion off-chain stack (published separately);
this repository only contains the on-chain side.

## Architecture

```
companion off-chain stack (published separately)
        │  signed payload (Pyth/Chainlink) or compressed slot word (32B)
        ▼
On-chain oracles
  ├─ CompressedOracleV1   codebook-compressed, packed feedId, no registry
  ├─ PythOracle           Pyth Lazer signed payloads
  └─ ChainlinkOracle      Chainlink Data Streams verified reports
        │  price(feedId, pool) / getOracleData(feedId)
        ▼
Price providers
  ├─ PriceProvider           (attributed, access-gated reads)
  └─ AnchoredPriceProvider   (band-clamped to a reference oracle, via AnchoredProviderFactory)
        │  getQuote() → (bid, ask, referencePrice)
        ▼
Consumer (pool / protocol)
```

## Repo layout

| Path | Contents |
|---|---|
| `contracts/` | Oracle and price-provider implementations, interfaces (`contracts/interfaces/`), test mocks (`contracts/mocks/`) |
| `contracts/oracles/` | `CompressedOracleV1`, `PythOracle`, `ChainlinkOracle`, and shared bases/utilities (`Codebook256`, `U64x32`, `TimeMs`, `LazerConsumer`, `Extsload`) |
| `script/` | The third-party provider-creation paths only: `CreateAnchoredProvider.s.sol` (create one `AnchoredPriceProvider` through an already-deployed `AnchoredProviderFactory`) and `CreatePriceProvider.s.sol` (create one plain `PriceProvider` through an already-deployed `PriceProviderFactory`), plus their shell wrappers `create-anchored-provider.sh` / `create-price-provider.sh`, and `NetworkConfig.sol` / `script/config/networks.json` (per-chain addresses they read — deploy-script working state, may lag `DEPLOYMENTS.md`) |
| `test/` | Foundry test suites, one `*.t.sol` per contract, mirroring `contracts/` |
| `docs/` | Design notes on the compressed-slot format, encodings, and the Anchored Price Provider |
| `licenses/` | Full text of the two licenses used in this repo |
| `examples/` | `examples/mm-pusher-ts` — a self-contained TypeScript pusher skeleton for market makers: compressed-lane publishing and Pyth-Lazer relaying, with an offline anvil demo (`npm run demo`) |
| `skills/` | Agent-executable instructions (Agent Skills format) for LLM-driven integrators: provider creation and both pusher lanes |

## Quickstart

```bash
git clone --recurse-submodules <this-repo-url>
cd oracle-contracts
forge build
forge test        # 485 tests
```

Requires [Foundry](https://book.getfoundry.sh/) (solc is pinned to `0.8.33` in `foundry.toml`,
`via-ir` enabled). Node.js is not required to build or test this repo.

`Codebook256.sol` embeds a 256-entry `[0, 10_000]` lookup table; the committed file is canonical.
Regenerating it from the JSON sources under `contracts/oracles/compressed/codebook/` is a
maintainer workflow (tooling not included in this repo) — see [`docs/codebook.md`](./docs/codebook.md)
for the table format.

## Integrating / creating your own provider

If you are integrating as a market maker and want the whole picture first — from your price
source to a pool swap — start with [`docs/mm-operations-guide.md`](./docs/mm-operations-guide.md).

The oracles (`CompressedOracleV1`, `PythOracle`, `ChainlinkOracle`) and the shared factories
(`PriceProviderFactory`, `AnchoredProviderFactory`) are already deployed on ten production chains:
all five contracts span all ten. Two lanes are pre-claimed and not yet operational — avalanche's
Pyth lane waits on Pyth Lazer shipping there, megaeth's Chainlink lane on its Data Streams verifier
going live —
see [`DEPLOYMENTS.md`](./DEPLOYMENTS.md) for the current per-chain matrix and addresses (deployed
via CreateX `deployCreate3`, so each contract sits at the same address on every chain it's
deployed to).

Because the oracles are registrationless, there is no feed-registration step to integrate with — a
feed exists once its first update lands from the companion off-chain stack.

To create your own `AnchoredPriceProvider` against a deployed `AnchoredProviderFactory`, follow the
[creation quickstart](./docs/anchored-price-provider-quickstart.md), which walks `script/create-anchored-provider.sh`
(wrapping `script/CreateAnchoredProvider.s.sol`) end to end — anyone can call it; the caller becomes
the provider owner. See [`docs/anchored-price-provider.md`](./docs/anchored-price-provider.md) for
the full design and admin-side controls (allow-list, envelopes) that gate what parameters a new
provider can be created with.

To create a plain `PriceProvider` instead — a thinner, single-oracle passthrough with no admin
allow-list or envelope, deployed on all ten chains — follow the
[plain-provider creation quickstart](./docs/price-provider-quickstart.md), which walks
`script/create-price-provider.sh` (wrapping `script/CreatePriceProvider.s.sol`) end to end; same
permissionless-creator model as the APP path.

The production deploy pipeline that first stood up the factories and oracles themselves (CreateX
CREATE3, run once per chain) is operated by the maintainers; its tooling is not part of this repo.

Market makers publishing their own prices (or relaying Pyth Lazer updates) should start from the
[`examples/mm-pusher-ts`](./examples/mm-pusher-ts) package — a copyable pusher skeleton with an
offline demo. If your integration is driven by an LLM coding agent, point it at the
[`skills/`](./skills) directory: each skill is a self-contained, verifiable runbook
(provider creation, compressed pusher, Pyth relayer).

## Docs index

| Doc | Description |
|---|---|
| [`docs/mm-operations-guide.md`](./docs/mm-operations-guide.md) | How a market maker launches and operates a metric pool (start here if you are new) |
| [`docs/anchored-price-provider.md`](./docs/anchored-price-provider.md) | Anchored Price Provider (APP) design: reference vs. source mode, the audit-once band clamp and exactly what it does and does not bound |
| [`docs/anchored-price-provider-quickstart.md`](./docs/anchored-price-provider-quickstart.md) | Manual, step-by-step walkthrough for creating one Anchored Price Provider |
| [`docs/price-provider-quickstart.md`](./docs/price-provider-quickstart.md) | Manual, step-by-step walkthrough for creating one plain Price Provider |
| [`docs/slot-structure.md`](./docs/slot-structure.md) | `CompressedOracleV1` slot/namespace layout and the packed, self-describing feedId |
| [`docs/oracle-packet-structure.md`](./docs/oracle-packet-structure.md) | Bit layout of the 32-byte compressed slot word |
| [`docs/codebook.md`](./docs/codebook.md) | `Codebook256` lookup-table format and the regeneration workflow |
| [`docs/u64x32.md`](./docs/u64x32.md) | `U64x32`, the fixed-point price encoding stored inside compressed slots |

## License

This repository uses a mixed license, matching each file's own `SPDX-License-Identifier` header:

- **BUSL-1.1** ([`licenses/BUSL_LICENSE`](./licenses/BUSL_LICENSE)) — the core oracle and
  price-provider-factory implementations:
  `contracts/AnchoredPriceProvider.sol`, `contracts/AnchoredProviderFactory.sol`,
  `contracts/PriceProviderFactory.sol`,
  `contracts/oracles/compressed/CompressedOracle.sol`, `contracts/oracles/compressed/OracleBase.sol`,
  `contracts/oracles/providers/OracleBase.sol`, `contracts/oracles/utils/LazerConsumer.sol`
  (original parser code; it only imports Pyth's MIT-licensed `pyth-lazer-sdk` library, which keeps
  its own license under `lib/`).
- **MIT** ([`licenses/MIT_LICENSE`](./licenses/MIT_LICENSE)) — everything else: interfaces,
  `PythOracle`/`ChainlinkOracle`, the plain price provider (`PriceProvider`), utilities, mocks,
  scripts, and tests.

The BUSL-1.1 grant permits production use of those seven files as long as it does not constitute a
"Competing Use" as defined in `licenses/BUSL_LICENSE` (broadly: don't resell the licensed
functionality itself as a competing product or service); each file converts to MIT on its own
Change Date. This is not a plain-MIT repository — check the header of any file you reuse.
