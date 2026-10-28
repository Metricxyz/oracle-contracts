# Contributing

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`, `anvil`) — `forge build` compiles with
  the solc version pinned in `foundry.toml` (`0.8.33`, `via-ir` enabled).
- Node.js is not required — `contracts/oracles/utils/Codebook256.sol` is a committed, canonical
  lookup table; regenerating it from JSON sources is a maintainer workflow (tooling not included in
  this repo). See [`docs/codebook.md`](./docs/codebook.md) for the format.

## Building & testing

```bash
forge build --sizes
forge test -vv
forge test --match-test <TestName>   # run a single test with traces
```

The full test suite must stay green. Any behavior change under `contracts/` needs a corresponding
change under `test/` (tests mirror contracts 1:1, `test/<Path>/<Contract>.t.sol`).

## Style

Solidity formatting is enforced with `forge fmt` (default settings) — run it before committing;
CI rejects unformatted code via `forge fmt --check`.

## Licensing

Seven core files (the compressed-oracle and price-provider-factory implementations) are
BUSL-1.1-licensed — see the License section of [`README.md`](./README.md) and
[`licenses/BUSL_LICENSE`](./licenses/BUSL_LICENSE). Changes to those files are contributions under
that license; everything else in the repo is MIT.
