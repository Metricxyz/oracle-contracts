# Pyth and Chainlink relay format

For relayers forwarding signed Pyth Lazer updates to `PythOracle` and Chainlink Data Streams
reports to `ChainlinkOracle`: the calldata each oracle accepts and the checks it applies. The
compressed lane is described in [the packet format](oracle-packet-structure.md).

Both oracles are permissionless to push to: the signature inside the payload is the trust anchor,
not the sender.

## Pyth Lazer push

`PythOracle` ingests through its payable `fallback()`. The calldata is:

```text
[feedsLength:2][feedId_0:4][feedId_1:4]…[feedId_{n-1}:4][priceUpdate:rest]
```

- `feedsLength` — `uint16`, big-endian: the number of feeds in the signed update.
- `feedId_i` — `uint32`, big-endian: the Lazer feed id of the i-th feed, in the same order as
  the feeds inside `priceUpdate`.
- `priceUpdate` — the signed Lazer update in its EVM format, as Pyth Lazer delivers it. The
  oracle passes it to the Pyth Lazer contract's `verifyUpdate` and parses the verified payload.

Every feed in the update carries exactly the properties the oracle expects. The deployed
`PythOracle` expects four, in any order: `0` Price, `4` Exponent, `5` Confidence and `12`
FeedUpdateTimestamp. Request the Lazer subscription with exactly that property set.

The oracle pays a 1-wei Lazer verification fee per push from its own balance; the relay can
attach the fee as `msg.value` instead.

### Checks that revert the push

| Error | Cause |
| --- | --- |
| `FeedsLengthMismatch` | `2 + 4·feedsLength` exceeds the calldata, or `feedsLength` differs from the number of feeds in the verified payload |
| `NoFeeds` | the verified payload holds no feed |
| `InvalidMagic` | the verified payload does not start with the Lazer EVM format magic |
| `FeedIdMismatch` | `feedId_i` differs from the id of the i-th feed in the payload |
| `UnexpectedPropsCount`, `UnknownProperty` | a feed carries a different property set than the expected one |
| `PayloadLengthMismatch` | parsing does not end exactly at the end of the verified payload: bytes remain after the last feed, or the payload is truncated (the parser reads past its end, so a truncated payload can also fail earlier with another parse error) |
| `SafeCastOverflowedUintDowncast` | a feed's price, scaled to 8 decimals, exceeds `uint64` |
| no error data | a feed's exponent is outside `[-65, 49]`, or the oracle holds less than the 1-wei fee (counting `msg.value`) |

A failed signature check reverts inside the Pyth Lazer contract. One feed that hits a revert
above reverts the whole update.

### Feeds skipped without a revert

The rest of the update is stored; a skipped feed keeps its last value and timestamp:

- no FeedUpdateTimestamp (its exists flag is 0);
- a price that is not positive, or that rounds to 0 at 8 decimals;
- a FeedUpdateTimestamp beyond the chain's `MAX_TIME_DRIFT` (event `FeedSkippedFutureTimestamp`);
- a FeedUpdateTimestamp not newer than the stored one.

A stored feed emits `FeedUpdated`. Freshness is the feed's own FeedUpdateTimestamp, not the
update header's timestamp.

### Order of checks

The checks run in this order; the first one a feed fails decides between skip and revert:

1. The calldata prefix, the Lazer verification and the parse of the whole payload (magic, feed
   count, each feed's id and property set) — any failure reverts.
2. Then each feed in payload order:
   1. no FeedUpdateTimestamp, or a price that is not positive — skip;
   2. an exponent outside `[-65, 49]`, or a price that exceeds `uint64` at 8 decimals — revert;
   3. a price that rounds to 0 at 8 decimals — skip;
   4. a FeedUpdateTimestamp beyond `MAX_TIME_DRIFT` — skip with `FeedSkippedFutureTimestamp`;
   5. a FeedUpdateTimestamp not newer than the stored one — ignored; otherwise stored.
3. After the last feed, a parse that did not end at the end of the payload reverts
   `PayloadLengthMismatch`.

## Chainlink Data Streams push

`ChainlinkOracle` ingests through `updateReport(bytes taggedReport)` and
`updateReports(bytes[] taggedReports)`. Each payload is the DON full report prefixed with one
tag byte:

```text
taggedReport = [tag:1][fullReport:rest]
```

- `tag` — selects the Chainlink VerifierProxy the report is verified through. The oracle reads
  the route with `verifierByTag(tag)` and lists the registered tags with `verifierTags()`. The
  constant `TAG_V050 = 0x50` names a v0.5.0 proxy (payable `verify`) and `TAG_V051 = 0x51` a
  v0.5.1 proxy (`verifyView`). The deployed oracles route tag `0x50` on every chain.
- `fullReport` — the full report exactly as the Data Streams API returns it (its `fullReport`
  field), unmodified. The oracle strips the tag and forwards the rest to the proxy.

Ingestion is not payable; the oracle forwards no verification fee.

### Checks that revert the push

| Error | Cause |
| --- | --- |
| `EmptyPayload` | the payload has no tag byte |
| `UnknownVerifierTag` | no VerifierProxy is registered under the tag |
| `UnsupportedReportSchema` | the report's schema is not v3, v4 or the v3-shaped High Frequency Streams (millisecond) schema, or the feed id's resolution nibble (its top 4 bits) is 2–15 |
| `ZeroTimestamp`, `FutureTimestamp` | the observation timestamp is zero, or beyond the chain's `MAX_TIME_DRIFT` |
| `TimeMsOverflow` | a High Frequency Streams `observationsTimestamp` exceeds `2^56 − 1` milliseconds |
| `InvalidReportPrice` | the report price is not positive, or its ask is below its bid |
| `SafeCastOverflowedUintDowncast` | the report price, scaled to 8 decimals, exceeds `uint64` |
| no error data | the verified report does not ABI-decode as its schema |

A failed verification reverts inside the VerifierProxy. In `updateReports`, one failing report
reverts the whole batch.

### Reports stored or skipped

- A report whose price rounds to 0 at 8 decimals is skipped.
- A report not newer than the stored observation for its feed is ignored.
- A v4 report whose market status is not open stores the stall sentinel, so providers halt on
  that feed until an open report arrives.

A stored report emits `FeedUpdated`.

### Order of checks

Each report, in batch order, goes through these checks; the first one it fails decides between
skip and revert:

1. the tag (`EmptyPayload`, `UnknownVerifierTag`) and the VerifierProxy verification — revert;
2. the schema (`UnsupportedReportSchema`) and its ABI decode — revert;
3. a price that is not positive, an ask below the bid (`InvalidReportPrice`), a price that exceeds
   `uint64` at 8 decimals, or a High Frequency Streams timestamp overflow (`TimeMsOverflow`) —
   revert;
4. a price that rounds to 0 at 8 decimals — skip;
5. a zero or future observation timestamp (`ZeroTimestamp`, `FutureTimestamp`) — revert;
6. an observation not newer than the stored one — ignored; otherwise stored.
