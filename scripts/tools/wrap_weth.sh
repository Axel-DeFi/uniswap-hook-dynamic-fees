#!/usr/bin/env bash
set -euo pipefail

# Wrap native ETH into WETH via deposit().
#
# Usage:
#   ./scripts/tools/wrap_weth.sh --amount-eth 0.1 [--weth <address>] [--rpc-url <url>] [--private-key <hex>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

CHAIN="ethereum"
AMOUNT_ETH=""
WETH_ADDRESS="${WETH_ADDRESS:-0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --amount-eth) AMOUNT_ETH="${2:-}"; shift 2 ;;
    --weth) WETH_ADDRESS="${2:-}"; shift 2 ;;
    --rpc-url) RPC_URL="${2:-}"; shift 2 ;;
    --private-key) PRIVATE_KEY="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${AMOUNT_ETH}" ]]; then
  echo "ERROR: --amount-eth is required" >&2
  exit 1
fi

load_hook_config "${CHAIN}"
resolve_private_key
resolve_rpc

echo "==> Wrapping ${AMOUNT_ETH} ETH into WETH ${WETH_ADDRESS}"
cast_rpc send \
  --rpc-url "${RPC_URL}" \
  --private-key "${PRIVATE_KEY}" \
  --value "${AMOUNT_ETH}ether" \
  "${WETH_ADDRESS}" \
  "deposit()"

