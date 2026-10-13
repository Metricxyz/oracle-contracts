# CompressedOracle Slot Structure

`CompressedOracleV1` packs up to **4 feeds** into a single 256-bit storage slot. Each feed occupies a 48-bit lane; the remaining lower 64 bits store slot-level metadata.

The oracle is **registrationless**: there is no feed registry and no creation step — a feed's location IS its identity, encoded directly in the feedId.

## Namespace & Keys

- Namespace base: `namespace = uint256(uint160(creator)) << 96`.
- Slot key: `slotKey = bytes32(namespace | slotId)`, where `slotId` is a `uint8`.
- Feed position: `positionIndex ∈ [0, 3]` selects the 48-bit lane within the slot.
- Feed id (self-describing, see `feedIdOf`):

```text
feedId = bytes32( uint256(uint160(creator)) << 96   // bits [255:96] creator
                | block.chainid << 16               // bits [95:16]  chain id (80 bits)
                | uint256(slotIndex) << 8           // bits [15:8]   slot index
                | positionIndex )                   // bits [7:0]    position index
```

Reads decode the coordinates straight from the feedId; an id with a foreign chain id,
`positionIndex > 3`, or a zero creator reverts `FeedNotFound`.

A wallet writes into `namespaceRemapping[msg.sender]`'s namespace, falling back to its
**own** namespace when no delegation is set — a creator needs zero setup transactions.
Delegation (`allowPushers`) requires each pusher's EIP-191 signature (and a deadline:
the signed consent has no data timestamp, so an undated signature could re-establish a
delegation after the pusher revoked it).

## Slot Layout (Big-Endian)

```text
bits 255 … 208 : oracle[0] (48 bits)
bits 207 … 160 : oracle[1] (48 bits)
bits 159 … 112 : oracle[2] (48 bits)
bits 111 …  64 : oracle[3] (48 bits)
bits  63 …   8 : timestamp (uint56, unix milliseconds)
bits   7 …   0 : reserved (always 0 in storage)
```

Each oracle lane encodes:

- `p` (32 bits) — price using `U64x32` pseudo-float (`U64x32.decode`).
- `s0` (8 bits) — spread index in `Codebook256`.
- `s1` (8 bits) — spread index in `Codebook256`.

## Default State

A never-pushed slot reads as all zeros: `timestamp = 0`, so every consumer rejects it
as stale — no seeding is needed. A lane with `s0 = 0xFF, s1 = 0xFF` is the explicit
"stalled" marker (readers surface spread0/spread1 as the stall sentinel `65_535` —
`type(uint16).max`, outside the codebook's `[0, 10_000]` value range).

## Updates (Fallback / Signature)

Updates overwrite the entire storage slot value.

- `fallback()` accepts a **single leading zero byte** followed by one or more 32-byte slot
  words — calldata is `0x00` + N×32 bytes (length ≡ 1 mod 32, N ≥ 1). The zero byte guarantees
  the first 4 bytes of calldata can never equal a function selector (none start with `0x00`),
  so a push whose word content happens to spell a selector still hits the fallback rather than
  dispatching to that function.
- `updateBySignature(feedCreator, newSlotValue, signature)` accepts a slot word whose EIP-191
  signature by the feed creator covers the 32-byte digest `keccak256(abi.encode(chainid,
  oracleAddress, feedCreator, newSlotValue))`, and is callable by anyone. The contract recovers over
  the prefixed hash (`toEthSignedMessageHash`), so a signature over the bare digest is rejected.

There is **no deadline** on either push path: each word carries its own timestamp and
the per-slot monotonicity check neutralizes replay (a replayed word is "not newer" and
is skipped).

A **slot word** matches the slot layout above, but uses the lowest byte to carry `slotId` in calldata:

```text
bits 255 …  64 : oracle[0..3]
bits  63 …   8 : timestamp (uint56, unix milliseconds)
bits   7 …   0 : slotId (uint8, used to derive the storage key; cleared before storing)
```

Guards:

- `timestamp` must strictly increase per slot (freshness guard; non-newer words are skipped).
- `floor(timestampMs / 1000) <= block.timestamp + MAX_TIME_DRIFT` must hold — the check is on whole seconds (`FutureTimestamp` otherwise).
