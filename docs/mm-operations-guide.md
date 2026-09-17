# Market-maker operations guide — launching and operating a metric pool

This guide is for a developer who has never run a market-making operation and has never touched
this oracle stack. It explains, end to end, how a market maker (MM) launches and then operates a
pool that trades at the MM's own prices — what the moving parts are, which of them live in this
repository, what you have to decide for yourself, and where the money is lost when something is
done carelessly. It sits one level above the integration documents: read this first, then go to
[`anchored-price-provider-quickstart.md`](./anchored-price-provider-quickstart.md),
[`price-provider-quickstart.md`](./price-provider-quickstart.md) and the
[`examples/mm-pusher-ts`](../examples/mm-pusher-ts) package when you are ready to type commands.

Nothing here is trading advice. This repository moves numbers from your infrastructure onto a
chain and shapes them into quotes; whether those numbers are good is entirely your problem, and
this guide is honest about where that boundary runs.

## At a glance

- **What this stack is.** On-chain oracles you push prices into, plus price providers that shape
  those prices into the bid/ask a pool quotes at swap time. The on-chain half is already deployed
  ([`DEPLOYMENTS.md`](../DEPLOYMENTS.md)); you run an off-chain **pusher** process (skeleton in
  [`examples/mm-pusher-ts`](../examples/mm-pusher-ts)).
- **Two publishing lanes.** *Compressed lane* — the prices are yours, your key is the trust
  anchor. *Pyth relay lane* — the prices are Pyth's, you are only a courier of Pyth-signed
  updates. You can run both. (§3 chooses between them.) A third relay lane, `ChainlinkOracle`
  (Chainlink Data Streams, every chain except megaeth), exists and behaves like the Pyth lane, but
  this guide and the example package ship **no pusher for it** — integrating it is a from-scratch
  build.
- **It fails closed.** Stale, out-of-guard, or degenerate data makes the provider **revert** and
  the swap not happen — the pool never quotes a knowingly-wrong price. Your job is to make that
  halt rare (§5) and to price the window where a quote can be stale-but-served (§6).
- **Reference cards.** [Units & encodings](#appendix-a-units-and-encodings-cheat-sheet) and
  [reverts](#appendix-b-revert-reference) are tabulated in the appendices — keep them open while
  you integrate.

### Prerequisites

- **Node.js 22+** and **[Foundry](https://book.getfoundry.sh/)** (the latter only for the offline
  `npm run demo` rehearsal).
- An **RPC endpoint** for each chain you target. Chain coverage varies by oracle — see
  [`DEPLOYMENTS.md`](../DEPLOYMENTS.md) (compressed lane on all ten production chains; the Pyth
  lane is deployed everywhere too, but on avalanche it waits on Pyth Lazer shipping — no push can
  land there yet).
- A **funded key** for gas on each chain.
- **Compressed lane:** a *creator key* (its address *is* your feed identity — keep it cold, §5)
  and, optionally, a hot *pusher key* you delegate to.
- **Pyth lane:** a **Lazer access token issued by Pyth** (for the subscription) and a relay
  wallet that only pays gas.
- **Chainlink lane (not tooled here):** a **Chainlink Data Streams subscription** (credentials to
  fetch DON-signed reports) and a relayer you build yourself — there is no example pusher, demo,
  or test vectors for it. Its on-chain verification fee differs from Pyth's (currently a `0`
  constant), so the Pyth fee-balance monitoring in §5 does not carry over unchanged.

### Contents

- [1. The big picture](#1-the-big-picture)
- [2. Choosing a pair and constructing the price](#2-choosing-a-pair-and-constructing-the-price)
- [3. Publishing: the compressed lane and the Pyth relay](#3-publishing-the-compressed-lane-and-the-pyth-relay)
- [4. Provider and pool wiring](#4-provider-and-pool-wiring)
- [5. Operations](#5-operations)
- [6. Risks: adverse selection, and the four levers you have](#6-risks-adverse-selection-and-the-four-levers-you-have)
- [7. What this repo gives you vs what you build](#7-what-this-repo-gives-you-vs-what-you-build)
- [Appendix A: units and encodings cheat sheet](#appendix-a-units-and-encodings-cheat-sheet)
- [Appendix B: revert reference](#appendix-b-revert-reference)

## 1. The big picture

A **metric pool**, for the purposes of this guide, is an AMM pool that does not compute its price
from its own reserves the way a constant-product pool does. Instead, at the moment of a swap, it
asks a **price provider** contract for a quote by calling `getQuote()` and executes the
trade at the returned bid or ask. The quote is three numbers, not two: `bid`, `ask`, and a
`referencePrice` — your own fair value, which must sit inside your bid/ask. The pool executes at the
edges and measures its fee from the reference out to whichever edge the trade takes, so where you put
the reference decides how the spread splits between buyers and sellers. The pool-side mechanics (how liquidity is held, how the swap is
settled) are outside this repository; everything from the quote backwards is what this repo
provides, and it is the part the market maker runs.

The price travels a fixed path:

```
your price source (off-chain, yours)
        │  a number you computed, plus how unsure you are about it
        ▼
pusher process (off-chain, yours — skeleton provided in examples/mm-pusher-ts)
        │  an encoded or signed update, sent as an ordinary transaction
        ▼
on-chain oracle (this repo: CompressedOracleV1, PythOracle, or ChainlinkOracle)
        │  stores mid price (8 decimals), spread (0.01-bps units), timestamp (ms)
        ▼
price provider (this repo: PriceProvider or AnchoredPriceProvider)
        │  getQuote() — staleness, validity and guard checks, then bid/ask/reference shaping
        ▼
pool (conceptual here) — executes the swap at your bid or ask
```

The cast of actors, and who plays them:

- **You, the market maker.** You produce prices, run the pusher process day and night, own the
  keys, and carry the P&L. In the compressed lane you are the price *source*; in the Pyth lane
  you are a *relayer* of prices Pyth has already signed.
- **The oracles** are already deployed (addresses in [`DEPLOYMENTS.md`](../DEPLOYMENTS.md); they
  are deployed via CREATE3, so each contract has the same address on every chain it exists on).
  They are registrationless: there is no feed-creation step and no registry. A feed exists the
  moment its first valid update lands, and not before.
- **The price providers** are contracts you create through already-deployed factories
  (`PriceProviderFactory`, `AnchoredProviderFactory`). Creation is permissionless; the creator
  becomes the provider's owner.
- **The maintainers** operate the deploy pipeline and hold the admin roles: the anchored
  factory's oracle allow-list and parameter envelopes, and the provider oracles' read-access
  administration. You do not need their permission to create feeds, push prices, or create
  providers; you do interact with admin-controlled state when a pool is registered for reads
  (section 4).
- **Traders and arbitrageurs.** The pool exists so traders can swap against your quotes. Some of
  those traders are arbitrageurs whose entire business is noticing when your on-chain quote is
  wrong before you do. They are not an anomaly; they are the adversary the whole operating
  discipline of sections 5 and 6 exists for.

One design decision shapes everything downstream: **the stack fails closed**. When a feed is
stale, a spread carries the off-hours marker, a price violates a guard, or a band degenerates,
the provider does not return its best guess — `getQuote()` reverts (`FeedStalled`, or
`FeedNotFound` before a feed's first update) and the swap does not happen. For you as an MM this
means the failure mode of a neglected feed is a pool that stops trading, not a pool that trades
at a wrong price. Downtime is lost revenue; mispricing is lost inventory. The contracts choose
downtime every time, and your operations job is to make downtime rare.

## 2. Choosing a pair and constructing the price

A quick vocabulary check, since the rest of the guide leans on it. A **pair** is the two tokens
being priced against each other (ETH/USDC: ETH is the *base*, USDC is the *quote*). The **mid**
is your best estimate of the fair price. The **bid** is the price at which the pool buys the base
from a trader, the **ask** is the price at which it sells; ask minus bid is the **spread**,
usually measured in **basis points** (bps, hundredths of a percent). The spread is not decoration
— it is the compensation you charge for taking the other side of every trade, and your only
per-trade buffer against being slightly wrong about the mid.

The provider reports the mid as well, as the quote's **reference price**, and it is not cosmetic:
the pool executes at the edges and derives its fee from the distance between the reference and the
edge the trade takes. A reference exactly between bid and ask charges both sides equally; moving it
towards the bid charges buyers more and sellers less. It must lie inside your own quote
(`bid <= reference <= ask`) or the pool rejects the read outright.

In this stack, the oracles are deliberately token-free: they store numbers under a `feedId` and
know nothing about what the numbers mean. The pair becomes concrete only at the provider, where
`baseToken` and `quoteToken` are mandatory constructor arguments. Prices are stored 8-decimal
(the oracles' `decimals` is 8), so a mid of 3,000.5 USDC per ETH is stored as `300050000000`.
Spreads are stored in 0.01-bps units (a fraction × 1e6, so 1 bp = 100 and 1% = 10,000; the stall
sentinel reads back as 65,535, **not** 10,000 — see Appendix A). This is the same unit the
compressed codebook uses, and it is what makes `confidenceParam = 10_000` mean a 1× multiplier on
the oracle's spread.

Where does the mid come from? That is your methodology, and this repository takes no position on
it. Typical inputs are order books and trades from the venues where the asset actually trades,
combined into a mid with your own filtering, outlier rejection, and staleness handling. The
contracts will faithfully transport a bad number, on time, with a beautiful spread around it.
**This stack transports prices; it does not produce them.** If you remember one sentence from
this section, that is the one.

### Synthesizing a cross price

Often the pair you want to quote has no single liquid market. Suppose you want an XXX/USDC pool
but XXX only trades liquidly against USDT. You then *synthesize* the cross:

```
XXX/USDC = XXX/USDT × USDT/USDC
```

You have two places to do this, and they are not equivalent:

- **Off-chain, in your pusher** (the usual choice in the compressed lane): you compute the
  product yourself and publish the finished XXX/USDC number. You control the sampling, the
  timing, and the rounding.
- **On-chain, in an AnchoredPriceProvider**: the APP supports a synthetic two-feed mode — pass a
  non-zero `quoteFeedId` at creation and the provider quotes the ratio
  `price(baseFeedId) / price(quoteFeedId)` (for example BTC/USD ÷ ETH/USD = BTC/ETH), dividing
  opposing interval edges: base low / quote high and base high / quote low. This works only when both legs live in the same reference oracle,
  and the composition rule is fixed to a single ratio.

Either way, the errors of the legs compound, and your published spread must say so. If your
XXX/USDT mid is uncertain by 20 bps and your USDT/USDC mid by 5 bps, the product is uncertain by
roughly the sum, 25 bps — relative errors of a product or ratio add, to first order. On top of
that comes *sampling skew*: the two legs were observed at slightly different moments, and in a
fast market even a 500 ms mismatch between legs is a real pricing error that no amount of arithmetic
precision removes. A synthesized cross should therefore carry a wider spread than either leg
alone, and the widening is not a formality — it is the honest price of not having a direct
market. When you synthesize off-chain, that widening is your responsibility.

⚠️ On the **on-chain** synthetic path (APP with a `quoteFeedId`), leg skew is bounded only by each
leg's own staleness bound — there is no cross-leg constraint. Two legs that are each
individually fresh may have been observed up to `maxRefStaleness` apart, so with the shipped
`DEFAULT_CLASS` value of 60 s the skew window is **60 seconds, not 500 ms**. The APP propagates both
legs' *uncertainties* through interval division, but this does not account for their age difference:
it does not grow when the legs drift apart in time, so it does not compensate for skew. Anyone who
can order their pushes — the relayer, or simply whoever pushes the two legs — can update one leg,
trade the cross at `newBase / oldQuote`, and update the other. This is the accepted oracle-lag risk
applied to a two-leg composition; the only lever that narrows it is a tighter
`maxRefStaleness` on two-feed classes. Set it deliberately, and treat the default as too loose for a
volatile pair.

The general principle: **your published spread is a statement about your own uncertainty**, and
the chain will hold you to it. Every source of error — venue noise, aggregation lag, leg skew,
quantization (next section), and the time that will pass before your next push — belongs inside
it. Publishing a spread tighter than your true uncertainty does not make your prices better; it
makes them free money for somebody else (section 6 makes this concrete).

## 3. Publishing: the compressed lane and the Pyth relay

This repo's oracles give you two ways to get a price on-chain, and they differ in one fundamental
respect: **who vouches for the number**.

### The compressed lane — you are the price source

`CompressedOracleV1` (deployed on all ten production chains) stores prices that *you* computed
and *your key* authorized. There is no external attestation: the trust anchor is your address,
which is literally baked into the feed's identity. A feedId packs
`(creator address, chain id, slot index, position index)` into 32 bytes; your address owns 256
slots of 4 feed positions each, on every chain the oracle is deployed to, with zero setup
transactions. There is no registration step to forget: derive the feedId, push, and the feed
exists.

Physically, each push writes one 32-byte **slot word** carrying up to 4 feeds (price + two
codebook-compressed spread fields per lane — the provider read path prices off the first,
`spread0`) and one shared millisecond timestamp. Three properties of the format matter
operationally, and all three are demonstrated by the example scripts:

1. **The slot is overwritten whole.** Every push re-encodes all 4 positions; unused positions are
   written as the explicit empty sentinel (`0xFF/0xFF`), which reads back as the stall spread
   (65,535) so providers halt on that lane. You cannot update one lane and leave the others alone.
2. **Timestamps must strictly increase per slot.** An update whose timestamp is not newer than
   what is stored is *silently ignored* — the transaction succeeds and changes nothing. This is
   the replay protection, and it is also why you run exactly one pusher per slot and verify by
   reading back. A timestamp too far ahead of the chain's clock reverts (`FutureTimestamp`).
3. **Encoding quantizes.** The price is stored as a `U64x32` pseudo-float (27-bit mantissa,
   5-bit exponent) and rounds *down*; the rounding error is orders of magnitude below a basis
   point and can be ignored against any realistic spread. The spread is compressed to one byte
   through the 256-entry `Codebook256` table and rounds *up* to the next table entry — the table
   is finest in the 0–50 bps region and coarser above. Both roundings err in the conservative
   direction, but you should log the quantized values your pusher actually published, not the
   ones you asked for.

Format references, if you want the bit layouts: [`slot-structure.md`](./slot-structure.md),
[`oracle-packet-structure.md`](./oracle-packet-structure.md), [`u64x32.md`](./u64x32.md),
[`codebook.md`](./codebook.md).

There are two submission paths. The direct path is a raw transaction to the oracle's `fallback`
whose calldata is a leading zero byte followed by one or more 32-byte words (the zero byte keeps
the calldata from ever matching a function selector) — batching several slots into one transaction
is native to the format. The relay path is `updateBySignature`: the feed creator signs the slot word
offline and anyone may submit it, which decouples the key that authorizes prices from the wallet
that pays gas.

### The Pyth relay — you are a courier

`PythOracle` (all ten chains; on avalanche it waits on Pyth Lazer and cannot accept a push yet)
consumes price updates that Pyth's Lazer service has
already signed. Your relayer subscribes to Lazer, receives signed envelopes, and forwards them verbatim
in a transaction; the on-chain contract verifies Lazer's signature and stores the result. You
never sign price data, and consequently you cannot alter it: a byte-level modification fails
verification, and anyone else relaying the same genuine envelope is indistinguishable from you.
Duplicate and out-of-order updates are dropped on-chain by each feed's signed timestamp, so two
relayers cannot corrupt each other.

You control exactly one dimension of quality in this lane: **timeliness**. The price content is
Pyth's. Two operational constraints are non-obvious and both revert the entire push when
violated: your Lazer subscription must request *exactly* the property set the oracle expects —
price, exponent, confidence, feedUpdateTimestamp, in the `evm` format — and the oracle pays a
1-wei verification fee per push *from its own balance*, which therefore must stay topped up
(section 5).

(`ChainlinkOracle`, the third oracle, follows the same relayed-attestation model with Chainlink
Data Streams reports; the example package does not include a pusher for it.)

### Choosing a lane

Publish through the compressed lane when the price is genuinely yours — your own methodology,
your own pairs, possibly pairs nobody else quotes. Relay through the Pyth lane when Pyth already
publishes the feed you need and you are content with their number, wanting only to keep the
on-chain copy fresh. Nothing stops you from running both: majors relayed, long-tail pairs pushed.

Whichever lane you choose, start from [`examples/mm-pusher-ts`](../examples/mm-pusher-ts). It is
a self-contained TypeScript skeleton (ethers v6 as the only runtime dependency, Node 22+) with
every encoding pinned against this repo's Solidity by test vectors, numbered scripts for each
step of both lanes, and an offline anvil demo (`npm run demo`) that deploys both oracles locally
and rehearses every scenario without keys, tokens, or a live chain. If the demo passes, your
toolchain and the encodings are correct; run it before every first push to a real network. If
your integration is driven by an LLM coding agent, the repo also ships step-by-step runbooks in
Agent Skills format: [`skills/setup-compressed-pusher/SKILL.md`](../skills/setup-compressed-pusher/SKILL.md),
[`skills/setup-pyth-relayer/SKILL.md`](../skills/setup-pyth-relayer/SKILL.md), and
[`skills/create-provider/SKILL.md`](../skills/create-provider/SKILL.md).

## 4. Provider and pool wiring

An oracle read gives raw material — a mid, a spread, a timestamp. A pool needs a two-sided quote
with safety semantics: what to do when data is stale, how wide to quote, when to refuse. That
shaping is the **price provider's** job, and this repo has two constructions. Both report the
oracle mid as the quote's reference price: the plain provider converts the oracle's own mid onto the
Q64 scale, and the APP reports the anchor's mid — in neither case is the reference derived from the
shaped edges, so no knob and no source can move it.

### Plain PriceProvider

The plain provider is a thin, single-oracle passthrough with exactly three knobs: the oracle's
own reported spread multiplied by an owner-tunable `confidenceParam` (default 0, up to a 100x
ceiling, rate-limited to one change per minute), a fixed per-side `marginStep` set immutably at
construction, and an immutable staleness bound `maxTimeDelta`. Creation through
`PriceProviderFactory` (deployed on all ten chains) is unconditionally
permissionless — any oracle, any feedId, no allow-list, no envelope. That freedom cuts both ways:
nothing but your own diligence constrains the parameters, which is why the plain provider is the
tool for setups you fully control end to end — for example, quoting off your own compressed feed.
Walkthrough: [`price-provider-quickstart.md`](./price-provider-quickstart.md).

### AnchoredPriceProvider (APP)

The APP is the standard construction for public pools, and its design goal is auditable safety
rather than flexibility. Every quote it returns is clamped to a **band** derived from a reference
oracle's own uncertainty: a single-feed interval with additive minMargin, or the ratio of opposing
leg bounds plus that margin for a synthetic pair. A custom quote source
can be attached and swapped instantly (`setSource`). The reference bounds how **tight** any source may quote: it can never quote inside the oracle's
uncertainty to extract LP value. Widening is **not** bounded: the pool quotes as wide as the source
says, so a source that tracks a venue an outsider can move hands that outsider your pool's price.
That is accepted rather than fixed: vetting the source is **your** due diligence, and
`setSource` should be treated as a pricing change, not a bounded knob. What a source cannot touch is
the reference price: the APP always reports the anchor's own mid, so widening a quote worsens the
execution price of whoever trades against it and does **not** inflate the pool's fee base. A source
must still return a reference of its own (three words, `bid <= reference <= ask`) or the read halts —
the value is checked and then discarded. Guarding the band is an immutable staleness bound
(`MAX_REF_STALENESS`: an older reference halts quoting). Each raw spread >= 65534 halts before
applying its multiplier, covering both saturation and the 65535 stall sentinel. Nonpositive
interval bounds or a pre-quantization upper relative deviation plus margin reaching 100% also
halt; for a ratio the deviation is `(uBase + uQuote)/(1 - uQuote)`. See the
[APP calculation details](anchored-price-provider.md) for rounding and E8 quantum propagation.

Creation goes through `AnchoredProviderFactory` (all ten chains) and is permissionless, but
the parameters must sit inside an admin-curated **envelope** for the feed's class, and the
reference oracle must be on the factory's allow-list (Pyth and Chainlink in production; a chain
missing one lane holds the other alone — see [`DEPLOYMENTS.md`](../DEPLOYMENTS.md)). The
deployed factory's creation call also takes per-leg initial
configuration — each leg of a synthetic pair carries its own staleness bound and spread
multiplier, with the multiplier ceiling (`spreadMultMax`) an envelope field like the rest. The
full parameter table, the envelope mechanics, and the owner/updater role model are in
[`anchored-price-provider.md`](./anchored-price-provider.md), with a copy-paste walkthrough in
[`anchored-price-provider-quickstart.md`](./anchored-price-provider-quickstart.md). Public-pool eligibility is the
machine-checkable predicate `AnchoredProviderFactory.isProvider(provider)` — deployed by that
factory, therefore built with envelope-approved parameters.

Two limits on how much that predicate proves. First, it is specific to `AnchoredProviderFactory`:
`PriceProviderFactory.isProvider` says only that the plain provider was created there, and that
factory performs **no validation of the oracle address whatsoever** — not an allow-list, not even a
zero-address or code-length check. A plain `PriceProvider` also has no band clamp by design. Both
are deliberate — the plain lane is permissionless and the oracle is the integrator's choice — but it
means `isProvider` on that factory is a provenance marker, not an eligibility check. Diligence on the
oracle behind a plain provider is the depositor's. (An oracle address of `0` simply makes the provider
non-functional: reads revert on the bare `extcodesize` check rather than returning the usual
`FeedStalled`.) Second, on the anchored factory the envelope covers four of the constructor's inputs,
and the live per-leg spread multipliers can still be tightened below 1× afterwards by the provider
owner or a delegated updater — so even there, `true` means "worth diligence", not "audited".

In both families the creator becomes the provider owner and can delegate the tuning setters to an
updater key (`grantUpdater` / `revokeUpdater`) or hand the provider over entirely
(`transferProviderOwnership`) — all through the factory. Note also that both constructions halt on a
stored spread of **65,535** (`type(uint16).max`), the reserved stall sentinel — *not* on 10,000; and
that creating a provider against a feed that has no data yet succeeds — the provider simply halts at
read time until the first update lands.

### How the pool actually reads

The read path differs by oracle family, and the difference matters for launch.

`CompressedOracleV1` is open: its `price(feedId, pool)` is a permissionless view function and the
pool argument is unused. A provider on a compressed feed needs no read-side setup at all.

`PythOracle` and `ChainlinkOracle` gate their reads. The public getters are disabled outright
(`getOracleData` reverts `ReadDisabled`), and the on-chain read path is the attributed, non-view
`price(feedId, pool)`, which enforces three things when called inside a real transaction: the
pool must be **registered** for that feedId, must not be blacklisted, and must prove it is
mid-swap — the oracle calls `pool.inSwap()` and requires it to return the provider's address,
binding the read to a pool that is, at this instant, executing a swap through this exact
provider. Registration is a permissionless, paid, one-time call on the oracle:
`register(feedId, pool, factory)`, where the pool's AMM factory must have been approved by the
oracle admin (`addApprovedFactory`) and must recognize the pool via `isPool` (the minimal factory
surface in [`IPoolFactory.sol`](../contracts/interfaces/IPoolFactory.sol)); the fee
(`registrationFee`) defaults to 1 wei and is admin-tunable. Anyone can pay to register any
legitimate pool. That is the entire pool-side wiring this stack requires: the pool transiently
marks itself in-swap with its provider, calls `getQuote()` (no arguments), and the
provider forwards the pool's address to the oracle.

Two side doors exist for reading gated oracles without being a pool: whitelisted contracts may
call `integratorPrice(feedId)` (admin-curated list), and off-chain software can `eth_call`
`price(feedId, address(0))` with no from-account — with `tx.origin == 0` the gating is skipped,
which is what the example scripts' readback verification uses. This is also why your monitoring
can always see your own feed without any registration.

### Launch order

For a compressed-lane launch, the sequence is: derive feedIds → first push → create provider
against the feed → (pool side) register the pool and wire it to the provider → set guards →
start the production pusher. The [`create-provider`](../skills/create-provider/SKILL.md) skill
automates the provider step with dry-runs and verification reads; the creation shell wrappers
(`script/create-anchored-provider.sh`, `script/create-price-provider.sh`) simulate first and
broadcast only when `BROADCAST=1` is set. For a Pyth-lane launch, replace the first two steps
with "confirm Lazer publishes the feed, relay once, verify by readback".

## 5. Operations

Launching is an afternoon. Operating is the actual job, and it is a control loop: publish often
enough to stay fresh, cheaply enough to stay solvent, safely enough that a mistake in any single
component costs you bounded money.

### Cadence, gas, staleness

Three numbers form a triangle. The provider's staleness bound (`maxTimeDelta` on the plain
provider, `MAX_REF_STALENESS` on the APP — for scale, the example production default-class
envelope caps the latter at 60 seconds) is the hard ceiling: let the feed age past it and every
swap reverts until your next push. Your push cadence must therefore beat the staleness bound with comfortable margin —
enough to absorb a missed push, an RPC hiccup, or a congested block without the pool going dark.
Pulling against that, every push is a storage write and costs gas, every block of every day; at a
10-second cadence that is ~8,640 transactions per day per slot, and the difference between a
10-second and a 30-second cadence is a threefold difference in your gas bill. The compressed
format helps — one word updates up to 4 feeds, one transaction batches many words — but the
tension is fundamental, and the right answer is a *policy*, not a constant: push immediately when
the price moves materially, push lazily (but always before staleness) when nothing happens. The
example loop ships a fixed interval and says so loudly; replacing it with your policy is expected.

### Price guards

Each feed can carry an on-chain `[min, max]` **price guard** (`setPriceGuard`, values 8-decimal).
Guards are enforced at provider read time: a mid outside the range halts quoting rather than
serving the price. A guard does not stop a bad push from landing — it stops the bad number from
ever reaching a swap, which converts "fat-finger multiplied by arbitrage" into "pool paused until
you push a sane price". Set guards generously wide (they are a sanity fence, not a trading band)
and move them as markets drift. On the compressed oracle, guard authority for your feeds defaults
to you, the feed creator, decodable from the feedId itself; an explicit per-feed guard role can
be handed over and accepted in a two-step flow (`setPendingStateGuardRole` →
`acceptStateGuardRole`). On the provider oracles the authority is the explicit state guard when
set, otherwise the oracle admin. A delegated guard is exclusive for day-to-day guard changes but
stays **revocable**: the feed's fallback authority — the creator on the compressed oracle, the
oracle admin on the provider oracles — can always dissolve it with `purgeStateGuardRole` (a
break-glass path, so a lost or compromised guard key can never freeze a feed's guard) and then
re-delegate.

### Key management

The compressed lane's key model is built for a cold/hot split, and you should use it. Your
**creator key** *is* your feed identity — its address is inside every feedId, so it cannot be
rotated without your feeds changing identity (and the providers anchored to them needing
recreation). Treat it accordingly: keep it cold (HSM/KMS-grade custody is your build, section 7)
and use it only to sign delegations, guard changes, and `updateBySignature` words. Day-to-day
pushing belongs to **delegated pusher keys**: `allowPushers` remaps a hot wallet into your
namespace, requiring the pusher's own EIP-191 consent signature with a deadline (an undated
consent could otherwise re-establish a delegation after revocation). Rotation is cheap and should
be routine: delegate the new key, retire the old one, `removePushers([old])` from the creator key
— or, if the pusher key itself is the one acting, `revokePusher()` self-revokes. A revoked key
does not go inert; it merely pushes into its *own* namespace again — your feeds never see it.
In the Pyth lane the stakes are lower by construction — the relay wallet signs no prices and
holds only gas money — and on the provider side, keep the provider-owner key cold too, using
`grantUpdater` for whatever tuning a warm key must be able to do (an updater can never
`setSource`).

### The Pyth fee balance

`PythOracle` pays a 1-wei signature-verification fee per push out of its own contract balance; if
the balance hits zero, every relay reverts ("Insufficient fee provided"). The balance is public
(`cast balance $PYTH_ORACLE_ADDRESS`), depletes by 1 wei per push, and is topped up by a plain
transfer to the oracle address (its `receive()` is payable). Put it on the monitoring list — it
is exactly the kind of dependency that fails months after everyone forgot it exists.

### Monitoring

The only truth that matters is on-chain state, so monitor that, not your process's good mood. The
non-negotiable check is **readback after push**: read the feed back and compare timestamp and
values — the example scripts exit non-zero on mismatch precisely because a compressed push with a
non-newer timestamp *succeeds as a transaction and changes nothing*. Beyond that, watch the age
of each feed's on-chain timestamp against its provider's staleness bound (alert well before the
bound, not at it), the pusher wallet's gas balance, the Pyth oracle's fee balance, and — the test
that catches everything at once — periodically `eth_call` your provider's `getQuote()`
and alert on `FeedStalled`. The skeleton's production loops send-and-await sequentially, back off
exponentially, and call an alert hook after 5 consecutive failures; that hook prints to stderr,
and wiring it to a real paging system is your integration.

### Stuck transactions — an honest limitation

The skeleton does **not** do replace-by-fee. Its loops send a transaction and await the receipt;
a transaction stuck in the mempool (gas price spike after submission, nonce gap) blocks the loop
until the RPC's receipt timeout, and while it blocks, your feed ages toward the staleness bound.
A production pusher needs a same-nonce gas-bump replacement policy — detect the stall, resubmit
with higher fees, cap the escalation — and that is deliberately left as your build: fee policy is
chain-specific, wallet-specific, and risk-specific. Until you have built it, understand that
mempool congestion converts directly into feed staleness, and staleness into a halted pool.

## 6. Risks: adverse selection, and the four levers you have

Quoting a two-sided market means granting the world a standing option: anyone may trade against
your bid or your ask at any moment, and they will do so exactly when it profits them. Most flow
is benign. The flow that isn't is **adverse selection**: counterparties who know the current
price better than your on-chain quote does — which, since your quote is a number you wrote into
storage some seconds ago, means anyone with a live market feed and a bot.

Make it concrete. You quote ETH/USDC with a 10 bps spread around a mid of 3,000: bid 2,998.50,
ask 3,001.50. The market jumps 1% to 3,030 and your pusher is asleep — crashed, stuck in the
mempool, out of gas — but the feed is not yet past its staleness bound, so the pool happily
serves your old quote. An arbitrageur buys ETH from the pool at 3,001.50 and sells it on a CEX at
3,030, clearing ~28.50 USDC per ETH, at size, repeatedly, until either your quote catches up or
the pool's inventory is gone. That money is not conjured — it is your inventory, sold below
market. The same mechanics fire without any outage if your spread is simply tighter than your
real uncertainty: quote 2 bps around a mid you only know to 10 bps, and every quiet oscillation
inside those 10 bps hands riskless basis points to whoever trades against the stale side.
A stale or too-tight quote is free money for arbitrageurs, and the counterparty of "free money"
is you.

You cannot eliminate adverse selection; you price it and you bound it. This stack hands you four
levers, and they map one-to-one onto the operating discipline of section 5:

1. **Timeliness.** The shorter the gap between the market moving and your on-chain mid moving,
   the smaller the window an arbitrageur can exploit. Cadence policy, stuck-transaction
   handling, and the staleness bound (which turns "too old to defend" into "halted") all serve
   this lever.
2. **Honest spreads.** The spread must cover your true uncertainty *including* the time until
   your next push. Wider spreads win less flow but lose less to informed flow; the codebook's
   round-up quantization nudges in the safe direction, but the honesty has to be yours.
3. **Guards.** Price guards (and, on the APP, the band clamp plus the stall-sentinel halt)
   bound the damage of the *bad* day — the fat-fingered decimal, the compromised pusher
   key, the poisoned upstream feed. They convert catastrophic mispricing into a halt.
4. **Monitoring.** Every mechanism above fails silently from your side (the chain does not call
   you). Readback verification, staleness alerts, and balance checks are what turn a
   money-leaking hour into a two-minute page.

Failure modes, honestly tabulated:

| Failure | On-chain behavior | Your exposure | Primary lever |
|---|---|---|---|
| Pusher process dies | feed ages past staleness bound → provider halts, swaps revert | downtime, no mispricing | monitoring (staleness alert) |
| Market moves, quote stale but within bound | pool serves the old quote | arbitrage loss until next push | timeliness + honest spreads |
| Spread tighter than real uncertainty | quotes served normally | steady bleed to informed flow | honest spreads |
| Bad price published (bug, fat finger) | guard violation halts the provider; inside the guard range it trades | bounded by guard width | guards |
| Compromised delegated pusher key | attacker pushes into your namespace until revoked | bounded by guards; revoke via `removePushers` | guards + key management |
| Stuck transaction, no RBF | loop blocks; feed ages | downtime, then staleness | your RBF policy + monitoring |
| Clock skew (ahead), **beyond** the oracle's drift tolerance | compressed/Chainlink push reverts `FutureTimestamp`; a Pyth Lazer packet skips just that feed and emits `FeedSkippedFutureTimestamp` (the rest of the packet still stores) | downtime for that feed | NTP + monitoring |
| Clock skew (ahead), **within** the drift tolerance | ⚠️ push **succeeds and stores** — but both price providers treat *any* `refTime > block.timestamp` as stale, so the feed is accepted on-chain and simultaneously unquotable. Swaps revert `FeedStalled` until block time catches up, and a corrective push with an *earlier* timestamp is silently dropped by the monotonic gate, so it cannot be repaired sooner | downtime up to the full drift window, self-clearing | keep the deployed drift at 0, or keep pusher clocks behind chain time |
| Clock skew (behind) / second pusher on the slot | words silently ignored | *silent* staleness — the dangerous kind | readback verification |
| Pyth oracle fee balance empty | every relay reverts | downtime on the Pyth lane | balance monitoring |
| RPC endpoint outage | pushes fail → staleness → halt | downtime | redundant RPCs (your build) |

Read the table's rhythm: almost every failure lands on "downtime" rather than "loss" — that is
the fail-closed design doing its work — and the residual loss scenarios are precisely the ones
governed by your own cadence and spread honesty. The contracts cannot protect you from quoting
confidently and wrongly; they can only refuse to quote what is provably stale or out of bounds.

## 7. What this repo gives you vs what you build

The example package calls itself a skeleton, and that word is chosen honestly. Here is the
division of labor, in one table:

| Capability | Repo gives you | You build |
|---|---|---|
| On-chain contracts | oracles, providers, factories — deployed, at stable CREATE3 addresses ([`DEPLOYMENTS.md`](../DEPLOYMENTS.md)) | — |
| Wire formats | encoders/decoders pinned by test vectors (u64x32, codebook, slot words, Lazer envelopes) | — |
| Push paths | working compressed-lane and Pyth-relay scripts, batching, readback verification | — |
| Key delegation | `allowPushers` / `removePushers` / `revokePusher` on-chain model + scripts | key *custody*: HSM/KMS, cold storage, rotation schedule |
| Safety rails | price guards, staleness halts, APP band clamp, stall-sentinel and plain-provider spread breaker | guard values and their upkeep |
| Rehearsal | offline anvil demo of both lanes, end to end | — |
| Agent runbooks | three verifiable skills (provider creation, both pusher lanes) | — |
| Price data | — | sourcing, aggregation, cross-price synthesis, the mid itself |
| Quoting policy | — | spread sizing, cadence policy (push-on-move, quiet-market throttling) |
| Transaction management | sequential send-and-await, backoff | replace-by-fee / stuck-tx policy, nonce management under load, redundant RPC failover |
| Observability | alert hook after 5 consecutive failures, non-zero exits on readback mismatch | real alerting/paging integration, dashboards, staleness and balance monitors |
| Capital | — | inventory management, rebalancing, hedging, capital allocation across pools |

The left column is genuinely done: the encodings match the Solidity bit for bit, the demo proves
the whole path without touching a live chain, and the operational sharp edges (whole-slot
overwrite, silent non-newer drops, the exact Lazer property set, the fee balance) are documented
where you will hit them. The right column is genuinely yours: everything in it is either
proprietary by nature (your prices, your risk) or too deployment-specific to ship responsibly
(your key ceremony, your paging stack, your fee policy).

A reasonable first week looks like this: run `npm run demo` until the whole path is boring; push
to a testnet or a low-stakes chain with the numbered scripts and watch the readbacks; create a
provider against your feed and `eth_call` its `getQuote()` yourself; set guards; then —
and only then — connect real price data, real keys, and real monitoring, in that order. The
contracts will not rush you, and the arbitrageurs will still be there when you arrive.

## Appendix A: units and encodings cheat sheet

Every quantity this stack moves has a fixed unit and, in the compressed lane, a fixed on-chain
encoding. Mismatches here are the single most common integration bug, so this table is the one to
keep open. The example encoders ([`examples/mm-pusher-ts`](../examples/mm-pusher-ts)) are pinned to
these by test vectors; the bit-level references are [`slot-structure.md`](./slot-structure.md),
[`oracle-packet-structure.md`](./oracle-packet-structure.md), [`u64x32.md`](./u64x32.md) and
[`codebook.md`](./codebook.md).

| Quantity | Unit / encoding | Rounding | Notes |
|---|---|---|---|
| Mid / price (all lanes) | integer, **8 decimals** | — | 3,000.5 → `300050000000`. The oracles' `decimals` is 8. |
| Spread | integer, **0.01-bps units** (fraction × 1e6) | — | 1 bp = `100`, 1% = `10000`. `ask − bid` measured on the mid. This is the same unit `confidenceParam` multiplies, so `confidenceParam = 10000` is a 1× multiplier. |
| Timestamp — **compressed lane** | **milliseconds** since epoch | — | Must **strictly increase per slot**; a non-newer word is silently ignored (see Appendix B). |
| Timestamp — **Pyth readback** (`refTime`) | **seconds** since epoch | — | ⚠️ Cross-lane trap: compressed is ms, Pyth `refTime` is s — a `×1000` apart. Normalize per lane. |
| Price storage (compressed) | `U64x32` pseudo-float, 27-bit mantissa / 5-bit exponent | **down** | Rounding error ≪ 1 bp against any realistic spread. |
| Spread storage (compressed) | `Codebook256`, 1 byte, 256-entry table | **up** (to next table entry) | Table is finest near zero, coarser toward the 1% ceiling. Both roundings err conservatively. |
| Off-hours / stall marker | sentinel `s0 = s1 = 0xFF` → reads back as spread **`65535`** | — | ⚠️ **Not `10000`.** Providers halt on `65535` (`type(uint16).max`) and on nothing else. A spread of `10000` is an ordinary 1% quote: it is *below* the plain `PriceProvider`'s 5% circuit breaker, so pushing `10000` with a **fresh** timestamp keeps the pool quoting through a closed market on a frozen price — `_isStale` does not fire either. Use the paired `0xFF/0xFF` sentinel to halt. |
| Empty / never-pushed lane | sentinel `s0 = s1 = 0xFF` (**index 255**) | — | Same encoding as the stall marker above — an empty lane and a deliberately stalled one are indistinguishable on the wire, and both read back as price `0`, spread `65535`, timestamp `0`. |
| Slot word (compressed) | **32 bytes**: up to 4 feeds + 1 shared timestamp | — | **Overwritten whole** every push; unused positions must be written as the empty sentinel. |
| `feedId` (compressed) | 32 bytes: `creator << 96 \| chainid << 16 \| slotIndex << 8 \| positionIndex` | — | Self-describing; no registry, no creation step. Derive it and push. |

## Appendix B: revert reference

Almost everything in this stack fails closed, which means you meet it as a revert. This table maps
the reverts (and the one dangerous *non*-revert) you will actually hit to their cause and fix.

| Revert | Where it fires | Cause | Fix |
|---|---|---|---|
| `FeedStalled()` | provider `getQuote()` (`PriceProvider`, `AnchoredPriceProvider`) | feed older than the staleness bound, or the band/quote degenerated | push a fresh update; check push cadence against `MAX_TIME_DELTA` / `MAX_REF_STALENESS` (§5). |
| `FeedNotFound(bytes32 feedId)` | oracle / provider read | the feed has **no data yet** — no first update has landed | push once, then verify by readback. A provider created against an empty feed is normal; it halts here until the first push. |
| `FutureTimestamp()` | compressed push (`TimeMs`) | update timestamp (converted to seconds, `ms / 1000`) exceeds `block.timestamp + drift` | fix host clock skew (NTP); stamp chain-relative time, never a wall clock that runs ahead. |
| `ReadDisabled()` | `PythOracle` / `ChainlinkOracle` public getters (`getOracleData`) | public getters are disabled on gated oracles | off-chain, `eth_call` `price(feedId, address(0))` with no `from` (gating skips when `tx.origin == 0`); on-chain, read the attributed path mid-swap, or use `integratorPrice` if whitelisted (§4). |
| `InsufficientFee(sent, required)` | `register(feedId, pool, factory)` on a gated oracle | registration fee underpaid (`registrationFee`, default 1 wei) | send `msg.value ≥ registrationFee`. |
| Pyth verification-fee depletion | `PythOracle` relay push | the oracle's **own balance** hit 0 (it pays ~1 wei/push) | top up with a plain transfer to the oracle address (`receive()` is payable); monitor `cast balance` (§5). |
| Lazer property-set mismatch | `PythOracle` relay push | the subscription didn't request **exactly** `{price, exponent, confidence, feedUpdateTimestamp}` in `evm` format | fix the Lazer subscription to the exact property set; the whole push reverts otherwise (§3). |
| *(no revert — silent)* non-newer timestamp | compressed push | the pushed word's timestamp is **not newer** than what the slot holds (replay protection; also a second pusher racing the slot) | the transaction **succeeds and changes nothing** — run exactly one pusher per slot and **verify by readback** (the example scripts exit non-zero on mismatch). |
