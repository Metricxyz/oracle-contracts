# Production deployments

Current production contracts are all at version `1.1.0` (solc 0.8.33). They are deployed via CreateX
`deployCreate3` with a per-contract salt (`"<ContractName>-<salt version>"`), which means **every
contract listed below sits at the same address on every chain it is deployed to** — the CREATE3
address depends only on the salt and the CreateX factory, not on bytecode or constructor arguments.
The deploy pipeline is operated by the maintainers; the canonical per-contract salts live in
`script/config/salts.json`, and `node script/verify-deployment.mjs --expect 1.1.0` reconciles this
file against the chains at any time.

Columns, left to right: ethereum (1), base (8453), arbitrum (42161), bsc (56), polygon (137),
avalanche (43114), monad (143), megaeth (4326), hyperevm (999), robinhood (4663).

| Contract | Address | salt | eth | base | arb | bsc | polygon | avax | monad | megaeth | hyper | robin |
|---|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `CompressedOracleV1` (`kind = "compressed"`) | `0xADDfc3a4c50E99BC0eF418696573DCffeE2EA8B4` | v6.6 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `PriceProviderFactory` | `0x313E90693849884Ab88e750a51227ae7e391b5F0` | v6.2 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `PythOracle` (`kind = "pyth-lazer"`) | `0x4ACDAF5429AeeF693b8804948d2Fd8FD1e64558a` | v6.5 | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ | ✓ | ✓ | ✓ | ✓ |
| `ChainlinkOracle` (`kind = "chainlink-datastreams"`) | `0x1E4a892698BAcb395F61B5d42Db93264b300770f` | v6 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ | ✓ | ✓ |
| `AnchoredProviderFactory` | `0x52a07f10C93F662D6C9B502ce4f184b7580d9675` | v6.4 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

The two `◐` cells are deployed at the canonical address but waiting on an upstream dependency
(pre-claimed lanes, 2026-09-06) — see [Per-chain notes](#per-chain-notes).
Contracts are **not** all on one salt version: each carries the salt of its own last redeploy.
`version()` is `1.1.0` everywhere — a bytecode redeploy at a fresh CREATE3 address is not
a version bump, and the push wire format is identical across builds.

**Same address does not mean same bytecode.** Two separate causes, both verified on-chain:

- *Immutables.* Constructor arguments baked into the runtime differ per chain. **polygon runs a
  10-second future tolerance** (`maxTimeDrift = 10`; every other chain carries 0), so on polygon all
  three oracles' runtimes differ from their siblings on other chains. The other nine `PythOracle`s
  are byte-identical (runtime keccak `0x0a0241c9…2e34`, 9,829 bytes) — avalanche's 2026-09-06
  pre-claim hash-matches the group, and ethereum's live code was verified to hash-match base's.
- *Build waves.* `ChainlinkOracle` was deployed in waves under the same salt and `version()`:
  ethereum, base, arbitrum, hyperevm and robinhood carry the 2026-08-17 build (11,202 bytes,
  non-payable `fallback`); bsc, polygon, avalanche and monad carry the current source (11,197
  bytes, payable `fallback`); megaeth's 2026-09-06 pre-claim is that same source cut from a later
  checkout — identical executable code, different trailing solc-metadata hash. Full-runtime hashes
  can therefore differ even between functionally identical builds: the pinned per-chain ledger is
  `script/config/codehashes.json` (full hashes, `verify-deployment.mjs`), while `_deploy`'s
  reference check compares metadata-stripped code.

**ethereum's Pyth lane is live.** Pyth Lazer has code on mainnet at its chain-constant address
`0xACeA761c27A909d4D3895128EBe6370FDE2dF481` (a proxy, and it has accepted real pushes). The
canonical `PythOracle` is deployed, funded and allow-listed: the mainnet `AnchoredProviderFactory`
allow-list holds **both** oracles (`getOracles → [ChainlinkOracle, PythOracle]`). The mainnet
anchored providers created so far all anchor to *Pyth*, so mainnet quoting depends on the Pyth
pusher's liveness (feed `refTime` freshness), not only on the Chainlink lane — monitor accordingly,
along with the fee balance below.

**bsc (chain id 56) migration is complete.** All five contracts are live at the canonical addresses
and fully configured (allow-list holds both oracles, DEFAULT_CLASS envelope set). Its Chainlink lane
verifies through the BNB Data Streams `VerifierProxy 2.0.0` at
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
Funding targets differ by deploy cohort:

| Chains | Funded to | Cohort |
|---|---|---|
| base, arbitrum, hyperevm, robinhood | 1e13 wei | v6.5 redeploy wave |
| ethereum, bsc, polygon, avalanche, monad, megaeth | 1e9 wei (1 gwei) | deploy-script default (`PYTH_FUND_WEI`) |

Either is effectively inexhaustible (1e9 = a billion pushes), but the balance is public
(`cast balance`) and belongs on the monitoring list — and watch the *direction*, not just non-zero:
a balance that stops decreasing means the pusher died, and 1-wei pool-registration fees can even
push it up. See §5 of [`docs/mm-operations-guide.md`](./docs/mm-operations-guide.md).

## Per-chain notes

The two `◐` lanes are **pre-claimed** (2026-09-06): deployed at the canonical address so the
permissionless CREATE3 salt cannot be squatted there, but not yet operational — each waits on an
upstream dependency and fails closed until it arrives.

**avalanche's `PythOracle` is deployed and waiting.** Pyth Lazer has no code on avalanche and is
not currently expected to arrive — but `pythLazer` is an immutable the constructor never calls, so
the oracle starts accepting pushes by itself if Lazer ever ships at its chain-constant address
(deployed with `ALLOW_CODELESS_LAZER`). It is funded (1 gwei) and allow-listed on the factory; a provider anchored
to it halts on read until the first push lands, which is what every feed does before its first
update.

**megaeth's `ChainlinkOracle` is deployed and waiting.** Chainlink documents `0x60fAa7fa…E9EB` as
MegaETH's verifier proxy but has not shipped code there yet; that address is baked as the tag-`0x50`
route. Verifier routes are ADMIN-mutable (`setVerifier`), so if the verifier lands at a different
address the route is retargeted, not redeployed — and a codeless verifier cannot leak a bad price:
ingestion reverts (the verify call gets no return data to decode). Unlike avalanche's Pyth lane it
is **deliberately NOT on the factory allow-list** — allow-list it only once the verifier is live and
a report verifies end-to-end; megaeth's `AnchoredProviderFactory` therefore still holds Pyth alone
(a provider anchors to exactly one oracle, so a single-oracle factory is perfectly usable). Do not
"fix" hyperevm's config by analogy: Chainlink deploys its verifiers at the same address on multiple
chains, and that very same `0x60fAa7fa…E9EB` **on hyperevm** is a live `VerifierProxy 2.0.0` that
hyperevm's deployed `ChainlinkOracle` routes through.

**polygon runs a 10-second future tolerance**, the only chain that does; everywhere else it is 0,
and 0 is the value to prefer. A push that arrives inside the tolerance is accepted on-chain while
both price providers treat any future `refTime` as stale, so the feed is stored and unquotable at
the same time — and the monotonic gate then refuses the earlier-timestamped push that would repair
it. The feed is stuck until block time catches up. Widen it only for a chain whose block timestamps
genuinely run ahead of the pusher, and only by that much.

## Salt versions

The salt column in the table above is current; `script/config/salts.json` is the machine source.
Every salt version that has ever appeared in the git history of this file or of salts.json is
**consumed** on at least one chain — CreateX reverts where a salt's
address already has code — so a fresh full release must pick a new `RELEASE_VERSION` and never reuse
one. Because addresses are salted by the version, any later release sits at new addresses; this file
tracks the current addresses only. The machine-readable list of retired addresses is generated into
`script/config/retired-addresses.json` (`node scripts/regen-retired-addresses.mjs` after every
redeploy), and `scripts/check-doc-addresses.mjs` gates docs/, examples/, skills/ and README.md
against it in CI.

The salts are **permissionless** CreateX salts: on any chain where a canonical address is still
empty, anyone can consume the salt and put foreign code at "our" address for good. All ten chains
hold all five contracts, and the standing policy
for chain #11 is to claim all five salts as step #0 of onboarding, before anything else is announced
or configured. Two automated checks back this up: `_deploy` refuses already-deployed code it cannot
reproduce from local sources with this run's constructor args (metadata-stripped hash), and
`verify-deployment.mjs` reconciles full per-chain runtime hashes against the pinned ledger in
`script/config/codehashes.json`.
