// SPDX-License-Identifier: MIT
/**
 * Local branded-ish type aliases for hex strings and addresses.
 *
 * Purpose: ethers v6 does not export its own branded string types — every
 * address/hex value is a plain `string` at the type level. This file is the
 * SINGLE place that defines what the rest of the package imports for these
 * two concepts, so a future client-library swap touches one type
 * definition instead of scattering `string` literals everywhere.
 *
 * What happens inside: nothing at runtime — this file is types only (it
 * compiles away completely; `tsc --noEmit` is the only thing that reads it).
 *
 * Inputs/outputs/env: none (pure type declarations, no runtime values).
 *
 * Place in the package: imported by every module under `src/`, `scripts/`,
 * `demo/`, and `test/` that needs a hex-string or address type. `Hex` keeps
 * the `0x${string}` template-literal shape so callers still get compile-time
 * "starts with 0x" checking; `Address` is intentionally a plain `string`
 * (ethers does not distinguish checksummed vs. non-checksummed addresses at
 * the type level — `getAddress` normalizes at runtime instead).
 */
export type Hex = `0x${string}`;
export type Address = string;
