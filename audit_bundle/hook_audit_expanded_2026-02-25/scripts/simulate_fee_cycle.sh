#!/usr/bin/env bash
set -euo pipefail

# Auto-load local .env (ignored by git) if present.
if [[ -f "./.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "./.env"
  set +a
fi

# Simulate a full fee cycle on a live deployed pool:
# 1) 400 -> 900 (UP)
# 2) reversal-lock check (still 900)
# 3) 900 -> 400 (DOWN)
#
# The script expects an already deployed hook + pool + PoolSwapTest helper.
#
# Usage:
#   ./scripts/simulate_fee_cycle.sh --chain arbitrum
#   ./scripts/simulate_fee_cycle.sh --chain arbitrum --swap-test-address <addr>
#   ./scripts/simulate_fee_cycle.sh --chain arbitrum --rpc-url <url>
#
# Optional env overrides:
#   SWAP_TEST_ADDRESS, STATE_VIEW_ADDRESS, HIGH_SWAP_AMOUNT, LOW_SWAP_AMOUNT
#
# Notes:
# - This script sends real transactions (broadcast only).
# - Designed for local/sepolia/prod flows in this repository.

CHAIN="local"
RPC_URL=""
SWAP_TEST_ADDRESS="${SWAP_TEST_ADDRESS:-}"
STATE_VIEW_ADDRESS="${STATE_VIEW_ADDRESS:-}"
HOOK_ADDRESS_OVERRIDE=""
# Optional fixed amounts; if empty, the script computes adaptive amounts from EMA.
HIGH_SWAP_AMOUNT="${HIGH_SWAP_AMOUNT:-}"
LOW_SWAP_AMOUNT="${LOW_SWAP_AMOUNT:-}"
POLL_SECONDS=20

# Compatibility with orchestrator:
# - Orchestrator may pass --private-key and --broadcast (forge-style). This script uses cast and treats --broadcast as a no-op.
PRIVATE_KEY_CLI=""
HAS_BROADCAST=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      cat <<'EOF'
Usage:
  ./scripts/simulate_fee_cycle.sh --chain <chain> [options]

Options:
  --rpc-url <url>              Override RPC URL.
  --swap-test-address <addr>   PoolSwapTest helper contract address.
  --state-view-address <addr>  Optional StateView address for slot0 checks.
  --hook-address <addr>        Override HOOK_ADDRESS.
  --high-amount <int>          Fixed amountSpecified for U1_HIGH (optional).
  --low-amount <int>           Fixed amountSpecified for LOW steps (optional).
  --poll-seconds <int>         Poll interval while waiting period close (default: 20).
  --private-key <hex>           Signer key (optional if PRIVATE_KEY is in config).
  --broadcast                    Required to send transactions (no-op flag for compatibility).
  --dry-run                      Skip sending transactions.
EOF
      exit 0
      ;;
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
    --swap-test-address)
      SWAP_TEST_ADDRESS="${2:-}"
      if [[ -z "${SWAP_TEST_ADDRESS}" ]]; then echo "ERROR: --swap-test-address requires a value"; exit 1; fi
      shift 2
      ;;
    --state-view-address)
      STATE_VIEW_ADDRESS="${2:-}"
      if [[ -z "${STATE_VIEW_ADDRESS}" ]]; then echo "ERROR: --state-view-address requires a value"; exit 1; fi
      shift 2
      ;;
    --hook-address)
      HOOK_ADDRESS_OVERRIDE="${2:-}"
      if [[ -z "${HOOK_ADDRESS_OVERRIDE}" ]]; then echo "ERROR: --hook-address requires a value"; exit 1; fi
      shift 2
      ;;
    --high-amount)
      HIGH_SWAP_AMOUNT="${2:-}"
      if [[ -z "${HIGH_SWAP_AMOUNT}" ]]; then echo "ERROR: --high-amount requires a value"; exit 1; fi
      shift 2
      ;;
    --low-amount)
      LOW_SWAP_AMOUNT="${2:-}"
      if [[ -z "${LOW_SWAP_AMOUNT}" ]]; then echo "ERROR: --low-amount requires a value"; exit 1; fi
      shift 2
      ;;
    --poll-seconds)
      POLL_SECONDS="${2:-}"
      if [[ -z "${POLL_SECONDS}" ]]; then echo "ERROR: --poll-seconds requires a value"; exit 1; fi
      shift 2
      ;;
    --private-key)
      PRIVATE_KEY_CLI="${2:-}"
      if [[ -z "${PRIVATE_KEY_CLI}" ]]; then echo "ERROR: --private-key requires a value"; exit 1; fi
      shift 2
      ;;
    --broadcast)
      HAS_BROADCAST=1
      shift
      ;;
    --dry-run|dry)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "ERROR: unknown argument: $1"
      exit 1
      ;;
  esac
done

cast_rpc() {
  NO_PROXY='*' no_proxy='*' HTTPS_PROXY='' HTTP_PROXY='' ALL_PROXY='' cast "$@"
}

CLI_RPC_URL="${RPC_URL}"

HOOK_CONF="./config/hook.conf"
if [[ -n "${CHAIN}" && -f "./config/hook.${CHAIN}.conf" ]]; then
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
CONFIG_RPC_URL="${RPC_URL:-}"
RPC_URL="${CLI_RPC_URL:-${CONFIG_RPC_URL:-}}"
if [[ -z "${RPC_URL}" ]]; then
  echo "ERROR: RPC URL not provided. Set RPC_URL in ${HOOK_CONF} or pass --rpc-url."
  exit 1
fi

if [[ -n "${HOOK_ADDRESS_OVERRIDE}" ]]; then
  HOOK_ADDRESS="${HOOK_ADDRESS_OVERRIDE}"
fi
if [[ -z "${HOOK_ADDRESS:-}" ]]; then
  echo "ERROR: HOOK_ADDRESS must be set in ${HOOK_CONF} or passed via --hook-address."
  exit 1
fi

if [[ -z "${VOLATILE:-}" || -z "${STABLE:-}" || -z "${STABLE_DECIMALS:-}" || -z "${TICK_SPACING:-}" ]]; then
  echo "ERROR: VOLATILE, STABLE, STABLE_DECIMALS and TICK_SPACING must be set in ${HOOK_CONF}."
  exit 1
fi

if [[ -n "${PRIVATE_KEY_CLI}" ]]; then
  PRIVATE_KEY="${PRIVATE_KEY_CLI}"
fi

if [[ "${DRY_RUN}" -eq 1 || "${HAS_BROADCAST}" -eq 0 ]]; then
  echo "==> simulate_fee_cycle: skipping (dry-run or no --broadcast)."
  exit 0
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "ERROR: PRIVATE_KEY must be set (via ${HOOK_CONF} or --private-key)."
  exit 1
fi
DEPLOYER="$(cast_rpc wallet address --private-key "${PRIVATE_KEY}" | awk '{print $1}')"
if [[ -z "${DEPLOYER}" ]]; then
  echo "ERROR: failed to derive deployer address from PRIVATE_KEY."
  exit 1
fi

if [[ -z "${SWAP_TEST_ADDRESS}" ]]; then
  SWAP_BROADCAST_PATH=""
  if [[ "${CHAIN}" == "arbitrum" ]]; then
    SWAP_BROADCAST_PATH="./scripts/out/broadcast/03_PoolSwapTest.s.sol/421614/run-latest.json"
  fi
  if [[ -n "${SWAP_BROADCAST_PATH}" && -f "${SWAP_BROADCAST_PATH}" ]]; then
    SWAP_TEST_ADDRESS="$(python3 - "${SWAP_BROADCAST_PATH}" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
txs = data.get("transactions", [])
if not txs:
    print("")
else:
    print((txs[0].get("contractAddress") or "").strip())
PY
    )"
  fi
fi

if [[ -z "${SWAP_TEST_ADDRESS}" ]]; then
  echo "==> simulate_fee_cycle: SWAP_TEST_ADDRESS not set, skipping."
  exit 0
fi

SWAP_TEST_CODE_SIZE="$(cast_rpc code --rpc-url "${RPC_URL}" "${SWAP_TEST_ADDRESS}" | wc -c | xargs)"
if [[ "${SWAP_TEST_CODE_SIZE}" -le 3 ]]; then
  echo "ERROR: no contract code at SWAP_TEST_ADDRESS=${SWAP_TEST_ADDRESS}"
  exit 1
fi

CURRENCY0="${VOLATILE}"
CURRENCY1="${STABLE}"

CURRENCY0_LC="$(printf '%s' "${CURRENCY0}" | tr '[:upper:]' '[:lower:]')"
CURRENCY1_LC="$(printf '%s' "${CURRENCY1}" | tr '[:upper:]' '[:lower:]')"
if [[ "${CURRENCY0_LC}" > "${CURRENCY1_LC}" ]]; then
  T_SWAP="${CURRENCY0}"
  CURRENCY0="${CURRENCY1}"
  CURRENCY1="${T_SWAP}"
fi

DYNAMIC_FEE_FLAG=8388608
# Use min+1 sqrt limit for zeroForOne exact input path.
SQRT_PRICE_LIMIT_X96=4295128740
SWAP_ZERO_FOR_ONE=true
TEST_SETTINGS="(false,false)"
SWAP_SIG="swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)(bytes32)"
POOL_KEY="(${CURRENCY0},${CURRENCY1},${DYNAMIC_FEE_FLAG},${TICK_SPACING},${HOOK_ADDRESS})"

PERIOD_SECONDS="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "periodSeconds()(uint32)" | awk '{print $1}')"
if [[ -z "${PERIOD_SECONDS}" || "${PERIOD_SECONDS}" -le 0 ]]; then
  echo "ERROR: failed to read periodSeconds() from hook."
  exit 1
fi

now_ts() {
  cast_rpc block --rpc-url "${RPC_URL}" latest --field timestamp | awk '{print $1}'
}

read_state() {
  local fee pv ema ps idx dir out
  fee="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "currentFeeBips()(uint24)" | awk '{print $1}')"
  out="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "unpackedState()(uint64,uint96,uint32,uint8,uint8)")"
  pv="$(printf '%s\n' "${out}" | sed -n '1p' | awk '{print $1}')"
  ema="$(printf '%s\n' "${out}" | sed -n '2p' | awk '{print $1}')"
  ps="$(printf '%s\n' "${out}" | sed -n '3p' | awk '{print $1}')"
  idx="$(printf '%s\n' "${out}" | sed -n '4p' | awk '{print $1}')"
  dir="$(printf '%s\n' "${out}" | sed -n '5p' | awk '{print $1}')"
  echo "${fee}|${pv}|${ema}|${ps}|${idx}|${dir}"
}

wait_for_next_period() {
  local label="$1"
  local state="$2"
  local ps target now rem
  IFS='|' read -r _ _ _ ps _ _ <<<"${state}"
  target=$((ps + PERIOD_SECONDS))
  while true; do
    now="$(now_ts)"
    if (( now >= target )); then
      break
    fi
    rem=$((target - now))
    echo "[wait:${label}] now=${now} target=${target} remaining=${rem}s"
    sleep "${POLL_SECONDS}"
  done
}

run_swap_step() {
  local label="$1"
  local amount="$2"
  local out tx
  local params

  params="(${SWAP_ZERO_FOR_ONE},-${amount},${SQRT_PRICE_LIMIT_X96})"
  echo "==> ${label}: swap amountSpecified=${amount}" >&2
  out="$(cast_rpc send --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" "${SWAP_TEST_ADDRESS}" "${SWAP_SIG}" "${POOL_KEY}" "${params}" "${TEST_SETTINGS}" 0x)"
  tx="$(echo "${out}" | awk '/^transactionHash[[:space:]]/{print $2; exit}')"
  if [[ -z "${tx}" ]]; then
    echo "ERROR: failed to parse transaction hash for step ${label}"
    exit 1
  fi
  echo "${tx}"
}

amount_for_target_vol() {
  local target_vol="$1"
  local amount
  local max_amount
  local bal_raw
  # For zeroForOne exact-input swaps in this pool, amountSpecified is token0 (USDC, 6 decimals).
  # Approximation: ~2 USDC per 1 USD of target period volume.
  amount=$(( (target_vol + 1) / 2 ))
  if (( amount < 100 )); then amount=100; fi
  bal_raw="$(cast_rpc call --rpc-url "${RPC_URL}" "${CURRENCY0}" "balanceOf(address)(uint256)" "${DEPLOYER}" | awk '{print $1}')"
  if [[ -n "${bal_raw}" && "${bal_raw}" =~ ^[0-9]+$ ]]; then
    max_amount=$(( bal_raw * 80 / 100 ))
    if (( max_amount > 0 && amount > max_amount )); then
      amount=${max_amount}
    fi
  fi
  echo "${amount}"
}

pick_high_amount() {
  local state="$1"
  local ema target
  IFS='|' read -r _ _ ema _ _ _ <<<"${state}"
  if [[ -n "${HIGH_SWAP_AMOUNT}" ]]; then
    echo "${HIGH_SWAP_AMOUNT}"
    return
  fi
  if (( ema <= 0 )); then
    target=150000
  else
    target=$(( ema * 3 ))
    if (( target < ema + 20000 )); then target=$(( ema + 20000 )); fi
    if (( target < 120000 )); then target=120000; fi
  fi
  echo "$(amount_for_target_vol "${target}")"
}

pick_low_amount() {
  local state="$1"
  local ema target
  IFS='|' read -r _ _ ema _ _ _ <<<"${state}"
  if [[ -n "${LOW_SWAP_AMOUNT}" ]]; then
    echo "${LOW_SWAP_AMOUNT}"
    return
  fi
  if (( ema <= 0 )); then
    target=3000
  else
    target=$(( ema / 20 ))
    if (( target < 1500 )); then target=1500; fi
  fi
  echo "$(amount_for_target_vol "${target}")"
}

START_STATE="$(read_state)"
IFS='|' read -r START_FEE START_PV START_EMA START_PS START_IDX START_DIR <<<"${START_STATE}"
START_NOW="$(now_ts)"

# Ensure deterministic close behavior for U1.
if (( START_NOW < START_PS + PERIOD_SECONDS )); then
  echo "==> Waiting for initial period close before U1..."
  wait_for_next_period "U1-pre" "${START_STATE}"
fi

declare -a STEP_LINES=()

append_step_line() {
  local label="$1"
  local amount="$2"
  local tx="$3"
  local before="$4"
  local after="$5"

  local b_fee b_pv b_ema b_ps b_idx b_dir
  local a_fee a_pv a_ema a_ps a_idx a_dir
  IFS='|' read -r b_fee b_pv b_ema b_ps b_idx b_dir <<<"${before}"
  IFS='|' read -r a_fee a_pv a_ema a_ps a_idx a_dir <<<"${after}"
  STEP_LINES+=("${label}|${amount}|${tx}|${b_fee}|${a_fee}|${b_idx}|${a_idx}|${b_dir}|${a_dir}|${a_pv}|${a_ema}|${a_ps}")
}

S_BEFORE="$(read_state)"
AMT_U1="$(pick_high_amount "${S_BEFORE}")"
TX_U1="$(run_swap_step "U1_HIGH" "${AMT_U1}")"
S_AFTER_U1="$(read_state)"
append_step_line "U1_HIGH" "${AMT_U1}" "${TX_U1}" "${S_BEFORE}" "${S_AFTER_U1}"

wait_for_next_period "U2" "${S_AFTER_U1}"
S_BEFORE="$(read_state)"
AMT_U2="$(pick_low_amount "${S_BEFORE}")"
TX_U2="$(run_swap_step "U2_LOW" "${AMT_U2}")"
S_AFTER_U2="$(read_state)"
append_step_line "U2_LOW" "${AMT_U2}" "${TX_U2}" "${S_BEFORE}" "${S_AFTER_U2}"
IFS='|' read -r FEE_B_U2 _ _ _ IDX_B_U2 _ <<<"${S_BEFORE}"
IFS='|' read -r FEE_U2 _ _ _ IDX_U2 DIR_U2 <<<"${S_AFTER_U2}"
if (( FEE_U2 <= FEE_B_U2 )) || (( IDX_U2 <= IDX_B_U2 )) || [[ "${DIR_U2}" != "1" ]]; then
  echo "ERROR: U2 expectation failed. expected UP move; got fee ${FEE_B_U2}->${FEE_U2}, idx ${IDX_B_U2}->${IDX_U2}, lastDir=${DIR_U2}"
  exit 1
fi

wait_for_next_period "D1" "${S_AFTER_U2}"
S_BEFORE="$(read_state)"
AMT_D1="$(pick_low_amount "${S_BEFORE}")"
TX_D1="$(run_swap_step "D1_LOW_LOCK" "${AMT_D1}")"
S_AFTER_D1="$(read_state)"
append_step_line "D1_LOW_LOCK" "${AMT_D1}" "${TX_D1}" "${S_BEFORE}" "${S_AFTER_D1}"
IFS='|' read -r FEE_B_D1 _ _ _ IDX_B_D1 _ <<<"${S_BEFORE}"
IFS='|' read -r FEE_D1 _ _ _ IDX_D1 DIR_D1 <<<"${S_AFTER_D1}"
if (( FEE_D1 != FEE_B_D1 )) || (( IDX_D1 != IDX_B_D1 )) || [[ "${DIR_D1}" != "0" ]]; then
  echo "ERROR: D1 expectation failed. expected reversal lock; got fee ${FEE_B_D1}->${FEE_D1}, idx ${IDX_B_D1}->${IDX_D1}, lastDir=${DIR_D1}"
  exit 1
fi

wait_for_next_period "D2" "${S_AFTER_D1}"
S_BEFORE="$(read_state)"
AMT_D2="$(pick_low_amount "${S_BEFORE}")"
TX_D2="$(run_swap_step "D2_LOW_DOWN" "${AMT_D2}")"
S_AFTER_D2="$(read_state)"
append_step_line "D2_LOW_DOWN" "${AMT_D2}" "${TX_D2}" "${S_BEFORE}" "${S_AFTER_D2}"
IFS='|' read -r FINAL_FEE FINAL_PV FINAL_EMA FINAL_PS FINAL_IDX FINAL_DIR <<<"${S_AFTER_D2}"
IFS='|' read -r FEE_B_D2 _ _ _ IDX_B_D2 _ <<<"${S_BEFORE}"
if (( FINAL_FEE >= FEE_B_D2 )) || (( FINAL_IDX >= IDX_B_D2 )) || [[ "${FINAL_DIR}" != "2" ]]; then
  echo "ERROR: D2 expectation failed. expected DOWN move; got fee ${FEE_B_D2}->${FINAL_FEE}, idx ${IDX_B_D2}->${FINAL_IDX}, lastDir=${FINAL_DIR}"
  exit 1
fi

POOL_ID=""
SLOT0_LP_FEE=""
SLOT0_TICK=""
if [[ -n "${STATE_VIEW_ADDRESS}" ]]; then
  set -f
  POOL_KEY_ENC="$(cast abi-encode 'f((address,address,uint24,int24,address))' "${POOL_KEY}")"
  set +f
  POOL_ID="$(cast keccak "${POOL_KEY_ENC}")"
  SLOT_OUT="$(cast_rpc call --rpc-url "${RPC_URL}" "${STATE_VIEW_ADDRESS}" "getSlot0(bytes32)(uint160,int24,uint24,uint24)" "${POOL_ID}")"
  SLOT0_TICK="$(printf '%s\n' "${SLOT_OUT}" | sed -n '2p' | awk '{print $1}')"
  SLOT0_LP_FEE="$(printf '%s\n' "${SLOT_OUT}" | sed -n '4p' | awk '{print $1}')"
fi

echo
echo "===== Dynamic Fee Simulation Report ====="
echo "Chain: ${CHAIN}"
echo "RPC: ${RPC_URL}"
echo "Hook: ${HOOK_ADDRESS}"
echo "PoolSwapTest: ${SWAP_TEST_ADDRESS}"
if [[ -n "${STATE_VIEW_ADDRESS}" ]]; then
  echo "StateView: ${STATE_VIEW_ADDRESS}"
  echo "PoolId: ${POOL_ID}"
fi
if [[ -n "${HIGH_SWAP_AMOUNT}" ]]; then
  echo "Fixed high amountSpecified: ${HIGH_SWAP_AMOUNT}"
else
  echo "High amountSpecified: adaptive"
fi
if [[ -n "${LOW_SWAP_AMOUNT}" ]]; then
  echo "Fixed low amountSpecified: ${LOW_SWAP_AMOUNT}"
else
  echo "Low amountSpecified: adaptive"
fi
echo "Period seconds: ${PERIOD_SECONDS}"
echo
echo "Initial state:"
echo "  feeBips=${START_FEE} periodVolUsd6=${START_PV} emaUsd6=${START_EMA} periodStart=${START_PS} feeIdx=${START_IDX} lastDir=${START_DIR}"
echo
printf "%-14s %-16s %-66s %-12s %-10s %-10s %-18s %-14s %-12s\n" \
  "Step" "Amount" "TxHash" "feeBips" "feeIdx" "lastDir" "periodVolUsd6" "emaUsd6" "periodStart"
printf "%-14s %-16s %-66s %-12s %-10s %-10s %-18s %-14s %-12s\n" \
  "----" "------" "------" "-------" "------" "-------" "------------" "------" "----------"
for line in "${STEP_LINES[@]}"; do
  IFS='|' read -r label amount tx bf af bidx aidx bdir adir apv aema aps <<<"${line}"
  printf "%-14s %-16s %-66s %-12s %-10s %-10s %-18s %-14s %-12s\n" \
    "${label}" "${amount}" "${tx}" "${bf}->${af}" "${bidx}->${aidx}" "${bdir}->${adir}" "${apv}" "${aema}" "${aps}"
done
echo
echo "Final state:"
echo "  feeBips=${FINAL_FEE} periodVolUsd6=${FINAL_PV} emaUsd6=${FINAL_EMA} periodStart=${FINAL_PS} feeIdx=${FINAL_IDX} lastDir=${FINAL_DIR}"
if [[ -n "${SLOT0_LP_FEE}" ]]; then
  echo "  slot0.tick=${SLOT0_TICK} slot0.lpFee=${SLOT0_LP_FEE}"
fi
echo
echo "Assertions:"
echo "  [OK] U2 produced UP move (fee/idx increased, lastDir=UP)"
echo "  [OK] D1 kept fee/idx unchanged and reset lastDir to NONE (reversal-lock)"
echo "  [OK] D2 produced DOWN move (fee/idx decreased, lastDir=DOWN)"
echo "===== Simulation successful ====="
