# Repository Guidelines

## Project structure

- `contracts/` — oracle and price-provider Solidity sources; `contracts/interfaces/` for
  interfaces, `contracts/mocks/` for test-only mocks, `contracts/oracles/` for
  `CompressedOracleV1` / `PythOracle` / `ChainlinkOracle` and their shared bases/utilities.
- `script/` — the third-party provider-creation paths only: `CreateAnchoredProvider.s.sol` (Anchored
  Price Provider, via `AnchoredProviderFactory`) and `CreatePriceProvider.s.sol` (plain
  `PriceProvider`, via `PriceProviderFactory` — both factories on all ten chains) plus their shell wrappers
  `create-anchored-provider.sh` / `create-price-provider.sh`, and `NetworkConfig.sol` /
  `script/config/networks.json` (per-chain config they read). `DEPLOYMENTS.md` is canonical for
  current production addresses — the committed `networks.json` is deploy-script working state and
  may lag behind it.
- `test/` — Foundry suites, one `*.t.sol` per contract, mirroring the `contracts/` layout
  (`test/oracles/`, `test/oracles/compressed/`, `test/oracles/utils/`, `test/mocks/`, `test/utils/`).
- `docs/` — design notes (compressed-slot format, encodings, Anchored Price Provider). See
  `README.md`'s docs index.
- `licenses/` — full text of the BUSL-1.1 and MIT licenses used across the repo.
- `skills/` — agent skills (`create-provider`); also discoverable via the committed
  `.claude/skills` symlink. Repo-relative paths inside a SKILL.md must be backtick-quoted.

The market-maker pusher is not in this repository. It lives in `Metricxyz/mm-pusher-ts`
(https://github.com/Metricxyz/mm-pusher-ts) with its own publishing examples, format specs and pusher
skills, and it vendors what it needs from here pinned to one commit. `script/GenerateVectors.s.sol`
is the one piece that stays on this side: it prints the vectors that repository pins its encoder
tests to. Do not reintroduce a pusher copy here.

## Build and test commands

- `forge build` — compile (solc pinned to `0.8.33` in `foundry.toml`, `via-ir = true`).
- `forge test -vv` — run the suite; `forge test --match-test <Name>` for one test.
- `contracts/oracles/utils/Codebook256.sol` is a committed, canonical lookup table; regenerating it
  from the JSON sources under `contracts/oracles/compressed/codebook/` is a maintainer workflow
  (tooling not included in this repo) — see [`docs/codebook.md`](./docs/codebook.md) for the format.

## Testing conventions

- Test contracts follow `ContractNameTest`, one file per contract, mirroring its path under
  `contracts/`.
- `foundry.toml` sets `no_match_path = "*/stash*"`: any test file placed under a path containing
  `stash` (e.g. a local `test/**/stash/` scratch dir) is excluded from `forge test` — use that for
  local, uncommitted work-in-progress tests without touching CI.

## Licensing

Seven files are BUSL-1.1 (the compressed oracle, both `OracleBase` variants, the price-provider
factory, `AnchoredPriceProvider`, `AnchoredProviderFactory`, and `LazerConsumer`); everything
else is MIT. Check
each file's `SPDX-License-Identifier` header — see `README.md`'s License section for the full list.

## Agent skills

When asked to create a price provider, follow `skills/create-provider/SKILL.md`: it is
orchestration over the canonical docs it links — read the skill first, then those docs. Publishing
and relaying prices are the pusher repository's skills, not this one's.
