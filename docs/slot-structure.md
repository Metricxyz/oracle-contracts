# CompressedOracle slot structure

For publishers and integrators of `CompressedOracleV1` feeds: how feeds are addressed and how a
storage slot is laid out. The calldata that writes a slot is in
[the packet format](oracle-packet-structure.md).

`CompressedOracleV1` packs up to **4 feeds** into one 256-bit storage slot. Each feed occupies a
48-bit lane; the lower 64 bits hold slot-level metadata.

The oracle is **registrationless**: there is no feed registry and no creation step — a feed's
location is its identity, encoded directly in the feedId.

## Namespace & keys

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
Delegation (`allowPushers`) requires each pusher's EIP-191 signature; the signed consent
carries a deadline. A contract pusher is delegated with `allowContractPushers` instead: the call
reverts unless the pusher contract answers `isPusher(creator)` with `true`, and takes no signature
or deadline. A pusher writes into one namespace at a time, so when two creators delegate the same
pusher, the later call takes it. A pusher leaves its delegation with `revokePusher()`; a creator
drops its own pushers with `removePushers`.

## Storage slot layout (big-endian)

```text
bits 255 … 208 : oracle[0] (48 bits)
bits 207 … 160 : oracle[1] (48 bits)
bits 159 … 112 : oracle[2] (48 bits)
bits 111 …  64 : oracle[3] (48 bits)
bits  63 …   8 : timestamp (uint56, unix milliseconds)
bits   7 …   0 : reserved (always 0 in storage)
```

Each lane encodes:

- `p` (32 bits) — the price as a [`U64x32`](u64x32.md) word; decoded, it is the E8 mid that
  `price()` returns.
- `s0` (8 bits) and `s1` (8 bits) — indices into [`Codebook256`](codebook.md); the decoded
  spreads are in 0.01-bps units (fraction × `1e6`).

An update overwrites the whole slot: every lane and the timestamp. The calldata word that carries
it adds the `slotId` in its lowest byte — see [the packet format](oracle-packet-structure.md).

## Default state

A never-pushed slot reads as all zeros: `timestamp = 0`, so every consumer rejects it as stale —
no seeding is needed. A lane with `s0 = 0xFF, s1 = 0xFF` is the explicit "stalled" marker.
A price read of it (`price`, `getOracleData`) ignores the lane's price bits and the slot's
timestamp and returns price `0`, timestamp `0`, and the stall sentinel `65_535`
(`type(uint16).max`, outside the codebook's `[0, 10_000]` value range) in both spread0 and
spread1. Consumers reject it as stalled, zero-priced and stale.
