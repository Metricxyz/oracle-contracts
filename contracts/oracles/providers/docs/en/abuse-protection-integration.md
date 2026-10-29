# Proposal: Pool & Factory integration for the oracle abuse-protection layer

Status: draft / for review
Scope: changes required in the **AMM pool** and **AMM pool factory** to consume the abuse-protection
read path already implemented in `contracts/oracles/providers/OracleBase.sol`. The price-provider
side is already shipped as `ProtectedPriceProvider` / `ProtectedPriceProviderL2` (see §4).

---

## TL;DR

- **Already shipped:** the oracle (`OracleBase`, shared by Pyth/Chainlink) has the abuse-protection
  layer — paid pool registration, blacklist, `PriceRead` event, and the attributed read
  `price(feedId, pool)`. No oracle changes needed. The **price-provider side is also shipped** as the
  standalone `ProtectedPriceProvider` / `ProtectedPriceProviderL2` (attributed read only — see §4).
- **What the AMM side must add** (this doc):
  - **Factory** implements `IPoolFactory`: just `isPool(address)` (+ a `PoolCreated` event). Consulted
    by the oracle **only at registration** time.
  - **Pool** exposes `inSwap()` (transient — the provider it is reading through) and a non-view
    `getBidAndAskPrice()` that marks itself in-swap and calls
    `ProtectedPriceProvider.getBidAndAskPrice()` (no args); `swap()` uses the same path.
  - (**Price provider** needs no AMM-side work — `ProtectedPriceProvider` / `…L2` are already shipped;
    just point the pool at one and `register` it. See §4.)
- **Access:** on-chain reads go **only** through `price(feedId, pool)` (pools) or `integratorPrice`
  (whitelisted integrators) — registration + non-blacklisted pool required. The public getters
  `getOracleData` / `getOracleDataBulk` / `price(bytes32)` are **disabled** (revert `ReadDisabled`);
  off-chain consumers read raw storage / events, never a Solidity getter.
- **Economics:** blacklist = access revocation; re-`register` = (paid) redemption. Raise
  `registrationFee` if abusers appear.
- **Security:** the in-swap marker lives **on the pool** — a pool can only ever mark itself, so it
  cannot frame another pool. The provider forwards its **real caller** (`msg.sender`) as the pool, and
  the oracle binds the read via `pool.inSwap() == provider`. The factory is consulted only at
  `register` (via `isPool` + the approved-factory set), never on the read path.

---

## 1. Background

The provider oracle (`OracleBase`, inherited by `PythOracle` and `ChainlinkOracle`) ships a
read-access / abuse-protection layer: on-chain price *consumption* requires a registered, non-blacklisted
pool, every such read is attributed via an event, and the maintainer can blacklist abusers who recover
only by paying the registration fee again.

What already exists on the oracle (no further oracle changes needed):

```solidity
interface IPoolFactory { function isPool(address pool) external view returns (bool); }     // validated at register
interface IPool        { function inSwap() external view returns (address priceProvider); } // queried on read

// OracleBase (providers)
function price(bytes32 feedId, address pool)
    external returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime); // non-view, emits PriceRead
function register(bytes32 feedId, address pool, address factory) external payable;       // pays fee, whitelists pool, clears blacklist
function addApprovedFactory(address factory) external; // ADMIN
function blacklisted(address) external view returns (bool);
function registrationFee() external view returns (uint256);
event PriceRead(address indexed reader, bytes32 indexed feedId);
```

The oracle authenticates a pool read like this:

1. the pool's price provider invokes `oracle.price(feedId, pool)`, forwarding the pool (its own
   `msg.sender`) as the argument;
2. oracle requires `pool != 0` and `IPool(pool).inSwap() == msg.sender` (the calling provider) — the
   pool must have marked itself in-swap with exactly this provider;
3. oracle requires `!blacklisted[pool]` and `registeredPool[feedId][pool]` (the pool must have paid
   registration for this feed);
4. oracle reads the data and emits `PriceRead(pool, feedId)`.

The pieces still owned by the AMM side are:

- a **factory** that implements `isPool` (so the oracle can validate a pool at `register`);
- a **pool** that exposes `inSwap()` and a `getBidAndAskPrice()` which marks itself in-swap with its
  provider, then reads through the shipped `ProtectedPriceProvider`.

The price-provider leg is done: `ProtectedPriceProvider` / `ProtectedPriceProviderL2` read the oracle
exclusively via the attributed `price(feedId, pool)`, forwarding their caller (see §4).

The providers oracle **disables** the public getters (`getOracleData` / `getOracleDataBulk` /
`price(bytes32)` revert `ReadDisabled`): the only on-chain read is the attributed `price(feedId, pool)`
(pools) / `integratorPrice` (integrators). The legacy `PriceProvider`, which read through
`getOracleData`, can therefore no longer read the providers oracle on-chain — it is fully superseded by
`ProtectedPriceProvider`.

---

## 2. Factory changes (`IPoolFactory`)

The AMM pool factory must track the pools it created and expose membership. A plain `mapping` is enough —
the public getter already satisfies `IPoolFactory.isPool`; no on-chain enumeration is needed (the oracle
only ever calls `isPool(address)` at registration; off-chain listing is served by `PoolCreated`):

```solidity
mapping(address => bool) public isPool; // public getter == IPoolFactory.isPool(address) -> bool

// on pool creation:
isPool[pool] = true;
emit PoolCreated(pool, ...);
```

`oracle.register(feedId, pool, factory)` uses this (against an ADMIN-approved factory) to validate "this
is a real pool of an approved factory". **The factory plays no role on the read path** — the in-swap
attestation lives on the pool (§3).

---

## 3. Pool changes (`MetricOmmPool`)

The **pool owns the in-swap marker** and exposes its own `getBidAndAskPrice()` (the "forwarded"
entrypoint). It marks itself in-swap with its provider immediately before the read and calls the provider
with **no arguments**; `swap()` uses the same path. Any read through the pool is attributed to the pool
(the oracle emits `PriceRead(pool, feedId)`).

```solidity
// transient slot (Solidity >=0.8.24, evm_version = prague — already set in foundry.toml)
address transient private _inSwapPriceProvider;

/// @notice Queried by the oracle to bind the read to the calling provider (0 outside a swap).
function inSwap() external view returns (address) {
    return _inSwapPriceProvider;
}

/// @notice Forwarded entrypoint — non-view (writes the transient marker, oracle emits).
function getBidAndAskPrice() public returns (uint128 bid, uint128 ask) {
    _inSwapPriceProvider = PRICE_PROVIDER;                       // mark self in-swap with the provider
    return IPriceProvider(PRICE_PROVIDER).getBidAndAskPrice();   // no args; see §4
}
```

At the existing swap read site (`var/MetricOmmPool.sol:565`), read the price through the pool's own
`getBidAndAskPrice()` instead of calling the provider directly.

Notes:

- The pool passes **nothing** to the provider; the provider forwards the pool (its `msg.sender`) to the
  oracle, which then queries `pool.inSwap()` and binds it to that provider.
- `getBidAndAskPrice()` is **non-view** (it writes the transient marker and the oracle emits an event).
- **Use EIP-1153 transient storage** for `_inSwapPriceProvider`: it auto-clears at end of tx, so a stale
  marker can never leak into a later, unrelated call; it is reentrancy-safe and cheap. For sequential
  swaps in one tx (e.g. a multi-hop router) each pool re-sets its own marker right before its own read.
- No persistent state, no manual clear, no extra reentrancy guard beyond the existing swap guard.

The pool must be `register`-ed with the oracle for its feed to use this on-chain path (see §5).

---

## 4. Price provider — shipped (`ProtectedPriceProvider` / `ProtectedPriceProviderL2`)

The provider side is **already implemented** as two standalone contracts —
`contracts/ProtectedPriceProvider.sol` (L1) and `contracts/ProtectedPriceProviderL2.sol` (L2),
usable by both Pyth and Chainlink feeds. They read **exclusively** through the attributed, non-view
path; there is **no** open `getOracleData` / `view` price getter on them. The existing
`PriceProvider` / `PriceProviderL2` are **left untouched in source**, but since the oracle disabled the
public getters they relied on, they can no longer read the providers oracle on-chain — fully superseded
here.

The single read entry is non-view and takes **no arguments** — it forwards `msg.sender` (the calling
pool):

```solidity
// contracts/ProtectedPriceProvider.sol — the only read entry
function getBidAndAskPrice() external returns (uint128 bid, uint128 ask) {
    (bid, ask) = _getBidAndAskPrice();
    if (bid == 0 || ask == type(uint128).max) revert FeedStalled();
}
```

The attributed oracle read is declared in its own minimal interface
(`contracts/interfaces/IPricedOracle.sol`) — kept separate from `IOffchainOracle` so existing
implementers (compressed oracle, mocks) are not forced to implement it:

```solidity
interface IPricedOracle {
    function price(bytes32 feedId, address pool)
        external returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime);
}

// inside ProtectedPriceProvider — forwards the pool (msg.sender) to the oracle
function _getBidAndAskPrice() internal returns (uint128, uint128) {
    (uint256 mid, uint256 spread,, uint256 refTime) =
        IPricedOracle(address(offchainOracle)).price(offchainFeedId, msg.sender);
    return _computeBidAsk(mid, spread, refTime); // staleness / guard / CL-deviation / spread / marginStep
}
```

Notes:

- The provider forwards `msg.sender` (the pool that called it) as the attributed reader — it cannot be
  spoofed to frame another pool, because the provider always reports its real caller.
- All downstream pricing (staleness, price guard, confidence spread, marginStep, the
  `bid < ask` invariant) is **identical** to the legacy `PriceProvider` and lives in the shared
  `_computeBidAsk(mid, spread, refTime)` helper — only the data source changed.
- `getBidAndAskPrice()` is **non-view** (the oracle emits `PriceRead` and enforces the pool-level
  blacklist / registration).
- **L2 (`ProtectedPriceProviderL2`)**: identical, but takes a `FUTURE_TOLERANCE` in its constructor and
  uses the L2-aware staleness check that tolerates an oracle `refTime` slightly ahead of
  `block.timestamp`.
- There is **no** `view` leg on these contracts, and the oracle's public getters are disabled too;
  off-chain consumers read raw storage / events / an indexer.

---

## 5. Registration & blacklist lifecycle

- **On-chain pool reads REQUIRE registration.** `price(feedId, pool)` requires
  `registeredPool[feedId][pool]` — the pool must have paid registration for that feed (and not be
  blacklisted) to use the attributed on-chain path.
- **Off-chain reads stay free.** Aggregators/arbitrageurs and dashboards read raw storage / events /
  an indexer — there is no on-chain Solidity getter to call (`getOracleData` / `getOracleDataBulk` /
  `price(bytes32)` revert `ReadDisabled` for everyone). This is the economic model: on-chain price
  *consumption* requires a registered pool; passive off-chain observation is free and unavoidable on a
  public chain.
- **Registration (`register{value}(feedId, pool, factory)`)** records the pool on the per-feed
  whitelist (`registeredPool`), banks the fee, and **clears any blacklist on the pool**. Overpayment is
  NOT refunded. `register` is permissionless (anyone may pay for a valid pool) and validates the pool
  via the approved factory's `isPool`. It is also the *recovery* path off a blacklist.
- **Economic deterrent.** `registrationFee` defaults to a token `1 wei` — intentionally minimal for
  now; raise it via `setRegistrationFee` if abusers appear. Misuse → maintainer blacklists the pool
  (observed via `PriceRead` events) → recovery requires paying the fee again.
- **Who pays / fee withdrawal.** The pool deployer calls `register` once. Accrued ETH is swept in full
  by ADMIN via `withdrawEth` — sweeping the entire balance (fees plus any operational reserve) is
  intentional.

---

## 6. End-to-end swap flow

```
EOA → MetricOmmPool.swap()
        MetricOmmPool → MetricOmmPool.getBidAndAskPrice()                // pool's forwarded entrypoint
            MetricOmmPool: _inSwapPriceProvider = PRICE_PROVIDER         // mark self in-swap (transient)
            MetricOmmPool → ProtectedPriceProvider.getBidAndAskPrice()   // no args
                              ProtectedPriceProvider → oracle.price(offchainFeedId, MetricOmmPool)  // forwards msg.sender (the pool)
                                oracle: require(pool != 0 && IPool(pool).inSwap() == msg.sender)    // pool.inSwap() == provider
                                oracle: require(!blacklisted[pool])
                                oracle: require(registeredPool[offchainFeedId][pool])
                                oracle: emit PriceRead(pool, offchainFeedId)
                          ProtectedPriceProvider applies spread / staleness / guard / CL-deviation
        ← bid/ask
        (transient inSwap marker auto-clears at end of tx)
```

Off-chain / aggregators read raw storage / events / an indexer; the public getters are disabled, so no
contract can consume the price on-chain without a registered pool.

---

## 7. Security considerations

- **In-swap marker lives on the pool**: `getBidAndAskPrice()` only ever sets `_inSwapPriceProvider` for
  itself — a pool can never mark another pool, so a read cannot be attributed/blacklisted to a pool that
  did not perform it. (No cross-pool `setInSwap` exists to abuse.)
- **Provider forwards its real caller**: the provider passes its own `msg.sender` (the pool) to the
  oracle, so it cannot be tricked into reading "as" a different pool.
- **Caller binding in the oracle** (`pool.inSwap() == msg.sender`): a read is valid only if the pool
  declared exactly this provider in-swap. An attacker calling `oracle.price(feed, V)` directly (for some
  registered pool `V`) fails, because `V.inSwap()` returns `V`'s real provider — or `0` outside `V`'s
  own swap — never the attacker.
- **Factory only at registration**: a pool can register only if an ADMIN-approved factory's `isPool`
  recognizes it; the read path does not consult the factory. *Note:* `removeApprovedFactory` blocks new
  registrations but not reads by already-registered pools of that factory — blacklist those if needed.
- **Transient marker**: no cross-call/cross-tx leakage; no reentrancy window because the marker is set
  and consumed within one synchronous call chain.
- **Shared price provider**: one `ProtectedPriceProvider` may serve many pools; the oracle resolves and
  blacklists the **pool** (the forwarded `msg.sender`), never the shared provider, so blacklisting one
  pool does not break others reading through the same provider.
- **Multi-hop routers**: each pool re-sets its own marker immediately before its own read; sequential
  reads in one tx each see their own pool.

---

## 8. Backward compatibility & migration

- The existing `PriceProvider` / `PriceProviderL2` are **untouched in source** — their
  `getBidAndAskPrice()` keeps working for off-chain integrations, but
  on-chain they can no longer read the providers oracle (the getters they used are disabled). The
  attributed path is a **separate** pair of contracts (`ProtectedPriceProvider` /
  `ProtectedPriceProviderL2`), so adoption is opt-in per pool — point a pool at a protected provider,
  add `inSwap()` to the pool, and `register` it; nothing forces migration of existing deployments.
- Existing pools that have not adopted `inSwap()` will fail `oracle.price(feed, pool)` with
  `InvalidInSwap` until upgraded. Plan the pool wiring and the `addApprovedFactory` call together.

---

## 9. Open questions / decisions

1. **Pool/factory address delivery — resolved.** The pool passes **nothing** to the provider; the
   provider forwards the pool (its `msg.sender`), so no factory/pool address needs threading through the
   call. The factory is referenced only at `register`.

---

## 10. Testing plan (AMM side)

- Factory: `isPool` membership; off-chain listing via `PoolCreated`.
- Pool: `inSwap()` returns the provider during a read and `0` otherwise (transient auto-clear across
  calls); `swap` marks in-swap then reads; a blacklisted pool's swap reverts `Blacklisted(pool)`; an
  unregistered pool reverts `NotRegistered(feedId, pool)`.
- ProtectedPriceProvider: `getBidAndAskPrice()` returns parity with the legacy `PriceProvider`
  computation for a clean pool and emits `PriceRead(pool, feedId)`; reverts `FeedStalled` on the
  `(0, max)` sentinel.
- Spoofing: a contract `X` calling `oracle.price(feed, V)` for a registered pool `V` reverts
  `InvalidInSwap` (because `V.inSwap() != X`); `X` reading "as itself" still requires `X` to be a
  registered pool whose `inSwap()` returns the calling provider.
- Recovery: blacklist a pool → swap reverts → `register{value: fee}` → swap succeeds again.
