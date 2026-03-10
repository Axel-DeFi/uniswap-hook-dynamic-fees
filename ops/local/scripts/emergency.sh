#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
load_local_config "emergency"

forge_local "ops/local/foundry/RunEmergencyChecksLocal.s.sol:RunEmergencyChecksLocal" "broadcast"
