#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
load_sepolia_config "smoke"

forge_sepolia "ops/sepolia/foundry/EnsureHookSepolia.s.sol:EnsureHookSepolia" "broadcast"
