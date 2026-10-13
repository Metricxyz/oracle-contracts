# Documentation requirements

These requirements govern the oracle documentation a market maker or integrator reads:
this `docs/` tree, the repository `README.md`, `skills/*/SKILL.md`, and the oracle and
market-maker pages of the product documentation that link here. The publishing side lives in the
pusher repository (https://github.com/Metricxyz/mm-pusher-ts) and keeps its own copies of the wire-format
specs, vendored from here; a change to a format page belongs in the same review as that repository's
refresh.

## 1. Layers and what each one owns

| Layer | Home | Owns | Must not contain |
| --- | --- | --- | --- |
| Product pages | GitBook (`use-metric/oracles`, `market-makers/*`, `developers/oracle-integration`) | What a price is, who vouches for it, product processes: onboarding, pool tiers, fees | Contract parameter tables, env-var tables, copied unit or error tables |
| Repository docs | this `docs/` tree | Executable procedure, units, access rules, failure behavior | Product policy, pricing strategy, marketing claims |
| Executable references | `script/` file headers, `DEPLOYMENTS.md` | Arguments, environment variables, addresses | Conceptual explanation |

A page states in its first three lines who it is for, what it produces, and which page
to read first. Every page is reachable from [`docs/README.md`](README.md); that index is
the only map.

## 2. One fact, one home

| Fact | Single source | Everything else |
| --- | --- | --- |
| Units, sentinels, freshness rules, read access, error table | [`oracle-reference.md`](oracle-reference.md) | Links to the section |
| Production addresses and chain availability | [`DEPLOYMENTS.md`](../DEPLOYMENTS.md) | Links; never inlines an address |
| Example script numbers, env vars, commands | the [pusher repository](https://github.com/Metricxyz/mm-pusher-ts) | Links; may name a lane, not its flags |
| Creation script arguments | the script's own header | Quickstarts link to it |
| Wire formats | `slot-structure.md`, `oracle-packet-structure.md`, `u64x32.md`, `codebook.md` | Link, never restate a bit layout |

Restating a rule in a second page is a defect even when the restatement is correct: the
two copies diverge on the next contract change. A one-clause reminder plus a link is
acceptable; a second table is not.

## 3. Invariants stated in identical words

These claims recur across layers. Reuse the wording; when the behavior changes, change
every occurrence in the same commit.

- A valid signature proves who supplied a price. It does not prove that the price is
  economically correct or that someone will keep publishing it.
- A successful transaction can leave a feed unchanged. Verify the stored observation.
- An APP quote is never tighter than its configured reference band, and nothing caps
  how far a source may widen it.
- The reported `referencePrice` is the anchor's own mid; a custom source cannot move it.
- Factory membership proves provenance, not liveness, and is not a pool-tier decision.
- A raw oracle read and an executable provider quote are different checks.
- Deployed bytecode or a matching `version()` does not identify the active deployment.
- The oracles are registrationless: there is no feed registration. Pool read registration
  for Pyth and Chainlink is a separate step.
- Feed identities carry no token metadata; the feed's economic meaning must match the
  provider's declared token pair.

## 4. Voice

Neutral and procedural. Instructions are imperative; statements about the system are
present tense and factual. No persuasion, no reassurance, no self-assessment: a page
does not call a limitation "honest", a behavior "a feature", or a guarantee
"audit-once". No superlatives, no "simply", "just", "of course".

Headings are sentence case. How-to headings name the action ("Create a plain price
provider"); reference headings name the subject ("Units and price direction"). Filler
titles such as "Cheatsheet", "Overview", "Usage reminders" and "Notes" are not headings.

State a limit as a limit, not as an apology, and always with its consequence: what a
reader must do because of it.

Wrap prose at 90 columns; tables, links and code blocks are exempt. Diagrams are ASCII
in a `text` block. Keep tables to six columns and one screen.

## 5. Commands and examples

- Every block runs as written from the repository root, or the block changes directory.
- Inputs come from named variables, guarded at first use: `: "${RPC_URL:?Set the RPC URL}"`.
  No placeholder addresses, no values copied from another chain.
- Reads that need a zero sender pass it explicitly and say why once, by link.
- Each block is followed by its expected result and by what a reader checks when the
  result differs.
- Demo values are labelled as demo values at the point of use.
- A command is verified against the current code before it is published.

## 6. Numbers

Every quantity carries its representation on first use in a page: E8 mid, spread as a
fraction × `1e6` (0.01-bps units), `1e18` fractions for margins and multipliers,
confidence × `10_000`, Q64.64 quotes, milliseconds in storage against seconds in
`price()`. Never write a bare "bps" for a `1e6` value, and never present `65535` as a
percentage: it is a sentinel.

## 7. Boundaries

Oracle documentation stops at the provider's quote and its read access. Pool tiers, fee
policy, UI workflows, API submission and conditional delivery belong to the product
documentation and are referenced by link. Where a reader must cross the boundary, the
page says so in one sentence and links once.

## 8. Cross-repository consistency

The published copy a reader reaches from the product documentation is part of the
deliverable. A documentation change is incomplete while the public mirror still serves
the superseded page, and product pages must not link to a path that does not exist in
the tree they point at. When the canonical page and the mirror differ, resolve the
mirror before publishing the product page that cites it.

## 9. Definition of done

A documentation change is done when:

1. Every relative link and anchor resolves in the tree it is published from.
2. Every command shown was run, or is a read-only call whose signature was checked
   against the current ABI.
3. Every unit, bound and error name was verified against the contract or test that
   defines it, and the check is recorded in the change description.
4. The invariants in section 3 appear in their canonical wording.
5. No fact from section 2 was duplicated outside its single source.
6. The index in `docs/README.md` lists every page in the tree.
7. Contract or script changes in the same commit updated their reference page and every
   walkthrough that executes them.
8. A change to a wire-format page, or to `script/GenerateVectors.s.sol`, states whether the
   pusher repository needs a matching refresh (`npm run sync:contracts`, then its own tests).
