#!/usr/bin/env bash
set -euo pipefail

# Execute a manual swap via PoolSwapTest.
#
# Usage:
#   ./scripts/tools/swap.sh --amount 1000000 --zero-for-one true
#   ./scripts/tools/swap.sh --amount 1000 --zero-for-one false --sqrt-limit 1461446703485210103287273052203988822378723970341
#
# Note:
# - amount is amountSpecified passed to pool swap params.
# - For exact-input use a negative amount internally (this script does it automatically).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

CHAIN="ethereum"
AMOUNT=""
ZERO_FOR_ONE="true"
SALT_HOOK_DATA="0x"
SWAP_TEST_ADDRESS="${SWAP_TEST_ADDRESS:-}"
HOOK_ADDRESS_OVERRIDE=""
SQRT_LIMIT_ZERO_FOR_ONE="4295128740"
SQRT_LIMIT_ONE_FOR_ZERO="1461446703485210103287273052203988822378723970341"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --amount) AMOUNT="${2:-}"; shift 2 ;;
    --zero-for-one) ZERO_FOR_ONE="${2:-}"; shift 2 ;;
    --swap-test-address) SWAP_TEST_ADDRESS="${2:-}"; shift 2 ;;
    --hook-address) HOOK_ADDRESS_OVERRIDE="${2:-}"; shift 2 ;;
    --hook-data) SALT_HOOK_DATA="${2:-}"; shift 2 ;;
    --sqrt-limit)
      if [[ "${ZERO_FOR_ONE}" == "true" ]]; then
        SQRT_LIMIT_ZERO_FOR_ONE="${2:-}"
      else
        SQRT_LIMIT_ONE_FOR_ZERO="${2:-}"
      fi
      shift 2
      ;;
    --rpc-url) RPC_URL="${2:-}"; shift 2 ;;
    --private-key) PRIVATE_KEY="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${AMOUNT}" ]]; then
  echo "ERROR: --amount is required" >&2
  exit 1
fi

load_pool_config "${CHAIN}"
resolve_private_key
resolve_rpc

if [[ -n "${HOOK_ADDRESS_OVERRIDE}" ]]; then
  HOOK_ADDRESS="${HOOK_ADDRESS_OVERRIDE}"
fi
if [[ -z "${HOOK_ADDRESS:-}" ]]; then
  echo "ERROR: HOOK_ADDRESS is empty in config; set it or pass --hook-address." >&2
  exit 1
fi

if [[ -z "${SWAP_TEST_ADDRESS}" ]]; then
  SWAP_TEST_ADDRESS="$(default_swap_test_address "${CHAIN}")"
fi
if [[ -z "${SWAP_TEST_ADDRESS}" ]]; then
  echo "ERROR: swap test helper is unknown for chain=${CHAIN}, pass --swap-test-address." >&2
  exit 1
fi

TOKENS=($(canonical_token_order "${TOKEN0}" "${TOKEN1}"))
C0="${TOKENS[0]}"
C1="${TOKENS[1]}"

AMOUNT_SPECIFIED="-${AMOUNT}"
if [[ "${ZERO_FOR_ONE}" == "true" ]]; then
  SQRT_LIMIT="${SQRT_LIMIT_ZERO_FOR_ONE}"
else
  SQRT_LIMIT="${SQRT_LIMIT_ONE_FOR_ZERO}"
fi

echo "==> swap via ${SWAP_TEST_ADDRESS}"
echo "    key=(${C0},${C1},8388608,${TICK_SPACING},${HOOK_ADDRESS})"
echo "    params=(${ZERO_FOR_ONE},${AMOUNT_SPECIFIED},${SQRT_LIMIT})"

cast_rpc send \
  --rpc-url "${RPC_URL}" \
  --private-key "${PRIVATE_KEY}" \
  "${SWAP_TEST_ADDRESS}" \
  "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)(bytes32)" \
  "(${C0},${C1},8388608,${TICK_SPACING},${HOOK_ADDRESS})" \
  "(${ZERO_FOR_ONE},${AMOUNT_SPECIFIED},${SQRT_LIMIT})" \
  "(false,false)" \
  "${SALT_HOOK_DATA}"
