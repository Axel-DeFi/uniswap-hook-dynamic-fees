#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

ensure_dirs
rm -f "${OPS_LOCAL_DIR}/out/state/"*.json "${OPS_LOCAL_DIR}/out/reports/"*.json "${OPS_LOCAL_DIR}/out/logs/"*.log

echo "local state/reports/logs reset"
