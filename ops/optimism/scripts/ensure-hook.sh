#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
load_live_config "smoke"

forge_live "ops/shared/foundry/EnsureHookLive.s.sol:EnsureHookLive" "broadcast"
