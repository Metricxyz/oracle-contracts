# Multiplier Oracle — pricing multiplier-based tokenized stocks

`MultiplierOracle` (`contracts/oracles/multiplier/`) prices tokenized stocks whose redemption ratio is an
on-chain **multiplier** — ERC-8056 "Scaled UI Amount" tokens:

| Token family | Chain | Multiplier | Corporate-action pause flag |
| --- | --- | --- | --- |
| Coinbase B20 Assets (AAPLc, NVDAc, …) | Base | `multiplier()` on the token (a B20 precompile) | `paused` in Coinbase's OracleRegistry `0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD` |
| Robinhood Stock Tokens | Robinhood Chain | `uiMultiplier()` on the token | `oraclePaused()` on the token |

The multiplier is the number of underlying shares one whole token (`10**decimals` raw units) redeems
for (WAD, `1e18` = one share). It moves on corporate actions — a reinvested dividend nudges it up, an N:1 split multiplies it by
N — while raw ERC-20 balances never change. Upstream feeds (Pyth, Chainlink) price the **share**, not the
token, so a pool reading them directly drifts below fair value with every dividend and is off by N× on
every split. This oracle turns a share feed into a token feed.

It is deployed on base and robinhood; the addresses are in
[the deployment record](DEPLOYMENTS.md#multiplier-lane-base-and-robinhood).

## Two kinds of feed

A feed is a triple `(underlying feed, token, params adapter)`. There are exactly two kinds, and they are
told apart by whether `token` and `params` are set:

| | **Stock feed** | **Passthrough feed** |
| --- | --- | --- |
| `token` | the multiplier-based token | `address(0)` |
| `params` | an allow-listed adapter for the token's family | `address(0)` |
| `underlying` | the share, e.g. Pyth `Equity.Index.AAPL/USD` | e.g. Pyth `Crypto.USDC/USD` |
| Output | `share price × multiplier / 1e18`, stalled while the issuer has it paused | the underlying price, unchanged |
| Adapter allow-list | required at creation and on every read | not involved — there is no adapter |
| Purpose | pricing the stock token | only the quote leg of a synthetic provider |

**The passthrough feed is not a stock feed.** It exists for one reason: a synthetic
`AnchoredPriceProvider` reads both legs of a pair from the **same** oracle. A stock token quoted in USDC is
therefore priced as

```
token/USDC = (stock feed: token/USD) ÷ (passthrough feed: USDC/USD)
```

and the USDC/USD leg has to come from this oracle too — with no multiplier and no adapter. If the pool
prices the token in USD directly (a single-leg provider, USDC taken as $1), no passthrough feed is needed
at all; that saves one oracle leg (about 44k gas per quote) at the cost of ignoring a USDC depeg.

`createFeed` rejects anything in between: exactly one of `token` / `params` set reverts `BadFeedConfig`.

**Precision.** The underlying price arrives already rounded down to 8 decimals, and the multiplier
scales that rounding error along with the price. A stock feed can therefore be off by up to about
`multiplier / 1e18` quanta of 1e-8 USD, not one quantum. Providers cover a single quantum of rounding,
so at a price of a few hundred quanta (below about $0.0001) with a large multiplier, the quoted band
can miss the true price. Example: the share is 1.099e-6 USD, which the underlying rounds to 109
quanta, and with a 4× multiplier the feed reads 436 against a true 439.6. At stock prices (1e10 quanta
and up) the error is about `(multiplier / 1e18 + 1)` quanta out of 1e10 or more.

> **A passthrough feed over a share feed is a mispriced stock feed.** The oracle cannot tell a quote
> currency from a share, since an underlying feed id is a number. `createFeed(shareFeedId, 0, 0)`
> therefore succeeds, and it returns the share price with no multiplier. That is the drift this oracle
> exists to remove:
>
> - the token is underpriced by every reinvested dividend;
> - after an N:1 split it is priced at 1/N of its value, and the pool is arbitraged out in one swap.
>
> This is no different from building the provider on the share feed of the underlying oracle directly.
> Use a passthrough feed only as the **quote** leg, and before trusting a provider built on this oracle, read what its feeds are bound to:
>
> - `feeds(baseFeedId)` must name the pool's base token and its family's adapter;
> - a passthrough quote leg must be a quote currency such as USDC/USD.

## Params adapters

A stock feed gets its multiplier and pause flag from a **params adapter** implementing
`IOracleParams.getOracleParams(token) → (uint256 multiplier, bool paused)`:

- **`B20AssetParams(registry)`** — Coinbase B20 Assets. Accepts only B20 Asset addresses (top 11 bytes
  `0xb2` + ten zero bytes; the Stablecoin variant has no multiplier) and returns the issuer
  OracleRegistry's answer: the multiplier read live from the token, plus the issuer's pause flag. On top
  of that answer the adapter applies the token's own ERC-8056 schedule (see below). The prefix check is a
  token-*type* check, not an issuer check: anyone can create a B20 Asset, and the registry answers for
  every one of them. The oracle is issuer-agnostic, like the pools it serves. Which token a
  feed binds is the feed creator's choice, and which feed a provider reads is the provider creator's.
- **`RobinhoodStockTokenParams`** — Robinhood Stock Tokens: `uiMultiplier()` and `oraclePaused()` read
  from the token itself, plus the token's ERC-8056 schedule (see below).

**Scheduled changes (both adapters).** Both token families can announce a multiplier change ahead of
time through `newUIMultiplier()` and `effectiveAt()` (on B20 Assets, via `updateUIMultiplier`). The
current multiplier (`uiMultiplier()`, and `multiplier()` for B20, which the registry reads) then
switches by itself at `effectiveAt`, without a transaction and without the pause flag.

Both adapters (`version()` `1.2.0`) apply one rule (`ScheduledMultiplier`) to a pending change,
whatever its lead time:
- **A small change** (at most `SMALL_CHANGE_BPS`, 10% of the current multiplier: a reinvested
  dividend): the announced multiplier, at once. There is no step at `effectiveAt` to time; the price
  moves when the announcement lands.
- **A larger change** (a split): `paused = true` from the announcement until `effectiveAt`. This holds
  even when the market splits the share first. After `effectiveAt` the issuer's flag is the guard, as
  for any corporate action.

The schedule getters are read with a bounded static call. A token without them, or one that answers
anything but a single 32-byte word, is read without a schedule: the issuer's answer is returned as
is. A huge announced value counts as a large change; it does not overflow.

`B20AssetParams` applies the rule to the registry's answer exactly as `RobinhoodStockTokenParams`
applies it to the token's. The registry's multiplier is the token's own `multiplier()`. Its only admin
setter is the pause flag, so the schedule read from the token describes that same value.

Risks the rule leaves:
- **A dividend announced before its ex-date.** The share price still carries the dividend, so pricing
  the announced multiplier at once overprices the token by up to the change, at most 10%, until the
  ex-date.
- **A split whose `effectiveAt` precedes the market's split.** After `effectiveAt` the new multiplier
  meets the old share price. Only the issuer's flag, or `setFeedDisabled`, covers that interval.
- **A large change that is not scheduled.** An instant `updateMultiplier` on B20, or any change the
  issuer applies without a schedule, is covered by the issuer's flag alone.

Both adapters are stateless and ownerless; one deployment per chain (per registry, for B20) serves every
token of that family. Another family plugs in with its own adapter — `MultiplierOracle` does not change.
An adapter must answer with exactly the ABI encoding of `(uint256, bool)`: 64 bytes, with the bool
word 0 or 1. The oracle calls it with at most `ADAPTER_GAS_LIMIT` (200 000) gas and copies at most 64
bytes of its output, so **every adapter failure stalls the read**:
- a revert, with any payload size;
- an answer of a different length, however large;
- a bool word other than 0 or 1;
- an adapter, or a token behind it, that burns its gas.

Nothing an adapter returns can run the read out of gas. The shipped adapters need a fraction of the
limit; an adapter that needs more than 200 000 gas stalls every read.

### Adapter allow-list

Adapters are curated by the oracle's `ADMIN_ROLE`:

| Call | Effect |
| --- | --- |
| `addParamsAdapter(adapter)` | stock feeds may be created on `adapter`, and read through it |
| `removeParamsAdapter(adapter)` | new stock feeds on `adapter` are refused **and every existing stock feed on it stalls** |
| `isParamsAdapter`, `paramsAdapterCount`, `getParamsAdapters(start, end)` | views |

The allow-list is checked on every read, not only at creation: removing an adapter is the kill switch
for an adapter found faulty, and adding it back resumes its feeds. `createFeed` returns an existing feed
unchanged, even when its adapter has since been removed. A successful `createFeed` therefore proves the
feed exists, not that it is readable: check `isParamsAdapter(feeds(feedId).params)` for that. Passthrough feeds have no adapter and
are never affected by the allow-list.

### Stopping feeds

The oracle's own controls and the underlying oracle's controls, from the narrowest to the widest:

| Call | Who | Scope | Reads |
| --- | --- | --- | --- |
| `setFeedDisabled(feedId, true)` | this oracle's `ADMIN_ROLE` | one feed, stock or passthrough | stall until re-enabled |
| `removeParamsAdapter(adapter)` | this oracle's `ADMIN_ROLE` | every stock feed on that adapter: one token family on the chain | stall until the adapter is added back |
| `setPriceGuard(underlyingFeed, …)` with an unreachable range, on the underlying | the underlying feed's `stateGuard`, else the underlying's ADMIN | every feed over that underlying, here and in any provider reading it directly | stall |
| `setBlacklist(provider, true)` on the underlying | the underlying's ADMIN | every read by that provider | revert `Blacklisted` |
| `removeIntegrator(multiplierOracle)` on the underlying | the underlying's ADMIN | this whole oracle | revert `NotWhitelisted` |

`setFeedDisabled` is the incident switch for one bad feed. For example, a token whose issuer misses
the pause flag on a split can be stopped without stopping the rest of its family. A pool blacklist on
the underlying is not a stop: anyone can clear it by registering the pool again.

A feed id commits to its adapter, so a feed cannot move to another adapter: a different adapter needs
feeds of its own, and providers built on them.

## Corporate actions and the pause flag

The share price and the multiplier never change at the same instant: the issuer flips the multiplier when
it chooses, the share price adjusts when the market prints. In between, `price × multiplier` can be off by
the full split ratio. The issuer's pause flag covers that window, and the issuer's procedure is:

1. set the pause flag;
2. update the multiplier;
3. wait until the market prices the share consistently with it;
4. if the share feed has a `priceGuard` on the underlying oracle, its owner retunes the guard for the
   new share price (see below);
5. clear the pause flag.

While the flag is set, every read of the stock feed stalls; quoting resumes by itself when the issuer
clears it.

**A guarded share feed must be retuned in the pause.** The underlying guard is checked against the
unscaled share price. An N:1 split moves that price N times while the token price stays put, so a guard
sized before the split stalls every stock feed over that share once the flag is cleared, until the guard
is retuned. The guard's owner (the feed's `stateGuard` on the underlying oracle, else its ADMIN) is not
the issuer and not this oracle's admin, which makes them part of every split on a guarded share. Retune
the guard with `setPriceGuard(shareFeed, newMin, newMax)` before step 5, or widen it to
`(0, type(uint128).max)` to disable it, since a guard cannot be deleted. Read `priceGuard(shareFeed)`
on the underlying oracle to see whether a share carries one. The oracle adds no judgement of its own — **the issuer is trusted outright**, for the
multiplier and for the flag. Robinhood documents `oraclePaused()` as advisory; the provider's staleness
bound stays the primary guard for stale prices either way.

**If the issuer is late with the flag.** The oracle cannot tell whether the multiplier and the share price
describe the same share, and nothing else stands in for the flag. The share feeds the relayer
publishes (`Equity.Index.*/USD`) update **around the clock, weekends included**, within seconds and
with a spread of 0.01–0.03 bp. Pyth's symbol registry lists a 09:30–16:00 New York schedule for them,
and that is not what is published on-chain.

So no closed market halts a provider. A corporate action applied without the flag is mispriced by the
full ratio on a fresh feed, at any hour, and staleness never trips. That holds in either order:

- **The multiplier leads the share price:** it moves before the share reprices.
- **The multiplier lags it:** the share reprices (to 1/N on an N:1 split) while the multiplier is still
  the old one. The token is quoted at 1/N of its value, and the pool's token side can be drained.

When the issuer schedules the change, both adapters narrow this using the published schedule (see
[Params adapters](#params-adapters)):
- a pending dividend is priced at once;
- a pending split stalls from its announcement until it takes effect.

What remains is the time between the split's `effectiveAt` and the market's repricing, and a change the
issuer applies without scheduling it.

A provider's staleness bound guards against the relayer stopping, not against corporate actions. The
deployed `DEFAULT_CLASS` envelope allows up to 60 s, but that is a setting, not a code limit. The
factory admin can widen it with `setEnvelope`, or move a feed to another class with `setFeedClass`, up
to the factory's hard `MAX_STALENESS` of 7 days. A directly deployed `AnchoredPriceProvider` or a plain
`PriceProvider` accepts up to 7 days as well. With a bound that long, the pool would keep quoting a
days-old price after a relayer outage. Whoever reviews a provider therefore reads the provider's own
bound, not how it was created:

- on an `AnchoredPriceProvider`, the cap `MAX_REF_STALENESS()` and the per-leg bounds actually
  enforced, `baseMaxStaleness()` / `quoteMaxStaleness()`, which a mutable provider can tighten but
  never raise above the cap;
- on a `PriceProvider`, `MAX_TIME_DELTA()`.

**Quoting at all hours.** Because the share feeds never stop and carry a near-zero spread, a provider
quotes the token around the clock, weekends included, with a band close to its `minMargin`. LPs carry
the overnight and weekend moves of that price at that margin, including the gap when the regular
session opens.

## When a read stalls

A stalled read returns `mid = 0`, `spread = STALL_SPREAD` (65 535). Providers revert on it (`FeedStalled`),
and the pool cannot swap.

| Condition | Stock feed | Passthrough feed |
| --- | --- | --- |
| Underlying price is 0, stalled or saturated (spread ≥ 65 534) | stall | stall |
| Underlying price outside its `priceGuard` on the underlying oracle (after a split, until the share guard is retuned) | stall | stall |
| Issuer pause flag set | stall | — |
| Adapter removed from the allow-list | stall | — |
| Adapter read reverts, runs out of its gas, or returns a malformed answer (wrong token family, no code, missing getter, wrong length, non-canonical bool) | stall | — |
| Multiplier is 0 | stall | — |

Access failures (pool not in swap, not registered, blacklisted) **revert**, exactly as on the underlying
oracle; they are not stalls. So do an unknown `feedId` and an underlying feed that has never been pushed
(`FeedNotFound`).

This oracle's own access to the underlying fails the same way. The underlying oracle's admin can remove
it as an integrator (`NotWhitelisted`) or blacklist it (`Blacklisted`). Either way every read of every
feed **reverts**. Both provider types revert on a stall too (`FeedStalled`), so for the pool the two
have the same effect: it cannot swap.

This is the underlying admin's kill switch for the whole oracle, above the per-adapter one.

## Access and attribution

`price(feedId, pool)` is gated like the underlying providers oracle: the pool must report
`inSwap() == msg.sender`, be registered for the underlying feed and not be blacklisted; the calling
provider must not be blacklisted either. `tx.origin == address(0)` (off-chain simulation) skips the pool
checks, as upstream. `register(feedId, pool, factory)` forwards the registration and its fee to the
underlying oracle, so its fees and blacklist remain the single source of truth. `priceGuard(feedId)`
returns `(0, 0)`: the underlying feed's guard is enforced inside `price`, against the share price it was
configured for.

The oracle reads the underlying through `integratorPrice`, so the underlying emits
`PriceRead(multiplierOracle, underlyingFeed)`; the pool attribution is this oracle's own
`PriceRead(pool, feedId)`. Off-chain joins keyed on `FeedUpdated(underlyingFeed)` need the
`feedId → underlying` mapping (`feeds(feedId)`, or the `FeedCreated` event).

The underlying's pool gate binds the read to its direct caller, so this oracle cannot proxy
`price(feedId, pool)` to the underlying: the pool reports its provider as in-swap, not this oracle. That is
why it reads as a whitelisted integrator and re-applies the pool gate itself.

## Wiring on a chain

On each chain ([DEPLOYMENTS.md](DEPLOYMENTS.md#multiplier-lane-base-and-robinhood)) the oracle's
underlying is that chain's `PythOracle`, and the adapter of the chain's token family is on the oracle's
allow-list: `B20AssetParams` over Coinbase's OracleRegistry
`0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD` on Base, `RobinhoodStockTokenParams` on Robinhood Chain.
The oracle is a whitelisted integrator on the `PythOracle` and is on the `AnchoredProviderFactory`
allow-list; new feed ids fall into the factory's `DEFAULT_CLASS` envelope unless assigned a class.
No feeds come with the oracle: `createFeed` is permissionless, and the feeds belong with the provider
that reads them (see below).

`MultiplierOracle` exposes `kind = "multiplier"` and `version = "1.1.0"`, like the other oracles. The
adapters expose `version = "1.2.0"`.

## Creating feeds and providers

Whoever builds a provider creates the feeds it reads. `createFeed` is permissionless and idempotent (an
existing feed is returned as is), and the feed id is deterministic — `feedIdOf(underlying, token, params)` —
so it can be computed before the feed exists.

1. `createFeed(shareFeedId, token, adapter)` for the stock token, with the adapter of the token's own
   family (canonical token addresses: Coinbase's tokenized-stocks page for Base, Robinhood's Token
   Contracts page / `api.robinhood.com/rhj/assets`). A PythOracle feed id is the **share**'s Lazer id as
   `bytes32` (`bytes32(uint256(lazerId))`).
2. `createFeed(usdcFeedId, address(0), address(0))` for the quote leg, if the provider is synthetic.
3. Create the provider on `multiplierOracle` with the stock feed as base (and the passthrough feed as quote
   for a synthetic pair), then register each pool with `multiplierOracle.register(feedId, pool, factory)`
   for every feed the provider reads.

A feed whose Lazer id has never been pushed to the PythOracle on that chain reverts `FeedNotFound` on
every read while the underlying feed has no data: check the underlying feed before building on it.

## Gas

Approximate costs with cold state, as in a real swap transaction, excluding the adapter allow-list
check (one cold storage read, about 2.1k):

| Read | Gas |
| --- | --- |
| `PythOracle.price` directly (reference) | ~18.7k |
| Passthrough leg through this oracle | ~44k |
| Stock leg, Coinbase (via `B20AssetParams` → registry → precompile) | ~59k |
| Stock leg, Robinhood | ~67k |

The schedule reads are included in both stock legs; they add about 0.6k on Base (NVDAc) and about
1.9k on Robinhood Chain (AAPL). While a change is pending, one more read adds about 1k.

A synthetic quote reads two legs; a single-leg provider reads one.

## What this oracle does not protect against

- **Issuer key compromise.** A compromised issuer can mint unbacked tokens or publish a forged multiplier;
  the oracle, which trusts the issuer, keeps quoting "fair" value.
- **Freezes and seizures.** Transfer pauses, allowlist/blocklist policies, `burnBlocked` and seizures act
  on the pool's balances, not on price.
- **A stock feed bound to the wrong family's adapter.** The pause flag only protects a token whose issuer
  operates it; bind each stock feed to the adapter of the token's own family (a B20 adapter refuses
  non-B20 addresses; a Robinhood-style token without `oraclePaused()` stalls).
- **A stock feed bound to another token than the pool trades.** Nothing on-chain ties a feed's token to
  its share feed or to the provider's base token. The feed id commits to all three, but `createFeed`
  accepts any combination: the AAPL share with a TSLA token, or with a token whose multiplier the
  creator controls. Before trusting a provider, check two bindings. `feeds(baseFeedId).token` must be the
  pool's base token, and the share feed must be that token's own share. Checking a provider's feed
  bindings is the same job as on any synthetic provider.
- **A corporate action without the pause flag, at any hour.** A multiplier that leads or lags the share
  price is priced wrong by the full ratio on a fresh feed. The share feeds never stop, so staleness does
  not catch it. See [If the issuer is late with the flag](#corporate-actions-and-the-pause-flag).
- **Off-session prices.** The provider quotes around the clock with a band close to `minMargin`, through
  nights, weekends and the gap at the open
  ([Quoting at all hours](#corporate-actions-and-the-pause-flag)).
