#!/usr/bin/env bash
set -euo pipefail

# Create + initialize the pool using Foundry Solidity script.
#
# Usage:
#   ./scripts/create_pool.sh --chain <chain> [<rpc_url>] [--broadcast] [--verify]
#   ./scripts/create_pool.sh [<rpc_url>] [--broadcast] [--verify]          # uses config/pool.conf
#
# Config:
#   - ./config/pool.<chain>.conf (preferred) or ./config/pool.conf (fallback)
# Hook address:
#   - If HOOK_ADDRESS is not set in the config, this script reads it from ./scripts/out/deploy.<chain>.json
#   - If read from JSON, the script can also persist it back into the config file.

CHAIN=""
RPC_URL=""
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain)
      CHAIN="${2:-}"
      if [[ -z "${CHAIN}" ]]; then echo "ERROR: --chain requires a value"; exit 1; fi
      shift 2
      ;;
    --rpc-url)
      RPC_URL="${2:-}"
      if [[ -z "${RPC_URL}" ]]; then echo "ERROR: --rpc-url requires a value"; exit 1; fi
      shift 2
      ;;
    -*)
      PASSTHROUGH+=("$1")
      shift
      ;;
    *)
      if [[ -z "${RPC_URL}" ]]; then
        RPC_URL="$1"
        shift
      else
        PASSTHROUGH+=("$1")
        shift
      fi
      ;;
  esac
done

POOL_CONF="./config/pool.conf"
if [[ -n "${CHAIN}" ]]; then
  POOL_CONF="./config/pool.${CHAIN}.conf"
fi

if [[ ! -f "${POOL_CONF}" ]]; then
  echo "ERROR: missing ${POOL_CONF}"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${POOL_CONF}"
set +a

# Resolve RPC URL: CLI > config RPC_URL
if [[ -z "${RPC_URL}" ]]; then
  RPC_URL="${RPC_URL:-}"
fi
if [[ -z "${RPC_URL}" ]]; then
  echo "ERROR: RPC URL not provided. Set RPC_URL in ${POOL_CONF} or pass it as an argument."
  exit 1
fi

if [[ -z "${HOOK_ADDRESS:-}" ]]; then
  DEPLOY_JSON="./scripts/out/deploy.json"
  if [[ -n "${CHAIN}" ]]; then
    DEPLOY_JSON="./scripts/out/deploy.${CHAIN}.json"
  fi
  if [[ ! -f "${DEPLOY_JSON}" ]]; then
    echo "ERROR: HOOK_ADDRESS not set and ${DEPLOY_JSON} not found"
    exit 1
  fi

  HOOK_ADDRESS="$(python3 - <<'PY'
import json
import sys
path = sys.argv[1]
with open(path,'r',encoding='utf-8') as f:
    data=json.load(f)
print(data.get('deploy',{}).get('hook',''))
PY
"${DEPLOY_JSON}")"

  if [[ -z "${HOOK_ADDRESS}" ]]; then
    echo "ERROR: failed to read hook address from ${DEPLOY_JSON}"
    exit 1
  fi

  export HOOK_ADDRESS

  # Persist it back into the config for convenience (idempotent).
  if grep -qE '^\s*HOOK_ADDRESS=' "${POOL_CONF}"; then
    # replace existing line
    sed -i.bak -E "s|^\s*HOOK_ADDRESS=.*$|HOOK_ADDRESS=${HOOK_ADDRESS}|g" "${POOL_CONF}"
  else
    echo "" >> "${POOL_CONF}"
    echo "HOOK_ADDRESS=${HOOK_ADDRESS}" >> "${POOL_CONF}"
  fi
  rm -f "${POOL_CONF}.bak"
  echo "==> Persisted HOOK_ADDRESS into ${POOL_CONF}"
fi

COMMON_ARGS=(--rpc-url "${RPC_URL}" -vvv "${PASSTHROUGH[@]}")

echo "==> Creating/initializing pool (scripts/foundry/CreatePool.s.sol) using ${POOL_CONF}"
forge script scripts/foundry/CreatePool.s.sol "${COMMON_ARGS[@]}"
