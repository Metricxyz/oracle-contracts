# Codebook256 Overview

`Codebook256` is a lookup table that maps an 8-bit index (0–255) to a 16-bit value in the range `[0, 10_000]`. It provides nonlinear spacing: indices near zero decode to finer steps, while larger indices cover wider bands. We rely on this structure to compress spread inputs down to one byte in every feed.

## Format

- Stored on-chain as `bytes constant TABLE`, each entry is two bytes (big-endian).
- Decoding: `value = TABLE[i*2] << 8 | TABLE[i*2 + 1]`.
- The current table is generated off-chain and embedded during builds.

## Precision Goals

- Maintain high resolution around tight spreads (0–50 bps).
- Allow coarser spacing in higher ranges (up to 10_000) to fit within 256 slots.
- No duplicate values to keep the mapping stable and reversible (though inverse lookup is performed off-chain).

## Regeneration Workflow

Source JSON files live under `codebook/`. To rebuild the Solidity constant after editing them:

```bash
npm run codebook:generate
```

This script:

1. Flattens every numeric entry from `codebook/*.json` into a single byte string.
2. Validates bounds and duplicates (throws on violations).
3. Rewrites `contracts/oracles/utils/Codebook256.sol` so `TABLE` contains the new hex data.

Always commit the regenerated Solidity file alongside the JSON source to keep the repository reproducible.

## Usage Reminders

- Decoding on-chain is cheap, but encoding (value → index) should happen off-chain to avoid searches in Solidity.
- Keep tests updated (`test/oracles/...`) when the distribution shifts; precision assumptions may change.
- If you add more than 256 entries, the build will fail—ensure the table stays within the byte-cap.
