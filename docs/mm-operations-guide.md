# Market-maker operations guide

Operate the feed and provider behind a Metric pool: publish or relay observations,
verify the result, and restore quoting when delivery fails. For a first setup, use
[the integration quickstart](integration-quickstart.md). For architecture and
provider selection, use [the overview](oracle-overview.md).

## At a glance

- Compressed feeds carry your own prices. Pyth and Chainlink carry verified upstream observations.
- A successful transaction can leave a feed unchanged. Verify the stored observation.
- Standard providers reject data outside their configured validity limits; they cannot identify every economically wrong price.
- Factory membership, feed health, pool read registration and pool tier are separate checks.

### Prerequisites

Use the selected deployment from [DEPLOYMENTS.md](../DEPLOYMENTS.md), a working RPC,
a funded pusher/relay key and the corresponding upstream data access. The example
package needs Node.js 22+; the local demo also needs Foundry.

### Contents

- [1. The big picture](#1-the-big-picture)
- [2. Choosing a pair and constructing the price](#2-choosing-a-pair-and-constructing-the-price)
- [3. Publishing: compressed, Pyth and Chainlink](#3-publishing-compressed-pyth-and-chainlink)
- [4. Provider and pool wiring](#4-provider-and-pool-wiring)
- [5. Operations](#5-operations)
- [6. Risks and recovery](#6-risks-and-recovery)
- [7. What you get vs what you build](#7-what-you-get-vs-what-you-build)
- [Appendix A: units and encodings cheat sheet](#appendix-a-units-and-encodings-cheat-sheet)
- [Appendix B: revert reference](#appendix-b-revert-reference)

## 1. The big picture

```text
+-------------------+     +---------------+     +----------------+     +------+
| source -> publisher| --> | oracle storage| --> | price provider | --> | pool |
+-------------------+     +---------------+     +----------------+     +------+
```

The publisher delivers observations. The oracle authenticates updates and orders
them by timestamp. The provider reads the selected feed(s), checks validity and
returns a bid, ask and reference price. The pool applies its swap rules.

Define an owner for each operational dependency: price source, publisher,
transaction delivery, reference-feed relay, provider configuration and alerts.
Shared Pyth/Chainlink feeds still need someone responsible for delivery. An
accepted upstream signature is not a promise of future updates or correct markets.

## 2. Choosing a pair and constructing the price

Record the economic meaning of each feed and the provider's token pair.
Feed identities carry no token metadata; the feed's economic meaning must match the
provider's declared token pair. A base/quote price means quote-token units per base-token
unit; `token0()` and `token1()` expose that ordering on the standard provider.

For your own compressed feed, define where the mid and spread come from, how old
inputs may be, how outliers are handled, and when publishing must stop or explicitly
stall. Publish an honest observation time; refreshing a frozen mid's timestamp can
keep a stale economic price quotable.

For Pyth/Chainlink, retain the upstream signed observation time. The relayer cannot
replace it with its reception or submission time. Match feed IDs and denominations
to the desired pair before creating the provider.

### Synthesizing a cross price

APP can divide two feeds from the same oracle: `BTC/USD ÷ ETH/USD = BTC/ETH`.
Choose legs that share a quote denomination and whose ratio matches the declared
tokens. The contract does not check those semantics.

Each leg has its own freshness limit, bounded by `MAX_REF_STALENESS`. There is no
separate cross-leg observation-skew limit: both legs can pass their age checks
while describing different market moments. Review both observation times when
operating a synthetic pair. The APP propagates uncertainty through opposing
interval edges; see [the APP reference](anchored-price-provider.md).

## 3. Publishing: compressed, Pyth and Chainlink

### The compressed lane — you are the price source

Derive the feed ID from the creator, chain ID, slot and position. A creator can push
directly without setup. A delegated hot key needs creator authorization and the
pusher's consent. The alternative `updateBySignature` path relays a creator-signed
slot word.

Every push replaces all four positions in a slot and their shared timestamp. Encode
unused positions with the paired `0xFF/0xFF` marker. A price-update payload has no
deadline prefix: the fallback format is one zero byte followed by 32-byte slot words.
Pusher-delegation consent has a deadline and replay rules of its own.

Use one coordinated writer per slot. Old/equal timestamps are ignored, and an
accepted future timestamp cannot be repaired by writing an earlier one. Read back
all affected positions using the creator's namespace after each critical update.

The compressed scripts in [the pusher package](https://github.com/Metricxyz/mm-pusher-ts) show ID
derivation, delegation, publishing, guards and creator-signed relay. Their sample prices are
educational data, not a production price source.

### The Pyth relay — you are a courier

Relay the signed Lazer envelope with its feed IDs in the exact signed order. Match
the deployed parser's property set; the standard example requests price, exponent,
confidence and feedUpdateTimestamp in EVM format. The oracle pays its fixed
verification fee from its own balance.

The checked-in parser skips invalid/unusable observations without advancing their
stored timestamp. A beyond-drift observation emits `FeedSkippedFutureTimestamp`
and does not block unrelated valid feeds in that packet. Malformed payloads,
signature failures and property/ID mismatches can still revert the whole call.

Use the pusher package's Pyth scripts and inspect each feed's stored value and observation time.
`getOracleData()` is disabled; use the zero-sender `price()` simulation described in
[read access](oracle-reference.md#read-access).

### The Chainlink relay — verified report delivery

Use the pusher package's Chainlink scripts. Configure Data Streams credentials, the
selected feed IDs, REST/WS endpoints and `CL_VERIFIER_TAG`. The tag chooses a route in the oracle's
`verifierByTag` mapping; the example prepends it to the upstream `fullReport`.
A wrong or unconfigured tag fails verification/routing.

The current implementation forwards a zero verification fee; the relayer pays gas.
Standard v3/v4 reports use second timestamps; supported High Frequency v3 reports use
millisecond timestamps. Both become E8 oracle prices with millisecond storage and
second-based `price()` readback; see [the schema table](oracle-reference.md#chainlink-report-schemas).
The example's HFS path uses WS rather than its standard-feed REST one-shot flow. Other
schemas, v11 included, revert, and one such report reverts the whole batch.

A v4 RWA feed carries a market status. A newer closed-market report is stored as a stall
and halts the provider until the next open report — unless its price floors below one E8
unit, in which case it is skipped and the last open quote stays until staleness halts it; treat that as expected outside trading
hours rather than as a delivery failure, and keep publishing through the close so the
stall lands.

Unlike the Pyth skip rule, a beyond-drift Chainlink observation reverts the call,
including the batch entry point `updateReports`. Inspect each report and use the actual readback to confirm
which observations advanced.

### Choosing a lane

Use compressed publishing for your own price methodology; use an upstream relay
when its feed covers your intended market. All three lanes have example code.
The offline Anvil demo covers compressed and Pyth only. Chainlink's unit tests do
not replace a real report-verification check on the target deployment.

## 4. Provider and pool wiring

Follow [plain provider creation](price-provider-quickstart.md) or
[APP creation](anchored-price-provider-quickstart.md), then the
[pool registration steps](integration-quickstart.md#6-wire-and-register-the-pool).

The plain provider reads one feed. Its default confidence setting ignores spread
for shaping, while still enforcing spread validity. APP reads a reference feed or
ratio and applies its configured band; a custom source can widen the final quote
or halt it. Source replacement remains owner-controlled in both APP variants.

### How the pool actually reads

Compressed `price()` is open and non-view: it emits an attributed event, but does
not authenticate the supplied pool. Its view getters remain open.

For Pyth/Chainlink, register the pool for every leg through an approved pool factory.
During the swap the pool must report that the calling provider is its `inSwap()`
provider; blacklist checks also apply. Approved external integrators have their
own gated read method. See [the read-access reference](oracle-reference.md#read-access).

### Launch order

1. Select deployments, pair and delivery responsibilities.
2. Publish/relay and verify the intended feed(s).
3. Dry-run provider creation, then create and verify the chosen parameters.
4. Create/configure the pool and register its feed reads where required.
5. Simulate the real swap context, with its update payload when applicable.
6. Verify stale-data halt and establish monitoring before serving traffic.

Creating a provider against an empty feed can succeed. Factory membership proves
provenance, not liveness or a pool tier; assess the pool's other requirements separately.

## 5. Operations

### Cadence, gas, staleness

Measure delay from **observation to inclusion**, including source lag, batching,
network delivery and retries. Configure provider limits for that measured path and
acceptable market exposure. A fixed “cadence plus one second” rule cannot account
for all chains or delivery paths.

For standing feeds, alert before a leg's age reaches its provider bound. For an
update-with-trade integration, an idle provider may be stale by design: monitor
fresh available submissions, builder acceptance, update-before-swap simulation and
actual fills. A pending update must execute before the consuming swap. Use the
product's integration workflow to arrange conditional delivery; the example loops
submit ordinary transactions and do not implement that service.

### Price guards

Guards are stored on the oracle and enforced by standard providers at read time.
Choose bounds in E8 price units. A guard does not stop an oracle storing an
out-of-range observation, and custom consumers need to enforce their own policy.

Compressed guard authority initially belongs to the feed creator; Pyth/Chainlink
guard authority initially belongs to the oracle admin. Delegated state-guard
handover must be accepted. The family-specific setter names differ; inspect the
[compressed base](../contracts/oracles/compressed/OracleBase.sol) and
[priced base](../contracts/oracles/providers/OracleBase.sol) before automating it.

### Key management

Keep compressed creator and provider-owner keys out of the continuously running
pusher. Delegate a hot pusher for publishing and, where needed, an updater for
provider knobs. Updaters cannot replace an APP source.

When rotating a pusher, authorize the replacement, verify its namespace/readback,
and remove the old authorization. A revoked key resumes publishing into its own
namespace; it does not become unable to transact. A consumed consent cannot be
reused: its next deadline must increase. Do not share one contract pusher between
creators; its namespace mapping is a single slot and later authorization replaces it.

### The Pyth fee balance

Monitor the oracle's native-token reserve as well as the relay wallet's gas. The
checked-in Lazer integration pays 1 wei per verification. A zero balance prevents
verification; fund the oracle through its payable receive path. Balance movement
alone is not a liveness signal: registrations, top-ups and admin withdrawals also
change it. Measure accepted feed observations directly.

### Monitoring

| Check | Successful signal | Investigate when |
| --- | --- | --- |
| Upstream data | New valid observation for the intended market | Missing, divergent or invalid inputs |
| Publication | Receipt and expected stored observation | Receipt absent, feed unchanged or skipped |
| Provider health | Valid quote in the intended call context | Stale/future leg, guard breach, invalid spread/band/source |
| Transaction queue | Nonces advance and inclusion remains timely | Stuck receipt, nonce gap or replacement failure |
| Funding | Wallet gas and required verification reserves | Reserve below operating threshold |
| Read permission | All pool/feed registrations and correct in-swap binding | Permission errors despite fresh data |

Use explicit zero-sender `eth_call` for off-chain quote inspection. Periodically
simulate the actual pool swap too: the zero-sender path bypasses some read gates.
Connect the example's alert hook to your monitoring; printing to stderr is not paging.

### Stuck transactions — an honest limitation

The example loops send and await receipts sequentially with backoff. They do not
implement same-nonce gas-bump replacement. A stuck transaction can block the loop
until the receipt timeout. Add a replacement policy, recovery ownership and RPC
failover suited to your network; do not start independent writers racing the same
slot or account nonce.

## 6. Risks and recovery

A fresh, correctly signed observation can still be wrong. Guard the methodology,
reference dependencies and configuration as well as the transport.

| Failure | Immediate response | Recovery check |
| --- | --- | --- |
| Stale source | Stop refreshing its observation time; stall your compressed position when appropriate | Fresh valid input, accepted update and quote |
| Wrong denomination or token pair | Stop serving the affected configuration | Correct feed/provider wiring and independently checked human price |
| Future timestamp already stored | Correct the producer's clock; do not expect an older timestamp to overwrite it | Chain time catches up and a valid newer observation is accepted |
| Bad custom source | Investigate the source; APP halts on invalid output | Owner selects a valid source or explicitly returns to reference mode |
| Excessively wide but valid quote | Investigate the source and its market | Quote policy restored; APP does not cap outward widening |
| Compromised delegated key | Revoke/rotate its authority and inspect written observations | Correct namespace, fresh valid data and no residual authority |
| Missing read access | Check pool factory, per-leg registration and blacklist state | Actual swap-context simulation succeeds |

A halt in the standard price path blocks quoting. It does not prove that arbitrary
pool extensions permit withdrawals; evaluate those separately in the pool workflow.

## 7. What you get vs what you build

| Capability | Provided | Integration responsibility |
| --- | --- | --- |
| Contracts | This repository: oracles, standard providers and factories | Select correct active deployments and parameters |
| Provider creation | This repository: creation scripts and the `create-provider` agent skill | Parameter choice and change review |
| Encoding and relay | Pusher package: compressed, Pyth and Chainlink examples with unit tests | Real source/subscription, delivery policy and upstream availability |
| Local rehearsal | Pusher package: compressed and Pyth Anvil demo | Live upstream verification and full pool swap testing |
| Administration | This repository: delegation, guards, owner/updater controls | Key custody, recovery ownership and change review |
| Transactions | Pusher package: sequential receipt waits and retry/backoff skeletons | Nonce recovery, replacement, redundant delivery and conditional submission |
| Monitoring | Pusher package: readback checks and alert hooks | Dashboards, alert thresholds and response coverage |
| Agent runbooks | Pusher package: compressed publishing and Pyth relay skills | Chainlink-specific orchestration where needed |

The pusher package is the separate [mm-pusher-ts](https://github.com/Metricxyz/mm-pusher-ts) repository.

## Appendix A: units and encodings cheat sheet

Use the canonical [units and price direction table](oracle-reference.md#units-and-price-direction)
and [special values](oracle-reference.md#encodings-and-special-values).
Wire-format details: [slot](slot-structure.md), [packet](oracle-packet-structure.md),
[U64x32](u64x32.md), [codebook](codebook.md).

## Appendix B: revert reference

Use the canonical [failure reference](oracle-reference.md#failure-reference).
It separates transaction reverts, skipped observations and successful transactions
that leave a feed unchanged.
