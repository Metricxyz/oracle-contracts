#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Full offline integration run for both pusher lanes: anvil -> deploy -> every
# compressed script (01..06, 04 bounded) + stale-ignore negative case -> pyth file-mode
# relay (10). Script 11 (WS) is not runnable offline; it shares its relay core with 10.
# Exits non-zero on ANY failure. This IS the CI integration test (npm run demo).
#
# Purpose: the single end-to-end rehearsal that proves the whole package
# (both oracle lanes, all scripts, the ethers v6 client plumbing) works
# against a REAL chain, not just against unit-level pinned vectors. `npm run
# demo` is this file; a green run is the acceptance bar for any change here.
#
# What happens: starts a throwaway anvil node on ANVIL_PORT (default 8570),
# deploys both oracles via DeployDemo.s.sol, exports the deployed addresses,
# then drives the compressed lane (derive -> delegate -> push-once ->
# stale-ignore negative case -> bounded production loop -> price guard ->
# signed-update relay) followed by the pyth lane (build a demo-signed Lazer
# envelope, relay it via script 10's file mode). Any script exiting non-zero
# (via `set -euo pipefail`) aborts the whole run; the EXIT trap always kills
# the anvil process and removes the temp envelope file.
#
# Env: ANVIL_PORT (optional, default 8570). Everything else (RPC_URL,
# CREATOR_PRIVATE_KEY, PUSHER_PRIVATE_KEY, SLOT_INDEX,
# COMPRESSED_ORACLE_ADDRESS, PYTH_ORACLE_ADDRESS, LAZER_UPDATE_FILE,
# LAZER_FEED_IDS) is derived/exported by this script itself for the child
# `npx tsx` processes.
#
# Place in the package: `npm run demo` runs exactly this file; it is the
# non-negotiable green-twice gate for any change under examples/mm-pusher-ts.
set -euo pipefail
cd "$(dirname "$0")/.."             # examples/mm-pusher-ts
REPO_ROOT="$(cd ../.. && pwd)"

PORT="${ANVIL_PORT:-8570}"
export RPC_URL="http://127.0.0.1:${PORT}"
# anvil's deterministic accounts: #0 deployer, #1 creator (cold), #2 pusher (hot)
DEPLOY_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export CREATOR_PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
export PUSHER_PRIVATE_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
CREATOR_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
export SLOT_INDEX=0

echo "── starting anvil on :${PORT}"
anvil --port "${PORT}" --silent &
ANVIL_PID=$!
trap 'kill ${ANVIL_PID} 2>/dev/null || true; rm -f "${LAZER_UPDATE_FILE:-}"' EXIT
for _ in $(seq 1 50); do
  cast chain-id --rpc-url "${RPC_URL}" >/dev/null 2>&1 && break
  sleep 0.2
done

echo "── deploying both lanes"
ADDR_JSON=$(cd "${REPO_ROOT}" && forge script examples/mm-pusher-ts/demo/DeployDemo.s.sol \
  --rpc-url "${RPC_URL}" --broadcast --private-key "${DEPLOY_KEY}" -vv | grep -o '{"compressedOracle".*}')
echo "${ADDR_JSON}"
COMPRESSED_ORACLE_ADDRESS=$(node -e "console.log(JSON.parse(process.argv[1]).compressedOracle)" "${ADDR_JSON}")
export COMPRESSED_ORACLE_ADDRESS
PYTH_ORACLE_ADDRESS=$(node -e "console.log(JSON.parse(process.argv[1]).pythOracle)" "${ADDR_JSON}")
export PYTH_ORACLE_ADDRESS

echo "── compressed lane: 01 derive + on-chain cross-check"
npx tsx scripts/01-derive-feed-id.ts

echo "── compressed lane: 02 delegate pusher -> creator namespace"
npx tsx scripts/02-authorize-pusher.ts

echo "── compressed lane: 03 push once WITH THE DELEGATED PUSHER KEY (readback via creator feedId)"
CREATOR_ADDRESS="${CREATOR_ADDRESS}" npx tsx scripts/03-push-once.ts

echo "── compressed lane: stale word is silently ignored"
CREATOR_ADDRESS="${CREATOR_ADDRESS}" npx tsx demo/assert-stale-ignored.ts

echo "── compressed lane: 04 bounded production loop (2 iterations)"
CREATOR_ADDRESS="${CREATOR_ADDRESS}" MAX_ITERATIONS=2 PUSH_INTERVAL_MS=200 VERIFY_READBACK=1 \
  npx tsx scripts/04-run-pusher.ts

echo "── compressed lane: 05 price guard (creator key)"
GUARD_MIN=5000000000000 GUARD_MAX=9000000000000 npx tsx scripts/05-set-price-guard.ts

echo "── compressed lane: 06 creator-signed word relayed by the pusher key"
npx tsx scripts/06-update-by-signature.ts

echo "── pyth lane: build demo update (demo signer) + 10 relay in file mode"
LAZER_UPDATE_FILE="$(mktemp)"
export LAZER_UPDATE_FILE
export LAZER_FEED_IDS=1,2
npx tsx demo/build-demo-update.ts
npx tsx scripts/10-pyth-push-once.ts

echo "── demo OK: both lanes verified against locally deployed contracts"
