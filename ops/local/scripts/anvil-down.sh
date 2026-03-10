#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
ensure_dirs

pid_file="${OPS_LOCAL_DIR}/out/state/anvil.pid"

if [[ ! -f "$pid_file" ]]; then
  echo "anvil is not running (pid file missing)"
  exit 0
fi

pid="$(cat "$pid_file")"
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" || true
  sleep 0.5
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" || true
  fi
  echo "anvil stopped: pid=${pid}"
else
  echo "anvil process already gone: pid=${pid}"
fi

rm -f "$pid_file"
