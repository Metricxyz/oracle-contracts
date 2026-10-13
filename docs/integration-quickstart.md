# Integrate an oracle

Follow this path to rehearse publishing locally, select a real feed, create a price
provider and verify its pool access. Commands run from the repository root unless
the block changes directory. Production steps require your own selected chain,
feed, token pair and funded transaction signer.

## 1. Rehearse locally

Publishing is rehearsed in the pusher package, a separate repository. Prerequisites:
Node.js 22+, npm, and Foundry (`forge`, `cast`, `anvil`). The first install may need
network access; the demo itself runs on a local chain with demo signing keys.

```bash
git clone git@github.com:Metricxyz/mm-pusher-ts.git
cd mm-pusher-ts
npm ci
npm test
npm run demo
```

Expected result: unit checks pass and the demo ends with
`demo OK: both lanes verified against locally deployed contracts`. It tests
compressed publishing/delegation/readback and a locally signed Pyth relay.
Chainlink has unit tests but is **not** part of this offline end-to-end demo.
This does not validate a real upstream subscription or production deployment.

## 2. Select the deployment and feed

Use [the comparison](oracle-overview.md#choose-an-oracle) and
[DEPLOYMENTS.md](../DEPLOYMENTS.md). Record the chain ID, oracle address, provider
factory address, feed IDs and economic token pair. Confirm dependencies and live
factory state on the selected chain. Supply explicit addresses to scripts; do not
assume their working `networks.json` is current.

Set these shell variables to your selected values before running the read-only checks:

```bash
: "${RPC_URL:?Set the target chain RPC URL}"
: "${ORACLE:?Set the oracle from DEPLOYMENTS.md}"
: "${FEED_ID:?Set a 32-byte feed ID}"
cast chain-id --rpc-url "$RPC_URL"
cast code "$ORACLE" --rpc-url "$RPC_URL"
cast call "$ORACLE" "kind()(string)" --rpc-url "$RPC_URL"
cast call "$ORACLE" "version()(string)" --rpc-url "$RPC_URL"
```

Expected result: the intended chain, nonempty code and the expected oracle kind.
These checks complement the deployment record; a matching version does not prove
that an address is the active instance.

## 3. Publish or arrange delivery

Use the [pusher package](https://github.com/Metricxyz/mm-pusher-ts) for environment setup
and executable commands:

| Source | Required setup | Verify |
| --- | --- | --- |
| Your own compressed feed | Choose slot/positions; derive IDs; optionally delegate a pusher; connect your own price source | All four positions and the stored timestamp after publishing |
| Pyth Lazer | Authorized upstream subscription, exact property set/feed order, relay signer and oracle fee balance | Feed's signed observation time and normalized mid |
| Chainlink Data Streams | API credentials, supported report/schema, configured verifier tag and relay signer | Report observation time and normalized mid |

The compressed one-shot scripts publish fixed **demo prices**. Reuse their codec
and readback logic, but connect your real price source before using a live feed.
If another party publishes a shared Pyth/Chainlink feed, agree who monitors and
restores delivery; a feed's existence is not a liveness commitment.

## 4. Check the raw data

This read-only command works for all three oracle families:

```bash
ZERO_ADDRESS=0x0000000000000000000000000000000000000000
cast call "$ORACLE" \
  "price(bytes32,address)(uint256,uint256,uint16,uint256)" \
  "$FEED_ID" "$ZERO_ADDRESS" --from "$ZERO_ADDRESS" --rpc-url "$RPC_URL"
```

The return order is `(mid, spread0, spread1, refTime)`: E8 price, 0.01-bps spread,
family-specific secondary spread, and **seconds**. Require a positive mid and a
recent, nonfuture timestamp; compare the value with your intended pair. Check all
legs of a synthetic feed. Treat any revert as a failed check to diagnose, not as
proof that usable data exists.

A compressed position in a never-written slot returns zeros; a never-written position
in a slot that has been written returns price `0` with the slot's shared timestamp.
Pyth/Chainlink missing feeds revert `FeedNotFound`. See [the failure reference](oracle-reference.md#failure-reference).

## 5. Create the provider

Choose one of the existing walkthroughs:

- [Plain provider](price-provider-quickstart.md): one feed, fixed margin and freshness,
  mutable confidence through its factory.
- [Anchored provider](anchored-price-provider-quickstart.md): reference feed(s),
  factory allowlist/envelope and optional custom source.

Run the creation script without `--broadcast` first. Check the transaction receipt and
`ProviderDeployed` event, then verify the returned provider's tokens, feed IDs and
limits. Constructor success does not prove feed health, correct pair semantics or
pool read access.

Read its quote off-chain with the same explicit zero sender:

```bash
: "${PROVIDER:?Set the newly created provider address}"
cast call "$PROVIDER" "getQuote()(uint128,uint128,uint128)" \
  --from "$ZERO_ADDRESS" --rpc-url "$RPC_URL"
```

Expected result: positive `bid`, `bid < ask`, and `bid <= referencePrice <= ask`,
all Q64.64. Decode and compare with the intended human price. For delivery with a
trade, simulate the required update **before** this quote read.

## 6. Wire and register the pool

Create/configure the pool through its integration workflow and set this provider.
For Pyth/Chainlink, register the pool for every feed read by the provider. This is
**pool read registration**, not feed creation. An APP ratio needs both legs.

With `POOL` and `POOL_FACTORY` set to your actual pool and its factory:

```bash
: "${POOL:?Set the pool address}"
: "${POOL_FACTORY:?Set the pool factory address}"
cast call "$POOL_FACTORY" "isPool(address)(bool)" "$POOL" --rpc-url "$RPC_URL"
FACTORY_COUNT=$(cast call "$ORACLE" "approvedFactoryCount()(uint256)" --rpc-url "$RPC_URL")
cast call "$ORACLE" "getApprovedFactories(uint256,uint256)(address[])" \
  0 "$FACTORY_COUNT" --rpc-url "$RPC_URL"
cast call "$ORACLE" "registrationFee()(uint256)" --rpc-url "$RPC_URL"
cast call "$ORACLE" "registeredPool(bytes32,address)(bool)" \
  "$FEED_ID" "$POOL" --rpc-url "$RPC_URL"
```

Require a recognized pool and an approved factory. If registration is absent, send
`register(bytes32,address,address)` with `(FEED_ID, POOL, POOL_FACTORY)` and exactly
the current registration fee using your chosen transaction signer, then repeat the
last check. Compressed reads need no registration.

Finally simulate the **actual swap path**, including its update payload where
applicable. A successful zero-sender quote does not test the real transaction's
registration and `inSwap()` context. Pool tier requirements and other pool guards
are separate from factory membership and belong to the pool documentation.

## 7. Establish operating checks

Before serving traffic, test missing/stale data and verify that the chosen provider
halts. Check every feed's delivery responsibility, gas/verification balances,
nonce recovery and alert handling. Use [the operations guide](mm-operations-guide.md)
and [the units/failure reference](oracle-reference.md).
