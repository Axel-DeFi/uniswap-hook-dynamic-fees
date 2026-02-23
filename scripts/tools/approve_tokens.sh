#!/usr/bin/env bash
set -euo pipefail

# Approve token0/token1 for a spender (or both test helpers).
#
# Usage:
#   ./scripts/tools/approve_tokens.sh --spender <address>
#   ./scripts/tools/approve_tokens.sh --spender both --chain ethereum

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

CHAIN="ethereum"
SPENDER=""
AMOUNT="${AMOUNT:-0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --spender) SPENDER="${2:-}"; shift 2 ;;
    --amount) AMOUNT="${2:-}"; shift 2 ;;
    --rpc-url) RPC_URL="${2:-}"; shift 2 ;;
    --private-key) PRIVATE_KEY="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${SPENDER}" ]]; then
  echo "ERROR: --spender is required (address | modify | swap | both)" >&2
  exit 1
fi

load_hook_config "${CHAIN}"
resolve_private_key
resolve_rpc

MOD_ADDR="$(default_modify_test_address "${CHAIN}")"
SWAP_ADDR="$(default_swap_test_address "${CHAIN}")"

declare -a SPENDERS=()
case "${SPENDER}" in
  modify) [[ -n "${MOD_ADDR}" ]] && SPENDERS+=("${MOD_ADDR}") ;;
  swap) [[ -n "${SWAP_ADDR}" ]] && SPENDERS+=("${SWAP_ADDR}") ;;
  both)
    [[ -n "${MOD_ADDR}" ]] && SPENDERS+=("${MOD_ADDR}")
    [[ -n "${SWAP_ADDR}" ]] && SPENDERS+=("${SWAP_ADDR}")
    ;;
  0x*) SPENDERS+=("${SPENDER}") ;;
  *) echo "ERROR: invalid --spender value: ${SPENDER}" >&2; exit 1 ;;
esac

if [[ "${#SPENDERS[@]}" -eq 0 ]]; then
  echo "ERROR: no spender resolved for chain=${CHAIN}" >&2
  exit 1
fi

for s in "${SPENDERS[@]}"; do
  echo "==> Approve token0=${TOKEN0} -> ${s}"
  cast_rpc send --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" "${TOKEN0}" \
    "approve(address,uint256)(bool)" "${s}" "${AMOUNT}"
  echo "==> Approve token1=${TOKEN1} -> ${s}"
  cast_rpc send --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" "${TOKEN1}" \
    "approve(address,uint256)(bool)" "${s}" "${AMOUNT}"
done

