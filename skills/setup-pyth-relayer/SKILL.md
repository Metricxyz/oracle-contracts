---
name: setup-pyth-relayer
description: Stand up a relay that forwards Pyth-Lazer-signed price updates into PythOracle. Use when asked to "relay Pyth Lazer updates", "push Pyth prices on-chain", or "set up the pyth lane".
---

# Set up a Pyth Lazer relayer

You are standing up the relay path on `examples/mm-pusher-ts` (see the README inside that
directory). The relayer NEVER signs price data — the Lazer signature is
the only trust anchor and anyone may push a genuine envelope.

Background reading: `docs/mm-operations-guide.md` — how a market maker launches and operates a
metric pool (the Pyth relay lane, operations, and risks in context).

## Guardrails

- Secrets (keys, the Lazer access token) only via env; never echo them.
- Rehearse offline first: `npm run demo` in `examples/mm-pusher-ts` exercises the exact relay
  core against a locally deployed `PythOracle`. Confirm with the user before mainnet relaying.
- Readback is ONLY via `eth_call` of `price(feedId, address(0))` with no from-account
  (`getOracleData` reverts `ReadDisabled` on this oracle); `refTime` is in seconds.

## The two traps

1. **Exact property set** — subscriptions must request exactly price / exponent / confidence /
   feedUpdateTimestamp with the `evm` format; any deviation reverts the whole push
   (`UnexpectedPropsCount` / `UnknownProperty`).
2. **The oracle pays the 1-wei verification fee from its own balance** — if the balance is
   empty every push reverts. Check `cast balance $PYTH_ORACLE_ADDRESS`; top up with a plain
   transfer (its `receive()` is payable).

## Steps

1. Prerequisites: Node ≥ 22, `npm ci` in `examples/mm-pusher-ts`, a Lazer access token (issued
   by Pyth), the Lazer uint32 feed ids to relay.
2. Offline rehearsal: `npm run demo`.
3. Configure `.env`: `RPC_URL`, `PYTH_ORACLE_ADDRESS` (from `DEPLOYMENTS.md` — every chain except
   avalanche), `PUSHER_PRIVATE_KEY`, `LAZER_WS_URL`, `LAZER_HTTP_URL`, `LAZER_ACCESS_TOKEN`,
   `LAZER_FEED_IDS`.
4. One-shot relay + verification: `npx tsx scripts/10-pyth-push-once.ts` (HTTPS mode). Non-zero
   exit = readback mismatch; stop and diagnose.
5. Production loop: `npx tsx scripts/11-pyth-run-pusher.ts` under a supervisor (it exits on WS
   close by design). Stale/duplicate updates are dropped on-chain by the per-feed signed
   timestamp — the loop needs no bookkeeping.

## Troubleshooting

| Symptom | Meaning | Action |
| --- | --- | --- |
| Revert `UnexpectedPropsCount`/`UnknownProperty` | subscription property set differs from the oracle's | request exactly the four properties above |
| Revert `FeedIdMismatch` | calldata id list order ≠ payload feed order | derive ids from the payload (script 10 does) |
| Revert "Insufficient fee provided" | oracle balance empty | top up the ORACLE address |
| `FeedNotFound` on readback | feed has no data yet on this oracle | push first, then read |
