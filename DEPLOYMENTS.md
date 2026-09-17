# Production deployments

Current production contracts are all at version `1.1.0` (solc 0.8.33). They are deployed via CreateX
`deployCreate3` with a **permissioned** salt: the salt carries the deployer address in its first 20
bytes, and CreateX guards it as
`keccak256(abi.encodePacked(bytes32(uint256(uint160(sender))), salt))`. A CREATE3 address is
therefore a function of the deployer key and the salt version — not of bytecode or constructor
arguments — so **every contract listed below sits at the same address on every chain it is deployed
to**, and no other sender can consume one of these salts. The deploy pipeline is operated by the
maintainers; the canonical per-contract salt versions live in `script/config/salts.json`.
`node script/verify-deployment.mjs --expect 1.1.0` reconciles this file against the chains at any time.

Columns, left to right: ethereum (1), base (8453), arbitrum (42161), bsc (56), polygon (137),
avalanche (43114), monad (143), megaeth (4326), hyperevm (999), robinhood (4663).

| Contract | Address | salt | eth | base | arb | bsc | polygon | avax | monad | megaeth | hyper | robin |
|---|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `CompressedOracleV1` (`kind = "compressed"`) | `0xE844701934D9C6085B292e428F41b911cC0b3872` | v1 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `PriceProviderFactory` | `0x050502eE4Da0eE2a9D44eE6046310F9f1532aCF2` | v1 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `PythOracle` (`kind = "pyth-lazer"`) | `0x30a88bf894D1b806125a23ebf23D715496fD7102` | v1 | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ | ✓ | ✓ | ✓ | ✓ |
| `ChainlinkOracle` (`kind = "chainlink-datastreams"`) | `0x810A649974f21bB6D3b2E781597EdBDAabe82228` | v1 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ | ✓ | ✓ |
| `AnchoredProviderFactory` | `0xb0eAE19259500Ac4Ca59b9a5cb8cDB2Da8076F0A` | v1 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

The two `◐` cells are deployed at the canonical address but waiting on an upstream dependency —
see [Per-chain notes](#per-chain-notes).
All five contracts share one salt version, `production-v1`. `version()` is `1.1.0` everywhere — a
bytecode redeploy at a fresh CREATE3 address is not a version bump, and the push wire format is
identical across builds.

**Same address does not mean same bytecode.** Constructor arguments baked into the runtime as
immutables differ per chain. **polygon runs a 10-second future tolerance** (`maxTimeDrift = 10`;
every other chain carries 0), so on polygon all three oracles' runtimes differ from their siblings,
and `ChainlinkOracle` additionally bakes a per-chain `feeToken` — giving it four distinct runtimes
(ethereum, base, arbitrum and polygon each their own; the six chains with no fee token share one).
The nine non-polygon `PythOracle`s are byte-identical (runtime keccak `0xd7169b76…7ca2`, 9,829
bytes), as are the nine non-polygon `CompressedOracleV1`s (`0x546b1ee2…f340`, 8,662 bytes); the two
factories take no per-chain constructor arguments and are byte-identical on all ten chains. The
pinned per-chain ledger of full runtime hashes is `script/config/codehashes.json` (checked by
`verify-deployment.mjs`), while `_deploy`'s reference check compares metadata-stripped code against
a local build.

**ethereum's Pyth lane is live.** Pyth Lazer has code on mainnet at its chain-constant address
`0xACeA761c27A909d4D3895128EBe6370FDE2dF481` (a proxy, and it has accepted real pushes). The
canonical `PythOracle` is deployed, funded and allow-listed: the mainnet `AnchoredProviderFactory`
allow-list holds **both** oracles (`getOracles → [ChainlinkOracle, PythOracle]`). The mainnet
anchored providers created so far all anchor to *Pyth*, so mainnet quoting depends on the Pyth
pusher's liveness rather than on the Chainlink lane. Those providers bound reference staleness at
15 seconds, so a push gap wider than that halts them fail-closed until the next push — monitor feed
`refTime` freshness against that bound, along with the fee balance below.

**bsc's Chainlink lane** verifies through the BNB Data Streams `VerifierProxy 2.0.0` at
`0xF276a4BC8Da323EA3E8c3c195a4E2E7615a898d1` (no FeeManager).

**Units and the DEFAULT_CLASS envelope.** `spread0` is emitted in 0.01-bps units (fraction × 1e6),
so `confidenceParam = 10_000` is a true 1× multiplier. The `AnchoredProviderFactory` DEFAULT_CLASS
envelope is identical on all ten chains: `minMarginMin = 1e11` (0.001 bps), `minMarginMax = 1e15`
(10 bps), staleness 0–60 s, `spreadMultMax = 2e18` (2.0×). The envelope has **no spread cap**: a
wide oracle spread widens a provider's band rather than halting it, and the only spread-related
halts are the stall sentinel (spread 65535) and a band reaching 100% half-width, both fail-closed
at read time.

**The `PythOracle` needs a native-token balance.** It pays a 1-wei Pyth Lazer verification fee per
push out of its own balance; at zero balance every relay reverts with `Insufficient fee provided`.
All ten chains are funded to 1e9 wei (1 gwei) — the deploy script's `PYTH_FUND_WEI` default, and
effectively inexhaustible at a billion pushes. The balance is public (`cast balance`) and belongs on
the monitoring list — watch the *direction*, not just non-zero: a balance that stops decreasing means
the pusher died, and 1-wei pool-registration fees can even push it up. See §5 of
[`docs/mm-operations-guide.md`](./docs/mm-operations-guide.md).

## Per-chain notes

The two `◐` lanes are **pre-claimed**: deployed at the canonical address so the lane stays on the
release's shared salt version, but not yet operational — each waits on an upstream dependency and
fails closed until it arrives. Deploying such a lane later under a fresh version would put that
chain's oracle at a different address than its siblings, which is what the pre-claim avoids.

**avalanche's `PythOracle` is deployed and waiting.** Pyth Lazer has no code on avalanche and is
not currently expected to arrive — but `pythLazer` is an immutable the constructor never calls, so
the oracle starts accepting pushes by itself if Lazer ever ships at its chain-constant address
(deployed with `ALLOW_CODELESS_LAZER`). It is funded (1 gwei) and allow-listed on the factory; a
provider anchored to it halts on read until the first push lands, which is what every feed does
before its first update.

**megaeth's `ChainlinkOracle` is deployed and waiting.** Chainlink documents `0x60fAa7fa…E9EB` as
MegaETH's verifier proxy but has not shipped code there yet; that address is baked as the tag-`0x50`
route (deployed with `ALLOW_CODELESS_VERIFIER`). Verifier routes are ADMIN-mutable (`setVerifier`),
so if the verifier lands at a different address the route is retargeted, not redeployed — and a
codeless verifier cannot leak a bad price: ingestion reverts (the verify call gets no return data to
decode). Unlike avalanche's Pyth lane it belongs **off** the factory allow-list until the verifier is
live and a report verifies end-to-end; the factory's `getOracles` is the authority on what is
currently listed. Do not "fix" hyperevm's config by analogy: Chainlink deploys its verifiers at the
same address on multiple chains, and that very same `0x60fAa7fa…E9EB` **on hyperevm** is a live
`VerifierProxy 2.0.0` that hyperevm's deployed `ChainlinkOracle` routes through.

**polygon runs a 10-second future tolerance**, the only chain that does; everywhere else it is 0,
and 0 is the value to prefer. A push that arrives inside the tolerance is accepted on-chain while
both price providers treat any future `refTime` as stale, so the feed is stored and unquotable at
the same time — and the monotonic gate then refuses the earlier-timestamped push that would repair
it. The feed is stuck until block time catches up. Widen it only for a chain whose block timestamps
genuinely run ahead of the pusher, and only by that much.

## Salt versions

The salt column in the table above is current; `script/config/salts.json` is the machine source.

Salt versions are scoped to the deployer key: the guarded salt mixes the sender in, so a version
consumed under one key does not constrain another, and a key rotation restarts numbering at
`production-v1`. Under a given key a version is consumed permanently — CreateX reverts where the
salt's address already has code — so a fresh full release must pick a new `RELEASE_VERSION` and
never reuse one. Because addresses are salted by the version, any later release sits at new
addresses; this file tracks the current addresses only. The machine-readable list of retired
addresses is generated into `script/config/retired-addresses.json`.
`node scripts/regen-retired-addresses.mjs` regenerates it after every redeploy.
`scripts/check-doc-addresses.mjs` gates docs/, examples/, skills/ and README.md against it in CI.

The permissioned salt also settles who can reach these addresses: CreateX's guard binds the salt to
the deployer, so a third party cannot claim "our" address on a chain where it is still empty.
Onboarding chain #11 is therefore a plain release run for that chain under the current salt
versions, which lands the same five addresses there. Two automated checks back the deploy itself:
`_deploy` refuses already-deployed code it cannot reproduce from local sources with this run's
constructor args (metadata-stripped hash), and `verify-deployment.mjs` reconciles full per-chain
runtime hashes against the pinned ledger in `script/config/codehashes.json`.
