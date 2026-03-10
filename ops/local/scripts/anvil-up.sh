#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
load_local_config "bootstrap"

require_cmd anvil
require_cmd curl

pid_file="${OPS_LOCAL_DIR}/out/state/anvil.pid"
log_file="${OPS_LOCAL_DIR}/out/logs/anvil.log"
port="${ANVIL_PORT:-8545}"
rpc_url="${RPC_URL:-http://127.0.0.1:${port}}"

if [[ -f "$pid_file" ]]; then
  old_pid="$(cat "$pid_file")"
  if kill -0 "$old_pid" 2>/dev/null; then
    echo "anvil already running (pid=${old_pid}, port=${port})"
    exit 0
  fi
fi

nohup anvil --chain-id "${CHAIN_ID_EXPECTED:-31337}" --port "$port" --host 127.0.0.1 >"$log_file" 2>&1 &
new_pid=$!
echo "$new_pid" >"$pid_file"

echo "anvil started: pid=${new_pid} port=${port}"
echo "log: $log_file"

retries="${ANVIL_STARTUP_RETRIES:-50}"
for ((i = 1; i <= retries; i++)); do
  if curl -fs --max-time 1 \
    -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    "$rpc_url" >/dev/null; then
    echo "anvil ready: ${rpc_url}"
    exit 0
  fi

  if ! kill -0 "$new_pid" 2>/dev/null; then
    echo "ERROR: anvil exited before becoming ready" >&2
    tail -n 40 "$log_file" >&2 || true
    rm -f "$pid_file"
    exit 1
  fi

  sleep 0.2
done

echo "ERROR: anvil RPC not ready after ${retries} attempts (${rpc_url})" >&2
tail -n 40 "$log_file" >&2 || true
kill "$new_pid" 2>/dev/null || true
rm -f "$pid_file"
exit 1
