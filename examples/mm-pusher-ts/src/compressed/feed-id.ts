// SPDX-License-Identifier: MIT
/**
 * Registrationless feedId codec — TS mirror of CompressedOracle.feedIdOf/_unpackFeedId.
 * feedId = creator << 96 | chainid << 16 | slotIndex << 8 | positionIndex.
 * The feedId's `slotIndex`, the slot word's low byte `slotId` (see slot.ts) and the
 * env var SLOT_INDEX are the SAME number: the storage-slot coordinate inside the
 * creator's namespace.
 *
 * Purpose: let any caller derive a feed's bytes32 id purely from public
 * coordinates (creator address, chain id, slot, position) WITHOUT a chain
 * round-trip — there is no on-chain registry to query. `readFeedIdOf` in
 * `oracle.ts` exists only to cross-check this local derivation matches the
 * contract's own `feedIdOf`.
 *
 * What happens inside: `feedIdOf` bit-packs the four fields into a 32-byte
 * hex string with plain bigint shifts (no ABI encoding needed — this is a
 * fixed positional layout, not a Solidity `abi.encode`); `parseFeedId`
 * reverses that, validating each field's range and rejecting the zero
 * creator (an all-zero feedId cannot be valid — creator is checked first,
 * position range second, matching the contract's own decode order).
 *
 * `getAddress` is the one ethers import here (feed-id.ts is otherwise pure
 * bigint math): it EIP-55 checksums the creator address recovered from the
 * feedId's high bits.
 *
 * Inputs/outputs/env: `feedIdOf(creator, chainId, slotIndex, positionIndex):
 * Hex`, `parseFeedId(feedId: Hex): ParsedFeedId`. Both throw `RangeError` on
 * out-of-domain input. No env vars, no I/O.
 *
 * Place in the package: consumed by every compressed-lane script (01, 03,
 * 04, 05, 06) and by `oracle.ts`'s cross-check read.
 */
import { getAddress } from 'ethers';
import type { Address, Hex } from '../common/types.js';

const X80 = (1n << 80n) - 1n;

export interface ParsedFeedId {
  creator: Address;
  chainId: bigint;
  slotIndex: number;
  positionIndex: number;
}

export function feedIdOf(
  creator: Address,
  chainId: bigint | number,
  slotIndex: number,
  positionIndex: number,
): Hex {
  const chain = BigInt(chainId);
  if (chain < 0n || chain > X80) throw new RangeError(`feed-id: chainId ${chain} exceeds 80 bits`);
  if (!Number.isInteger(slotIndex) || slotIndex < 0 || slotIndex > 255) {
    throw new RangeError(`feed-id: slotIndex ${slotIndex} out of [0, 255]`);
  }
  if (!Number.isInteger(positionIndex) || positionIndex < 0 || positionIndex > 3) {
    throw new RangeError(`feed-id: positionIndex ${positionIndex} out of [0, 3]`);
  }
  const id =
    (BigInt(creator) << 96n) | (chain << 16n) | (BigInt(slotIndex) << 8n) | BigInt(positionIndex);
  return `0x${id.toString(16).padStart(64, '0')}`;
}

export function parseFeedId(feedId: Hex): ParsedFeedId {
  const raw = BigInt(feedId);
  const positionIndex = Number(raw & 0xffn);
  const slotIndex = Number((raw >> 8n) & 0xffn);
  const chainId = (raw >> 16n) & X80;
  const creatorRaw = raw >> 96n;
  if (creatorRaw === 0n) throw new RangeError('feed-id: zero creator');
  if (positionIndex > 3)
    throw new RangeError(`feed-id: positionIndex ${positionIndex} out of [0, 3]`);
  const creator = getAddress(`0x${creatorRaw.toString(16).padStart(40, '0')}`);
  return { creator, chainId, slotIndex, positionIndex };
}
