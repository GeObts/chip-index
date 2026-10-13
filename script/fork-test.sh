#!/usr/bin/env bash
# Run the Base-mainnet fork tests with Base's forge (it executes the real B20 precompiles).
# Usage (from WSL):   ./script/fork-test.sh [extra forge args]
# BASE_RPC_URL defaults to the public Base endpoint; set your own for speed.
set -euo pipefail
cd "$(dirname "$0")/.."
export BASE_RPC_URL="${BASE_RPC_URL:-https://mainnet.base.org}"
exec "$HOME/.foundry/bin/base-forge" test --match-path "test/fork/*" "$@"
