// SPDX-License-Identifier: MIT
/**
 * U64x32 pseudo-float codec — TS mirror of contracts/oracles/utils/U64x32.sol.
 * Packed u32 layout: [exponent:5][mantissa:27]; decoded value = mantissa << exponent.
 * Encoding rounds DOWN: the smallest exponent is chosen so the mantissa fits 27 bits,
 * and the bits shifted out are lost. See docs/u64x32.md.
 *
 * Purpose: give the off-chain scripts the EXACT same lossy quantization the
 * Solidity library applies on-chain, so a pusher can predict what a pushed
 * price will read back as (`quantizeU64x32`) before spending gas on it.
 *
 * What happens inside: pure bigint/number bit-twiddling — no ABI encoding,
 * no RPC, no cryptography. `encodeU64x32` repeatedly halves the mantissa and
 * bumps the exponent until it fits 27 bits (rounding down, discarding the
 * shifted-out low bits); `decodeU64x32` reverses that into the quantized
 * bigint value actually stored on-chain.
 *
 * Inputs/outputs/env: `encodeU64x32(bigint): number` (a packed uint32),
 * `decodeU64x32(number): bigint`, `quantizeU64x32(bigint): bigint`
 * (round-trip helper). No env vars, no I/O.
 *
 * Place in the package: this file has NO client/RPC/ABI dependency and is
 * untouched by the ethers v6 client-library migration (only its header doc
 * was expanded here); it is a leaf module consumed by `slot.ts` (one lane
 * field) and directly by scripts/tests that need to predict on-chain
 * quantization.
 */
export const MANT_BITS = 27;
export const MANT_MAX = (1n << 27n) - 1n;
export const EXP_MAX = 31;
export const U64X32_MAX = MANT_MAX << 31n;

export function encodeU64x32(value: bigint): number {
  if (value < 0n) throw new RangeError(`u64x32: negative value ${value}`);
  if (value > U64X32_MAX) throw new RangeError(`u64x32: ${value} exceeds max ${U64X32_MAX}`);
  let exponent = 0;
  let mantissa = value;
  while (mantissa > MANT_MAX) {
    mantissa >>= 1n;
    exponent += 1;
  }
  // NOTE: plain arithmetic, not `<<` — JS bitwise ops are 32-bit signed and would overflow.
  return exponent * 2 ** MANT_BITS + Number(mantissa);
}

export function decodeU64x32(packed: number): bigint {
  if (!Number.isInteger(packed) || packed < 0 || packed > 0xffffffff) {
    throw new RangeError(`u64x32: packed value ${packed} is not a u32`);
  }
  const exponent = Math.floor(packed / 2 ** MANT_BITS);
  const mantissa = packed % 2 ** MANT_BITS;
  return BigInt(mantissa) << BigInt(exponent);
}

/** The value that will actually be stored on-chain for `value` (shows the quantization error). */
export function quantizeU64x32(value: bigint): bigint {
  return decodeU64x32(encodeU64x32(value));
}
