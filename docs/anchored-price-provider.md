# Anchored Price Provider (APP) — creation & lifecycle flow

The **Anchored Price Provider (APP)** is the standard anchored construction. Every quote
it returns is **clamped to a reference band** derived from the anchor oracle's own uncertainty:

```text
bid       = min(refBid, custom_bid)
ask       = max(refAsk, custom_ask)
reference = mid                    ← the anchor's, always
```

The quote is three values: the two executable edges and the **reference price**
(`bid <= reference <= ask`). The APP's reference is the
anchor's own mid — carried as the exact `midNum/midDen` ratio and divided out once, never derived from
the shaped edges. No source, confidence, `marginStep` or spread multiplier can move it.

The **floor guarantee**: the final quote is *never tighter* than the reference interval.
For a single feed this is `mid · (1 ± (spreadBps · spreadMult + minMargin))`, with spread
and margin converted to fractions. For a synthetic pair, keep each leg's multiplied relative
uncertainty separate (`uBase`, `uQuote`) and divide the opposing interval edges:

```text
refBid = baseMid · (1 - uBase) / (quoteMid · (1 + uQuote)) - mid · minMargin
refAsk = baseMid · (1 + uBase) / (quoteMid · (1 - uQuote)) + mid · minMargin
mid    = baseMid / quoteMid
```

The implementation additionally propagates the E8 quanta as described below. The raw spread sum
is used only for the optional confidence-shaped quote, which is clamped to these reference
edges.

`spreadBps` enters the band **multiplied** by the per-leg `spreadMult`, which may be set *below*
1× — so the guarantee is relative to the multiplied spread, not the raw oracle spread, and a provider
owner or a delegated updater can tighten that term (to zero, in the limit) when the provider is
mutable and its cooldown has elapsed. `minMargin` is the only term nobody can move after
deployment, and it is required to be strictly positive.

A custom source, confidence or `marginStep` may widen a quote beyond the interval; any tighter
edge is clipped to the reference. This is enforced by the band clamp (`min`/`max` vs the reference
`refBid`/`refAsk`), the `bidOut >= askOut` halt, and Floor/Ceil rounding. The factory does not
review arbitrary source code; operators must assess the source and its dependencies.

In **source mode** that bound is one-directional. Inward, the source is clipped at the live
configured reference band. Per-leg multipliers below 1× can narrow that band relative to the
upstream uncertainty; minMargin remains a positive floor. Outward, nothing bounds it: the quote is
as wide as the source says. Widening does *not* reach the reference price. A source must return a
reference of its own — exactly three words, with `bid <= reference <= ask` — or the read halts; the
value is validated and then discarded.

**8-decimal quantization cover.** A Pyth or Chainlink mid represents a pre-normalization
benchmark in `[mid, mid+1)/1e8`, so the upstream interval's upper edge is `(mid+1)/1e8 · (1 + u)`.
Single-feed quoting applies the uncertainty and the margin to that upper bound: the ask is
`(mid+1)/1e8 · (1 + u + minMargin)`, rounded up. The bid stays at the floored band edge
`mid · (1 − u − minMargin)`, which is conservative because the true mid is at or above it.

For a **synthetic** cross, propagate both quanta through the interval calculation itself: use
`baseMid` and `quoteMid+1` for the bid, `baseMid+1` and `quoteMid` for the ask, together with the
respective uncertainty factors. Round the bid down and ask up to Q64, then subtract/add
`ceil(mid · minMargin)` in Q64 once per side. This can widen each edge by
less than two Q64 units compared with a single exact division including the margin.
`referencePrice` remains the floored Q64 ratio of the stored mids.

Enforced in `_computeBidAsk` (`contracts/AnchoredPriceProvider.sol`). The plain provider's cover in
`PriceProvider._getQuote` (step 6) applies the same principle to its own shaping: the ask is
`(mid + 1)/1e8` scaled by the full configured factor `(1 + spread · confidence) · stepAskFactor`,
floored at 1×: a negative `marginStep` narrows the confidence widening but never drags the upper
bound *below* `mid + 1`. Its inversion guard still runs on the pre-cover shaped pair, so the extra
quantum cannot mask a misconfigured `marginStep`.

Contracts: `contracts/AnchoredPriceProvider.sol`, `contracts/AnchoredProviderFactory.sol`,
interface `contracts/interfaces/IAnchoredProviderFactory.sol`. One factory instance is deployed **per
chain**, with the chain's reference oracles admin-allow-listed on that same instance — Pyth +
Chainlink on most chains, plus the `MultiplierOracle` on base and robinhood. On avalanche both are
allow-listed, but the Pyth lane cannot ingest: Pyth Lazer has no code there. On megaeth only Pyth is
allow-listed, because the Chainlink verifier has no code there (see `DEPLOYMENTS.md` for the
deployed addresses and the per-chain notes).

---

## Actors & roles

| Actor | Role | Can do |
|---|---|---|
| **Factory admin** | `ADMIN_ROLE` on the factory | curate the oracle allow-list (`addOracle`/`removeOracle`), define envelopes (`setEnvelope`/`removeEnvelope`), assign feed classes (`setFeedClass`) |
| **Creator** | permissionless | call `createAnchoredProvider` — becomes the provider's `providerOwner` |
| **Provider owner** | per-provider | `setSource`, `grantUpdater`/`revokeUpdater`, `transferProviderOwnership`, and the tuning setters (`setConfidence`, `setSpreadMultipliers`, `setMaxStaleness`) |
| **Updater** | per-provider, granted by owner | the tuning setters only (never `setSource`) |

The factory's allow-list and envelopes are the governance surface; **creating** a provider is then
permissionless but can only happen with parameters that were inside the admin-curated envelope.

---

## Prerequisites

Before an APP can quote a feed:

1. **Reference oracle on the factory allow-list** — the chain's `PythOracle` or `ChainlinkOracle`, or
   the `MultiplierOracle` on base and robinhood (see [Step 1](#step-1--curate-the-oracle-allow-list-admin)).
   It supplies the shared `OracleData{ price, spread0, spread1, timestampMs }` (`price` an 8-decimal
   mid, `spread0` in 0.01-bps units).
2. **Feed(s) have data in that oracle.** `PythOracle` and `ChainlinkOracle` are registrationless:
   there is no feed registration (a `MultiplierOracle` feed is created with `createFeed`).
   Pool read registration is a separate step. There is no registrar role. A **Pyth / Chainlink** feed exists once its first provider-signed update
   lands (while it has none, oracle reads revert `FeedNotFound`). Provider creation itself does not validate the feed — a provider
   anchored to a feed with no data deploys fine and halts at read time until data arrives.
3. *(For live pool reads, not for creation itself)* the oracle's read-access layer
   must admit the consuming pool: its AMM factory `addApprovedFactory(factory)` + the pool
   `register(feedId, pool, factory)`. A `MultiplierOracle` feed is registered through the
   `MultiplierOracle`, which forwards the call (and fee) to its underlying oracle for the
   underlying feed; the approved factories and blacklist that apply are the underlying oracle's. See
   the `OracleBase` natspec (`contracts/oracles/providers/OracleBase.sol`) for the full mechanism.

---

## The flow

```text
ADMIN                                              CREATOR (permissionless)        OWNER / UPDATER
─────                                              ────────────────────────       ───────────────
1. addOracle(referenceOracle)       ──┐ allow-list
2. setEnvelope(classId|DEFAULT_CLASS) │ param bounds
3. setFeedClass(feedId, classId)      │ (optional; else DEFAULT_CLASS)
                                      ▼
                              4. createAnchoredProvider(oracle, baseFeedId, …)
                                 ├─ oracle ∈ allow-list?         → else OracleNotAllowed
                                 ├─ classId = feedClass[feed] or DEFAULT_CLASS
                                 ├─ envelope exists?             → else EnvelopeNotFound
                                 ├─ params ∈ envelope?           → else ParamsOutOfEnvelope
                                 └─ new AnchoredPriceProvider(…)  → ProviderDeployed
                                                                  ▼
                                                       5. setSource / setConfidence /
                                                          grantUpdater / transferProviderOwnership
                                                                  ▼
                                                       6. pool reads getQuote()
                                                          → (bid, ask, referencePrice)
                                                          (provenance: factory.isProvider(p))
```

### Step 1 — Curate the oracle allow-list (admin)

The factory is at the same address on every chain. Its allow-list holds the chain's reference
oracles named above (per-chain detail in [`DEPLOYMENTS.md`](DEPLOYMENTS.md)); `getOracles` returns it.

```solidity
factory.addOracle(referenceOracle);     // ADMIN_ROLE; ZeroOracle / OracleAlreadyAllowed
factory.removeOracle(referenceOracle);  // only blocks NEW providers
```

Removal does **not** affect already-deployed providers: each holds its oracle immutably and stays
`isProvider() == true`.

### Step 2 — Define a parameter envelope (admin)

An `Envelope` is the per-pair-class box of allowed clamp parameters. Providers can only be created with
parameters inside it.

```solidity
struct Envelope {
    uint256 minMarginMin;  uint256 minMarginMax;   // BPS_BASE_U scale (1 bps = 1e14)
    uint256 stalenessMin;  uint256 stalenessMax;   // seconds
    uint256 spreadMultMax;                          // ceiling for maxSpreadMult (1e18 = 1.0×)
    bool    exists;
}
factory.setEnvelope(classId, envelope);  // ADMIN_ROLE
factory.removeEnvelope(classId);         // ADMIN_ROLE; EnvelopeNotFound if the class has none
```

`setEnvelope` rejects (`BadEnvelope`) a zero `classId`, an inverted range, and any corner outside the
provider's hard bounds — so every in-envelope value of the three parameters it bounds is constructor-valid, and
for those three `createAnchoredProvider` fails with `ParamsOutOfEnvelope` rather than a provider-level revert.
`marginStep`, the token pair and the initial configuration sit outside the envelope and can still
revert in the provider constructor:

- `classId != 0`
- `minMarginMin > 0` (the provider constructor rejects `minMargin == 0` — `MinMarginZero`)
- `minMarginMin <= minMarginMax`
- `stalenessMax <= 7 days`, `stalenessMin <= stalenessMax`
- `spreadMultMax >= 1e18` (must admit the 1.0× default)

The envelope has no construction-time band-width constraint. Reads fail closed on **each leg's
raw spread >= 65534**, before applying its multiplier. This rejects the Pyth/Chainlink saturation
ceiling and the 65535 stall sentinel; a value rounded to exactly 65534 is also rejected
because it cannot be distinguished from a clipped value. A zero multiplier cannot bypass this guard.

Reads also reject nonpositive interval bounds and a pre-quantization upper relative deviation
plus minMargin reaching 100%. For a synthetic pair that deviation is
`(uBase + uQuote)/(1 - uQuote)`, rounded up. A zero reference bid, a reference ask above
`type(uint128).max` (checked before and after the quantization cover), a source or shaped ask above
it, and invalid source output also halt. An ask of exactly `type(uint128).max` is the halt
sentinel, so `getQuote` reverts `FeedStalled` on it as well: a returned ask is always below
`type(uint128).max`. These guards are the provider's, not the oracle's: direct `integratorPrice` consumers
must implement their own saturation guard.

**`DEFAULT_CLASS`** = `keccak256("AnchoredProviderFactory.DEFAULT_CLASS")` is the fallback class for feeds
with no explicit class. Without a `DEFAULT_CLASS` envelope, unclassified feeds revert
`EnvelopeNotFound(DEFAULT_CLASS)` at create.

> Production `DEFAULT_CLASS` envelope (identical on all ten chains):
> `minMarginMin 1e11 (0.001 bps), minMarginMax 1e15 (10 bps), stalenessMin 0, stalenessMax 60 s,
> spreadMultMax 2e18 (2.0×)`.
>
> ⚠️ Margins are on the `BPS_BASE_U = 1e18` scale (1 bps = `1e14`), while the oracles' `spread0` is
> in 0.01-bps units (one spread unit = `1e12` on the margin scale) — don't mix the two. The `1e11`
> floor is the lower *bound* a curator may create above; with a near-zero
> `minMargin` the band rests almost entirely on the oracle's own spread.

### Step 3 — Assign feeds to classes (admin, optional)

```solidity
factory.setFeedClass(feedId, classId);  // classId 0 unassigns → falls back to DEFAULT_CLASS
```

A non-zero `classId` must already have an envelope (`EnvelopeNotFound` otherwise). Feeds left unassigned
use `DEFAULT_CLASS` at create time.

### Step 4 — Create the provider (permissionless)

```solidity
address provider = factory.createAnchoredProvider(
    oracle,             // must be in the allow-list
    baseFeedId,         // its class drives the envelope
    quoteFeedId,        // 0 = single-feed; else synthetic ratio
    minMargin,          // per-side margin, 1e18 scale (1 bps = 1e14); MUST be > 0
    maxRefStaleness,    // seconds; 0 = refTime must equal block.timestamp
    maxSpreadMult,      // per-leg spread-multiplier ceiling (1e18 = 1.0×)
    mutableParams,      // false = immutable, true = customizable
    marginStep,         // fixed shaping bias (NOT envelope-bound)
    baseToken,          // pair tokens — mandatory (providers never read a token from the oracle)
    quoteToken,
    init                // InitialConfig: (source, baseMaxStaleness, quoteMaxStaleness,
);                      //                 baseSpreadMult, quoteSpreadMult)
```

Checks, in order: `oracle ∈ allow-list` (`OracleNotAllowed`) → resolve `classId` → `envelope.exists`
(`EnvelopeNotFound`) → `minMargin / maxRefStaleness / maxSpreadMult` each within the
envelope (`ParamsOutOfEnvelope`) → deploy `new AnchoredPriceProvider(...)`. The provider is recorded
(`_providers`, `providerOwner = msg.sender`) and `ProviderDeployed` is emitted.

#### Parameters

| Param | Meaning |
|---|---|
| `oracle` | which allow-listed reference oracle to anchor to |
| `baseFeedId` | the feed; **single-feed** mid = `price(baseFeedId)`. Its class selects the envelope |
| `quoteFeedId` | optional 2nd feed for **synthetic** ratio: mid = `price(base) / price(quote)` (e.g. BTC/USD ÷ ETH/USD = BTC/ETH); `0` = single-feed |
| `minMargin` | per-side margin on top of the oracle spread, `1e18` scale (1 bps = `1e14`). **Must be > 0** (`MinMarginZero`): it is the only band term no live knob can shrink |
| `maxRefStaleness` | seconds; the cap on the per-leg `baseMaxStaleness` / `quoteMaxStaleness`, which are what reads enforce — a reference older than its leg's bound **halts** quoting (`FeedStalled`). `0` = `refTime` must equal `block.timestamp` (whole seconds) |
| `maxSpreadMult` | per-leg spread-multiplier ceiling (`1e18` = 1.0×); must be `>= 1e18` and `<=` the envelope's `spreadMultMax`. Bounds how far a live multiplier can widen the band |
| `mutableParams` | `false` → fixed knobs (owner can still replace `source`); `true` → customizable (`confidenceParam` + the per-leg staleness/multiplier knobs tunable via factory) |
| `marginStep` | fixed shaping bias, immutable, applied to the step factors at construction. **NOT** envelope-bound — the band clamp neutralizes any sign. Requires `\|marginStep\| < 1e18` |
| `baseToken` / `quoteToken` | the pair tokens — **mandatory**, non-zero, distinct (providers never read a token from the oracle; the pair lives on the provider) |
| `init` | `InitialConfig` applied at construction through the same validation the setters use: `(source, baseMaxStaleness, quoteMaxStaleness, baseSpreadMult, quoteSpreadMult)`; pass `(0, maxRefStaleness, maxRefStaleness, 1e18, 1e18)` for the plain reference-mode default |

Provider-constructor guards (all satisfied automatically when params are in a valid envelope, except the
non-envelope-bound `marginStep`, token pair and `init`): `maxRefStaleness <= 7 days`
(`MaxRefStalenessOutOfBounds`), `minMargin > 0` (`MinMarginZero`),
`maxSpreadMult >= 1e18` (`MaxSpreadMultOutOfBounds`), `|marginStep| < 1e18`
(`MarginStepOutOfBounds`), tokens non-zero and distinct; the `init` legs go through the same
validation the setters use (`SpreadMultOutOfBounds` above `maxSpreadMult`, `StalenessOutOfBounds`
above `maxRefStaleness`). Feed existence is **not** checked at
construction — a feed with no data halts at read time instead.

### Step 5 — Curate the provider (owner / updater)

```solidity
factory.setSource(provider, newSource);                 // owner; 0 = reference mode. Instant; band bounds the source inward only
factory.setConfidence(providers, values);               // owner/updater; mutableParams only. ≤ 1_000_000, own 60 s cooldown
factory.setSpreadMultipliers(providers, baseM, quoteM); // owner/updater; mutableParams only; each ≤ maxSpreadMult, own 60 s cooldown
factory.setMaxStaleness(providers, baseS, quoteS);      // owner/updater; mutableParams only; each ≤ MAX_REF_STALENESS, own 60 s cooldown
factory.grantUpdater(provider, updater);                // owner; delegates the tuning setters (not setSource)
factory.revokeUpdater(provider, updater);               // owner
factory.transferProviderOwnership(provider, newOwner);  // owner
```

With `confidence = 0` and `marginStep = 0` a customizable provider's shaped quote degenerates to the band
edges — behaviorally identical to the immutable variant.

### Step 6 — Consume from a pool

**`factory.isProvider(provider) == true`** establishes factory provenance: the provider was created
under that factory's envelope constraints. It does not establish live feed health, pair semantics
or pool read registration.

The read path is **attributed and non-view** (the Pyth, Chainlink and Multiplier oracles serve no view read): the pool
marks itself in-swap with this provider and calls `getQuote()` (no args); the provider forwards
the pool (its `msg.sender`) to `oracle.price(feedId, pool)`, which binds the read via
`pool.inSwap() == provider`. This requires the pool to be registered for the feed (Prerequisite 3).
Factory approval is checked when the pool registers, not on each read: removing a factory from the
oracle's approved list does not undo registrations made through it.

---

## Errors quick-reference

| Error | Where | Cause |
|---|---|---|
| `ZeroOracle` / `OracleAlreadyAllowed` / `OracleNotFound` | `addOracle`/`removeOracle` | bad allow-list op |
| `BadEnvelope` | `setEnvelope` | zero `classId`, inverted range, or corner outside provider hard bounds |
| `EnvelopeNotFound(classId)` | `removeEnvelope`, `setFeedClass`, `createAnchoredProvider` | class/`DEFAULT_CLASS` envelope not configured |
| `OracleNotAllowed(oracle)` | `createAnchoredProvider` | oracle not in the allow-list |
| `ParamsOutOfEnvelope` | `createAnchoredProvider` | a clamp param fell outside the feed's envelope |
| `MinMarginZero` / `MaxRefStalenessOutOfBounds` / `MaxSpreadMultOutOfBounds` / `MarginStepOutOfBounds` | provider constructor | param outside the provider's hard bounds (unreachable through a valid envelope, except `marginStep`) |
| `SpreadMultOutOfBounds` / `StalenessOutOfBounds` | constructor (`init` legs) and the tuning setters | per-leg multiplier above `maxSpreadMult`, per-leg staleness above `maxRefStaleness` |
| `ConfidenceParamOutOfBounds` | `setConfidence` | confidence above `CONFIDENCE_MAX` (1e6 = 100×) |
| `FeedNotFound` | oracle read path (`getQuote`) | the reference oracle holds no observation for the feed |
| `FeedStalled` | oracle read path (`getQuote`) | stale reference, saturated/stalled spread, guard violation, nonpositive/oversized interval — or a source that reverted, returned anything other than three words, quoted zero/inverted, or placed its reference outside its own `[bid, ask]` |
| `NotProviderOwner` / `NotProviderUpdater` / `ImmutableProvider` / `CooldownNotElapsed` | curator controls | wrong caller / immutable variant / a confidence, spread-multiplier or staleness setter called within 60 s of its own last update |
| `ProviderNotTracked` / `LengthMismatch` | factory curator controls | provider not created by this factory / batch array lengths differ |
| `OnlyFactory` | provider setters | a provider setter called directly instead of through the factory |

## Scripts

| Script | Purpose |
|---|---|
| `script/CreateAnchoredProvider.s.sol` | create one provider through a deployed factory (see the [creation quickstart](./anchored-price-provider-quickstart.md)) |
