#!/usr/bin/env bash
set -euo pipefail

# Add liquidity through PoolModifyLiquidityTest.
#
# Usage:
#   ./scripts/tools/add_liquidity.sh --liquidity 1000000000000000
#   ./scripts/tools/add_liquidity.sh --liquidity 1000000000000 --tick-lower -120000 --tick-upper 120000

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

CHAIN="ethereum"
LIQUIDITY_DELTA=""
TICK_LOWER="-887220"
TICK_UPPER="887220"
SALT="0x0000000000000000000000000000000000000000000000000000000000000000"
HOOK_ADDRESS_OVERRIDE=""
MODIFY_TEST_ADDRESS="${MODIFY_TEST_ADDRESS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --liquidity) LIQUIDITY_DELTA="${2:-}"; shift 2 ;;
    --tick-lower) TICK_LOWER="${2:-}"; shift 2 ;;
    --tick-upper) TICK_UPPER="${2:-}"; shift 2 ;;
    --salt) SALT="${2:-}"; shift 2 ;;
    --hook-address) HOOK_ADDRESS_OVERRIDE="${2:-}"; shift 2 ;;
    --modify-test-address) MODIFY_TEST_ADDRESS="${2:-}"; shift 2 ;;
    --rpc-url) RPC_URL="${2:-}"; shift 2 ;;
    --private-key) PRIVATE_KEY="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${LIQUIDITY_DELTA}" ]]; then
  echo "ERROR: --liquidity is required" >&2
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

if [[ -z "${MODIFY_TEST_ADDRESS}" ]]; then
  MODIFY_TEST_ADDRESS="$(default_modify_test_address "${CHAIN}")"
fi
if [[ -z "${MODIFY_TEST_ADDRESS}" ]]; then
  echo "ERROR: modify test helper is unknown for chain=${CHAIN}, pass --modify-test-address." >&2
  exit 1
fi

TOKENS=($(canonical_token_order "${TOKEN0}" "${TOKEN1}"))
C0="${TOKENS[0]}"
C1="${TOKENS[1]}"

echo "==> add liquidity via ${MODIFY_TEST_ADDRESS}"
echo "    key=(${C0},${C1},8388608,${TICK_SPACING},${HOOK_ADDRESS})"
echo "    params=(${TICK_LOWER},${TICK_UPPER},${LIQUIDITY_DELTA},${SALT})"

cast_rpc send \
  --rpc-url "${RPC_URL}" \
  --private-key "${PRIVATE_KEY}" \
  "${MODIFY_TEST_ADDRESS}" \
  "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)(int256)" \
  "(${C0},${C1},8388608,${TICK_SPACING},${HOOK_ADDRESS})" \
  "(${TICK_LOWER},${TICK_UPPER},${LIQUIDITY_DELTA},${SALT})" \
  0x
