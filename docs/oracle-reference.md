# Oracle reference

This reference describes the checked-in contracts. Use a matching deployment and
ABI; `version()` identifies an interface/wire-format family, not a specific build
or the active address.

## Units and price direction

| Value | Representation | Example or rule |
| --- | --- | --- |
| Oracle mid | Unsigned integer, 8 decimals | `12345000000` represents `123.45` |
| `spread0` | Relative fraction × `1e6` (0.01-bps units) | `100` = 1 bp; `10_000` = 1%; used as per-side uncertainty by the standard providers |
| `spread1` | Family-specific secondary field | Compressed: independently decoded spread; Pyth/Chainlink: `65535` means unused. Standard providers use `spread0` |
| Stored observation time | Milliseconds | `OracleData.timestampMs` |
| `price()` observation time | Whole seconds | `refTime = floor(timestampMs / 1000)` |
| Provider freshness limits | Seconds | Age is compared with `block.timestamp` |
| Provider quote | `uint128` Q64.64 | Human quote price × `2^64`; bid rounds down, ask up |
| `marginStep`, `minMargin` | Fraction × `1e18` | `1e14` = 1 bp per side |
| `confidenceParam` | Multiplier × `10_000` | `0` ignores spread for shaping, `10_000` = 1×, `1_000_000` = 100× |
| APP per-leg spread multipliers | Multiplier × `1e18` | `1e18` = 1×; bounded by `maxSpreadMult` |

Prices mean **quote-token units per base-token unit**. `CompressedOracleV1`, `PythOracle`
and `ChainlinkOracle` do not store token identities; a `MultiplierOracle` stock feed stores the
token whose multiplier it applies (`feeds(feedId)`), not the provider's pair. The standard providers expose `token0() = baseToken` and
`token1() = quoteToken`; their quote math does not query token decimals. The consumer
must handle token-amount decimal conversion separately.

For a single feed, `referencePrice = floor(mid × 2^64 / 1e8)`. APP's two-feed mode
uses `floor(baseMid × 2^64 / quoteMid)` without rounding the intermediate ratio to
8 decimals. Both feeds must match the intended pair and share a quote denomination.

## Encodings and special values

Compressed feed IDs pack `(creator << 96) | (chainId << 16) | (slotIndex << 8) |
positionIndex`. Slot indices are `0..255`; positions are `0..3`. Reads reject a
zero creator, a foreign chain ID or an invalid position.

A compressed slot holds four price/spread entries and one shared timestamp. Every
push replaces the whole slot. Use the paired codebook indices `0xFF/0xFF` for an
unused or deliberately stalled position; it reads back as price `0`, spreads
`65535`, timestamp `0`. An untouched slot instead contains zeros. Both are
unquotable, but their raw readbacks differ.

`65535` is a sentinel, **not a percentage**. Pyth/Chainlink real uncertainty
saturates at `65534`; APP rejects `spread0 >= 65534` before applying multipliers.
The plain provider rejects `spread0 > 50_000` (5%) and the stall sentinel.
Compressed ordinary spreads top out at `10_000` (1%); exceeding the representable
range must not silently understate the uncertainty of a live feed.

U64x32 rounds a compressed mid down to its representable grid; codebook encoding
rounds an in-range spread up. A compressed price's quantization step can be larger
than one E8 unit. See [U64x32](u64x32.md), [codebook](codebook.md),
[packet layout](oracle-packet-structure.md) and [namespace layout](slot-structure.md).

## Chainlink report schemas

The oracle decodes three Data Streams schemas, selected by the feed ID's own schema
version. All of them carry 18-decimal prices, scaled down to the E8 oracle mid.

| Schema | Feeds | Mid | `spread0` | Observation time, as reported |
| --- | --- | --- | --- | --- |
| v3 | Crypto | `price` | From bid/ask | `observationsTimestamp`, seconds |
| v4 | RWA | `price` | `0` while the market is open; no bid/ask in the schema | `observationsTimestamp`, seconds |
| High Frequency Streams | v3-shaped only | `benchmarkPrice` | From bid/ask | `observationsTimestamp`, already milliseconds |

Whatever the report's unit, the oracle stores the observation time in milliseconds
and `price()` returns it floored to seconds.

Where a schema carries a book, `spread0` is the maximum deviation of bid and ask
from the mid. Any other schema — v11 included — reverts with
`UnsupportedReportSchema`, as does an ID whose resolution nibble says milliseconds
but whose base schema is not v3, or whose resolution nibble is 2–15. One such report reverts the whole `updateReports`
batch it rides in.

A v4 report carries a market status: `0` unknown, `1` closed, `2` open. Anything but
`2` is stored with the stall sentinel as its spread, so providers halt while the
market is shut and resume on the next open report.

A report whose price floors below one E8 unit is skipped: the stored value and its
timestamp stay as they were, and the rest of the batch proceeds. That applies to a
closed v4 report too, so a sub-unit price at the close leaves the last open quote in
place until the provider's own staleness bound halts it.

## Read access

| Read | Compressed | Pyth / Chainlink |
| --- | --- | --- |
| `getOracleData` / `getOracleDataBulk` | Open, `view` | Always revert `ReadDisabled`, including in `eth_call` |
| `price(feedId, pool)` | Open; emits `PriceRead` | Gated; emits `PriceRead` |
| `integratorPrice(feedId)` | Not provided | Requires an approved, non-blacklisted integrator |
| Missing data | A never-written slot returns zeros | `FeedNotFound` until the first stored update |

For a real Pyth/Chainlink pool read, the pool must be registered for **each** feed
and report `inSwap() == msg.sender`, where the caller is its provider. Caller and
pool blacklist checks also apply. Registration is permissionless and payable:
`register(feedId, pool, poolFactory)` checks that the factory is approved and
recognizes the pool. Pay the current `registrationFee`; excess payment is retained.
Registering also clears any blacklist entry on the pool.

An off-chain call with `tx.origin == address(0)` bypasses the pool/in-swap/registration
checks on `price()`. It still checks feed existence and the caller blacklist.
Use an explicit zero sender with `cast call`. This is a simulation facility, not
permission for an arbitrary contract to consume the data on-chain.

The standard providers' `getQuote()` and the attributed `price()` path are
**non-view**. `eth_call` can simulate them; an on-chain `STATICCALL` cannot execute
their event-emitting oracle reads. An APP custom source, by contrast, is invoked
with `STATICCALL` and must support that context.

Compressed `PriceRead` only records calls through `price()` and does not authenticate
the supplied pool address. Open getters and storage reads emit no such event.

## Freshness and ordering

A standard provider rejects a leg when `refTime == 0`, `refTime > block.timestamp`,
or `block.timestamp - refTime > limit`. Equality with the age limit is accepted.
Plain `MAX_TIME_DELTA` must be `1..604800`. APP's immutable `MAX_REF_STALENESS` may
be `0..604800`; each leg's configured limit must not exceed it. APP limit `0`
requires `refTime == block.timestamp`.

These limits apply when quoting. Push-time drift tolerance is a separate check,
and an accepted future timestamp can still prevent quoting until chain time catches up.

| Update path | Ordering | Timestamp beyond push drift tolerance |
| --- | --- | --- |
| Compressed fallback | Strictly newer per slot; old/equal word ignored | Transaction reverts |
| Compressed `updateBySignature` | Strictly newer per slot; old/equal word returns `false` | Transaction reverts |
| Pyth Lazer | Strictly newer per feed; old/equal entry ignored | Feed skipped; `FeedSkippedFutureTimestamp` emitted; other valid entries can proceed |
| Chainlink `updateReport` / `updateReports` | Strictly newer per feed; old/equal report ignored | Transaction reverts, including the batch call |

The price-update payloads have no deadline prefix. Compressed **pusher delegation**
through `allowPushers` is different: its consent signature includes a deadline,
which must be unexpired and strictly greater than the previously consumed deadline
for that pusher/creator pair. `allowContractPushers` delegates a pusher contract on its
live `isPusher(creator)` answer instead, with no signature or deadline; see
[the namespace rules](slot-structure.md#namespace--keys).

A successful receipt does not prove that a particular feed advanced. Verify the
stored value/timestamp and relevant `FeedUpdated` events. For signed streams,
verify the report's own observation time, not its reception time or packet envelope time.

## Provider controls

| Control | Plain provider | APP |
| --- | --- | --- |
| Oracle, feeds, token pair | Immutable | Immutable |
| Fixed margin / hard freshness ceiling | Immutable | Immutable |
| Source replacement | Not supported | Owner through factory, including `mutableParams = false` |
| Confidence | Owner or updater through factory; 60-second cooldown | Same, only when mutable |
| Per-leg freshness and spread multipliers | Not supported | Owner or updater through factory; only when mutable; bounds and separate 60-second cooldowns apply |
| Updater grants / ownership transfer | Owner through factory | Owner through factory |

APP source calls receive at most `500_000` gas. They must succeed and return exactly
three ABI words with a positive bid, `bid < ask`, an ask below `type(uint128).max`,
and their reference inside their own quote. That reference is validated and then discarded: the reported
`referencePrice` is the anchor's own mid, and a custom source cannot move it. Invalid
output, a revert or out-of-gas halts APP; there is no automatic fallback to reference
mode. The owner can explicitly select reference mode with a
zero source address. See [IAnchorSource](../contracts/interfaces/IAnchorSource.sol).

## Failure reference

| Symptom | Likely cause | Check and action |
| --- | --- | --- |
| `FeedNotFound` | No verified data, invalid compressed ID, or a `MultiplierOracle` feed ID that was never created (or whose underlying feed has no data) | Check oracle, chain, feed ID and first accepted update |
| `ReadDisabled` | Direct getter on Pyth/Chainlink | Use zero-sender `eth_call` of `price()` for inspection, or the authorized on-chain path |
| `InvalidInSwap` / `NotRegistered` | Wrong caller context or missing pool/feed registration | Check approved pool factory, registration of every leg, and provider wiring |
| `Blacklisted` / `NotWhitelisted` | Read permission denied; on a `MultiplierOracle` read, `NotWhitelisted` means the multiplier oracle is not an integrator on its underlying oracle | Inspect caller/pool or integrator status with the oracle administrator |
| `InsufficientFee` / `FactoryNotApproved` / `NotAPool` | `register` paid less than `registrationFee`, named a factory off the oracle's list, or a pool that factory does not recognize | Read `registrationFee` and `isApprovedFactory`; pass the pool's own factory |
| `FeedStalled` | Stale/future/zero price, guard breach, spread limit, invalid band/source or quote | Read the raw leg data, provider limits and guards; for APP inspect every leg and the custom source |
| Successful push, unchanged price | Older/equal timestamp, skipped feed, wrong address/namespace | Compare readback and events; check deployment identity, pusher remapping and observation time |
| `FutureTimestamp` | Observation too far ahead of chain time | Correct timestamp generation; an earlier update cannot overwrite a stored newer one |
| `FeedSkippedFutureTimestamp` | Pyth skipped a future observation | Inspect that feed's clock/data; check other feeds separately |
| `DeadlineExceeded` / `StaleConsent` | Expired/reused pusher consent | Obtain new consent with a later deadline; do not add a deadline to price calldata |
| Delegation call reverts without an error | `allowPushers`: a well-formed signature that does not recover to its pusher (a malformed one reverts with an OpenZeppelin `ECDSA…` error), or `pushers` and `signatures` of different lengths; `allowContractPushers`: the pusher's `isPusher(creator)` call fails or returns `false` | Re-sign the consent for this chain, oracle, deadline, pusher and creator; check the pusher contract |
| `NoSelfRemapping` / `InvalidManager` | A delegation call names the caller itself, `revokePusher` from a wallet with no delegation, or `removePushers` on a pusher not delegated to the caller | Check `namespaceRemapping(pusher)`; see [the namespace rules](slot-structure.md#namespace--keys) |
| `InvalidNamespace` / `updateBySignature` reverts without an error | Zero `feedCreator`, or a signature that does not recover to `feedCreator` | See [the signed-update guards](oracle-packet-structure.md#required-guards) |
| `BadCalldataLength` | Wrong compressed wire format | Use one zero prefix byte followed by one or more 32-byte slot words |
| `UnknownVerifierTag` | Chainlink route not configured | Check `verifierByTag` and the report's leading tag byte; see [the relay format](relay-payload-format.md#chainlink-data-streams-push) |
| `UnsupportedReportSchema` | Report schema the oracle does not decode (anything but v3, v4 and v3-shaped HFS; v11 included), a millisecond feed ID whose base schema is not v3, or a feed ID resolution nibble of 2–15 | Check the schema version in the feed ID against [the schema table](#chainlink-report-schemas); the whole batch reverted |
| Other Chainlink push reverts (`EmptyPayload`, `ZeroTimestamp`, `TimeMsOverflow`, `InvalidReportPrice`, `SafeCastOverflowedUintDowncast`) | Malformed tag or report content | See [the Chainlink revert table](relay-payload-format.md#chainlink-data-streams-push) |
| `NotImplemented` | Calldata for a function `ChainlinkOracle` does not have, for example a Pyth-format push | Check the target oracle and its entry point |
| Chainlink feed stalled while the market is shut | A v4 report with a market status other than open | Expected outside trading hours; the feed resumes with the next open report |
| Lazer property/ID mismatch | Wrong signed property set or feed order | Request the Lazer payload with the property set the oracle expects and pass feed IDs in the payload's feed order; see [the relay format](relay-payload-format.md#pyth-lazer-push) |
| Other Pyth push reverts (`FeedsLengthMismatch`, `NoFeeds`, `InvalidMagic`, `PayloadLengthMismatch`, `SafeCastOverflowedUintDowncast`, no error data) | Malformed prefix or payload, an out-of-range exponent or price, or no balance for the 1-wei fee | See [the Pyth revert table](relay-payload-format.md#pyth-lazer-push) |
| `ParamsOutOfEnvelope` / `EnvelopeNotFound` | APP creation outside the selected class policy | Read the feed class and effective envelope on the target factory |
| `CooldownNotElapsed` / `ImmutableProvider` | Update too soon or knob not mutable | Inspect timestamps and `MUTABLE_PARAMS`; source replacement has separate owner-only rules |

An oracle/provider halt prevents the affected standard quote from executing. It does
not by itself describe deposit/withdrawal availability or the behavior of arbitrary
custom pool extensions.

Implementation references: [compressed oracle](../contracts/oracles/compressed/CompressedOracle.sol),
[priced oracle base](../contracts/oracles/providers/OracleBase.sol),
[Lazer parser](../contracts/oracles/utils/LazerConsumer.sol),
[Chainlink oracle](../contracts/oracles/providers/ChainlinkOracle.sol),
[plain provider](../contracts/PriceProvider.sol), [APP](../contracts/AnchoredPriceProvider.sol).
