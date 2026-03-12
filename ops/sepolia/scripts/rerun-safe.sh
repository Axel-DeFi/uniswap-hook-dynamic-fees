#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
load_live_config "rerun"
require_live_preflight
ensure_live_drivers

forge_live "ops/shared/foundry/RunRerunSafeValidationLive.s.sol:RunRerunSafeValidationLive" "broadcast"
