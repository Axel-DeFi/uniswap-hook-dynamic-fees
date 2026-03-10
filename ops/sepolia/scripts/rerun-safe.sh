#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
load_sepolia_config "rerun"
ensure_sepolia_drivers

forge_sepolia "ops/sepolia/foundry/RunRerunSafeValidationSepolia.s.sol:RunRerunSafeValidationSepolia" "broadcast"
