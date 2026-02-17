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

# If running in dry-run mode (no --broadcast), skip pool creation to avoid confusing failures.
HAS_BROADCAST=0
for a in "${PASSTHROUGH[@]}"; do
  if [[ "$a" == "--broadcast" ]]; then HAS_BROADCAST=1; break; fi
done

if [[ -n "${RPC_URL}" ]]; then
  ./scripts/deploy_hook.sh "${CHAIN_ARGS[@]}" "${RPC_URL}" "${PASSTHROUGH[@]}"
  if [[ "${HAS_BROADCAST}" -eq 1 || "${FORCE_CREATE_POOL_DRYRUN:-0}" -eq 1 ]]; then
    ./scripts/create_pool.sh "${CHAIN_ARGS[@]}" "${RPC_URL}" "${PASSTHROUGH[@]}"
  else
    echo "==> Dry-run detected (no --broadcast). Skipping pool creation. Run create_pool.sh separately or re-run with --broadcast."
  fi
else
  ./scripts/deploy_hook.sh "${CHAIN_ARGS[@]}" "${PASSTHROUGH[@]}"
  if [[ "${HAS_BROADCAST}" -eq 1 || "${FORCE_CREATE_POOL_DRYRUN:-0}" -eq 1 ]]; then
    ./scripts/create_pool.sh "${CHAIN_ARGS[@]}" "${PASSTHROUGH[@]}"
  else
    echo "==> Dry-run detected (no --broadcast). Skipping pool creation. Run create_pool.sh separately or re-run with --broadcast."
  fi
fi
