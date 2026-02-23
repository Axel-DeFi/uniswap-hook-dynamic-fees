#!/usr/bin/env bash
set -euo pipefail

# Simulate "arbitrage-like" traffic on a live pool:
# - Varies swap sizes over time
# - Alternates directions in balanced mode
# - Switches direction automatically after price-limit failures
# - Tracks gas usage and average tx cost
#
# Usage:
#   ./scripts/tools/simulate_arb_traffic.sh --chain ethereum
#   ./scripts/tools/simulate_arb_traffic.sh --chain ethereum --tx-count 80

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

CHAIN="ethereum"
TX_COUNT="40"
MIN_ETH_RESERVE_WEI="5000000000000000" # 0.005 ETH safety reserve
PAUSE_SECONDS="0"

SWAP_TEST_ADDRESS="${SWAP_TEST_ADDRESS:-}"
HOOK_ADDRESS_OVERRIDE=""

# Default ranges (exact-input amounts)
# USDC has 6 decimals
USDC_MIN="5000000"      # 5 USDC
USDC_MAX="50000000"     # 50 USDC
# WETH has 18 decimals
WETH_MIN="500000000000000"    # 0.0005 WETH
WETH_MAX="5000000000000000"   # 0.005 WETH

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --tx-count) TX_COUNT="${2:-}"; shift 2 ;;
    --min-eth-reserve-wei) MIN_ETH_RESERVE_WEI="${2:-}"; shift 2 ;;
    --pause-seconds) PAUSE_SECONDS="${2:-}"; shift 2 ;;
    --swap-test-address) SWAP_TEST_ADDRESS="${2:-}"; shift 2 ;;
    --hook-address) HOOK_ADDRESS_OVERRIDE="${2:-}"; shift 2 ;;
    --usdc-min) USDC_MIN="${2:-}"; shift 2 ;;
    --usdc-max) USDC_MAX="${2:-}"; shift 2 ;;
    --weth-min) WETH_MIN="${2:-}"; shift 2 ;;
    --weth-max) WETH_MAX="${2:-}"; shift 2 ;;
    --rpc-url) RPC_URL="${2:-}"; shift 2 ;;
    --private-key) PRIVATE_KEY="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

load_hook_config "${CHAIN}"
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
POOL_KEY="(${C0},${C1},8388608,${TICK_SPACING},${HOOK_ADDRESS})"
SWAP_SIG="swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)(bytes32)"

DEPLOYER="$(cast_rpc wallet address --private-key "${PRIVATE_KEY}" | awk '{print $1}')"
if [[ -z "${DEPLOYER}" ]]; then
  echo "ERROR: failed to derive deployer from PRIVATE_KEY." >&2
  exit 1
fi

read_hook_state() {
  local fee out pv ema ps idx dir
  fee="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "currentFeeBips()(uint24)" | awk '{print $1}')"
  out="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "unpackedState()(uint64,uint96,uint32,uint8,uint8)")"
  pv="$(printf '%s\n' "${out}" | sed -n '1p' | awk '{print $1}')"
  ema="$(printf '%s\n' "${out}" | sed -n '2p' | awk '{print $1}')"
  ps="$(printf '%s\n' "${out}" | sed -n '3p' | awk '{print $1}')"
  idx="$(printf '%s\n' "${out}" | sed -n '4p' | awk '{print $1}')"
  dir="$(printf '%s\n' "${out}" | sed -n '5p' | awk '{print $1}')"
  echo "${fee}|${pv}|${ema}|${ps}|${idx}|${dir}"
}

eth_balance_wei() {
  cast_rpc balance "${DEPLOYER}" --rpc-url "${RPC_URL}" | awk '{print $1}'
}

scale_amount() {
  local min="$1"
  local max="$2"
  local step="$3"
  if (( max <= min )); then
    echo "${min}"
    return
  fi
  local range phase
  range=$((max - min))
  phase=$(( (step * 7919) % 1000 ))
  echo $(( min + (range * phase) / 999 ))
}

run_swap() {
  local dir="$1"
  local amount="$2"
  local zero_for_one sqrt_limit params

  if [[ "${dir}" == "usdc_to_weth" ]]; then
    zero_for_one="true"
    sqrt_limit="4295128740"
  else
    zero_for_one="false"
    sqrt_limit="1461446703485210103287273052203988822378723970341"
  fi

  params="(${zero_for_one},-${amount},${sqrt_limit})"

  local out rc tx gas price
  set +e
  out="$(cast_rpc send --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" "${SWAP_TEST_ADDRESS}" "${SWAP_SIG}" "${POOL_KEY}" "${params}" "(false,false)" 0x 2>&1)"
  rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    echo "ERR|${out}"
    return 1
  fi

  tx="$(printf '%s\n' "${out}" | awk '/^transactionHash[[:space:]]/{print $2; exit}')"
  gas="$(printf '%s\n' "${out}" | awk '/^gasUsed[[:space:]]/{print $2; exit}')"
  price="$(printf '%s\n' "${out}" | awk '/^effectiveGasPrice[[:space:]]/{print $2; exit}')"
  if [[ -z "${tx}" || -z "${gas}" || -z "${price}" ]]; then
    echo "ERR|failed_to_parse_cast_output"
    return 1
  fi

  local cost
  cost=$((gas * price))
  echo "OK|${tx}|${gas}|${price}|${cost}"
}

START_ETH="$(eth_balance_wei)"
START_STATE="$(read_hook_state)"
IFS='|' read -r START_FEE START_PV START_EMA START_PS START_IDX START_DIR <<<"${START_STATE}"

echo "==> Start traffic simulation"
echo "    chain=${CHAIN} deployer=${DEPLOYER}"
echo "    tx_count=${TX_COUNT} min_eth_reserve_wei=${MIN_ETH_RESERVE_WEI}"
echo "    usdc_range=${USDC_MIN}..${USDC_MAX} weth_range=${WETH_MIN}..${WETH_MAX}"

ok_count=0
fail_count=0
ok_usdc_to_weth=0
ok_weth_to_usdc=0
fail_usdc_to_weth=0
fail_weth_to_usdc=0
total_gas=0
total_cost=0

force_dir=""
force_steps=0

for ((i=1; i<=TX_COUNT; i++)); do
  bal_eth="$(eth_balance_wei)"
  if (( bal_eth <= MIN_ETH_RESERVE_WEI )); then
    echo "==> stop: ETH reserve reached at step ${i} (balance=${bal_eth})"
    break
  fi

  dir=""
  if (( force_steps > 0 )); then
    dir="${force_dir}"
    force_steps=$((force_steps - 1))
  else
    if (( i % 2 == 1 )); then
      dir="usdc_to_weth"
    else
      dir="weth_to_usdc"
    fi
  fi

  if [[ "${dir}" == "usdc_to_weth" ]]; then
    amount="$(scale_amount "${USDC_MIN}" "${USDC_MAX}" "${i}")"
  else
    amount="$(scale_amount "${WETH_MIN}" "${WETH_MAX}" "${i}")"
  fi

  result="$(run_swap "${dir}" "${amount}" || true)"
  kind="${result%%|*}"

  if [[ "${kind}" == "OK" ]]; then
    IFS='|' read -r _ tx gas price cost <<<"${result}"
    ok_count=$((ok_count + 1))
    total_gas=$((total_gas + gas))
    total_cost=$((total_cost + cost))
    if [[ "${dir}" == "usdc_to_weth" ]]; then
      ok_usdc_to_weth=$((ok_usdc_to_weth + 1))
    else
      ok_weth_to_usdc=$((ok_weth_to_usdc + 1))
    fi
    echo "step=${i} dir=${dir} amount=${amount} tx=${tx} gas=${gas} gasPrice=${price} costWei=${cost}"
  else
    fail_count=$((fail_count + 1))
    err="${result#ERR|}"
    short_err="$(printf '%s' "${err}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
    if [[ "${dir}" == "usdc_to_weth" ]]; then
      fail_usdc_to_weth=$((fail_usdc_to_weth + 1))
      force_dir="weth_to_usdc"
      force_steps=3
    else
      fail_weth_to_usdc=$((fail_weth_to_usdc + 1))
      force_dir="usdc_to_weth"
      force_steps=3
    fi
    echo "step=${i} dir=${dir} amount=${amount} FAIL=${short_err}"
  fi

  if (( PAUSE_SECONDS > 0 )); then
    sleep "${PAUSE_SECONDS}"
  fi
done

END_ETH="$(eth_balance_wei)"
END_STATE="$(read_hook_state)"
IFS='|' read -r END_FEE END_PV END_EMA END_PS END_IDX END_DIR <<<"${END_STATE}"

avg_gas=0
avg_cost=0
if (( ok_count > 0 )); then
  avg_gas=$((total_gas / ok_count))
  avg_cost=$((total_cost / ok_count))
fi

echo
echo "===== Arbitrage-like Traffic Report ====="
echo "Chain: ${CHAIN}"
echo "Hook: ${HOOK_ADDRESS}"
echo "Swap helper: ${SWAP_TEST_ADDRESS}"
echo "Deployer: ${DEPLOYER}"
echo "Start ETH: ${START_ETH}"
echo "End ETH:   ${END_ETH}"
echo
echo "Traffic result:"
echo "  success=${ok_count} fail=${fail_count}"
echo "  success usdc->weth=${ok_usdc_to_weth}, weth->usdc=${ok_weth_to_usdc}"
echo "  fail usdc->weth=${fail_usdc_to_weth}, weth->usdc=${fail_weth_to_usdc}"
echo
echo "Gas cost:"
echo "  totalGasUsed=${total_gas}"
echo "  totalCostWei=${total_cost}"
echo "  avgGasUsedPerSuccessTx=${avg_gas}"
echo "  avgCostWeiPerSuccessTx=${avg_cost}"
echo
echo "Hook state:"
echo "  start fee=${START_FEE} idx=${START_IDX} periodVol=${START_PV} ema=${START_EMA} periodStart=${START_PS} lastDir=${START_DIR}"
echo "  end   fee=${END_FEE} idx=${END_IDX} periodVol=${END_PV} ema=${END_EMA} periodStart=${END_PS} lastDir=${END_DIR}"
echo "===== End Report ====="

