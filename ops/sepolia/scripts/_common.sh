#!/usr/bin/env bash
set -euo pipefail

export OPS_NETWORK="sepolia"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../shared/scripts/live_common.sh"
