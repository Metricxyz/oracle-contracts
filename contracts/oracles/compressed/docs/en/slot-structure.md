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
`positionIndex > 3`, or a zero creator reverts `FeedNotFound` — exactly like an
unregistered feed used to.

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
"stalled" marker (readers surface spread0/spread1 as `10_000`).

## Updates (Fallback / Signature)

Updates overwrite the entire storage slot value.

- `fallback()` accepts one or more 32-byte slot words (no prefix; calldata length must
  be a non-zero multiple of 32).
- `updateBySignature(feedCreator, newSlotValue, signature)` accepts a slot word signed
  by the feed creator over `keccak256(abi.encode(chainid, oracleAddress, feedCreator,
  newSlotValue))`, and is callable by anyone.

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
- `timestamp` must not be further in the future than the configured drift (`FutureTimestamp`).
