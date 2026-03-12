#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
scenario="${OPS_SCENARIO:-smoke}"
load_local_config "$scenario"

forge_local "ops/local/foundry/InspectLocalState.s.sol:InspectLocalState" "readonly"
