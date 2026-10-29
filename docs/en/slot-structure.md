# CompressedOracle Slot Structure

`CompressedOracleV1` packs up to **4 feeds** into a single 256-bit storage slot. Each feed occupies a 48-bit lane; the remaining lower 64 bits store slot-level metadata.

## Namespace & Keys

- Namespace base: `namespace = uint256(uint160(creator)) << 96`.
- Slot key: `slotKey = bytes32(namespace | slotId)`, where `slotId` is a `uint8`.
- Feed position: `positionIndex ∈ [0, 3]` selects the 48-bit lane within the slot.
- Feed id: `feedId = keccak256(abi.encodePacked(chainid, address(this), slotKey, positionIndex))`.

Only the creator (or an approved pusher via `namespaceRemapping`) can write to the creator namespace via `fallback`.

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

On `createOracles` each newly created feed lane is initialized to `DEFAULT_ORACLE_DATA_VALUE`:

- `p = 0`, `s0 = 0xFF`, `s1 = 0xFF` (treated as “unset”; readers surface spread0/spread1 as `10_000`).

Uncreated lanes remain zero. `timestamp` is not set during creation.

## Updates (Fallback / Signature)

Updates overwrite the entire storage slot value.

- `fallback()` accepts a `uint32 deadline` followed by one or more 32-byte slot words.
- `updateBySignature()` accepts a slot word signed by the feed creator, and is callable by anyone.

A **slot word** matches the slot layout above, but uses the lowest byte to carry `slotId` in calldata:

```text
bits 255 …  64 : oracle[0..3]
bits  63 …   8 : timestamp (uint56, unix milliseconds)
bits   7 …   0 : slotId (uint8, used to derive the storage key; cleared before storing)
```

Guards:

- `timestamp` must strictly increase per slot (freshness guard).
- `timestamp` must not be in the future (`FutureTimestamp`).
- For the *current* (partially-filled) slot, all **uncreated lanes must be zero**, otherwise the update reverts with `UninializedPush`.
