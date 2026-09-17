#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Regenerates test/vectors.json from the repo's own Solidity. Run from anywhere.
#
# Purpose: the ONE way test/vectors.json is meant to change — by re-deriving
# it from GenerateVectors.s.sol, never by hand-editing the JSON. This keeps
# the TS package's byte-identity pins honest: they always trace back to a
# Solidity computation, not to a value someone typed in to make a test pass.
#
# What happens: cd's to the repo root (so `forge script` sees the full
# workspace), runs GenerateVectors.s.sol, greps its one JSON stdout line out
# of forge's verbose (-vv) trace output, and overwrites
# examples/mm-pusher-ts/test/vectors.json with it.
#
# Inputs/outputs/env: no env vars; reads nothing but the Solidity source.
# Output: overwrites test/vectors.json and echoes its new contents.
#
# Place in the package: `npm run vectors:regen` runs exactly this file. NOT
# part of `npm test`/`npm run demo` — those CONSUME test/vectors.json, they
# never regenerate it; this script is a manual/deliberate action only.
set -euo pipefail
cd "$(dirname "$0")/../../.."   # repo root
forge script examples/mm-pusher-ts/demo/GenerateVectors.s.sol -vv |
  grep -o '{"lazerEnvelope".*}' > examples/mm-pusher-ts/test/vectors.json
cat examples/mm-pusher-ts/test/vectors.json
