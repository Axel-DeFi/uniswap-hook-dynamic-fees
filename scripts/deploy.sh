#!/usr/bin/env bash
set -euo pipefail

# One-shot deployment: deploy hook, then create + initialize pool.
#
# Usage:
#   ./scripts/deploy.sh --chain <chain> [<rpc_url>] [--broadcast] [--verify]
#   ./scripts/deploy.sh [<rpc_url>] [--broadcast] [--verify]

CHAIN_ARGS=()

if [[ "${1:-}" == "--chain" ]]; then
  CHAIN_ARGS=(--chain "${2:-}")
  shift 2
fi

# Optional RPC url (positional). If omitted, config RPC_URL is used.
RPC_URL="${1:-}"
if [[ -n "${RPC_URL}" && "${RPC_URL}" != --* ]]; then
  shift
else
  RPC_URL=""
fi

PASSTHROUGH=("$@")

if [[ -n "${RPC_URL}" ]]; then
  ./scripts/deploy_hook.sh "${CHAIN_ARGS[@]}" "${RPC_URL}" "${PASSTHROUGH[@]}"
  ./scripts/create_pool.sh "${CHAIN_ARGS[@]}" "${RPC_URL}" "${PASSTHROUGH[@]}"
else
  ./scripts/deploy_hook.sh "${CHAIN_ARGS[@]}" "${PASSTHROUGH[@]}"
  ./scripts/create_pool.sh "${CHAIN_ARGS[@]}" "${PASSTHROUGH[@]}"
fi
