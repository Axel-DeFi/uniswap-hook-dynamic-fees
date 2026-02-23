#!/usr/bin/env bash
set -euo pipefail

# Auto-load local .env (ignored by git) if present.
if [[ -f "./.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "./.env"
  set +a
fi

# Create + initialize the pool using Foundry Solidity script.
#
# Usage:
#   ./scripts/create_pool.sh --chain <chain> [<rpc_url>] [--broadcast] [--verify]
#   ./scripts/create_pool.sh [<rpc_url>] [--broadcast] [--verify]          # uses config/hook.conf
#
# Config:
#   - ./config/hook.<chain>.conf (preferred) or ./config/hook.conf (fallback)
#
# Hook address:
#   - If HOOK_ADDRESS is not set in the config, this script reads it from ./scripts/out/deploy.<chain>.json
#   - If read from JSON, the script persists it back into the config file.
#
# Initial price:
#   - Provide INIT_PRICE_USD (stable per 1 volatile token) in the hook config.
#   - This script converts INIT_PRICE_USD -> INIT_SQRT_PRICE_X96 automatically.

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

CLI_RPC_URL="${RPC_URL}"

HOOK_CONF="./config/hook.conf"
if [[ -n "${CHAIN}" ]]; then
  CHAIN_HOOK_CONF="./config/hook.${CHAIN}.conf"
  if [[ -f "${CHAIN_HOOK_CONF}" ]]; then
    HOOK_CONF="${CHAIN_HOOK_CONF}"
  fi
fi

if [[ ! -f "${HOOK_CONF}" ]]; then
  echo "ERROR: missing ${HOOK_CONF}"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${HOOK_CONF}"
set +a

# Resolve RPC URL: CLI > config RPC_URL
CONFIG_RPC_URL="${RPC_URL:-}"
RPC_URL="${CLI_RPC_URL:-${CONFIG_RPC_URL:-}}"
if [[ -z "${RPC_URL}" ]]; then
  echo "ERROR: RPC URL not provided. Set RPC_URL in ${HOOK_CONF} or pass it as an argument."
  exit 1
fi

if [[ -z "${POOL_MANAGER:-}" ]]; then
  echo "ERROR: POOL_MANAGER must be set in ${HOOK_CONF}"
  exit 1
fi

if [[ -z "${TOKEN0:-}" || -z "${TOKEN1:-}" ]]; then
  echo "ERROR: TOKEN0 and TOKEN1 must be set in ${HOOK_CONF}"
  exit 1
fi

if [[ -z "${TICK_SPACING:-}" ]]; then
  echo "ERROR: TICK_SPACING must be set in ${HOOK_CONF}"
  exit 1
fi

if [[ -z "${STABLE:-}" ]]; then
  echo "ERROR: STABLE must be set in ${HOOK_CONF}"
  exit 1
fi

if [[ -z "${INIT_PRICE_USD:-}" ]]; then
  echo "ERROR: INIT_PRICE_USD must be set in ${HOOK_CONF} (stable per 1 volatile token)"
  exit 1
fi

HAS_BROADCAST=0
HAS_WALLET_FLAG=0
for a in "${PASSTHROUGH[@]}"; do
  case "$a" in
    --broadcast) HAS_BROADCAST=1 ;;
    --private-key|--private-keys|--mnemonics|--mnemonic-passphrases|--mnemonic-derivation-paths|--mnemonic-indexes|--keystore|--account|--ledger|--trezor|--unlocked|--sender)
      HAS_WALLET_FLAG=1
      ;;
  esac
done
if [[ "${HAS_BROADCAST}" -eq 1 && "${HAS_WALLET_FLAG}" -eq 0 && -n "${PRIVATE_KEY:-}" ]]; then
  PASSTHROUGH+=(--private-key "${PRIVATE_KEY}")
fi
if [[ "${HAS_BROADCAST}" -eq 1 && "${HAS_WALLET_FLAG}" -eq 0 && -z "${PRIVATE_KEY:-}" ]]; then
  echo "ERROR: --broadcast requires a signer. Set PRIVATE_KEY/DEFAULT_PRIVATE_KEY or pass a wallet flag."
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

  HOOK_ADDRESS="$(python3 - "${DEPLOY_JSON}" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path,'r',encoding='utf-8') as f:
    data=json.load(f)
print((data.get('hook') or data.get('deploy',{}).get('hook') or '').strip())
PY
  )"

  if [[ -z "${HOOK_ADDRESS}" ]]; then
    echo "ERROR: failed to read hook address from ${DEPLOY_JSON}"
    exit 1
  fi

  export HOOK_ADDRESS

  # Persist it back into the config for convenience (idempotent).
  if grep -qE '^\s*HOOK_ADDRESS=' "${HOOK_CONF}"; then
    sed -i.bak -E "s|^\s*HOOK_ADDRESS=.*$|HOOK_ADDRESS=${HOOK_ADDRESS}|g" "${HOOK_CONF}"
  else
    echo "" >> "${HOOK_CONF}"
    echo "# Hook address (optional). Auto-filled by scripts/create_pool.sh" >> "${HOOK_CONF}"
    echo "HOOK_ADDRESS=${HOOK_ADDRESS}" >> "${HOOK_CONF}"
  fi
  rm -f "${HOOK_CONF}.bak"
  echo "==> Persisted HOOK_ADDRESS into ${HOOK_CONF}"
fi

# Convert INIT_PRICE_USD -> INIT_SQRT_PRICE_X96 using the existing utility.
INIT_SQRT_PRICE_X96="$(./scripts/calc_init_sqrt_price.sh "$(basename "${HOOK_CONF}")" --from-usd --sqrt-only)"
export INIT_SQRT_PRICE_X96

COMMON_ARGS=(--rpc-url "${RPC_URL}" -vvv "${PASSTHROUGH[@]}")

echo "==> INIT_PRICE_USD=${INIT_PRICE_USD} (STABLE=${STABLE})"
echo "==> INIT_SQRT_PRICE_X96=${INIT_SQRT_PRICE_X96}"
echo "==> Creating/initializing pool (scripts/foundry/CreatePool.s.sol) using ${HOOK_CONF}"
forge script scripts/foundry/CreatePool.s.sol "${COMMON_ARGS[@]}"
