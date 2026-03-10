#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
load_local_config "full"

forge_local "ops/local/foundry/RunFullValidationLocal.s.sol:RunFullValidationLocal" "broadcast"
