# Verifying audit-edbc5f0

The tag `audit-edbc5f0` publishes the contracts at commit `edbc5f0e7efe9f3177e49eea52636d4930550c1b` of our private repository `smart-contracts-poc`. That commit is the version named in:

- **Zellic re-audit, September 2026** (`OMM Reaudit - Zellic Audit Report.pdf`, p. 10: "Only changes between edbc5f0...8b72555"). The re-audit reviewed the changes from this commit to `8b72555`, published as tag [`audit-8b72555`](https://github.com/Metricxyz/oracle-contracts/tree/audit-8b72555).

The public tag is a new commit without the private history, so its own hash is not `edbc5f0`. The `contracts/`
folder is unchanged, though, and git hashes let you prove that without access to the private repo.

## What the two files are

Both are in the `verify/` folder of this tag, next to `verify.py`.

- `commit.raw`: the audited commit object, byte for byte. Its git hash is `edbc5f0…`. It names the commit's root
  tree, its parents, author, signature and message.
- `tree.raw`: the root tree object of that commit, byte for byte. It lists the top-level files and folders with
  their hashes, including `contracts`. It contains names and hashes only, no file contents.

## The check

1. `sha1("commit <size>\0" + commit.raw)` must equal `edbc5f0e7efe9f3177e49eea52636d4930550c1b`, the hash in the reports.
2. `commit.raw` names root tree `a1d282dabb6364a96c880067ef5ff1f9cadee6ef`, and `sha1("tree <size>\0" + tree.raw)` must equal it.
3. In `tree.raw`, the `contracts` entry is `5ace29538dea65022bcf781a992498d476bf5114`.
4. In the public tag, `contracts/` must hash to the same `5ace29538dea65022bcf781a992498d476bf5114`.

Because each hash covers the full content beneath it, a match at step 4 means every file in `contracts/` is
identical to the audited code.

## Run it

```bash
git clone --branch audit-edbc5f0 https://github.com/Metricxyz/oracle-contracts.git
cd oracle-contracts
python verify/verify.py .
```

Expected output ends with:

```
OK: contracts/ at this tag is identical to contracts/ in audited commit edbc5f0e7efe9f3177e49eea52636d4930550c1b
```

Or by hand with git only:

```bash
git hash-object -t commit verify/commit.raw   # edbc5f0e7efe9f3177e49eea52636d4930550c1b
git hash-object -t tree verify/tree.raw       # a1d282dabb6364a96c880067ef5ff1f9cadee6ef
git hash-object -w -t tree verify/tree.raw    # stores the tree object locally
git ls-tree a1d282dabb6364a96c880067ef5ff1f9cadee6ef contracts   # ... tree 5ace29538dea65022bcf781a992498d476bf5114  contracts
git rev-parse HEAD:contracts              # 5ace29538dea65022bcf781a992498d476bf5114
```

## What is not published

Deployment scripts, internal tooling, CI and examples are left out (`script/`, `scripts/`, `config-ui/`, `contract-registry/`, `AGENTS.md`), and so is `test/debug.t.sol`, a local debugging test with a private RPC URL. Everything else is as in the audited commit, plus this `VERIFY.md` and its `verify/` folder. Only
`contracts/` is claimed identical to the audited commit.

Note: the reports link to `github.com/Oracle-Based-Pool/smart-contracts-poc`, the private repository. It is not public.
