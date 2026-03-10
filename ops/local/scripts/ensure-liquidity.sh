#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
load_local_config "bootstrap"

forge_local "ops/local/foundry/EnsureLiquidityLocal.s.sol:EnsureLiquidityLocal" "broadcast"
