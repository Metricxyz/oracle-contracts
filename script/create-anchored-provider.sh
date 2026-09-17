#!/usr/bin/env bash
# Create ONE Anchored Price Provider through the deployed AnchoredProviderFactory on ONE network.
# Thin wrapper over script/CreateAnchoredProvider.s.sol — the params come from env vars (see that
# script's header). The base feed does not need data yet: creation succeeds without reading the
# oracle, and reads revert (FeedNotFound from the reference oracle) until the feed's first update lands —
# see Step 1 of docs/anchored-price-provider-quickstart.md. The caller (PRIVATE_KEY) becomes the provider
# owner; the params must sit inside the factory's envelope for the feed's class.
#
#   # dry-run (simulate, nothing sent):
#   NETWORK=base BASE_FEED_ID=397 \
#     BASE_TOKEN=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
#     QUOTE_TOKEN=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
#     MIN_MARGIN=100000000000000 MAX_REF_STALENESS=60 \
#     PRIVATE_KEY=0x... ./script/create-anchored-provider.sh
#
#   # broadcast for real:
#   ... BROADCAST=1 ./script/create-anchored-provider.sh
#
#   # fully configured at construction (custom source + a 2x base multiplier + tighter base leg):
#   NETWORK=base BASE_FEED_ID=397 \
#     BASE_TOKEN=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
#     QUOTE_TOKEN=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
#     MIN_MARGIN=100000000000000 MAX_REF_STALENESS=60 \
#     MAX_SPREAD_MULT=2000000000000000000 BASE_SPREAD_MULT=2000000000000000000 BASE_MAX_STALENESS=30 \
#     SOURCE=0xYourCuratorSource \
#     PRIVATE_KEY=0x... BROADCAST=1 ./script/create-anchored-provider.sh
#
# Optional env (defaults): REFERENCE=pyth|chainlink · REFERENCE_ORACLE=0x… (overrides REFERENCE)
#   · ANCHORED_PROVIDER_FACTORY=0x… (overrides networks.json deployments.anchoredProviderFactory)
#   · QUOTE_FEED_ID=0 · MAX_SPREAD_MULT=1e18 · MUTABLE_PARAMS=false · MARGIN_STEP=0
# Optional initial config, applied at construction (defaults: plain 1.0×/shared-staleness configuration):
#   SOURCE=0 · BASE_MAX_STALENESS / QUOTE_MAX_STALENESS = MAX_REF_STALENESS
#   · BASE_SPREAD_MULT / QUOTE_SPREAD_MULT = 1e18 (< 1e18 tightens, up to MAX_SPREAD_MULT widens)
set -euo pipefail
: "${PRIVATE_KEY:?set PRIVATE_KEY (creator = provider owner)}"
: "${NETWORK:?set NETWORK (key into script/config/networks.json, e.g. base)}"

BROADCAST_FLAG=""
[ "${BROADCAST:-0}" = "1" ] && BROADCAST_FLAG="--broadcast"

forge script script/CreateAnchoredProvider.s.sol --rpc-url "$NETWORK" $BROADCAST_FLAG

[ -z "$BROADCAST_FLAG" ] && echo "dry-run only — re-run with BROADCAST=1 to create the provider on-chain."
