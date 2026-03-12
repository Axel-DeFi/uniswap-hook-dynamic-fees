#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
load_local_config "bootstrap"

forge_local "ops/local/foundry/StartAnvilState.s.sol:StartAnvilState" "broadcast"
load_state_env
forge_local "ops/local/foundry/DeployHookLocal.s.sol:DeployHookLocal" "broadcast"
load_state_env
forge_local "ops/local/foundry/EnsurePoolLocal.s.sol:EnsurePoolLocal" "broadcast"
forge_local "ops/local/foundry/EnsureLiquidityLocal.s.sol:EnsureLiquidityLocal" "broadcast"
