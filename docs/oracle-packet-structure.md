# Bit Packing Cheatsheet

## Slot Word (32 bytes)

`CompressedOracleV1` consumes 32-byte **slot words** through both `fallback()` and `updateBySignature()`.

The slot word layout is:

```text
bits 255 … 208 : oracle[0].p (32b) | oracle[0].s0 (8b) | oracle[0].s1 (8b)
bits 207 … 160 : oracle[1].p (32b) | oracle[1].s0 (8b) | oracle[1].s1 (8b)
bits 159 … 112 : oracle[2].p (32b) | oracle[2].s0 (8b) | oracle[2].s1 (8b)
bits 111 …  64 : oracle[3].p (32b) | oracle[3].s0 (8b) | oracle[3].s1 (8b)
bits  63 …   8 : timestamp (uint56, unix milliseconds)
bits   7 …   0 : slotId (uint8)
```

Notes:

- `p` — `U64x32`-encoded price (stored as `uint32`).
- `s0` / `s1` — indices into `Codebook256.TABLE`. The decoded values are in **0.01-bps units**
  (fraction × 1e6): `100` = 1 bp, `10_000` = 1% = the table's ceiling — *not* whole bps. The reserved
  pair `s0 = s1 = 0xFF` is the stall sentinel and reads back as `65_535` on both. It is the only
  explicit stall marker; providers also halt on stale, zero or guard-breaching data, on spreads past
  their own limits, and when confidence shaping consumes the bid.
- `slotId` is used to derive the storage key, but is **cleared before storing** (the stored slot always has `0x00` in the lowest byte).
- The entire slot is overwritten on update: if you update a single lane, you must still supply correct values for the other lanes.

## Fallback Payload (Off-chain → On-chain)

`fallback()` expects a single leading zero byte, then one or more slot words (no deadline
prefix — each word carries its own timestamp):

```text
[0x00][word0(32)][word1(32)]...
```

where every `wordN` is a slot word as described above. Calldata length must be `1 + 32·N`
with `N ≥ 1` (`BadCalldataLength` otherwise). The leading zero byte makes the calldata's
first 4 bytes `0x00....`, which matches no function selector (none start with `0x00`), so a
push whose word content happens to spell a selector still hits `fallback()` instead of
dispatching to that function.

## Signature Payload (Off-chain → On-chain)

`updateBySignature(feedCreator, newSlotValue, signature)` expects `newSlotValue` to be a single slot word (same layout), signed by `feedCreator` over:

```text
digest = keccak256(abi.encode(chainid, oracleAddress, feedCreator, newSlotValue))
signed = keccak256("\x19Ethereum Signed Message:\n32" ‖ digest)
```

The creator signs the 32-byte `digest` as an EIP-191 personal message — the contract recovers the
signer from `MessageHashUtils.toEthSignedMessageHash(digest)`. A signature over `digest` itself,
without the prefix, is rejected.

## Required Guards

- `floor(timestampMs / 1000) <= block.timestamp + MAX_TIME_DRIFT` must hold — the check is on whole seconds (`FutureTimestamp` otherwise).
- `timestamp` must be strictly increasing per slot (older updates are ignored — this is
  also the replay protection: there is no deadline anywhere on the push paths).
