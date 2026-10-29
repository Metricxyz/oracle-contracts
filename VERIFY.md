# Verifying audit-eda97bb

The tag `audit-eda97bb` publishes the contracts at commit `eda97bbcc1d33dd6c86f6993fa43d4e206755df0` of our private repository `smart-contracts-poc`. That commit is the version named in:

- **Zellic audit, June 2026** (`Metric OMM - Zellic Audit Report.pdf`, p. 11: "Version eda97bbcc1…")

The public tag is a new commit without the private history, so its own hash is not `eda97bb`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `eda97bb…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `eda97bbcc1d33dd6c86f6993fa43d4e206755df0`, the hash in the reports.
2. `commit.raw` names root tree `f6cdc7e1fe4b26c3698870b5d3dbda16d1b38c11`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `b5ae57073381fae094398b12affcbe8b5012520b`.
4. In the public tag, `contracts/` must hash to the same `b5ae57073381fae094398b12affcbe8b5012520b`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-eda97bb https://github.com/Metricxyz/oracle-contracts.git
cd oracle-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit eda97bbcc1d33dd6c86f6993fa43d4e206755df0
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # eda97bbcc1d33dd6c86f6993fa43d4e206755df0
git hash-object -t tree verify/tree.raw       # f6cdc7e1fe4b26c3698870b5d3dbda16d1b38c11
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree f6cdc7e1fe4b26c3698870b5d3dbda16d1b38c11 contracts   # ... tree b5ae57073381fae094398b12affcbe8b5012520b  contracts
git rev-parse HEAD:contracts              # b5ae57073381fae094398b12affcbe8b5012520b
```

## What is not published

Deployment scripts, internal tooling, CI and examples are left out (`script/`, `scripts/`, `config-ui/`, `contract-registry/`, `AGENTS.md`), and so is `test/debug.t.sol`, a local debugging test with a private RPC URL. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

Note: the reports link to `github.com/Oracle-Based-Pool/smart-contracts-poc`, the private repository. It is not public.
