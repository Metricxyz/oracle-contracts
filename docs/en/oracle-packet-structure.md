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
- `s0` / `s1` — indices into `Codebook256.TABLE` (decoded to spread0/spread1 in bps).
- `slotId` is used to derive the storage key, but is **cleared before storing** (the stored slot always has `0x00` in the lowest byte).
- The entire slot is overwritten on update: if you update a single lane, you must still supply correct values for the other lanes.

## Fallback Payload (Off-chain → On-chain)

`fallback()` expects:

```text
[deadline(uint32)][word0(32)][word1(32)]...
```

where every `wordN` is a slot word as described above.

## Signature Payload (Off-chain → On-chain)

`updateBySignature(feedCreator, deadline, newSlotValue, signature)` expects `newSlotValue` to be a single slot word (same layout), signed by `feedCreator` over:

```text
keccak256(abi.encode(chainid, oracleAddress, feedCreator, deadline, newSlotValue))
```

## Required Guards

- `deadline` must be in the future (`DeadlineExceeded` otherwise).
- `timestamp` must not be in the future (`FutureTimestamp` otherwise).
- `timestamp` must be strictly increasing per slot (older updates are ignored).
- For the creator’s *current* (partially filled) slot, uncreated lanes must be zero (`UninializedPush` otherwise).
