#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
load_live_config "emergency"
require_live_preflight

forge_live "ops/shared/foundry/RunEmergencyChecksLive.s.sol:RunEmergencyChecksLive" "broadcast"
