#!/usr/bin/env bash
set -euo pipefail

# Deploy the hook (CREATE2 mined for permission bits) using Foundry Solidity script.
#
# Usage:
#   ./scripts/deploy_hook.sh --chain <chain> [<rpc_url>] [--broadcast] [--verify]
#   ./scripts/deploy_hook.sh [<rpc_url>] [--broadcast] [--verify]          # uses config/hook.conf
#
# Config:
#   - ./config/hook.<chain>.conf (preferred) or ./config/hook.conf (fallback)
# Output:
#   - ./scripts/out/deploy.<chain>.json (or ./scripts/out/deploy.json if chain not set)
#
# Notes:
# - If RPC_URL is set in the config, you can omit <rpc_url> on the CLI.
# - This script sets DEPLOY_JSON_PATH for the Solidity script, so the output path is deterministic.

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
      # positional rpc url (optional)
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

HOOK_CONF="./config/hook.conf"
if [[ -n "${CHAIN}" ]]; then
  HOOK_CONF="./config/hook.${CHAIN}.conf"
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
if [[ -z "${RPC_URL}" ]]; then
  RPC_URL="${RPC_URL:-}"
fi
if [[ -z "${RPC_URL}" ]]; then
  echo "ERROR: RPC URL not provided. Set RPC_URL in ${HOOK_CONF} or pass it as an argument."
  exit 1
fi


# Optional safety: verify STABLE_DECIMALS matches the token's on-chain decimals().
# Set SKIP_DECIMALS_CHECK=1 to bypass.
if [[ "${SKIP_DECIMALS_CHECK:-0}" != "1" ]]; then
  if [[ -z "${STABLE:-}" || -z "${STABLE_DECIMALS:-}" ]]; then
    echo "ERROR: STABLE and STABLE_DECIMALS must be set in ${HOOK_CONF}"
    exit 1
  fi

  echo "==> Checking stable decimals for ${STABLE} ..."
  ONCHAIN_DECIMALS="$(cast call "${STABLE}" "decimals()(uint8)" --rpc-url "${RPC_URL}" 2>/dev/null || true)"
  ONCHAIN_DECIMALS="$(echo "${ONCHAIN_DECIMALS}" | tr -d '\r' | tr -d '\n' | xargs)"
  if [[ -z "${ONCHAIN_DECIMALS}" ]]; then
    echo "ERROR: failed to read decimals() for STABLE=${STABLE}. If this token does not implement decimals(), set SKIP_DECIMALS_CHECK=1."
    exit 1
  fi
  if [[ "${ONCHAIN_DECIMALS}" != "${STABLE_DECIMALS}" ]]; then
    echo "ERROR: STABLE_DECIMALS=${STABLE_DECIMALS} does not match on-chain decimals()=${ONCHAIN_DECIMALS} for STABLE=${STABLE}"
    exit 1
  fi
fi

OUT_PATH="./scripts/out/deploy.json"
if [[ -n "${CHAIN}" ]]; then
  OUT_PATH="./scripts/out/deploy.${CHAIN}.json"
fi

mkdir -p ./scripts/out
export DEPLOY_JSON_PATH="${OUT_PATH}"

COMMON_ARGS=(--rpc-url "${RPC_URL}" -vvv "${PASSTHROUGH[@]}")

echo "==> Deploying hook (scripts/foundry/DeployHook.s.sol) using ${HOOK_CONF}"
forge script scripts/foundry/DeployHook.s.sol "${COMMON_ARGS[@]}"

if [[ ! -f "${OUT_PATH}" ]]; then
  echo "ERROR: expected ${OUT_PATH} to be created"
  exit 1
fi

echo "==> Wrote ${OUT_PATH}"
