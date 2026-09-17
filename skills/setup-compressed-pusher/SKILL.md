---
name: setup-compressed-pusher
description: Stand up a market-maker pusher that publishes its own prices into CompressedOracleV1. Use when asked to "push our prices into the compressed oracle", "publish prices on-chain", "set up a compressed feed/pusher", or "become a price source".
---

# Set up a compressed-lane pusher

You are standing up the own-price push path on `examples/mm-pusher-ts`. The README inside
`examples/mm-pusher-ts` is the canonical walkthrough; format references:
`docs/oracle-packet-structure.md`, `docs/u64x32.md`, `docs/codebook.md`, `docs/slot-structure.md`.

Background reading: `docs/mm-operations-guide.md` — how a market maker launches and operates a
metric pool (the compressed lane, operations, and risks in context).

## Guardrails

- Secrets only via env (`.env` from `examples/mm-pusher-ts/.env.example`); never echo keys.
- Rehearse EVERYTHING on the offline demo first (`npm run demo` inside `examples/mm-pusher-ts`)
  before touching a real chain. Get explicit user confirmation before the first mainnet push.
- Every push step ends with the script's own readback verification — treat a non-zero exit as
  failure even when the transaction succeeded (stale words are silently ignored on-chain).

## The three traps (read before pushing)

1. **The slot is overwritten WHOLE** — all 4 positions are re-encoded on every push; unused
   positions are `'empty'` (the 0xFF/0xFF sentinel — it reads back as the stall spread 65535, so
   providers halt on that lane).
2. **Timestamps must strictly increase per slot** — an older word is silently ignored; that is
   the only replay protection. Keep one pusher process per slot.
3. **Encoding quantizes** — U64x32 rounds the price down, the codebook rounds spreads UP to the
   next table entry. The scripts print the quantized values; confirm they are acceptable.

## Steps

1. Prerequisites: Node ≥ 22, Foundry (for the demo), `npm ci` in `examples/mm-pusher-ts`.
2. Offline rehearsal: `npm run demo` — both lanes must pass locally.
3. Configure `.env`: `RPC_URL`, `COMPRESSED_ORACLE_ADDRESS` (from `DEPLOYMENTS.md` — deployed on
   all ten production chains), `PUSHER_PRIVATE_KEY`, `CREATOR_PRIVATE_KEY`, `SLOT_INDEX`.
4. Derive feedIds: `npx tsx scripts/01-derive-feed-id.ts` (cross-checks on-chain). There is no
   registration step — a feed exists once its first update lands. Give the position feedIds to
   whoever creates the provider (see the `create-provider` skill).
5. OPTIONAL delegation (cold creator / hot pusher split): `npx tsx scripts/02-authorize-pusher.ts`.
   Skip it and a key simply pushes into its own namespace.
6. Revocation: the creator can revoke a delegated (e.g. compromised) pusher key at any time with
   `removePushers([pusher])`; a pusher can also self-revoke with `revokePusher()`. Both are calls
   on the oracle contract. After revocation the key pushes into its OWN namespace again.
7. First real push + verification: `npx tsx scripts/03-push-once.ts` (non-zero exit = readback
   mismatch; stop and diagnose).
8. Guards: `npx tsx scripts/05-set-price-guard.ts` with the user's min/max (1e8-scaled).
9. Production loop: adapt the `PriceSource` interface in `scripts/04-run-pusher.ts` to the MM's
   market data; run under a supervisor. Cadence policy is the MM's own decision — the skeleton
   only provides a fixed interval.

## Troubleshooting

| Symptom | Meaning | Action |
| --- | --- | --- |
| Revert `FutureTimestamp` | local clock ahead of chain beyond the drift | fix NTP; retry |
| Tx ok but readback stale | timestamp not strictly newer | ensure one pusher per slot, monotonic clock |
| Revert `BadCalldataLength` | calldata not N×32 bytes | words must be exactly 32 bytes each |
| Position reads price 0 / ts 0 | empty-lane sentinel (0xFF/0xFF) | expected for unused positions |
