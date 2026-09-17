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
- `examples/mm-pusher-ts/` — TypeScript pusher skeleton (compressed + pyth lanes). Test with
  `npm ci && npm test && npm run typecheck && npm run demo` inside that directory (the demo
  needs Foundry's anvil). Every file in the examples package opens with a header mini-doc
  (purpose, intent, what happens, env consumed) — keep it when editing, extend it when adding files.
- `skills/` — agent skills (`create-provider`, `setup-compressed-pusher`, `setup-pyth-relayer`);
  also discoverable via the committed `.claude/skills` symlink. Repo-relative paths inside a
  SKILL.md must be backtick-quoted — a vitest test in the examples package checks they exist.

## Build and test commands

- `forge build` — compile (solc pinned to `0.8.33` in `foundry.toml`, `via-ir = true`).
- `forge test -vv` — run the suite (485 tests); `forge test --match-test <Name>` for one test.
- `contracts/oracles/utils/Codebook256.sol` is a committed, canonical lookup table; regenerating it
  from the JSON sources under `contracts/oracles/compressed/codebook/` is a maintainer workflow
  (tooling not included in this repo) — see [`docs/codebook.md`](./docs/codebook.md) for the format.

## Testing conventions

- Test contracts follow `ContractNameTest`, one file per contract, mirroring its path under
  `contracts/`.
- `foundry.toml` sets `no_match_path = "*/stash*"`: any test file placed under a path containing
  `stash` (e.g. a local `test/**/stash/` scratch dir) is excluded from `forge test` — use that for
  local, uncommitted work-in-progress tests without touching CI.

## Public mirror

`Oracle-Based-Pool/smart-contracts-public` mirrors `contracts/`, `test/`, `docs/`, `examples/`,
`skills/` and the third-party provider-creation path in `script/`. Everything else — `scripts/`,
`contract-registry/`, the deploy tooling in `script/` — is private by omission.

Sync it with `node scripts/sync-public.mjs` (add `--check` to report drift and write nothing; it
exits non-zero when anything is stale, so it works in a pre-release check). Do not copy by hand: the
public copy is not byte-identical, and the script is what makes "is it in sync?" answerable.

**Mark internal reasoning `/// @custom:internal` — the script strips those blocks from the public
copy.** The line to draw is operability: a reader integrating against these contracts needs the
warnings — that a constant must not be raised, what a sentinel means, which paths fail closed — and
those stay. What goes is the record of our own decisions: commit hashes, deploy-version history, why
one option was chosen over another. When a comment carries both, split it; the `@dev` half stays and
the `@custom:internal` half goes.

## Licensing

Seven files are BUSL-1.1 (the compressed oracle, both `OracleBase` variants, the price-provider
factory, `AnchoredPriceProvider`, `AnchoredProviderFactory`, and `LazerConsumer`); everything
else is MIT. Check
each file's `SPDX-License-Identifier` header — see `README.md`'s License section for the full list.

## Agent skills

When asked to create a price provider, follow `skills/create-provider/SKILL.md`.
When asked to publish MM prices into the compressed oracle, follow
`skills/setup-compressed-pusher/SKILL.md`. When asked to relay Pyth Lazer updates, follow
`skills/setup-pyth-relayer/SKILL.md`. Each skill is orchestration over the canonical docs it
links — read the skill first, then the docs it points to.
