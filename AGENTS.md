# Repository Guidelines

## Project structure

- `contracts/` — the price providers and their factories at the top level; `contracts/interfaces/`
  for interfaces; `contracts/oracles/compressed/` for `CompressedOracleV1` and its base (plus the
  codebook JSON source); `contracts/oracles/providers/` for `PythOracle` / `ChainlinkOracle` and
  their shared `OracleBase`; `contracts/oracles/multiplier/` for `MultiplierOracle` and its params
  adapters; and `contracts/oracles/utils/` for the shared utilities.
- `script/` — the third-party provider-creation paths only: `CreateAnchoredProvider.s.sol` (Anchored
  Price Provider, via `AnchoredProviderFactory`) and `CreatePriceProvider.s.sol` (plain
  `PriceProvider`, via `PriceProviderFactory` — both factories on all ten chains) plus their shell wrappers
  `create-anchored-provider.sh` / `create-price-provider.sh`. The scripts take the factory and oracle
  addresses from env; `docs/DEPLOYMENTS.md` lists the production addresses.
- `test/` — Foundry suites: provider and factory suites at the top level; `PythOracle` /
  `ChainlinkOracle` suites directly in `test/oracles/` (there is no `test/oracles/providers/`);
  `test/oracles/compressed/`, `test/oracles/multiplier/` and `test/oracles/utils/` for the matching
  `contracts/oracles/` directories; `test/mocks/` and `test/utils/` for test helpers. Suites exist
  per contract and per behavior (e.g. `QuoteSafety.t.sol`, `OracleBaseReadAccess.t.sol`).
- `docs/` — all documentation: the repository README and index (`docs/README.md`), the deployment
  record, the security policy, and the integration and reference pages.
- `licenses/` — full text of the BUSL-1.1 and MIT licenses used across the repo.
- `skills/` — agent skills (`create-provider`). Repo-relative paths inside a SKILL.md must be
  backtick-quoted.

The market-maker pusher is not in this repository. It lives in `Metricxyz/mm-pusher-ts`
(https://github.com/Metricxyz/mm-pusher-ts) with its own publishing examples, format specs and pusher
skills.

## Build and test commands

- `forge build` — compile (solc pinned to `0.8.33` in `foundry.toml`, `via_ir = true`).
- `forge test -vv` — run the suite; `forge test --match-test <Name>` for one test.
- `contracts/oracles/utils/Codebook256.sol` is a committed, canonical lookup table; its JSON source
  is under `contracts/oracles/compressed/codebook/` — see [`docs/codebook.md`](./docs/codebook.md)
  for the format.

## Testing conventions

- Test contracts follow `ContractNameTest`, in the `test/` layout above; a contract may
  have several suites (e.g. `ChainlinkOracleRouting`), and behavior suites (e.g. `QuoteSafety`,
  `OracleBaseReadAccess`) cover several contracts. The multiplier oracle's params adapters are tested with it, in
  `test/oracles/multiplier/MultiplierOracle.t.sol`.
- `foundry.toml` sets `no_match_path = "*/stash*"`: any test file placed under a path containing
  `stash` (e.g. a local `test/**/stash/` scratch dir) is excluded from `forge test` — use that for
  local, uncommitted work-in-progress tests.

## Licensing

Seven files are BUSL-1.1 (the compressed oracle, both `OracleBase` variants, the price-provider
factory, `AnchoredPriceProvider`, `AnchoredProviderFactory`, and `LazerConsumer`); everything
else is MIT. Check
each file's `SPDX-License-Identifier` header — see the License section of `docs/README.md` for the full list.

## Agent skills

When asked to create a price provider, follow `skills/create-provider/SKILL.md`: it is
orchestration over the canonical docs it links — read the skill first, then those docs. Publishing
and relaying prices are the pusher repository's skills, not this one's.
