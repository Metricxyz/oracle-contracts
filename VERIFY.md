# Verifying audit-a7644f6

The tag `audit-a7644f6` publishes the contracts at commit `a7644f6baf09e9c595c64c26764b6b8ef7358a6d` of our private repository `smart-contracts-poc`. That commit is the version named in:

- **Sherlock collaborative audit, May–June 2026** (`2026.07.06 - Final - Metric Collaborative Audit Report`, p. 4: "AuditedCommit: a7644f6baf…")

The public tag is a new commit without the private history, so its own hash is not `a7644f6`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `a7644f6…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `a7644f6baf09e9c595c64c26764b6b8ef7358a6d`, the hash in the reports.
2. `commit.raw` names root tree `0cf7cd912b2274bedeee6bdbbc70b1713f0fcb0f`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `bdc761ae585ed9f27569b79ca564537820502705`.
4. In the public tag, `contracts/` must hash to the same `bdc761ae585ed9f27569b79ca564537820502705`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-a7644f6 https://github.com/Metricxyz/oracle-contracts.git
cd oracle-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit a7644f6baf09e9c595c64c26764b6b8ef7358a6d
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # a7644f6baf09e9c595c64c26764b6b8ef7358a6d
git hash-object -t tree verify/tree.raw       # 0cf7cd912b2274bedeee6bdbbc70b1713f0fcb0f
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree 0cf7cd912b2274bedeee6bdbbc70b1713f0fcb0f contracts   # ... tree bdc761ae585ed9f27569b79ca564537820502705  contracts
git rev-parse HEAD:contracts              # bdc761ae585ed9f27569b79ca564537820502705
```

## What is not published

Deployment scripts, internal tooling, CI and examples are left out (`script/`, `scripts/`, `config-ui/`, `contract-registry/`, `AGENTS.md`), and so is `test/debug.t.sol`, a local debugging test with a private RPC URL. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

Note: the reports link to `github.com/Oracle-Based-Pool/smart-contracts-poc`, the private repository. It is not public.
