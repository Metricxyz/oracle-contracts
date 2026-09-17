#!/usr/bin/env bash
# Create ONE plain Price Provider through the deployed PriceProviderFactory on ONE network.
# Thin wrapper over script/CreatePriceProvider.s.sol — the params come from env vars (see that
# script's header). Creation is unconditionally permissionless (no admin allow-list/envelope, unlike
# AnchoredProviderFactory): the caller (PRIVATE_KEY) becomes the provider owner regardless of the
# oracle/feed/params chosen. PriceProviderFactory is deployed on ethereum only — see
# ../DEPLOYMENTS.md.
#
#   # dry-run (simulate, nothing sent):
#   NETWORK=ethereum FEED_ID=397 \
#     BASE_TOKEN=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
#     QUOTE_TOKEN=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
#     MARGIN_STEP=0 MAX_TIME_DELTA=60 \
#     PRIVATE_KEY=0x... ./script/create-price-provider.sh
#
#   # broadcast for real:
#   ... BROADCAST=1 ./script/create-price-provider.sh
#
# Optional env (defaults): REFERENCE=compressed|pyth|chainlink (default compressed)
#   · REFERENCE_ORACLE=0x… (overrides REFERENCE)
#   · PRICE_PROVIDER_FACTORY=0x… (overrides networks.json deployments.priceProviderFactory)
set -euo pipefail
: "${PRIVATE_KEY:?set PRIVATE_KEY (creator = provider owner)}"
: "${NETWORK:?set NETWORK (key into script/config/networks.json, e.g. ethereum)}"

BROADCAST_FLAG=""
[ "${BROADCAST:-0}" = "1" ] && BROADCAST_FLAG="--broadcast"

forge script script/CreatePriceProvider.s.sol --rpc-url "$NETWORK" $BROADCAST_FLAG

[ -z "$BROADCAST_FLAG" ] && echo "dry-run only — re-run with BROADCAST=1 to create the provider on-chain."
