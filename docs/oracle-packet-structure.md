# Compressed oracle packet format

For publishers writing to `CompressedOracleV1`: the calldata of a push and of a signed update,
and the checks a word must pass. Read [the slot structure](slot-structure.md) first for feed
addressing and the lane encoding.

## Slot word (32 bytes)

`CompressedOracleV1` consumes 32-byte **slot words** through both `fallback()` and
`updateBySignature()`. A slot word is the storage slot with the `slotId` in its lowest byte:

```text
bits 255 … 208 : oracle[0].p (32b) | oracle[0].s0 (8b) | oracle[0].s1 (8b)
bits 207 … 160 : oracle[1].p (32b) | oracle[1].s0 (8b) | oracle[1].s1 (8b)
bits 159 … 112 : oracle[2].p (32b) | oracle[2].s0 (8b) | oracle[2].s1 (8b)
bits 111 …  64 : oracle[3].p (32b) | oracle[3].s0 (8b) | oracle[3].s1 (8b)
bits  63 …   8 : timestamp (uint56, unix milliseconds)
bits   7 …   0 : slotId (uint8)
```

- `p`, `s0`, `s1` — the lane fields described in [the slot structure](slot-structure.md):
  a [`U64x32`](u64x32.md) price that decodes to the E8 mid, and two [`Codebook256`](codebook.md)
  indices that decode to spreads in 0.01-bps units (fraction × `1e6`; `10_000` = 1% is the
  table's ceiling). The reserved pair `s0 = s1 = 0xFF` is the stall sentinel and reads back as
  `65_535` on both. It is the only explicit stall marker; providers also halt on stale, zero or
  guard-breaching data, on spreads past their own limits, and when confidence shaping consumes
  the bid.
- `slotId` derives the storage key and is **cleared before storing** (the stored slot always has
  `0x00` in the lowest byte).
- The whole slot is overwritten on update: a push that changes one lane still supplies correct
  values for the other lanes.

## Fallback payload

`fallback()` takes one leading byte, then one or more slot words (no deadline prefix — each
word carries its own timestamp):

```text
[0x00][word0(32)][word1(32)]...
```

Calldata length must be `1 + 32·N` with `N ≥ 1` (`BadCalldataLength` otherwise). The contract
does not check the leading byte; it only skips it. Set it to `0x00`: the calldata's first 4 bytes
are then `0x00....`, which matches no function selector (none start with `0x00`), so a push whose
word content happens to spell a selector still hits `fallback()` instead of dispatching to that
function.

## Signature payload

`updateBySignature(feedCreator, newSlotValue, signature)` takes a single slot word, signed by
`feedCreator`, and is callable by anyone. The signature covers:

```text
digest = keccak256(abi.encode(chainid, oracleAddress, feedCreator, newSlotValue))
signed = keccak256("\x19Ethereum Signed Message:\n32" ‖ digest)
```

The creator signs the 32-byte `digest` as an EIP-191 personal message — the contract recovers the
signer from `MessageHashUtils.toEthSignedMessageHash(digest)`. A signature over `digest` itself,
without the prefix, is rejected.

## Required guards

- `floor(timestampMs / 1000) <= block.timestamp + MAX_TIME_DRIFT` must hold — the check is on
  whole seconds (`FutureTimestamp` otherwise).
- `timestamp` must be strictly increasing per slot; a non-newer word is skipped (`fallback()`
  moves on to the next word, `updateBySignature()` returns `false`). This is also the replay
  protection: there is no deadline on either push path.
- `updateBySignature()` reverts `InvalidNamespace` when `feedCreator` is the zero address.
- `updateBySignature()` reverts when the signature does not recover to `feedCreator`: a
  well-formed signature by another key reverts without an error, a malformed one reverts with
  OpenZeppelin's `ECDSAInvalidSignature`, `ECDSAInvalidSignatureLength` or
  `ECDSAInvalidSignatureS`. The signature is checked only for a newer word, so a non-newer word
  returns `false` before it.
