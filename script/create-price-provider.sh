#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Create ONE plain Price Provider through the deployed PriceProviderFactory on ONE network.
# Run it from the repository root, where it reads ./.env.
# Thin wrapper over script/CreatePriceProvider.s.sol — the params come from env vars (see that
# script's header). Creation is permissionless (no admin allow-list/envelope, unlike
# AnchoredProviderFactory): anyone can create a provider and the caller (PRIVATE_KEY) becomes its
# owner. The provider's constructor still bounds the inputs: MARGIN_STEP strictly between -1e18
# and 1e18, MAX_TIME_DELTA in 1..604800 seconds, BASE_TOKEN and QUOTE_TOKEN nonzero and distinct.
# Creation does not read the oracle or check the feed. Chain availability is in docs/DEPLOYMENTS.md.
#
# NETWORK is a Foundry RPC alias from foundry.toml (set its RPC_* variable); the factory and oracle
# addresses come from docs/DEPLOYMENTS.md.
#
#   # dry-run (simulate, nothing sent):
#   NETWORK=ethereum PRICE_PROVIDER_FACTORY=0x… \
#     REFERENCE_ORACLE=0x… FEED_ID=397 \
#     BASE_TOKEN=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf \
#     QUOTE_TOKEN=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
#     MARGIN_STEP=0 MAX_TIME_DELTA=60 \
#     PRIVATE_KEY=0x... ./script/create-price-provider.sh
#
#   # broadcast for real:
#   ... BROADCAST=1 ./script/create-price-provider.sh
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
: "${NETWORK:?set NETWORK (Foundry RPC alias from foundry.toml, e.g. ethereum)}"
: "${PRICE_PROVIDER_FACTORY:?set PRICE_PROVIDER_FACTORY (docs/DEPLOYMENTS.md)}"
: "${REFERENCE_ORACLE:?set REFERENCE_ORACLE (docs/DEPLOYMENTS.md)}"

BROADCAST_FLAG=""
[ "${BROADCAST:-0}" = "1" ] && BROADCAST_FLAG="--broadcast"

forge script script/CreatePriceProvider.s.sol --rpc-url "$NETWORK" $BROADCAST_FLAG

if [ -z "$BROADCAST_FLAG" ]; then
  echo "dry-run only — re-run with BROADCAST=1 to create the provider on-chain."
fi
