#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
scenario="${OPS_SCENARIO:-smoke}"
load_sepolia_config "$scenario"

forge_sepolia "ops/sepolia/foundry/InspectSepoliaState.s.sol:InspectSepoliaState" "readonly"
