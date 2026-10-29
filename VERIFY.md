# Verifying audit-056c204

The tag `audit-056c204` publishes the contracts at commit `056c20454dd867e388986f83b78d05809b921e49` of our private repository `smart-contracts-poc`. That commit is the version named in:

- **Sherlock collaborative audit, May–June 2026** (`2026.07.06 - Final - Metric Collaborative Audit Report`, p. 4: "FinalCommit: 056c20454d…")
- **Sherlock bug bounty contest, September 2026** (`2026.09.15 - Final - Metric Public Bug Bounty Audit Contest Report`, p. 4: "AuditedCommit: 056c20454d…")

The public tag is a new commit without the private history, so its own hash is not `056c204`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `056c204…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `056c20454dd867e388986f83b78d05809b921e49`, the hash in the reports.
2. `commit.raw` names root tree `0f4680c710bcc8821ffbb3cc95861f770ca53197`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `0fb82d4cc7ebdba126ca9bc866dd85da1c7908da`.
4. In the public tag, `contracts/` must hash to the same `0fb82d4cc7ebdba126ca9bc866dd85da1c7908da`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-056c204 https://github.com/Metricxyz/oracle-contracts.git
cd oracle-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit 056c20454dd867e388986f83b78d05809b921e49
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # 056c20454dd867e388986f83b78d05809b921e49
git hash-object -t tree verify/tree.raw       # 0f4680c710bcc8821ffbb3cc95861f770ca53197
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree 0f4680c710bcc8821ffbb3cc95861f770ca53197 contracts   # ... tree 0fb82d4cc7ebdba126ca9bc866dd85da1c7908da  contracts
git rev-parse HEAD:contracts              # 0fb82d4cc7ebdba126ca9bc866dd85da1c7908da
```

## What is not published

Deployment scripts, internal tooling, CI and examples are left out (`script/`, `scripts/`, `config-ui/`, `contract-registry/`, `AGENTS.md`), and so is `test/debug.t.sol`, a local debugging test with a private RPC URL. In `foundry.toml` the Alchemy RPC key is replaced with `${ALCHEMY_API_KEY}`; it is the only file changed. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

Note: the reports link to `github.com/Oracle-Based-Pool/smart-contracts-poc`, the private repository. It is not public.
