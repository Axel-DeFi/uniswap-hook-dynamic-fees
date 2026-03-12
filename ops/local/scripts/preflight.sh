#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
scenario="${OPS_SCENARIO:-bootstrap}"
load_local_config "$scenario"

forge_local "ops/local/foundry/PreflightLocal.s.sol:PreflightLocal" "readonly"
