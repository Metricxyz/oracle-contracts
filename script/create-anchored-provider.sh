#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Create ONE Anchored Price Provider through the deployed AnchoredProviderFactory on ONE network.
# Run it from the repository root, where it reads ./.env.
# Thin wrapper over script/CreateAnchoredProvider.s.sol — the params come from env vars (see that
# script's header). The base feed does not need data yet: creation succeeds without reading the
# oracle. Until the feed's first update lands, reads revert FeedNotFound from a PythOracle,
# ChainlinkOracle or MultiplierOracle reference, and FeedStalled from the provider on a
# CompressedOracleV1 feed (it reads as zeros, i.e. stale) — see Step 2 of
# docs/anchored-price-provider-quickstart.md. The caller (PRIVATE_KEY) becomes the provider
# owner; the params must sit inside the factory's envelope for the feed's class.
#
# NETWORK is a Foundry RPC alias from foundry.toml (set its RPC_* variable); the factory and oracle
# addresses come from docs/DEPLOYMENTS.md.
#
#   # dry-run (simulate, nothing sent):
#   NETWORK=base ANCHORED_PROVIDER_FACTORY=0x… \
#     REFERENCE_ORACLE=0x… BASE_FEED_ID=397 \
#     BASE_TOKEN=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
#     QUOTE_TOKEN=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
#     MIN_MARGIN=100000000000000 MAX_REF_STALENESS=60 \
#     PRIVATE_KEY=0x... ./script/create-anchored-provider.sh
#
#   # broadcast for real:
#   ... BROADCAST=1 ./script/create-anchored-provider.sh
#
#   # fully configured at construction (custom source + a 2x base multiplier + tighter base leg):
#   NETWORK=base ANCHORED_PROVIDER_FACTORY=0x… REFERENCE_ORACLE=0x… BASE_FEED_ID=397 \
#     BASE_TOKEN=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
#     QUOTE_TOKEN=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
#     MIN_MARGIN=100000000000000 MAX_REF_STALENESS=60 \
#     MAX_SPREAD_MULT=2000000000000000000 BASE_SPREAD_MULT=2000000000000000000 BASE_MAX_STALENESS=30 \
#     SOURCE=0xYourCuratorSource \
#     PRIVATE_KEY=0x... BROADCAST=1 ./script/create-anchored-provider.sh
#
# Optional env (defaults): QUOTE_FEED_ID=0 · MAX_SPREAD_MULT=1e18 · MUTABLE_PARAMS=false · MARGIN_STEP=0
# Optional initial config, applied at construction (defaults: plain 1.0×/shared-staleness configuration):
#   SOURCE=0 · BASE_MAX_STALENESS / QUOTE_MAX_STALENESS = MAX_REF_STALENESS
#   · BASE_SPREAD_MULT / QUOTE_SPREAD_MULT = 1e18 (< 1e18 tightens, up to MAX_SPREAD_MULT widens)
set -euo pipefail
# Load ./.env when present. Variables already set in the environment
# (exported or passed on the command line) keep their values; .env only fills the unset ones.
if [ -f .env ]; then
  _preset=""
  for _name in $(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' .env); do
    if [ -n "${!_name+x}" ]; then _preset+="$(declare -p "$_name")"$'\n'; fi
  done
  set -a; . ./.env; set +a
  eval "$_preset"
  unset _preset _name
fi
: "${PRIVATE_KEY:?set PRIVATE_KEY (creator = provider owner)}"
: "${NETWORK:?set NETWORK (Foundry RPC alias from foundry.toml, e.g. base)}"
: "${ANCHORED_PROVIDER_FACTORY:?set ANCHORED_PROVIDER_FACTORY (docs/DEPLOYMENTS.md)}"
: "${REFERENCE_ORACLE:?set REFERENCE_ORACLE (docs/DEPLOYMENTS.md)}"

BROADCAST_FLAG=""
[ "${BROADCAST:-0}" = "1" ] && BROADCAST_FLAG="--broadcast"

forge script script/CreateAnchoredProvider.s.sol --rpc-url "$NETWORK" $BROADCAST_FLAG

if [ -z "$BROADCAST_FLAG" ]; then
  echo "dry-run only — re-run with BROADCAST=1 to create the provider on-chain."
fi
