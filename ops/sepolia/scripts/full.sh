#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
load_sepolia_config "full"
require_sepolia_preflight
ensure_sepolia_drivers

forge_sepolia "ops/sepolia/foundry/RunFullValidationSepolia.s.sol:RunFullValidationSepolia" "broadcast"
