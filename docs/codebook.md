# Codebook256 Overview

`Codebook256` is a lookup table that maps an 8-bit index (0–255) to a 16-bit value in the range `[0, 10_000]`. It provides nonlinear spacing: indices near zero decode to finer steps, while larger indices cover wider bands. This structure compresses spread inputs down to one byte in every feed.

## Format

- Stored on-chain as `bytes constant TABLE`, each entry is two bytes (big-endian).
- Decoding: `value = TABLE[i*2] << 8 | TABLE[i*2 + 1]`.
- The current table is generated off-chain and committed; the checked-in Solidity file is canonical.

## Precision Goals

- Maintain high resolution around tight spreads (0–50 bps).
- Allow coarser spacing in higher ranges (up to 10_000) to fit within 256 slots.
- Values are non-decreasing, but **not** duplicate-free: the committed table saturates, so indices
  251–255 all hold the maximum `10_000`. Encoding rounds **up** to the first entry ≥ the target, so it
  always yields the *lowest* index for a saturated value (251) and never emits 255 by accident —
  index 255 only ever appears as half of the reserved `0xFF/0xFF` stall sentinel.

## Regeneration Workflow

The committed `contracts/oracles/utils/Codebook256.sol` is canonical — it is generated from the
source JSON files under `contracts/oracles/compressed/codebook/`, which are also included here for
reference. Regeneration is a maintainer workflow, run by `scripts/generate-codebook.cjs` (in this
repo) and enforced in CI by the `codebook` job, which regenerates and then `git diff --exit-code`s —
so drift in either direction fails the build. The generator:

1. Flattens every numeric entry from `codebook/*.json` into a single byte string. ⚠️ It globs the
   **whole directory**, sorted — adding a second JSON file that sorts before the canonical one shifts
   every index, and both CI gates still pass because they regenerate from the same glob. Keep exactly
   one source file.
2. Validates that each entry is an integer in `[0, MAX_VALUE]` (10_000) — *not* merely the uint16
   range, since an entry of 65_535 would let a single lane mint the reserved stall sentinel — and
   that the table is exactly 256 entries, the uint8 index space. It does **not** check for duplicates;
   duplicates are expected (see the saturated tail above).
3. Rewrites `contracts/oracles/utils/Codebook256.sol` so `TABLE` contains the new hex data.

The regenerated Solidity file and the JSON source are always committed together to keep the two in sync.

## Usage Reminders

- Decoding on-chain is cheap, but encoding (value → index) should happen off-chain to avoid searches in Solidity.
- Keep tests updated (`test/oracles/...`) when the distribution shifts; precision assumptions may change.
- The table must be exactly 256 entries; the generator rejects anything else. Fewer would make
  `Codebook256.decode` return `ok = false` for the high indices and revert `CodebookDecodeFailed` on
  read, bricking the compressed lane; more are silently unreachable through a uint8 index.
- The table's ceiling is `MAX_VALUE = 10_000`, which in the 0.01-bps units the providers consume is
  **1%**, not 100%. The plain `PriceProvider`'s circuit breaker sits at 50_000 (5%), so a compressed
  feed can never trip it — a compressed lane halts only via the reserved `0xFF/0xFF` sentinel.
