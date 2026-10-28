# Verifying audit-8b72555

The tag `audit-8b72555` publishes the oracle contracts audited at commit
`8b72555ba7322b97b5c998e1cadee7100677d9a4` of our private repository `smart-contracts-poc`. That commit is the
version named in:

- **Zellic re-audit, September 2026** (`OMM Reaudit - Zellic Audit Report.pdf`, p. 11: "Version 8b72555ba7…")
- **Sherlock bug bounty contest, September 2026** (`2026.09.15 - Final - Metric Public Bug Bounty Audit Contest Report`, p. 4: "Final Commit 8b72555ba7…")

The public tag is a new commit (`e72b3dc`) without the private history, so its own hash is not `8b72555`. The
`contracts/` folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `8b72555…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `8b72555ba7322b97b5c998e1cadee7100677d9a4`, the hash in the reports.
2. `commit.raw` names root tree `8a9e7651a46392617f9af51c868a768e5e20c6d8`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `f2fd9c61adb7d3931a47f5f48718ca1e387afa2b`.
4. In the public tag, `contracts/` must hash to the same `f2fd9c61adb7d3931a47f5f48718ca1e387afa2b`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-8b72555 https://github.com/Metricxyz/oracle-contracts.git
cd oracle-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit 8b72555ba7322b97b5c998e1cadee7100677d9a4
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # 8b72555ba7322b97b5c998e1cadee7100677d9a4
git hash-object -t tree verify/tree.raw       # 8a9e7651a46392617f9af51c868a768e5e20c6d8
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree 8a9e7651a46392617f9af51c868a768e5e20c6d8 contracts   # ... tree f2fd9c61adb7d3931a47f5f48718ca1e387afa2b  contracts
git rev-parse HEAD:contracts              # f2fd9c61adb7d3931a47f5f48718ca1e387afa2b
```

## What is not published

The tag contains `contracts/`, `test/`, `docs/`, `lib/`, `licenses/`, `skills/`, build config, `README.md`,
`DEPLOYMENTS.md`, `CONTRIBUTING.md`, and this `VERIFY.md` with its `verify/` folder. Deployment scripts, internal tooling, CI and examples are left out, and a
few internal files under `test/` and `docs/` were removed. Only `contracts/` is claimed identical to the audited
commit.

Note: the reports link to `github.com/Oracle-Based-Pool/smart-contracts-poc`, the private repository's former
location. It is not public.
