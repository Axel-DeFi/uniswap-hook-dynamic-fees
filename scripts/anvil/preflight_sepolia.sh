#!/usr/bin/env bash
set -euo pipefail

# Anvil Sepolia preflight suite for VolumeDynamicFeeHook v2.
#
# Required env:
#   SEPOLIA_FORK_URL   Sepolia RPC URL used for forking.
#   PRIVATE_KEY        Signer private key used as hook owner/creator.
#
# Optional env:
#   SEPOLIA_FORK_BLOCK Fork block number (default: latest).
#   VERBOSE=1          Enable verbose debug logs.
#
# What this validates:
#   - Deploy/create pipeline against local Anvil fork (no manual steps).
#   - Runtime/admin correctness scenarios S0..S8 (access, pause gating, updates, warp transitions).
#   - Script-level regression surface and ABI compatibility checks.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/anvil/lib.sh"

require_cmd anvil
require_cmd cast
require_cmd forge
require_cmd jq
require_cmd python3
require_cmd rg

: "${SEPOLIA_FORK_URL:?SEPOLIA_FORK_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"

export CHAIN="sepolia"
export RPC_URL="http://127.0.0.1:8545"
export VERBOSE="${VERBOSE:-0}"

OWNER_PK="${PRIVATE_KEY}"
GUARDIAN_PK="0x59c6995e998f97a5a0044966f0945385aace2f59b95f4d9b3e9b6a38f9f6f62b"
OUTSIDER_PK="0x5de4111afa1a4b94908fef3deabf442ba4f8d615f4c6d93ce2d5d4f29e6f5f3f"
ETH_RICH_WEI="1000000000000000000000"
DYNAMIC_FEE_FLAG="8388608"
SQRT_PRICE_LIMIT_X96_ZFO="4295128739"
SQRT_PRICE_LIMIT_X96_OZF="1461446703485210103287273052203988822378723970342"
POOL_ID=""
POOL_KEY=""
HOOK_ADDRESS=""
SWAP_HELPER=""
MODIFY_HELPER=""
OWNER_ADDR=""
GUARDIAN_ADDR=""
OUTSIDER_ADDR=""
CHAIN_ID="11155111"
ANVIL_PID=""
CONFIG_PATH="${ROOT_DIR}/config/hook.sepolia.conf"
CONFIG_BACKUP=""

PASS_COUNT=0
FAIL_COUNT=0
declare -A SCENARIO_STATUS
declare -A SCENARIO_REASON
declare -A SCENARIO_METRICS

BASE_MIN_CLOSEVOL_TO_CASH_USD6=""
BASE_UP_R_TO_CASH_BPS=""
BASE_CASH_HOLD_PERIODS=""
BASE_MIN_CLOSEVOL_TO_EXTREME_USD6=""
BASE_UP_R_TO_EXTREME_BPS=""
BASE_UP_EXTREME_CONFIRM_PERIODS=""
BASE_EXTREME_HOLD_PERIODS=""
BASE_DOWN_R_FROM_EXTREME_BPS=""
BASE_DOWN_EXTREME_CONFIRM_PERIODS=""
BASE_DOWN_R_FROM_CASH_BPS=""
BASE_DOWN_CASH_CONFIRM_PERIODS=""
BASE_EMERGENCY_FLOOR_CLOSEVOL_USD6=""
BASE_EMERGENCY_CONFIRM_PERIODS=""

SC_REASON=""
SC_KEYS=""

cleanup() {
  if [[ -n "${ANVIL_PID}" ]]; then
    kill "${ANVIL_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${CONFIG_BACKUP}" && -f "${CONFIG_BACKUP}" ]]; then
    cp "${CONFIG_BACKUP}" "${CONFIG_PATH}"
  fi
}
trap cleanup EXIT INT TERM

kv_get() {
  local blob="$1"
  local key="$2"
  tr ' ' '\n' <<<"${blob}" | sed -n "s/^${key}=//p" | head -n 1
}

set_scenario_fail() {
  SC_REASON="$1"
  return 1
}

refresh_metrics() {
  local snap fee r close hold
  snap="$(call_hook_getters "${HOOK_ADDRESS}")"
  fee="$(kv_get "${snap}" "current_fee_bips")"
  r="$(kv_get "${snap}" "r_bps")"
  close="$(kv_get "${snap}" "period_vol")"
  hold="$(kv_get "${snap}" "hold_remaining")"
  SC_KEYS="feeTier=${fee} rBps=${r} closeVol=${close} holdRemaining=${hold}"
}

record_scenario() {
  local id="$1"
  local status="$2"
  local reason="$3"
  local metrics="$4"
  SCENARIO_STATUS["${id}"]="${status}"
  SCENARIO_REASON["${id}"]="${reason}"
  SCENARIO_METRICS["${id}"]="${metrics}"
}

run_scenario() {
  local id="$1"
  local fn="$2"

  SC_REASON=""
  SC_KEYS=""

  log "==> ${id}"
  if "${fn}"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    record_scenario "${id}" "PASS" "${SC_REASON:-ok}" "${SC_KEYS}"
    log "${id}: PASS - ${SC_REASON:-ok} | ${SC_KEYS}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    record_scenario "${id}" "FAIL" "${SC_REASON:-failed}" "${SC_KEYS}"
    log "${id}: FAIL - ${SC_REASON:-failed} | ${SC_KEYS}"
  fi
}

backup_config() {
  CONFIG_BACKUP="$(mktemp "/tmp/preflight_sepolia_conf.XXXXXX")"
  cp "${CONFIG_PATH}" "${CONFIG_BACKUP}"
}

set_config_hook_address() {
  local new_hook="$1"
  python3 - "${CONFIG_PATH}" "${new_hook}" <<'PY'
import re
import sys

path = sys.argv[1]
hook = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    src = f.read()

if re.search(r"^HOOK_ADDRESS=.*$", src, flags=re.M):
    src = re.sub(r"^HOOK_ADDRESS=.*$", f"HOOK_ADDRESS={hook}", src, flags=re.M)
else:
    src = src.rstrip() + f"\nHOOK_ADDRESS={hook}\n"

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
PY
}

load_config() {
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/.env"
  fi

  # shellcheck disable=SC1090
  set -a
  source "${CONFIG_PATH}"
  set +a
}

apply_v2_defaults() {
  : "${CREATOR_FEE_LIMIT:=10}"
  : "${CASH_TIER:=0.25}"
  : "${EXTREME_TIER:=0.90}"
  : "${MIN_CLOSEVOL_TO_CASH_USD6:=1000000000}"
  : "${UP_R_TO_CASH_BPS:=18000}"
  : "${CASH_HOLD_PERIODS:=4}"
  : "${MIN_CLOSEVOL_TO_EXTREME_USD6:=4000000000}"
  : "${UP_R_TO_EXTREME_BPS:=40000}"
  : "${UP_EXTREME_CONFIRM_PERIODS:=2}"
  : "${EXTREME_HOLD_PERIODS:=4}"
  : "${DOWN_R_FROM_EXTREME_BPS:=13000}"
  : "${DOWN_EXTREME_CONFIRM_PERIODS:=2}"
  : "${DOWN_R_FROM_CASH_BPS:=10500}"
  : "${DOWN_CASH_CONFIRM_PERIODS:=3}"
  : "${EMERGENCY_FLOOR_CLOSEVOL_USD6:=600000000}"
  : "${EMERGENCY_CONFIRM_PERIODS:=3}"

  export CREATOR_FEE_LIMIT
  export CASH_TIER EXTREME_TIER
  export MIN_CLOSEVOL_TO_CASH_USD6 UP_R_TO_CASH_BPS CASH_HOLD_PERIODS
  export MIN_CLOSEVOL_TO_EXTREME_USD6 UP_R_TO_EXTREME_BPS UP_EXTREME_CONFIRM_PERIODS EXTREME_HOLD_PERIODS
  export DOWN_R_FROM_EXTREME_BPS DOWN_EXTREME_CONFIRM_PERIODS DOWN_R_FROM_CASH_BPS DOWN_CASH_CONFIRM_PERIODS
  export EMERGENCY_FLOOR_CLOSEVOL_USD6 EMERGENCY_CONFIRM_PERIODS
}

wait_for_rpc() {
  local i
  for i in $(seq 1 60); do
    if cast chain-id --rpc-url "${RPC_URL}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  die "Anvil RPC did not start on ${RPC_URL}"
}

start_anvil() {
  local args
  args=(--host 127.0.0.1 --port 8545 --chain-id "${CHAIN_ID}" --fork-url "${SEPOLIA_FORK_URL}" --silent)
  if [[ -n "${SEPOLIA_FORK_BLOCK:-}" ]]; then
    args+=(--fork-block-number "${SEPOLIA_FORK_BLOCK}")
  fi
  anvil "${args[@]}" >/tmp/preflight_sepolia_anvil.log 2>&1 &
  ANVIL_PID="$!"
  wait_for_rpc
}

prepare_accounts() {
  OWNER_ADDR="$(cast wallet address --private-key "${OWNER_PK}" | awk '{print $1}')"
  GUARDIAN_ADDR="$(cast wallet address --private-key "${GUARDIAN_PK}" | awk '{print $1}')"
  OUTSIDER_ADDR="$(cast wallet address --private-key "${OUTSIDER_PK}" | awk '{print $1}')"

  set_eth_balance "${OWNER_ADDR}" "${ETH_RICH_WEI}"
  set_eth_balance "${GUARDIAN_ADDR}" "${ETH_RICH_WEI}"
  set_eth_balance "${OUTSIDER_ADDR}" "${ETH_RICH_WEI}"
}

helper_addr_from_artifacts() {
  local script_name="$1"
  local path addr code
  for path in \
    "${ROOT_DIR}/scripts/out/broadcast/${script_name}.s.sol/${CHAIN_ID}/run-latest.json" \
    "${ROOT_DIR}/lib/v4-periphery/broadcast/${script_name}.s.sol/${CHAIN_ID}/run-latest.json"
  do
    if [[ -f "${path}" ]]; then
      addr="$(extract_contract_from_broadcast "${path}")"
      if [[ -n "${addr}" ]]; then
        code="$(cast code --rpc-url "${RPC_URL}" "${addr}" 2>/dev/null || true)"
        if [[ -n "${code}" && "${code}" != "0x" ]]; then
          printf '%s\n' "${addr}"
          return 0
        fi
      fi
    fi
  done
  return 1
}

ensure_modify_helper() {
  local addr
  if addr="$(helper_addr_from_artifacts "02_PoolModifyLiquidityTest" 2>/dev/null)"; then
    printf '%s\n' "${addr}"
    return 0
  fi
  forge script lib/v4-periphery/script/02_PoolModifyLiquidityTest.s.sol:DeployPoolModifyLiquidityTest \
    --sig "run(address)" "${POOL_MANAGER}" \
    --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" --broadcast >/dev/null
  helper_addr_from_artifacts "02_PoolModifyLiquidityTest"
}

ensure_swap_helper() {
  local addr
  if addr="$(helper_addr_from_artifacts "03_PoolSwapTest" 2>/dev/null)"; then
    printf '%s\n' "${addr}"
    return 0
  fi
  forge script lib/v4-periphery/script/03_PoolSwapTest.s.sol:DeployPoolSwapTest \
    --sig "run(address)" "${POOL_MANAGER}" \
    --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" --broadcast >/dev/null
  helper_addr_from_artifacts "03_PoolSwapTest"
}

deploy_and_create_pipeline() {
  backup_config

  export REQUIRE_GUARDIAN_CONTRACT=0
  export PRIVATE_KEY="${OWNER_PK}"
  export GUARDIAN="${GUARDIAN_ADDR}"
  export CREATOR_FEE_ADDRESS="${OWNER_ADDR}"

  ./scripts/deploy_hook.sh --chain "${CHAIN}" --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" --broadcast >/tmp/preflight_deploy.log 2>&1

  HOOK_ADDRESS="$(extract_hook_from_deploy_json "${ROOT_DIR}/scripts/out/deploy.sepolia.json")"
  [[ -n "${HOOK_ADDRESS}" ]] || die "Failed to parse HOOK_ADDRESS from scripts/out/deploy.sepolia.json"
  set_config_hook_address "${HOOK_ADDRESS}"

  ./scripts/create_pool.sh --chain "${CHAIN}" --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" --broadcast >/tmp/preflight_create_pool.log 2>&1

  read -r TOKEN0 TOKEN1 <<<"$(sort_tokens "${VOLATILE}" "${STABLE}")"
  POOL_KEY="(${TOKEN0},${TOKEN1},${DYNAMIC_FEE_FLAG},${TICK_SPACING},${HOOK_ADDRESS})"
  POOL_ID="$(compute_pool_id "${VOLATILE}" "${STABLE}" "${TICK_SPACING}" "${HOOK_ADDRESS}")"
}

ensure_allowance_max() {
  local token="$1"
  local spender="$2"
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${token}" \
    "approve(address,uint256)" "${spender}" \
    "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" >/dev/null
}

bootstrap_liquidity() {
  local stable_balance liq params candidate
  local -a liquidity_candidates

  stable_balance="$(cast_call_single "${STABLE}" "balanceOf(address)(uint256)" "${OWNER_ADDR}")"
  if [[ -z "${stable_balance}" || "${stable_balance}" == "0" ]]; then
    die "Owner has zero stable token balance (${STABLE}) on fork; cannot bootstrap active liquidity for swaps"
  fi

  ensure_allowance_max "${STABLE}" "${MODIFY_HELPER}"
  ensure_allowance_max "${STABLE}" "${SWAP_HELPER}"

  liquidity_candidates=(
    "1000000000000000"
    "100000000000000"
    "10000000000000"
    "1000000000000"
    "100000000000"
    "10000000000"
    "1000000000"
  )

  for candidate in "${liquidity_candidates[@]}"; do
    params="(-887220,887220,${candidate},0x0000000000000000000000000000000000000000000000000000000000000000)"
    if cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" --value "5000000000000000000" "${MODIFY_HELPER}" \
      "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)" \
      "${POOL_KEY}" "${params}" "0x" >/dev/null 2>&1; then
      liq="${candidate}"
      break
    fi
  done

  [[ -n "${liq:-}" ]] || die "Failed to add active liquidity via PoolModifyLiquidityTest"
}

swap_exact_in_eth() {
  local amount_wei="$1"
  local params
  params="(true,-${amount_wei},${SQRT_PRICE_LIMIT_X96_ZFO})"
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" --value "${amount_wei}" "${SWAP_HELPER}" \
    "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)(bytes32)" \
    "${POOL_KEY}" "${params}" "(false,false)" "0x" >/dev/null
}

close_period_with_seed() {
  local seed_amount="$1"
  local period
  period="$(cast_call_single "${HOOK_ADDRESS}" "periodSeconds()(uint32)")"
  warp_seconds "$((period + 1))"
  swap_exact_in_eth "${seed_amount}"
}

load_fee_tiers() {
  local count i
  FEE_TIERS_BY_IDX=()
  count="$(cast_call_single "${HOOK_ADDRESS}" "feeTierCount()(uint16)")"
  for i in $(seq 0 $((count - 1))); do
    FEE_TIERS_BY_IDX+=("$(cast_call_single "${HOOK_ADDRESS}" "feeTiers(uint256)(uint24)" "${i}")")
  done
  FLOOR_IDX="$(cast_call_single "${HOOK_ADDRESS}" "floorIdx()(uint8)")"
  CASH_IDX="$(cast_call_single "${HOOK_ADDRESS}" "cashIdx()(uint8)")"
  EXTREME_IDX="$(cast_call_single "${HOOK_ADDRESS}" "extremeIdx()(uint8)")"
  CAP_IDX="$(cast_call_single "${HOOK_ADDRESS}" "capIdx()(uint8)")"
}

tier_by_idx() {
  local idx="$1"
  printf '%s\n' "${FEE_TIERS_BY_IDX[${idx}]}"
}

load_controller_params() {
  CP_MIN_CLOSEVOL_TO_CASH_USD6="$(cast_call_single "${HOOK_ADDRESS}" "minCloseVolToCashUsd6()(uint64)")"
  CP_UP_R_TO_CASH_BPS="$(cast_call_single "${HOOK_ADDRESS}" "upRToCashBps()(uint16)")"
  CP_CASH_HOLD_PERIODS="$(cast_call_single "${HOOK_ADDRESS}" "cashHoldPeriods()(uint8)")"
  CP_MIN_CLOSEVOL_TO_EXTREME_USD6="$(cast_call_single "${HOOK_ADDRESS}" "minCloseVolToExtremeUsd6()(uint64)")"
  CP_UP_R_TO_EXTREME_BPS="$(cast_call_single "${HOOK_ADDRESS}" "upRToExtremeBps()(uint16)")"
  CP_UP_EXTREME_CONFIRM_PERIODS="$(cast_call_single "${HOOK_ADDRESS}" "upExtremeConfirmPeriods()(uint8)")"
  CP_EXTREME_HOLD_PERIODS="$(cast_call_single "${HOOK_ADDRESS}" "extremeHoldPeriods()(uint8)")"
  CP_DOWN_R_FROM_EXTREME_BPS="$(cast_call_single "${HOOK_ADDRESS}" "downRFromExtremeBps()(uint16)")"
  CP_DOWN_EXTREME_CONFIRM_PERIODS="$(cast_call_single "${HOOK_ADDRESS}" "downExtremeConfirmPeriods()(uint8)")"
  CP_DOWN_R_FROM_CASH_BPS="$(cast_call_single "${HOOK_ADDRESS}" "downRFromCashBps()(uint16)")"
  CP_DOWN_CASH_CONFIRM_PERIODS="$(cast_call_single "${HOOK_ADDRESS}" "downCashConfirmPeriods()(uint8)")"
  CP_EMERGENCY_FLOOR_CLOSEVOL_USD6="$(cast_call_single "${HOOK_ADDRESS}" "emergencyFloorCloseVolUsd6()(uint64)")"
  CP_EMERGENCY_CONFIRM_PERIODS="$(cast_call_single "${HOOK_ADDRESS}" "emergencyConfirmPeriods()(uint8)")"
}

persist_base_controller() {
  load_controller_params
  BASE_MIN_CLOSEVOL_TO_CASH_USD6="${CP_MIN_CLOSEVOL_TO_CASH_USD6}"
  BASE_UP_R_TO_CASH_BPS="${CP_UP_R_TO_CASH_BPS}"
  BASE_CASH_HOLD_PERIODS="${CP_CASH_HOLD_PERIODS}"
  BASE_MIN_CLOSEVOL_TO_EXTREME_USD6="${CP_MIN_CLOSEVOL_TO_EXTREME_USD6}"
  BASE_UP_R_TO_EXTREME_BPS="${CP_UP_R_TO_EXTREME_BPS}"
  BASE_UP_EXTREME_CONFIRM_PERIODS="${CP_UP_EXTREME_CONFIRM_PERIODS}"
  BASE_EXTREME_HOLD_PERIODS="${CP_EXTREME_HOLD_PERIODS}"
  BASE_DOWN_R_FROM_EXTREME_BPS="${CP_DOWN_R_FROM_EXTREME_BPS}"
  BASE_DOWN_EXTREME_CONFIRM_PERIODS="${CP_DOWN_EXTREME_CONFIRM_PERIODS}"
  BASE_DOWN_R_FROM_CASH_BPS="${CP_DOWN_R_FROM_CASH_BPS}"
  BASE_DOWN_CASH_CONFIRM_PERIODS="${CP_DOWN_CASH_CONFIRM_PERIODS}"
  BASE_EMERGENCY_FLOOR_CLOSEVOL_USD6="${CP_EMERGENCY_FLOOR_CLOSEVOL_USD6}"
  BASE_EMERGENCY_CONFIRM_PERIODS="${CP_EMERGENCY_CONFIRM_PERIODS}"
}

set_controller_params() {
  local tuple
  tuple="(${CP_MIN_CLOSEVOL_TO_CASH_USD6},${CP_UP_R_TO_CASH_BPS},${CP_CASH_HOLD_PERIODS},${CP_MIN_CLOSEVOL_TO_EXTREME_USD6},${CP_UP_R_TO_EXTREME_BPS},${CP_UP_EXTREME_CONFIRM_PERIODS},${CP_EXTREME_HOLD_PERIODS},${CP_DOWN_R_FROM_EXTREME_BPS},${CP_DOWN_EXTREME_CONFIRM_PERIODS},${CP_DOWN_R_FROM_CASH_BPS},${CP_DOWN_CASH_CONFIRM_PERIODS},${CP_EMERGENCY_FLOOR_CLOSEVOL_USD6},${CP_EMERGENCY_CONFIRM_PERIODS})"
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))" \
    "${tuple}" >/dev/null
}

restore_base_controller() {
  CP_MIN_CLOSEVOL_TO_CASH_USD6="${BASE_MIN_CLOSEVOL_TO_CASH_USD6}"
  CP_UP_R_TO_CASH_BPS="${BASE_UP_R_TO_CASH_BPS}"
  CP_CASH_HOLD_PERIODS="${BASE_CASH_HOLD_PERIODS}"
  CP_MIN_CLOSEVOL_TO_EXTREME_USD6="${BASE_MIN_CLOSEVOL_TO_EXTREME_USD6}"
  CP_UP_R_TO_EXTREME_BPS="${BASE_UP_R_TO_EXTREME_BPS}"
  CP_UP_EXTREME_CONFIRM_PERIODS="${BASE_UP_EXTREME_CONFIRM_PERIODS}"
  CP_EXTREME_HOLD_PERIODS="${BASE_EXTREME_HOLD_PERIODS}"
  CP_DOWN_R_FROM_EXTREME_BPS="${BASE_DOWN_R_FROM_EXTREME_BPS}"
  CP_DOWN_EXTREME_CONFIRM_PERIODS="${BASE_DOWN_EXTREME_CONFIRM_PERIODS}"
  CP_DOWN_R_FROM_CASH_BPS="${BASE_DOWN_R_FROM_CASH_BPS}"
  CP_DOWN_CASH_CONFIRM_PERIODS="${BASE_DOWN_CASH_CONFIRM_PERIODS}"
  CP_EMERGENCY_FLOOR_CLOSEVOL_USD6="${BASE_EMERGENCY_FLOOR_CLOSEVOL_USD6}"
  CP_EMERGENCY_CONFIRM_PERIODS="${BASE_EMERGENCY_CONFIRM_PERIODS}"
  set_controller_params
}

reset_state_floor_unpaused() {
  cast send --rpc-url "${RPC_URL}" --private-key "${GUARDIAN_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null
  cast send --rpc-url "${RPC_URL}" --private-key "${GUARDIAN_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null
}

state_debug_json() {
  cast_call_json "${HOOK_ADDRESS}" "getStateDebug()(uint8,uint8,uint8,uint8,uint8,uint64,uint64,uint96,bool)"
}

scenario_s0() {
  local expected_mask hook_int hook_mask permissions fee_floor current_fee

  load_fee_tiers
  fee_floor="$(tier_by_idx "${FLOOR_IDX}")"
  current_fee="$(cast_call_single "${HOOK_ADDRESS}" "currentFeeBips()(uint24)")"
  assert_eq "initial fee is floor" "${current_fee}" "${fee_floor}" || return 1

  expected_mask=$(( (1 << 12) + (1 << 7) + (1 << 6) + (1 << 3) ))
  hook_int="$(python3 - <<'PY' "${HOOK_ADDRESS}"
import sys
print(int(sys.argv[1], 16))
PY
)"
  hook_mask="$((hook_int & expected_mask))"
  assert_eq "hook address flags mask" "${hook_mask}" "${expected_mask}" || return 1

  assert_eq "dynamic fee flag in pool key" "$(python3 - <<'PY' "${POOL_KEY}"
import re
import sys
m = re.search(r'\(([^,]+),([^,]+),([^,]+),', sys.argv[1])
print(m.group(3) if m else "")
PY
)" "${DYNAMIC_FEE_FLAG}" || return 1

  swap_exact_in_eth "2000000000000000" || return 1

  current_fee="$(cast_call_single "${HOOK_ADDRESS}" "currentFeeBips()(uint24)")"
  assert_eq "fee after smoke swap remains floor" "${current_fee}" "${fee_floor}" || return 1

  SC_REASON="deployed, pool initialized, minimal swap successful"
  refresh_metrics
}

scenario_s1() {
  local tiers_arg period ema lull deadband creator_bps ctrl_tuple
  local err_not_creator err_not_guardian

  err_not_creator="$(cast sig "NotCreator()")"
  err_not_guardian="$(cast sig "NotGuardian()")"

  load_fee_tiers
  load_controller_params

  tiers_arg="[$(IFS=,; echo "${FEE_TIERS_BY_IDX[*]}")]"
  period="$(cast_call_single "${HOOK_ADDRESS}" "periodSeconds()(uint32)")"
  ema="$(cast_call_single "${HOOK_ADDRESS}" "emaPeriods()(uint8)")"
  lull="$(cast_call_single "${HOOK_ADDRESS}" "lullResetSeconds()(uint32)")"
  deadband="$(cast_call_single "${HOOK_ADDRESS}" "deadbandBps()(uint16)")"
  creator_bps="$(cast_call_single "${HOOK_ADDRESS}" "creatorFeeBps()(uint16)")"
  ctrl_tuple="(${CP_MIN_CLOSEVOL_TO_CASH_USD6},${CP_UP_R_TO_CASH_BPS},${CP_CASH_HOLD_PERIODS},${CP_MIN_CLOSEVOL_TO_EXTREME_USD6},${CP_UP_R_TO_EXTREME_BPS},${CP_UP_EXTREME_CONFIRM_PERIODS},${CP_EXTREME_HOLD_PERIODS},${CP_DOWN_R_FROM_EXTREME_BPS},${CP_DOWN_EXTREME_CONFIRM_PERIODS},${CP_DOWN_R_FROM_CASH_BPS},${CP_DOWN_CASH_CONFIRM_PERIODS},${CP_EMERGENCY_FLOOR_CLOSEVOL_USD6},${CP_EMERGENCY_CONFIRM_PERIODS})"

  expect_revert "non-owner setFeeTiersAndRoles" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OUTSIDER_ADDR}\" \"${HOOK_ADDRESS}\" \"setFeeTiersAndRoles(uint24[],uint8,uint8,uint8,uint8)\" \"${tiers_arg}\" \"${FLOOR_IDX}\" \"${CASH_IDX}\" \"${EXTREME_IDX}\" \"${CAP_IDX}\"" \
    "${err_not_creator}" || return 1
  expect_revert "non-owner setTimingParams" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OUTSIDER_ADDR}\" \"${HOOK_ADDRESS}\" \"setTimingParams(uint32,uint8,uint32,uint16)\" \"${period}\" \"${ema}\" \"${lull}\" \"${deadband}\"" \
    "${err_not_creator}" || return 1
  expect_revert "non-owner setControllerParams" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OUTSIDER_ADDR}\" \"${HOOK_ADDRESS}\" \"setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))\" \"${ctrl_tuple}\"" \
    "${err_not_creator}" || return 1
  expect_revert "non-owner setCreatorFeePercent" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OUTSIDER_ADDR}\" \"${HOOK_ADDRESS}\" \"setCreatorFeePercent(uint16)\" 1" \
    "${err_not_creator}" || return 1
  expect_revert "non-owner setCreatorFeeConfig" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OUTSIDER_ADDR}\" \"${HOOK_ADDRESS}\" \"setCreatorFeeConfig(address,uint16)\" \"${OUTSIDER_ADDR}\" \"${creator_bps}\"" \
    "${err_not_creator}" || return 1
  expect_revert "non-owner setGuardian" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OUTSIDER_ADDR}\" \"${HOOK_ADDRESS}\" \"setGuardian(address)\" \"${OUTSIDER_ADDR}\"" \
    "${err_not_creator}" || return 1

  cast send --rpc-url "${RPC_URL}" --private-key "${GUARDIAN_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1
  cast send --rpc-url "${RPC_URL}" --private-key "${GUARDIAN_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1
  expect_revert "guardian cannot setGuardian" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${GUARDIAN_ADDR}\" \"${HOOK_ADDRESS}\" \"setGuardian(address)\" \"${GUARDIAN_ADDR}\"" \
    "${err_not_creator}" || return 1
  expect_revert "outsider cannot pause" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OUTSIDER_ADDR}\" \"${HOOK_ADDRESS}\" \"pause()\"" \
    "${err_not_guardian}" || return 1

  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8,uint8)" "${tiers_arg}" "${FLOOR_IDX}" "${CASH_IDX}" "${EXTREME_IDX}" "${CAP_IDX}" >/dev/null || return 1
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setTimingParams(uint32,uint8,uint32,uint16)" "${period}" "${ema}" "${lull}" "${deadband}" >/dev/null || return 1
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))" "${ctrl_tuple}" >/dev/null || return 1
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "setCreatorFeePercent(uint16)" 0 >/dev/null || return 1
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "setCreatorFeeConfig(address,uint16)" "${OWNER_ADDR}" "${creator_bps}" >/dev/null || return 1
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "setGuardian(address)" "${GUARDIAN_ADDR}" >/dev/null || return 1
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1

  SC_REASON="role gating enforced; guardian limited to pause flow; owner control ok"
  refresh_metrics
}

scenario_s2() {
  local err_requires_paused tiers_arg floor_fee now_ts period ema lull deadband
  local state_json fee_idx hold_rem up_streak down_streak em_streak period_start ema_vol

  err_requires_paused="$(cast sig "RequiresPaused()")"
  load_fee_tiers
  tiers_arg="[$(IFS=,; echo "${FEE_TIERS_BY_IDX[*]}")]"
  floor_fee="$(tier_by_idx "${FLOOR_IDX}")"
  period="$(cast_call_single "${HOOK_ADDRESS}" "periodSeconds()(uint32)")"
  ema="$(cast_call_single "${HOOK_ADDRESS}" "emaPeriods()(uint8)")"
  lull="$(cast_call_single "${HOOK_ADDRESS}" "lullResetSeconds()(uint32)")"
  deadband="$(cast_call_single "${HOOK_ADDRESS}" "deadbandBps()(uint16)")"

  swap_exact_in_eth "3000000000000000" || return 1
  close_period_with_seed "1000000000000000" || return 1

  expect_revert "setFeeTiersAndRoles requires paused" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setFeeTiersAndRoles(uint24[],uint8,uint8,uint8,uint8)\" \"${tiers_arg}\" \"${FLOOR_IDX}\" \"${CASH_IDX}\" \"${EXTREME_IDX}\" \"${CAP_IDX}\"" \
    "${err_requires_paused}" || return 1

  cast send --rpc-url "${RPC_URL}" --private-key "${GUARDIAN_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8,uint8)" "${tiers_arg}" "${FLOOR_IDX}" "${CASH_IDX}" "${EXTREME_IDX}" "${CAP_IDX}" >/dev/null || return 1

  now_ts="$(block_timestamp)"
  state_json="$(state_debug_json)"
  fee_idx="$(jq -r '.[0]' <<<"${state_json}")"
  hold_rem="$(jq -r '.[1]' <<<"${state_json}")"
  up_streak="$(jq -r '.[2]' <<<"${state_json}")"
  down_streak="$(jq -r '.[3]' <<<"${state_json}")"
  em_streak="$(jq -r '.[4]' <<<"${state_json}")"
  period_start="$(jq -r '.[5]' <<<"${state_json}")"
  ema_vol="$(jq -r '.[7]' <<<"${state_json}")"
  assert_eq "tiers reset feeIdx=floor" "${fee_idx}" "${FLOOR_IDX}" || return 1
  assert_eq "tiers reset hold=0" "${hold_rem}" "0" || return 1
  assert_eq "tiers reset upStreak=0" "${up_streak}" "0" || return 1
  assert_eq "tiers reset downStreak=0" "${down_streak}" "0" || return 1
  assert_eq "tiers reset emergencyStreak=0" "${em_streak}" "0" || return 1
  assert_eq "tiers reset ema=0" "${ema_vol}" "0" || return 1
  if (( period_start > now_ts + 2 || period_start + 2 < now_ts )); then
    set_scenario_fail "periodStart mismatch after setFeeTiersAndRoles reset" || return 1
  fi
  assert_eq "paused true after pause flow" "$(cast_call_single "${HOOK_ADDRESS}" "isPaused()(bool)")" "true" || return 1
  cast send --rpc-url "${RPC_URL}" --private-key "${GUARDIAN_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1
  assert_eq "fee still floor after tiers reset" "$(cast_call_single "${HOOK_ADDRESS}" "currentFeeBips()(uint24)")" "${floor_fee}" || return 1

  swap_exact_in_eth "3000000000000000" || return 1
  close_period_with_seed "1000000000000000" || return 1

  expect_revert "setTimingParams requires paused" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setTimingParams(uint32,uint8,uint32,uint16)\" \"${period}\" \"${ema}\" \"${lull}\" \"${deadband}\"" \
    "${err_requires_paused}" || return 1

  cast send --rpc-url "${RPC_URL}" --private-key "${GUARDIAN_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setTimingParams(uint32,uint8,uint32,uint16)" "${period}" "${ema}" "${lull}" "${deadband}" >/dev/null || return 1
  now_ts="$(block_timestamp)"
  state_json="$(state_debug_json)"
  fee_idx="$(jq -r '.[0]' <<<"${state_json}")"
  hold_rem="$(jq -r '.[1]' <<<"${state_json}")"
  up_streak="$(jq -r '.[2]' <<<"${state_json}")"
  down_streak="$(jq -r '.[3]' <<<"${state_json}")"
  em_streak="$(jq -r '.[4]' <<<"${state_json}")"
  period_start="$(jq -r '.[5]' <<<"${state_json}")"
  ema_vol="$(jq -r '.[7]' <<<"${state_json}")"
  assert_eq "timing reset feeIdx=floor" "${fee_idx}" "${FLOOR_IDX}" || return 1
  assert_eq "timing reset hold=0" "${hold_rem}" "0" || return 1
  assert_eq "timing reset upStreak=0" "${up_streak}" "0" || return 1
  assert_eq "timing reset downStreak=0" "${down_streak}" "0" || return 1
  assert_eq "timing reset emergencyStreak=0" "${em_streak}" "0" || return 1
  assert_eq "timing reset ema=0" "${ema_vol}" "0" || return 1
  if (( period_start > now_ts + 2 || period_start + 2 < now_ts )); then
    set_scenario_fail "periodStart mismatch after setTimingParams reset" || return 1
  fi
  cast send --rpc-url "${RPC_URL}" --private-key "${GUARDIAN_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1

  SC_REASON="pause gating for cold updates enforced; reset semantics deterministic"
  refresh_metrics
}

scenario_s3() {
  local original_up_cash original_min_cash original_cash_hold original_down_cash_confirm

  load_controller_params
  original_up_cash="${CP_UP_R_TO_CASH_BPS}"
  original_min_cash="${CP_MIN_CLOSEVOL_TO_CASH_USD6}"
  original_cash_hold="${CP_CASH_HOLD_PERIODS}"
  original_down_cash_confirm="${CP_DOWN_CASH_CONFIRM_PERIODS}"

  CP_UP_R_TO_CASH_BPS="$((original_up_cash + 1))"
  set_controller_params || return 1
  assert_eq "hot update upRToCashBps" "$(cast_call_single "${HOOK_ADDRESS}" "upRToCashBps()(uint16)")" "${CP_UP_R_TO_CASH_BPS}" || return 1

  CP_MIN_CLOSEVOL_TO_CASH_USD6="$((original_min_cash + 123456))"
  set_controller_params || return 1
  assert_eq "hot update minCloseVolToCashUsd6" "$(cast_call_single "${HOOK_ADDRESS}" "minCloseVolToCashUsd6()(uint64)")" "${CP_MIN_CLOSEVOL_TO_CASH_USD6}" || return 1

  CP_CASH_HOLD_PERIODS="$((original_cash_hold + 1))"
  if (( CP_CASH_HOLD_PERIODS > 31 )); then CP_CASH_HOLD_PERIODS=31; fi
  set_controller_params || return 1
  assert_eq "hot update cashHoldPeriods" "$(cast_call_single "${HOOK_ADDRESS}" "cashHoldPeriods()(uint8)")" "${CP_CASH_HOLD_PERIODS}" || return 1

  CP_DOWN_CASH_CONFIRM_PERIODS="$((original_down_cash_confirm + 1))"
  if (( CP_DOWN_CASH_CONFIRM_PERIODS > 7 )); then CP_DOWN_CASH_CONFIRM_PERIODS=7; fi
  set_controller_params || return 1
  assert_eq "hot update downCashConfirmPeriods" "$(cast_call_single "${HOOK_ADDRESS}" "downCashConfirmPeriods()(uint8)")" "${CP_DOWN_CASH_CONFIRM_PERIODS}" || return 1

  SC_REASON="controller hot params updated live and persisted"
  refresh_metrics
}

scenario_s4() {
  local limit expected_revert creator_bps after_bps creator_now

  limit="$(cast_call_single "${HOOK_ADDRESS}" "creatorFeeLimitPercent()(uint16)")"
  assert_eq "creator fee limit" "${limit}" "10" || return 1

  expected_revert="$(cast sig "CreatorFeePercentLimitExceeded(uint16,uint16)")"
  expect_revert "creator fee percent above limit" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setCreatorFeePercent(uint16)\" 11" \
    "${expected_revert}" || return 1

  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "setCreatorFeePercent(uint16)" 5 >/dev/null || return 1
  after_bps="$(cast_call_single "${HOOK_ADDRESS}" "creatorFeeBps()(uint16)")"
  assert_eq "creator fee bps updated to 500" "${after_bps}" "500" || return 1

  creator_bps="$(cast_call_single "${HOOK_ADDRESS}" "creatorFeeBps()(uint16)")"
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "setCreatorFeeConfig(address,uint16)" "${GUARDIAN_ADDR}" "${creator_bps}" >/dev/null || return 1
  creator_now="$(cast_call_single "${HOOK_ADDRESS}" "creator()(address)")"
  assert_eq "creator switched to guardian" "${creator_now,,}" "${GUARDIAN_ADDR,,}" || return 1

  cast send --rpc-url "${RPC_URL}" --private-key "${GUARDIAN_PK}" "${HOOK_ADDRESS}" "setCreatorFeeConfig(address,uint16)" "${OWNER_ADDR}" "${creator_bps}" >/dev/null || return 1
  creator_now="$(cast_call_single "${HOOK_ADDRESS}" "creator()(address)")"
  assert_eq "creator switched back to owner" "${creator_now,,}" "${OWNER_ADDR,,}" || return 1

  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "setCreatorFeePercent(uint16)" 0 >/dev/null || return 1
  after_bps="$(cast_call_single "${HOOK_ADDRESS}" "creatorFeeBps()(uint16)")"
  assert_eq "creator fee bps back to zero" "${after_bps}" "0" || return 1
  swap_exact_in_eth "1500000000000000" || return 1

  SC_REASON="creator fee limit enforced; address mutable; percent zero path healthy"
  refresh_metrics
}

scenario_s5() {
  local state_json fee_idx hold_rem up_streak down_streak em_streak
  local floor_idx cash_idx extreme_idx
  local high_swap low_swap

  high_swap="3000000000000000"
  low_swap="1000000000000"

  load_fee_tiers
  floor_idx="${FLOOR_IDX}"
  cash_idx="${CASH_IDX}"
  extreme_idx="${EXTREME_IDX}"

  reset_state_floor_unpaused || return 1
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "setCreatorFeePercent(uint16)" 0 >/dev/null || return 1

  load_controller_params
  CP_MIN_CLOSEVOL_TO_CASH_USD6="1000000"
  CP_UP_R_TO_CASH_BPS="9000"
  CP_CASH_HOLD_PERIODS="2"
  CP_MIN_CLOSEVOL_TO_EXTREME_USD6="1000000"
  CP_UP_R_TO_EXTREME_BPS="9000"
  CP_UP_EXTREME_CONFIRM_PERIODS="2"
  CP_EXTREME_HOLD_PERIODS="2"
  CP_DOWN_R_FROM_EXTREME_BPS="11000"
  CP_DOWN_EXTREME_CONFIRM_PERIODS="2"
  CP_DOWN_R_FROM_CASH_BPS="11000"
  CP_DOWN_CASH_CONFIRM_PERIODS="2"
  CP_EMERGENCY_FLOOR_CLOSEVOL_USD6="1"
  CP_EMERGENCY_CONFIRM_PERIODS="3"
  set_controller_params || return 1

  state_json="$(state_debug_json)"
  assert_eq "bootstrap ema starts at 0" "$(jq -r '.[7]' <<<"${state_json}")" "0" || return 1

  swap_exact_in_eth "${high_swap}" || return 1
  close_period_with_seed "${high_swap}" || return 1
  fee_idx="$(jq -r '.[0]' <<<"$(state_debug_json)")"
  assert_eq "bootstrap closure stays floor" "${fee_idx}" "${floor_idx}" || return 1

  swap_exact_in_eth "${high_swap}" || return 1
  close_period_with_seed "${high_swap}" || return 1
  state_json="$(state_debug_json)"
  fee_idx="$(jq -r '.[0]' <<<"${state_json}")"
  hold_rem="$(jq -r '.[1]' <<<"${state_json}")"
  assert_eq "jump to cash" "${fee_idx}" "${cash_idx}" || return 1
  assert_true "cash hold set >0" "[[ ${hold_rem} -gt 0 ]]" || return 1

  swap_exact_in_eth "${high_swap}" || return 1
  close_period_with_seed "${high_swap}" || return 1
  state_json="$(state_debug_json)"
  fee_idx="$(jq -r '.[0]' <<<"${state_json}")"
  up_streak="$(jq -r '.[2]' <<<"${state_json}")"
  assert_eq "still cash after first extreme confirm" "${fee_idx}" "${cash_idx}" || return 1
  assert_true "upExtreme streak started" "[[ ${up_streak} -ge 1 ]]" || return 1

  swap_exact_in_eth "${high_swap}" || return 1
  close_period_with_seed "${high_swap}" || return 1
  state_json="$(state_debug_json)"
  fee_idx="$(jq -r '.[0]' <<<"${state_json}")"
  hold_rem="$(jq -r '.[1]' <<<"${state_json}")"
  assert_eq "jump to extreme after confirms" "${fee_idx}" "${extreme_idx}" || return 1
  assert_true "extreme hold set >0" "[[ ${hold_rem} -gt 0 ]]" || return 1

  close_period_with_seed "${low_swap}" || return 1
  assert_eq "down blocked by hold #1" "$(jq -r '.[0]' <<<"$(state_debug_json)")" "${extreme_idx}" || return 1

  close_period_with_seed "${low_swap}" || return 1
  state_json="$(state_debug_json)"
  assert_eq "still extreme while down confirmations start" "$(jq -r '.[0]' <<<"${state_json}")" "${extreme_idx}" || return 1
  assert_true "down streak started from extreme" "[[ $(jq -r '.[3]' <<<"${state_json}") -ge 1 ]]" || return 1

  close_period_with_seed "${low_swap}" || return 1
  assert_eq "extreme down to cash after confirms" "$(jq -r '.[0]' <<<"$(state_debug_json)")" "${cash_idx}" || return 1

  close_period_with_seed "${low_swap}" || return 1
  assert_eq "cash down confirm #1 keeps cash" "$(jq -r '.[0]' <<<"$(state_debug_json)")" "${cash_idx}" || return 1

  close_period_with_seed "${low_swap}" || return 1
  assert_eq "cash down to floor after confirms" "$(jq -r '.[0]' <<<"$(state_debug_json)")" "${floor_idx}" || return 1

  CP_EMERGENCY_FLOOR_CLOSEVOL_USD6="900000000000"
  CP_EMERGENCY_CONFIRM_PERIODS="2"
  set_controller_params || return 1

  swap_exact_in_eth "${high_swap}" || return 1
  close_period_with_seed "${high_swap}" || return 1
  assert_eq "re-enter cash for emergency test" "$(jq -r '.[0]' <<<"$(state_debug_json)")" "${cash_idx}" || return 1

  close_period_with_seed "${low_swap}" || return 1
  assert_eq "emergency confirm #1 keeps cash" "$(jq -r '.[0]' <<<"$(state_debug_json)")" "${cash_idx}" || return 1

  close_period_with_seed "${low_swap}" || return 1
  state_json="$(state_debug_json)"
  fee_idx="$(jq -r '.[0]' <<<"${state_json}")"
  hold_rem="$(jq -r '.[1]' <<<"${state_json}")"
  up_streak="$(jq -r '.[2]' <<<"${state_json}")"
  down_streak="$(jq -r '.[3]' <<<"${state_json}")"
  em_streak="$(jq -r '.[4]' <<<"${state_json}")"
  assert_eq "emergency floor forces floor" "${fee_idx}" "${floor_idx}" || return 1
  assert_eq "emergency reset hold" "${hold_rem}" "0" || return 1
  assert_eq "emergency reset up streak" "${up_streak}" "0" || return 1
  assert_eq "emergency reset down streak" "${down_streak}" "0" || return 1
  assert_eq "emergency reset emergency streak" "${em_streak}" "0" || return 1

  restore_base_controller || return 1

  SC_REASON="v2 state-machine transitions validated with warp/hold/confirm/emergency"
  refresh_metrics
}

scenario_s6() {
  local period lull warp_by state_json fee_idx hold_rem

  period="$(cast_call_single "${HOOK_ADDRESS}" "periodSeconds()(uint32)")"
  lull="$(cast_call_single "${HOOK_ADDRESS}" "lullResetSeconds()(uint32)")"
  warp_by=$((period * 4))
  if (( warp_by >= lull )); then
    warp_by=$((lull - 1))
  fi
  if (( warp_by < period )); then
    warp_by="${period}"
  fi

  warp_seconds "${warp_by}"
  swap_exact_in_eth "2000000000000000" || return 1

  state_json="$(state_debug_json)"
  fee_idx="$(jq -r '.[0]' <<<"${state_json}")"
  hold_rem="$(jq -r '.[1]' <<<"${state_json}")"
  assert_true "feeIdx in bounds after multi-period close" "[[ ${fee_idx} -ge ${FLOOR_IDX} && ${fee_idx} -le ${CAP_IDX} ]]" || return 1
  assert_true "holdRemaining sane" "[[ ${hold_rem} -ge 0 && ${hold_rem} -le 31 ]]" || return 1

  SC_REASON="multi-period close path executes without revert and keeps coherent state"
  refresh_metrics
}

scenario_s7() {
  local lull floor_idx cash_idx state_json fee_idx ema_vol hold_rem up_streak down_streak em_streak

  load_fee_tiers
  floor_idx="${FLOOR_IDX}"
  cash_idx="${CASH_IDX}"

  load_controller_params
  CP_MIN_CLOSEVOL_TO_CASH_USD6="1000000"
  CP_UP_R_TO_CASH_BPS="9000"
  CP_CASH_HOLD_PERIODS="2"
  CP_EMERGENCY_FLOOR_CLOSEVOL_USD6="1"
  CP_EMERGENCY_CONFIRM_PERIODS="3"
  set_controller_params || return 1

  reset_state_floor_unpaused || return 1
  swap_exact_in_eth "3000000000000000" || return 1
  close_period_with_seed "3000000000000000" || return 1
  swap_exact_in_eth "3000000000000000" || return 1
  close_period_with_seed "3000000000000000" || return 1
  assert_eq "lull precondition reaches cash" "$(jq -r '.[0]' <<<"$(state_debug_json)")" "${cash_idx}" || return 1

  lull="$(cast_call_single "${HOOK_ADDRESS}" "lullResetSeconds()(uint32)")"
  warp_seconds "$((lull + 1))"
  swap_exact_in_eth "1000000000000" || return 1

  state_json="$(state_debug_json)"
  fee_idx="$(jq -r '.[0]' <<<"${state_json}")"
  hold_rem="$(jq -r '.[1]' <<<"${state_json}")"
  up_streak="$(jq -r '.[2]' <<<"${state_json}")"
  down_streak="$(jq -r '.[3]' <<<"${state_json}")"
  em_streak="$(jq -r '.[4]' <<<"${state_json}")"
  ema_vol="$(jq -r '.[7]' <<<"${state_json}")"
  assert_eq "lull reset fee to floor" "${fee_idx}" "${floor_idx}" || return 1
  assert_eq "lull reset ema to zero" "${ema_vol}" "0" || return 1
  assert_eq "lull reset hold" "${hold_rem}" "0" || return 1
  assert_eq "lull reset up streak" "${up_streak}" "0" || return 1
  assert_eq "lull reset down streak" "${down_streak}" "0" || return 1
  assert_eq "lull reset emergency streak" "${em_streak}" "0" || return 1

  restore_base_controller || return 1

  SC_REASON="lull reset clears EMA/counters and returns fee to floor"
  refresh_metrics
}

scenario_s8() {
  local hook_addr removed_hits

  ./scripts/deploy_hook.sh --chain "${CHAIN}" --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" >/tmp/preflight_deploy_dry.log 2>&1 || return 1
  ./scripts/create_pool.sh --chain "${CHAIN}" --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" >/tmp/preflight_create_dry.log 2>&1 || return 1

  hook_addr="$(extract_hook_from_deploy_json "${ROOT_DIR}/scripts/out/deploy.sepolia.json")"
  [[ -n "${hook_addr}" ]] || return 1

  removed_hits="$(rg -n "setCreatorFeeAddress\\(|setControllerParamsO4\\(|legacyO4|obsoleteO4" scripts test/scripts -S || true)"
  if [[ -n "${removed_hits}" ]]; then
    set_scenario_fail "detected references to removed O4-era methods in scripts" || return 1
  fi

  SC_REASON="dry-run scripts succeeded and no removed O4 references detected"
  refresh_metrics
}

print_summary() {
  local id
  log ""
  log "===== PREFLIGHT SUMMARY ====="
  log "pass=${PASS_COUNT} fail=${FAIL_COUNT}"
  for id in S0 S1 S2 S3 S4 S5 S6 S7 S8; do
    log "${id}: ${SCENARIO_STATUS[${id}]:-N/A} - ${SCENARIO_REASON[${id}]:-n/a} | ${SCENARIO_METRICS[${id}]:-n/a}"
  done
}

main() {
  load_config
  apply_v2_defaults
  start_anvil
  prepare_accounts

  log "owner=${OWNER_ADDR}"
  log "guardian=${GUARDIAN_ADDR}"
  log "outsider=${OUTSIDER_ADDR}"
  log "chain=${CHAIN} chain_id=${CHAIN_ID}"

  deploy_and_create_pipeline
  MODIFY_HELPER="$(ensure_modify_helper)"
  SWAP_HELPER="$(ensure_swap_helper)"

  [[ -n "${MODIFY_HELPER}" ]] || die "Failed to resolve PoolModifyLiquidityTest helper"
  [[ -n "${SWAP_HELPER}" ]] || die "Failed to resolve PoolSwapTest helper"

  bootstrap_liquidity

  log "hook=${HOOK_ADDRESS}"
  log "pool_manager=${POOL_MANAGER}"
  log "pool_id=${POOL_ID}"
  log "pool_key=${POOL_KEY}"
  log "swap_helper=${SWAP_HELPER}"
  log "modify_helper=${MODIFY_HELPER}"

  load_fee_tiers
  persist_base_controller

  run_scenario "S0" scenario_s0
  run_scenario "S1" scenario_s1
  run_scenario "S2" scenario_s2
  run_scenario "S3" scenario_s3
  run_scenario "S4" scenario_s4
  run_scenario "S5" scenario_s5
  run_scenario "S6" scenario_s6
  run_scenario "S7" scenario_s7
  run_scenario "S8" scenario_s8

  print_summary
  if (( FAIL_COUNT > 0 )); then
    exit 1
  fi
}

main "$@"
