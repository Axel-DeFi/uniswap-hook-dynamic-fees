#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
scenario="${OPS_SCENARIO:-smoke}"
load_live_config "$scenario"

forge_live "ops/shared/foundry/PreflightLive.s.sol:PreflightLive" "readonly"
