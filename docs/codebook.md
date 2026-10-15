# Codebook256

For publishers encoding spreads into `CompressedOracleV1` slot words and for readers decoding
them; read [the slot structure](slot-structure.md) first.

`Codebook256` is a lookup table that maps an 8-bit index (0–255) to a 16-bit spread in 0.01-bps
units (fraction × `1e6`), in the range `[0, 10_000]`. Spacing is nonlinear: indices near zero
decode to finer steps, larger indices cover wider bands. Each spread fits in one byte of a
feed's lane.

## Format

- Stored on-chain as `bytes constant TABLE`, each entry is two bytes (big-endian).
- Decoding: `value = TABLE[i*2] << 8 | TABLE[i*2 + 1]`.
- The table is generated off-chain and committed; the checked-in Solidity file is canonical.

## Precision

- Steps are finest near zero: `1` (0.01 bps) up to `9`, one step of `3` to `12`, then `2` up to
  `118`, `5` up to `438` and `10` up to `1_078`; above that the step is `150` up to `9_928`, and
  index 251 holds the ceiling `10_000`.
- Values are non-decreasing, but **not** duplicate-free: the committed table saturates, so indices
  251–255 all hold the maximum `10_000`. The pair `0xFF/0xFF` is the reserved stall sentinel and
  reads back as `65_535` on both sides; index 255 in any other pair decodes to `10_000`.

## Source data

The `Codebook256` contract holds the canonical table; its JSON source holds the same table:

- every entry is an integer in `[0, MAX_VALUE]` (10_000);
- the table is exactly 256 entries, the uint8 index space;
- duplicates are expected (see the saturated tail above).

## Using the table

- The contracts decode (index → value) only; encoding (value → index) happens off-chain.
- The table has exactly 256 entries.
- The table's ceiling is `MAX_VALUE = 10_000`, which in the 0.01-bps units the providers consume is
  **1%**, not 100%. The plain `PriceProvider`'s circuit breaker sits at 50_000 (5%), so a compressed
  feed can never trip that breaker. The reserved `0xFF/0xFF` pair is the only explicit stall
  marker, but not the only way to halt: stale or zero data, a guard breach, or a confidence
  multiplier large enough to consume the whole bid (spread `10_000` at `confidenceParam = 1_000_000`)
  halt a provider too.
