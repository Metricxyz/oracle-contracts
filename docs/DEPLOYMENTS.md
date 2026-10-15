# Production deployments

Production contracts report version `1.1.0` (solc 0.8.33), except the multiplier lane's two params
adapters, which report `1.2.0`. They are deployed via CreateX `deployCreate3` with a
**permissioned** salt: the salt carries the deployer address in its first 20 bytes, and CreateX
guards it as `keccak256(abi.encodePacked(bytes32(uint256(uint160(sender))), salt))`. A CREATE3
address is therefore a function of the deployer key and the salt — not of bytecode or
constructor arguments — so **every contract listed below sits at the same address on every chain it
is deployed to**, and no other sender can use one of these salts.

Columns, left to right: ethereum (1), base (8453), arbitrum (42161), bsc (56), polygon (137),
avalanche (43114), monad (143), megaeth (4326), hyperevm (999), robinhood (4663).

| Contract | Address | eth | base | arb | bsc | polygon | avax | monad | megaeth | hyper | robin |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `CompressedOracleV1` (`kind = "compressed"`) | `0xE844701934D9C6085B292e428F41b911cC0b3872` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `PriceProviderFactory` | `0x050502eE4Da0eE2a9D44eE6046310F9f1532aCF2` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `PythOracle` (`kind = "pyth-lazer"`) | `0x30a88bf894D1b806125a23ebf23D715496fD7102` | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ | ✓ | ✓ | ✓ | ✓ |
| `ChainlinkOracle` (`kind = "chainlink-datastreams"`) | `0x810A649974f21bB6D3b2E781597EdBDAabe82228` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ | ✓ | ✓ |
| `AnchoredProviderFactory` | `0xb0eAE19259500Ac4Ca59b9a5cb8cDB2Da8076F0A` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

The two `◐` cells are deployed but cannot ingest updates: the upstream contract they verify through
has no code on that chain — see [Per-chain notes](#per-chain-notes). `version()` is `1.1.0` on all
five contracts. The multiplier oracle and its adapters exist only on base and robinhood and are
listed in [Multiplier lane](#multiplier-lane-base-and-robinhood).

**Same address does not mean same bytecode.** Constructor arguments baked into the runtime as
immutables differ per chain. polygon's oracles carry `maxTimeDrift = 10` (0 elsewhere, see
[Per-chain notes](#per-chain-notes)), so on polygon all three oracles' runtimes differ from their siblings,
and `ChainlinkOracle` additionally bakes a per-chain `feeToken` — giving it five distinct runtimes
(ethereum, base, arbitrum and polygon each their own; the six chains with no fee token share one).
The nine non-polygon `PythOracle`s are byte-identical (runtime keccak `0xd7169b76…7ca2`, 9,829
bytes), as are the nine non-polygon `CompressedOracleV1`s (`0x546b1ee2…f340`, 8,662 bytes). The two
factories' only constructor argument, the admin, is written to role storage rather than baked into
the runtime, so each factory is byte-identical on all ten chains.

**Ingestion configuration is the same on every chain.** Each `PythOracle` expects the Lazer
properties `0` Price, `4` Exponent, `5` Confidence and `12` FeedUpdateTimestamp. Each
`ChainlinkOracle` routes tag `0x50` only (`verifierTags()` returns `[0x50]`); on megaeth that route
points at an address without code (see [Per-chain notes](#per-chain-notes)). The
[relay format](relay-payload-format.md) describes both.

**bsc's Chainlink lane** verifies through the BNB Data Streams `VerifierProxy 2.0.0` at
`0xF276a4BC8Da323EA3E8c3c195a4E2E7615a898d1` (no FeeManager).

**Units and the DEFAULT_CLASS envelope.** `spread0` is emitted in 0.01-bps units (fraction × 1e6),
so `confidenceParam = 10_000` is a 1× multiplier. The `AnchoredProviderFactory` DEFAULT_CLASS
envelope is identical on all ten chains: `minMarginMin = 1e11` (0.001 bps), `minMarginMax = 1e15`
(10 bps), staleness 0–60 s, `spreadMultMax = 2e18` (2.0×). The envelope has **no spread cap**: a
wide oracle spread widens a provider's band rather than halting it, but APP rejects raw spread
>= 65534 (saturated uncertainty or the 65535 stall sentinel) before multiplication. Nonpositive interval edges or an upper relative deviation plus margin reaching
100% also halt at read time. See [the reference](oracle-reference.md).

**The `PythOracle` needs a native-token balance.** It pays a 1-wei Pyth Lazer verification fee per
push out of its own balance. Below that, the call into Pyth Lazer cannot carry its value and the
push reverts before Pyth's own `Insufficient fee provided` check is reached; the oracle's ingestion
entry point is payable, so a relay can also attach the fee itself. The balance is public (`cast balance`); registration payments, top-ups and admin withdrawals also
change it, so feed liveness is read from accepted observations, not from the balance.

## Multiplier lane (base and robinhood)

`MultiplierOracle` prices tokenized stocks whose redemption ratio is an on-chain multiplier, as
`share price × multiplier` over the chain's `PythOracle` ([reference](multiplier-oracle.md),
[integrator quickstart](multiplier-oracle-quickstart.md)). It is deployed on the two chains whose
stock tokens it reads, each with the adapter of that chain's token family:

| Contract | Address | base | robin |
|---|---|:-:|:-:|
| `MultiplierOracle` (`kind = "multiplier"`) | `0x6c38232B0597ef335bCdC86029cDc9e23A17F166` | ✓ | ✓ |
| `B20AssetParams` (Coinbase B20 Assets) | `0x1D4995C8d5e8946cd2A60Baa25802Bb7D877E41c` | ✓ | — |
| `RobinhoodStockTokenParams` (Robinhood Stock Tokens) | `0xCefea5dE67DF272c994d8a67cB4dd4bB495EE420` | — | ✓ |

The `MultiplierOracle` reports `version()` `1.1.0`, the adapters `1.2.0`. The oracle's runtime takes the
`PythOracle` as its only immutable, so it is byte-identical on both chains.

On both chains the adapter is on the oracle's allow-list, the oracle is a whitelisted integrator on
the `PythOracle`, and it is on the `AnchoredProviderFactory`
allow-list. The oracle's `ADMIN_ROLE` is held by the Safe
`0xa082C768B1C40f5e980b75959D85cF245AFF0FAE`.
`B20AssetParams` reads Coinbase's OracleRegistry `0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD`.

A stock feed reads the share's Lazer feed on the `PythOracle`. US equities are published there as
`Equity.Index.*/USD` ids (AAPL is 3191), not `Equity.US.*/USD`; a feed over an id that is not
published reverts `FeedNotFound` on every read. Which ids have data on a chain, and whether a USDC/USD
quote leg exists there, is live state: check it as in Step 0 of the quickstart.

## Per-chain notes

**avalanche's `PythOracle`** points at Pyth Lazer's chain-constant address, which has no code on
avalanche, so every push reverts and its feeds hold no data. It is on the factory allow-list; a
provider anchored to it halts on read with `FeedNotFound`.

**megaeth's `ChainlinkOracle`** routes tag `0x50` to `0x60fAa7fa…E9EB`, the address Chainlink
documents as MegaETH's verifier proxy. There is no code at that address, so ingestion reverts (the
verify call returns no data to decode). The route is ADMIN-mutable (`setVerifier`). The oracle is not
on the factory allow-list; `getOracles` on the factory lists what is. On hyperevm the same
`0x60fAa7fa…E9EB` is a `VerifierProxy 2.0.0`, and hyperevm's `ChainlinkOracle` routes through it.

**polygon's oracles accept timestamps up to 10 seconds ahead of block time** (`maxTimeDrift = 10`;
0 on every other chain). Both price providers treat a future `refTime` as stale, so a feed stored
with a future timestamp is unquotable until block time reaches it, and the monotonic gate refuses
every push with an earlier timestamp.

## Salts

The guarded salt mixes the deployer in, and CreateX reverts where the salt's address already has
code, so each salt deploys to its address once. The guard binds the salt to the deployer, so no
third party can deploy to these addresses.
