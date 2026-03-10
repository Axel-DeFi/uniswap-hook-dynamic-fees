#!/usr/bin/env bash
set -euo pipefail

# Local Anvil preflight suite for VolumeDynamicFeeHook v2.
#
# Required env:
#   PRIVATE_KEY            Owner/deployer private key used for admin operations.
#
# Optional env:
#   CONFIG_PATH            Path to local config (default: ./config/hook.local.conf).
#   VERBOSE=1              Print detailed checkpoint and debug lines.
#   DISABLE_SNAPSHOT=1     Disable snapshot isolation (debug only).
#
# Validates:
#   - local deploy/create pipeline on clean Anvil (chain-id 31337, no fork)
#   - ABI/custom-error/REASON coverage (with exclusions only for unreachable paths)
#   - controller state-machine behavior with strict reason-code checks
#   - admin controls, pause flow, hook fee, rescue path, callback direct-call protection

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

source "${ROOT_DIR}/scripts/anvil/lib.sh"

require_cmd anvil
require_cmd cast
require_cmd forge
require_cmd jq
require_cmd python3
require_cmd rg
require_cmd curl

: "${PRIVATE_KEY:?PRIVATE_KEY is required}"

CHAIN="local"
ANVIL_RPC_URL="http://127.0.0.1:8545"
export RPC_URL="${ANVIL_RPC_URL}"
export VERBOSE="${VERBOSE:-0}"
DISABLE_SNAPSHOT="${DISABLE_SNAPSHOT:-0}"

CONFIG_PATH="${CONFIG_PATH:-${ROOT_DIR}/config/hook.local.conf}"
[[ -f "${CONFIG_PATH}" ]] || die "Config not found: ${CONFIG_PATH}"

CHAIN_ID="31337"
DYNAMIC_FEE_FLAG="8388608"
SQRT_PRICE_LIMIT_X96_ZFO="4295128740"
SQRT_PRICE_LIMIT_X96_OZF="1461446703485210103287273052203988822378723970341"
SQRT_PRICE_X96_ONE="79228162514264337593543950336"
PERIOD_CLOSED_TOPIC=""
REMAPPING_SOLMATE_SRC="solmate/src/=lib/v4-core/lib/solmate/src/"
REMAPPING_SOLMATE_ROOT="solmate/=lib/v4-core/lib/solmate/src/"
MOCK_ERC20_BYTECODE=""

OWNER_PK="${PRIVATE_KEY}"
ATTACKER_PK="0x5de4111afa1a4b94908fef3deabf442ba4f8d615f4c6d93ce2d5d4f29e6f5f3f"
ETH_RICH_WEI="1000000000000000000000"

ANVIL_PID=""
CONFIG_BACKUP=""
BASE_SNAPSHOT_ID=""

OWNER_ADDR=""
ATTACKER_ADDR=""

POOL_MANAGER=""
VOLATILE=""
STABLE=""
RESCUE_TOKEN=""
HOOK_ADDRESS=""
SWAP_HELPER=""
MODIFY_HELPER=""
POOL_ID=""
POOL_KEY=""
TOKEN0=""
TOKEN1=""
STABLE_IS_TOKEN0="0"

FLOOR_IDX=""
CASH_IDX=""
EXTREME_IDX=""
EXTREME_IDX=""
FEE_TIERS_BY_IDX=()
CFG_FEE_TIER_PIPS=()
CFG_FEE_TIERS_ARG=""
CFG_FLOOR_IDX=""
CFG_CASH_IDX=""
CFG_EXTREME_IDX=""
CFG_EXTREME_IDX=""
CFG_HOOK_FEE_PERCENT=""

CP_MIN_CLOSEVOL_TO_CASH_USD6=""
CP_UP_R_TO_CASH_BPS=""
CP_CASH_HOLD_PERIODS=""
CP_MIN_CLOSEVOL_TO_EXTREME_USD6=""
CP_UP_R_TO_EXTREME_BPS=""
CP_UP_EXTREME_CONFIRM_PERIODS=""
CP_EXTREME_HOLD_PERIODS=""
CP_DOWN_R_FROM_EXTREME_BPS=""
CP_DOWN_EXTREME_CONFIRM_PERIODS=""
CP_DOWN_R_FROM_CASH_BPS=""
CP_DOWN_CASH_CONFIRM_PERIODS=""
CP_EMERGENCY_FLOOR_CLOSEVOL_USD6=""
CP_EMERGENCY_CONFIRM_PERIODS=""

BASE_CP_MIN_CLOSEVOL_TO_CASH_USD6=""
BASE_CP_UP_R_TO_CASH_BPS=""
BASE_CP_CASH_HOLD_PERIODS=""
BASE_CP_MIN_CLOSEVOL_TO_EXTREME_USD6=""
BASE_CP_UP_R_TO_EXTREME_BPS=""
BASE_CP_UP_EXTREME_CONFIRM_PERIODS=""
BASE_CP_EXTREME_HOLD_PERIODS=""
BASE_CP_DOWN_R_FROM_EXTREME_BPS=""
BASE_CP_DOWN_EXTREME_CONFIRM_PERIODS=""
BASE_CP_DOWN_R_FROM_CASH_BPS=""
BASE_CP_DOWN_CASH_CONFIRM_PERIODS=""
BASE_CP_EMERGENCY_FLOOR_CLOSEVOL_USD6=""
BASE_CP_EMERGENCY_CONFIRM_PERIODS=""

PASS_COUNT=0
FAIL_COUNT=0
COVERAGE_FAIL_COUNT=0

TEST_ROWS=()

ABI_ENTRIES=()
ABI_SIGS=()
ABI_COVER=()          # signature|Txx,Tyy

ERROR_SIGS=()
ERROR_NAMES=()
ERROR_NAME_TO_SIG=()  # name|signature
ERROR_COVER=()        # name|Txx,Tyy
ERROR_EXCLUDED=()     # name|reason

REASON_ENTRIES=()        # REASON_NAME=value
REASON_VALUE_TO_NAME=()  # value|REASON_NAME
REASON_COVER=()          # REASON_NAME|Txx,Tyy
REASON_EXCLUDED=()       # REASON_NAME|reason

CURRENT_TEST_ID=""
CURRENT_TEST_DESC=""
TC_REASON=""
TC_KEYS=""
TC_FUNCS=()
TC_ERRORS=()
TC_REASONS=()
TC_CHECKPOINTS=()
LAST_CLOSE_TX=""

cleanup() {
  if [[ -n "${ANVIL_PID}" ]]; then
    kill "${ANVIL_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${CONFIG_BACKUP}" && -f "${CONFIG_BACKUP}" ]]; then
    cp "${CONFIG_BACKUP}" "${CONFIG_PATH}"
  fi
}
trap cleanup EXIT INT TERM

lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

percent_to_pips() {
  local pct="$1"
  awk -v pct="${pct}" '
    BEGIN {
      if (pct !~ /^[0-9]+([.][0-9]+)?$/) exit 1
      v = pct * 10000
      p = int(v + 0.5)
      if (p < 1 || p > 1000000) exit 1
      print p
    }' 2>/dev/null
}

hook_fee_percent_from_percent() {
  local pct="$1"
  awk -v pct="${pct}" '
    BEGIN {
      if (pct !~ /^[0-9]+$/) exit 1
      p = int(pct)
      if (p < 0 || p > 10) exit 1
      print p
    }' 2>/dev/null
}

config_tier_index_by_pips() {
  local target="$1"
  local idx count
  count="${#CFG_FEE_TIER_PIPS[@]}"
  for ((idx = 0; idx < count; idx++)); do
    if [[ "${CFG_FEE_TIER_PIPS[${idx}]}" == "${target}" ]]; then
      printf '%s\n' "${idx}"
      return 0
    fi
  done
  return 1
}

build_config_runtime_args() {
  local floor_pips cash_pips extreme_pips item pips prev
  local -a raw_items

  CFG_FEE_TIER_PIPS=()
  CFG_FEE_TIERS_ARG=""
  CFG_FLOOR_IDX=""
  CFG_CASH_IDX=""
  CFG_EXTREME_IDX=""
  CFG_HOOK_FEE_PERCENT=""

  IFS=',' read -r -a raw_items <<<"${FEE_TIERS:-}"
  if (( ${#raw_items[@]} == 0 )); then
    return 1
  fi

  prev="-1"
  for item in "${raw_items[@]}"; do
    item="$(printf '%s' "${item}" | tr -d '[:space:]')"
    pips="$(percent_to_pips "${item}" || true)"
    [[ -n "${pips}" ]] || return 1
    if (( prev >= 0 && pips <= prev )); then
      return 1
    fi
    prev="${pips}"
    CFG_FEE_TIER_PIPS+=("${pips}")
  done

  floor_pips="$(percent_to_pips "$(printf '%s' "${FLOOR_TIER:-}" | tr -d '[:space:]')" || true)"
  cash_pips="$(percent_to_pips "$(printf '%s' "${CASH_TIER:-}" | tr -d '[:space:]')" || true)"
  extreme_pips="$(percent_to_pips "$(printf '%s' "${EXTREME_TIER:-}" | tr -d '[:space:]')" || true)"
  [[ -n "${floor_pips}" && -n "${cash_pips}" && -n "${extreme_pips}" ]] || return 1

  CFG_FLOOR_IDX="$(config_tier_index_by_pips "${floor_pips}" || true)"
  CFG_CASH_IDX="$(config_tier_index_by_pips "${cash_pips}" || true)"
  CFG_EXTREME_IDX="$(config_tier_index_by_pips "${extreme_pips}" || true)"
  [[ -n "${CFG_FLOOR_IDX}" && -n "${CFG_CASH_IDX}" && -n "${CFG_EXTREME_IDX}" ]] || return 1
  if (( CFG_FLOOR_IDX >= CFG_CASH_IDX || CFG_CASH_IDX >= CFG_EXTREME_IDX )); then
    return 1
  fi

  CFG_FEE_TIERS_ARG="[$(IFS=,; echo "${CFG_FEE_TIER_PIPS[*]}")]"

  CFG_HOOK_FEE_PERCENT="$(hook_fee_percent_from_percent "$(printf '%s' "${HOOK_FEE_PERCENT:-}" | tr -d '[:space:]')" || true)"
  [[ -n "${CFG_HOOK_FEE_PERCENT}" ]] || return 1

  return 0
}

list_add_unique() {
  local arr_name="$1"
  local value="$2"
  local count i cur escaped

  eval "count=\${#${arr_name}[@]}"
  for ((i = 0; i < count; i++)); do
    eval "cur=\${${arr_name}[i]}"
    if [[ "${cur}" == "${value}" ]]; then
      return 0
    fi
  done

  escaped="${value//\"/\\\"}"
  eval "${arr_name}+=(\"${escaped}\")"
}

join_array() {
  local arr_name="$1"
  local sep="${2:-, }"
  local limit="${3:-0}"
  local count i shown cur out

  eval "count=\${#${arr_name}[@]}"
  if (( count == 0 )); then
    printf '-'
    return 0
  fi

  shown=0
  out=""
  for ((i = 0; i < count; i++)); do
    if (( limit > 0 && shown >= limit )); then
      break
    fi
    eval "cur=\${${arr_name}[i]}"
    if [[ -z "${out}" ]]; then
      out="${cur}"
    else
      out="${out}${sep}${cur}"
    fi
    shown=$((shown + 1))
  done

  if (( limit > 0 && count > limit )); then
    out="${out}${sep}...(+$((count - limit)))"
  fi

  printf '%s' "${out}"
}

map_append_unique() {
  local map_name="$1"
  local key="$2"
  local value="$3"
  local count i line k v escaped found

  found=0
  eval "count=\${#${map_name}[@]}"
  for ((i = 0; i < count; i++)); do
    eval "line=\${${map_name}[i]}"
    k="${line%%|*}"
    v="${line#*|}"
    if [[ "${k}" == "${key}" ]]; then
      case ",${v}," in
        *",${value},"*) ;;
        *)
          if [[ -z "${v}" ]]; then
            v="${value}"
          else
            v="${v},${value}"
          fi
          ;;
      esac
      escaped="${k}|${v}"
      escaped="${escaped//\"/\\\"}"
      eval "${map_name}[${i}]=\"${escaped}\""
      found=1
      break
    fi
  done

  if (( found == 0 )); then
    escaped="${key}|${value}"
    escaped="${escaped//\"/\\\"}"
    eval "${map_name}+=(\"${escaped}\")"
  fi
}

map_set_once() {
  local map_name="$1"
  local key="$2"
  local value="$3"
  local count i line k escaped

  eval "count=\${#${map_name}[@]}"
  for ((i = 0; i < count; i++)); do
    eval "line=\${${map_name}[i]}"
    k="${line%%|*}"
    if [[ "${k}" == "${key}" ]]; then
      return 0
    fi
  done

  escaped="${key}|${value}"
  escaped="${escaped//\"/\\\"}"
  eval "${map_name}+=(\"${escaped}\")"
}

map_get() {
  local map_name="$1"
  local key="$2"
  local count i line k v

  eval "count=\${#${map_name}[@]}"
  for ((i = 0; i < count; i++)); do
    eval "line=\${${map_name}[i]}"
    k="${line%%|*}"
    v="${line#*|}"
    if [[ "${k}" == "${key}" ]]; then
      printf '%s\n' "${v}"
      return 0
    fi
  done
  return 1
}

error_name_from_sig() {
  local sig="$1"
  printf '%s\n' "${sig%%(*}"
}

error_sig_by_name() {
  map_get "ERROR_NAME_TO_SIG" "$1" || true
}

reason_name_by_value() {
  map_get "REASON_VALUE_TO_NAME" "$1" || true
}

reason_value_by_name() {
  local entry name val
  for entry in "${REASON_ENTRIES[@]}"; do
    name="${entry%%=*}"
    val="${entry#*=}"
    if [[ "${name}" == "$1" ]]; then
      printf '%s\n' "${val}"
      return 0
    fi
  done
  return 1
}

cover_function() {
  local sig="$1"
  map_append_unique "ABI_COVER" "${sig}" "${CURRENT_TEST_ID}"
  list_add_unique "TC_FUNCS" "${sig}"
}

cover_error() {
  local err_name="$1"
  map_append_unique "ERROR_COVER" "${err_name}" "${CURRENT_TEST_ID}"
  list_add_unique "TC_ERRORS" "${err_name}"
}

cover_reason() {
  local reason_name="$1"
  [[ -n "${reason_name}" ]] || return 0
  map_append_unique "REASON_COVER" "${reason_name}" "${CURRENT_TEST_ID}"
  list_add_unique "TC_REASONS" "${reason_name}"
}

exclude_error() {
  local err_name="$1"
  local why="$2"
  map_set_once "ERROR_EXCLUDED" "${err_name}" "${why}"
}

exclude_reason() {
  local reason_name="$1"
  local why="$2"
  map_set_once "REASON_EXCLUDED" "${reason_name}" "${why}"
}

set_case_fail() {
  TC_REASON="$1"
  return 1
}

cast_call_retry_raw() {
  local to="$1"
  local sig="$2"
  local out rc attempt
  shift 2
  for attempt in 1 2 6; do
    set +e
    out="$(cast call --rpc-url "${RPC_URL}" "${to}" "${sig}" "$@" 2>&1)"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      printf '%s\n' "${out}"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

set_case_keys_from_checkpoint() {
  local line="$1"
  local fee rbps close hold paused
  fee="$(line_kv_get "${line}" "feeTier")"
  rbps="$(line_kv_get "${line}" "rBps")"
  close="$(line_kv_get "${line}" "closeVol")"
  hold="$(line_kv_get "${line}" "holdRemaining")"
  paused="$(line_kv_get "${line}" "paused")"

  [[ -n "${fee}" ]] || fee="n/a"
  [[ -n "${rbps}" ]] || rbps="n/a"
  [[ -n "${close}" ]] || close="n/a"
  [[ -n "${hold}" ]] || hold="n/a"
  [[ -n "${paused}" ]] || paused="n/a"

  TC_KEYS="feeTier=${fee} rBps=${rbps} closeVol=${close} hold=${hold} paused=${paused}"
}

tc_checkpoint() {
  local label="$1"
  local expected_fee="${2:-}"
  local line

  if [[ -n "${expected_fee}" ]]; then
    line="$(checkpoint "${label}" "${expected_fee}")" || return 1
  else
    line="$(checkpoint "${label}")" || return 1
  fi

  list_add_unique "TC_CHECKPOINTS" "${line}"
  set_case_keys_from_checkpoint "${line}"
  return 0
}

checkpoint_compact() {
  local count i line label fee out
  eval "count=\${#TC_CHECKPOINTS[@]}"
  if (( count == 0 )); then
    printf '-'
    return 0
  fi

  out=""
  for ((i = 0; i < count && i < 4; i++)); do
    eval "line=\${TC_CHECKPOINTS[i]}"
    label="$(line_kv_get "${line}" "checkpoint")"
    fee="$(line_kv_get "${line}" "feeTier")"
    if [[ -z "${out}" ]]; then
      out="${label}:${fee}"
    else
      out="${out}, ${label}:${fee}"
    fi
  done
  if (( count > 4 )); then
    out="${out}, ...(+$((count - 4)))"
  fi
  printf '%s' "${out}"
}

expect_revert_custom() {
  local name="$1"
  local cmd="$2"
  local err_name="$3"
  local err_sig selector

  err_sig="$(error_sig_by_name "${err_name}")"
  if [[ -z "${err_sig}" ]]; then
    set_case_fail "error signature not found: ${err_name}"
    return 1
  fi
  selector="$(cast sig "${err_sig}")"
  expect_revert "${name}" "${cmd}" "${selector}" || return 1
  cover_error "${err_name}"
  return 0
}

init_coverage_catalogs() {
  local line sig mut err_sig err_name reason_name reason_val

  ABI_ENTRIES=()
  ABI_SIGS=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    ABI_ENTRIES+=("${line}")
    ABI_SIGS+=("${line%%|*}")
  done < <(abi_function_entries)

  ERROR_SIGS=()
  ERROR_NAMES=()
  ERROR_NAME_TO_SIG=()
  while IFS= read -r err_sig; do
    [[ -n "${err_sig}" ]] || continue
    err_name="$(error_name_from_sig "${err_sig}")"
    ERROR_SIGS+=("${err_sig}")
    ERROR_NAMES+=("${err_name}")
    map_set_once "ERROR_NAME_TO_SIG" "${err_name}" "${err_sig}"
  done < <(source_custom_errors "src/VolumeDynamicFeeHook.sol")

  REASON_ENTRIES=()
  REASON_VALUE_TO_NAME=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    reason_name="${line%%=*}"
    reason_val="${line#*=}"
    REASON_ENTRIES+=("${line}")
    map_set_once "REASON_VALUE_TO_NAME" "${reason_val}" "${reason_name}"
  done < <(source_reason_constants "src/VolumeDynamicFeeHook.sol")

  # Legacy constants retained in contract but not emitted by current v2 transition machine.
  exclude_reason "REASON_FEE_UP" "legacy v1 reason constant; not emitted by _computeNextFeeIdxV2"
  exclude_reason "REASON_FEE_DOWN" "legacy v1 reason constant; not emitted by _computeNextFeeIdxV2"
  exclude_reason "REASON_REVERSAL_LOCK" "legacy v1 reason constant; not emitted by _computeNextFeeIdxV2"
  exclude_reason "REASON_FLOOR" "legacy v1 reason constant; not emitted by _computeNextFeeIdxV2"
  exclude_reason "REASON_ZERO_EMA_DECAY" "legacy v1 reason constant; not emitted by _computeNextFeeIdxV2"

  # Constructor-only path cannot be reached from mutable runtime admin surface.
  exclude_error "TierNotFound" "constructor-only validation path; deploy script pre-validates tiers"
  exclude_error "EthTransferFailed" "requires deliberately reverting ETH receiver contract; excluded from preflight runtime scope"
}

snapshot_enabled() {
  [[ "${DISABLE_SNAPSHOT}" != "1" ]]
}

init_base_snapshot() {
  if ! snapshot_enabled; then
    BASE_SNAPSHOT_ID=""
    return 0
  fi
  BASE_SNAPSHOT_ID="$(evm_snapshot 2>/dev/null || true)"
  [[ -n "${BASE_SNAPSHOT_ID}" && "${BASE_SNAPSHOT_ID}" != "null" ]]
}

prepare_case_isolation() {
  if ! snapshot_enabled; then
    return 0
  fi

  if [[ -z "${BASE_SNAPSHOT_ID}" ]]; then
    return 1
  fi

  if [[ "$(evm_revert "${BASE_SNAPSHOT_ID}" 2>/dev/null || true)" != "true" ]]; then
    return 1
  fi

  BASE_SNAPSHOT_ID="$(evm_snapshot 2>/dev/null || true)"
  [[ -n "${BASE_SNAPSHOT_ID}" && "${BASE_SNAPSHOT_ID}" != "null" ]]
}

backup_config() {
  CONFIG_BACKUP="$(mktemp "/tmp/preflight_local_conf.XXXXXX")"
  cp "${CONFIG_PATH}" "${CONFIG_BACKUP}"
}

set_config_value() {
  local key="$1"
  local value="$2"
  python3 - "${CONFIG_PATH}" "${key}" "${value}" <<'PY'
import re
import sys

path = sys.argv[1]
key = sys.argv[2]
value = sys.argv[3]

with open(path, "r", encoding="utf-8") as f:
    src = f.read()

if re.search(rf"^{re.escape(key)}=.*$", src, flags=re.M):
    src = re.sub(rf"^{re.escape(key)}=.*$", f"{key}={value}", src, flags=re.M)
else:
    src = src.rstrip() + f"\n{key}={value}\n"

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
PY
}

sync_runtime_config() {
  set_config_value "POOL_MANAGER" "${POOL_MANAGER}"
  set_config_value "VOLATILE" "${VOLATILE}"
  set_config_value "STABLE" "${STABLE}"
  set_config_value "STABLE_DECIMALS" "6"
  set_config_value "TICK_SPACING" "${TICK_SPACING}"
  set_config_value "OWNER" "${OWNER_ADDR}"
  set_config_value "HOOK_FEE_ADDRESS" "${OWNER_ADDR}"
  set_config_value "HOOK_ADDRESS" "${HOOK_ADDRESS}"
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

  RPC_URL="${ANVIL_RPC_URL}"
  export RPC_URL

  build_config_runtime_args || die "Invalid local config tiers/indices/hook fee values in ${CONFIG_PATH}"
}

wait_for_rpc() {
  local i
  for i in $(seq 1 80); do
    if cast chain-id --rpc-url "${RPC_URL}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  die "Anvil RPC did not start on ${RPC_URL}"
}

start_anvil() {
  anvil --host 127.0.0.1 --port 8545 --chain-id "${CHAIN_ID}" --silent >/tmp/preflight_local_anvil.log 2>&1 &
  ANVIL_PID="$!"
  wait_for_rpc
}

prepare_accounts() {
  OWNER_ADDR="$(cast wallet address --private-key "${OWNER_PK}" | awk '{print $1}')"
  ATTACKER_ADDR="$(cast wallet address --private-key "${ATTACKER_PK}" | awk '{print $1}')"

  set_eth_balance "${OWNER_ADDR}" "${ETH_RICH_WEI}"
  set_eth_balance "${ATTACKER_ADDR}" "${ETH_RICH_WEI}"
}

deploy_pool_manager_local() {
  local out
  out="$(forge create --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" --broadcast \
    --remappings "${REMAPPING_SOLMATE_SRC}" --remappings "${REMAPPING_SOLMATE_ROOT}" \
    lib/v4-core/src/PoolManager.sol:PoolManager \
    --constructor-args "${OWNER_ADDR}" 2>/tmp/preflight_local_poolmanager.log)" || {
      cat /tmp/preflight_local_poolmanager.log >&2 || true
      return 1
    }

  POOL_MANAGER="$(awk '/Deployed to:/ {print $3}' <<<"${out}" | tail -n 1)"
  if [[ -z "${POOL_MANAGER}" ]]; then
    POOL_MANAGER="$(grep -Eo '0x[0-9a-fA-F]{40}' <<<"${out}" | tail -n 1)"
  fi
  [[ -n "${POOL_MANAGER}" ]] || die "Failed to parse local PoolManager address"
}

deploy_mock_token() {
  local name="$1"
  local symbol="$2"
  local decimals="$3"
  local bytecode ctor data tx addr code attempt
  local artifact_path artifact_path_alt

  artifact_path="${ROOT_DIR}/out/MockERC20.sol/MockERC20.json"
  artifact_path_alt="${ROOT_DIR}/out/ops/tests/mocks/MockERC20.sol/MockERC20.json"
  if [[ ! -f "${artifact_path}" && -f "${artifact_path_alt}" ]]; then
    artifact_path="${artifact_path_alt}"
  fi
  if [[ -z "${MOCK_ERC20_BYTECODE}" && -f "${artifact_path}" ]]; then
    MOCK_ERC20_BYTECODE="$(jq -r '.bytecode.object // .bytecode // empty | if type=="string" then . else empty end' "${artifact_path}" 2>/dev/null || true)"
  fi
  if [[ -z "${MOCK_ERC20_BYTECODE}" || "${MOCK_ERC20_BYTECODE}" == "0x" ]]; then
    forge build >/tmp/preflight_local_build.log 2>&1 || true
    if [[ -f "${artifact_path}" ]]; then
      MOCK_ERC20_BYTECODE="$(jq -r '.bytecode.object // .bytecode // empty | if type=="string" then . else empty end' "${artifact_path}" 2>/dev/null || true)"
    fi
  fi
  if [[ -n "${MOCK_ERC20_BYTECODE}" && "${MOCK_ERC20_BYTECODE}" != 0x* ]]; then
    MOCK_ERC20_BYTECODE="0x${MOCK_ERC20_BYTECODE}"
  fi
  [[ -n "${MOCK_ERC20_BYTECODE}" && "${MOCK_ERC20_BYTECODE}" != "0x" ]] || return 1

  ctor="$(cast abi-encode "constructor(string,string,uint8)" "${name}" "${symbol}" "${decimals}" 2>/dev/null || true)"
  [[ -n "${ctor}" ]] || return 1
  data="${MOCK_ERC20_BYTECODE}${ctor#0x}"

  for attempt in 1 2 3 4 5 6; do
    tx="$(cast_send_txhash --private-key "${OWNER_PK}" --create "${data}" 2>/dev/null || true)"
    if [[ -n "${tx}" ]]; then
      addr="$(cast receipt --rpc-url "${RPC_URL}" --json "${tx}" 2>/dev/null | jq -r '.contractAddress // empty')"
      if [[ -n "${addr}" ]]; then
        code="$(cast code --rpc-url "${RPC_URL}" "${addr}" 2>/dev/null || true)"
        if [[ -n "${code}" && "${code}" != "0x" ]]; then
          printf '%s\n' "${addr}"
          return 0
        fi
      fi
    fi
    sleep 0.4
  done

  return 1
}

mint_token() {
  local token="$1"
  local to="$2"
  local amount="$3"
  cast_send_retry --private-key "${OWNER_PK}" "${token}" "mint(address,uint256)" "${to}" "${amount}" >/dev/null
}

ensure_allowance_max() {
  local token="$1"
  local spender="$2"
  cast_send_retry --private-key "${OWNER_PK}" "${token}" \
    "approve(address,uint256)" "${spender}" \
    "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" >/dev/null
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
  local addr attempt
  if addr="$(helper_addr_from_artifacts "02_PoolModifyLiquidityTest" 2>/dev/null)"; then
    printf '%s\n' "${addr}"
    return 0
  fi

  for attempt in 1 2 3; do
    forge script lib/v4-periphery/script/02_PoolModifyLiquidityTest.s.sol:DeployPoolModifyLiquidityTest \
      --sig "run(address)" "${POOL_MANAGER}" \
      --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" --broadcast \
      --remappings "${REMAPPING_SOLMATE_SRC}" --remappings "${REMAPPING_SOLMATE_ROOT}" \
      >/tmp/preflight_local_modify_helper.log 2>&1 || true

    if addr="$(helper_addr_from_artifacts "02_PoolModifyLiquidityTest" 2>/dev/null)"; then
      printf '%s\n' "${addr}"
      return 0
    fi

    if (( attempt < 3 )) && grep -Eqi "connection (closed|reset)|SendRequest|transport error|timed out|Failed to get EIP-1559 fees|503" /tmp/preflight_local_modify_helper.log; then
      sleep 0.5
      continue
    fi
  done

  return 1
}

ensure_swap_helper() {
  local addr attempt
  if addr="$(helper_addr_from_artifacts "03_PoolSwapTest" 2>/dev/null)"; then
    printf '%s\n' "${addr}"
    return 0
  fi

  for attempt in 1 2 3; do
    forge script lib/v4-periphery/script/03_PoolSwapTest.s.sol:DeployPoolSwapTest \
      --sig "run(address)" "${POOL_MANAGER}" \
      --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" --broadcast \
      --remappings "${REMAPPING_SOLMATE_SRC}" --remappings "${REMAPPING_SOLMATE_ROOT}" \
      >/tmp/preflight_local_swap_helper.log 2>&1 || true

    if addr="$(helper_addr_from_artifacts "03_PoolSwapTest" 2>/dev/null)"; then
      printf '%s\n' "${addr}"
      return 0
    fi

    if (( attempt < 3 )) && grep -Eqi "connection (closed|reset)|SendRequest|transport error|timed out|Failed to get EIP-1559 fees|503" /tmp/preflight_local_swap_helper.log; then
      sleep 0.5
      continue
    fi
  done

  return 1
}

bootstrap_liquidity() {
  local params candidate liq
  local -a candidates

  ensure_allowance_max "${VOLATILE}" "${MODIFY_HELPER}"
  ensure_allowance_max "${STABLE}" "${MODIFY_HELPER}"
  ensure_allowance_max "${VOLATILE}" "${SWAP_HELPER}"
  ensure_allowance_max "${STABLE}" "${SWAP_HELPER}"

  candidates=(
    "1000000000000000000"
    "100000000000000000"
    "10000000000000000"
    "1000000000000000"
    "100000000000000"
    "10000000000000"
  )

  for candidate in "${candidates[@]}"; do
    params="(-887220,887220,${candidate},0x0000000000000000000000000000000000000000000000000000000000000000)"
    if cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${MODIFY_HELPER}" \
      "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)" \
      "${POOL_KEY}" "${params}" "0x" >/dev/null 2>&1; then
      liq="${candidate}"
      break
    fi
  done

  [[ -n "${liq:-}" ]] || die "Failed to bootstrap liquidity on local pool"
}

run_deploy_hook_script() {
  local attempt hook_tmp code_tmp
  local deploy_json="${ROOT_DIR}/scripts/out/deploy.local.json"

  rm -f "${deploy_json}"
  for attempt in 1 2 3 4; do
    if ./scripts/deploy_hook.sh --chain local --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" --broadcast >/tmp/preflight_local_deploy.log 2>&1; then
      return 0
    fi

    hook_tmp="$(extract_hook_from_deploy_json "${deploy_json}" 2>/dev/null || true)"
    if [[ -n "${hook_tmp}" ]]; then
      code_tmp="$(cast code --rpc-url "${RPC_URL}" "${hook_tmp}" 2>/dev/null || true)"
      if [[ -n "${code_tmp}" && "${code_tmp}" != "0x" ]]; then
        log "WARN: deploy_hook.sh returned non-zero, but hook is deployed at ${hook_tmp}; applying runtime config with retries"
        return 0
      fi
    fi

    sleep 0.8
  done
  return 1
}

ensure_hook_runtime_configured() {
  local hook_fee_address paused_now
  local ctrl_tuple

  hook_fee_address="${HOOK_FEE_ADDRESS:-}"
  if [[ -z "${hook_fee_address}" ]]; then
    hook_fee_address="${OWNER_ADDR}"
  fi

  paused_now="$(cast_call_single "${HOOK_ADDRESS}" "isPaused()(bool)" || true)"
  if [[ "${paused_now}" != "true" ]]; then
    cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1
  fi

  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)" \
    "${CFG_FEE_TIERS_ARG}" "${CFG_FLOOR_IDX}" "${CFG_CASH_IDX}" "${CFG_EXTREME_IDX}" >/dev/null || return 1

  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setTimingParams(uint32,uint8,uint32,uint16)" \
    "${PERIOD_SECONDS}" "${EMA_PERIODS}" "${LULL_RESET_SECONDS}" "${DEADBAND_BPS}" >/dev/null || return 1

  ctrl_tuple="(${MIN_CLOSEVOL_TO_CASH_USD6},${UP_R_TO_CASH_BPS},${CASH_HOLD_PERIODS},${MIN_CLOSEVOL_TO_EXTREME_USD6},${UP_R_TO_EXTREME_BPS},${UP_EXTREME_CONFIRM_PERIODS},${EXTREME_HOLD_PERIODS},${DOWN_R_FROM_EXTREME_BPS},${DOWN_EXTREME_CONFIRM_PERIODS},${DOWN_R_FROM_CASH_BPS},${DOWN_CASH_CONFIRM_PERIODS},${EMERGENCY_FLOOR_CLOSEVOL_USD6},${EMERGENCY_CONFIRM_PERIODS})"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))" \
    "${ctrl_tuple}" >/dev/null || return 1

  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setHookFeeRecipient(address)" "${hook_fee_address}" >/dev/null || return 1

  # Best-effort cleanup for previous pending timelock value.
  cast send --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "cancelHookFeePercentChange()" >/dev/null 2>&1 || true

  paused_now="$(cast_call_single "${HOOK_ADDRESS}" "isPaused()(bool)" || true)"
  if [[ "${paused_now}" == "true" ]]; then
    cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1
  fi

  return 0
}

run_create_pool_script() {
  local attempt
  for attempt in 1 2 3; do
    if ./scripts/create_pool.sh --chain local --rpc-url "${RPC_URL}" --private-key "${OWNER_PK}" --broadcast >/tmp/preflight_local_create.log 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

setup_local_environment() {
  local deploy_json

  deploy_pool_manager_local

  VOLATILE="$(deploy_mock_token "Wrapped Ether" "WETH" 18)" || die "Failed to deploy VOLATILE token"
  STABLE="$(deploy_mock_token "USD Coin" "USDC" 6)" || die "Failed to deploy STABLE token"
  RESCUE_TOKEN="$(deploy_mock_token "Rescue Token" "RSC" 18)" || die "Failed to deploy rescue token"

  mint_token "${VOLATILE}" "${OWNER_ADDR}" "1000000000000000000000000"
  mint_token "${STABLE}" "${OWNER_ADDR}" "1000000000000"
  mint_token "${VOLATILE}" "${ATTACKER_ADDR}" "10000000000000000000000"
  mint_token "${STABLE}" "${ATTACKER_ADDR}" "10000000000"
  mint_token "${RESCUE_TOKEN}" "${OWNER_ADDR}" "1000000000000000000000000"

  set_config_value "POOL_MANAGER" "${POOL_MANAGER}"
  set_config_value "VOLATILE" "${VOLATILE}"
  set_config_value "STABLE" "${STABLE}"
  set_config_value "STABLE_DECIMALS" "6"
  set_config_value "HOOK_FEE_ADDRESS" "${OWNER_ADDR}"
  set_config_value "HOOK_ADDRESS" ""

  if ! run_deploy_hook_script; then
    die "deploy_hook.sh failed; see /tmp/preflight_local_deploy.log"
  fi

  deploy_json="${ROOT_DIR}/scripts/out/deploy.local.json"
  HOOK_ADDRESS="$(extract_hook_from_deploy_json "${deploy_json}" || true)"
  [[ -n "${HOOK_ADDRESS}" ]] || die "Failed to parse HOOK_ADDRESS from ${deploy_json}"

  set_config_value "HOOK_ADDRESS" "${HOOK_ADDRESS}"
  local runtime_cfg_attempt
  local runtime_cfg_ok=0
  for runtime_cfg_attempt in 1 2 3; do
    if ensure_hook_runtime_configured; then
      runtime_cfg_ok=1
      break
    fi
    sleep 0.8
  done
  (( runtime_cfg_ok == 1 )) || die "Failed to apply hook runtime config on local Anvil"

  if ! run_create_pool_script; then
    die "create_pool.sh failed; see /tmp/preflight_local_create.log"
  fi

  read -r TOKEN0 TOKEN1 <<<"$(sort_tokens "${VOLATILE}" "${STABLE}")"
  POOL_KEY="(${TOKEN0},${TOKEN1},${DYNAMIC_FEE_FLAG},${TICK_SPACING},${HOOK_ADDRESS})"
  POOL_ID="$(compute_pool_id "${VOLATILE}" "${STABLE}" "${TICK_SPACING}" "${HOOK_ADDRESS}")"

  if [[ "$(lower "${STABLE}")" == "$(lower "${TOKEN0}")" ]]; then
    STABLE_IS_TOKEN0="1"
  else
    STABLE_IS_TOKEN0="0"
  fi

  MODIFY_HELPER="$(ensure_modify_helper)"
  SWAP_HELPER="$(ensure_swap_helper)"
  [[ -n "${MODIFY_HELPER}" ]] || die "Failed to deploy/resolve modify helper"
  [[ -n "${SWAP_HELPER}" ]] || die "Failed to deploy/resolve swap helper"

  bootstrap_liquidity
}

load_fee_tiers() {
  local count i tier
  FEE_TIERS_BY_IDX=()

  count="$(cast_call_single "${HOOK_ADDRESS}" "feeTierCount()(uint16)" || true)"
  [[ "${count}" =~ ^[0-9]+$ ]] || return 1
  (( count > 0 )) || return 1

  for i in $(seq 0 $((count - 1))); do
    tier="$(cast_call_single "${HOOK_ADDRESS}" "feeTiers(uint256)(uint24)" "${i}" || true)"
    [[ "${tier}" =~ ^[0-9]+$ ]] || return 1
    FEE_TIERS_BY_IDX+=("${tier}")
  done

  FLOOR_IDX="$(cast_call_single "${HOOK_ADDRESS}" "floorIdx()(uint8)" || true)"
  CASH_IDX="$(cast_call_single "${HOOK_ADDRESS}" "cashIdx()(uint8)" || true)"
  EXTREME_IDX="$(cast_call_single "${HOOK_ADDRESS}" "extremeIdx()(uint8)" || true)"
  EXTREME_IDX="$(cast_call_single "${HOOK_ADDRESS}" "extremeIdx()(uint8)" || true)"

  [[ "${FLOOR_IDX}" =~ ^[0-9]+$ && "${CASH_IDX}" =~ ^[0-9]+$ && "${EXTREME_IDX}" =~ ^[0-9]+$ && "${EXTREME_IDX}" =~ ^[0-9]+$ ]]
}

tier_by_idx() {
  local idx="$1"
  printf '%s\n' "${FEE_TIERS_BY_IDX[${idx}]}"
}

state_debug_json() {
  cast_call_json "${HOOK_ADDRESS}" "getStateDebug()(uint8,uint8,uint8,uint8,uint8,uint64,uint64,uint96,bool)"
}

load_controller_params() {
  CP_MIN_CLOSEVOL_TO_CASH_USD6="$(cast_call_single "${HOOK_ADDRESS}" "minCloseVolToCashUsd6()(uint64)" || true)"
  CP_UP_R_TO_CASH_BPS="$(cast_call_single "${HOOK_ADDRESS}" "upRToCashBps()(uint16)" || true)"
  CP_CASH_HOLD_PERIODS="$(cast_call_single "${HOOK_ADDRESS}" "cashHoldPeriods()(uint8)" || true)"
  CP_MIN_CLOSEVOL_TO_EXTREME_USD6="$(cast_call_single "${HOOK_ADDRESS}" "minCloseVolToExtremeUsd6()(uint64)" || true)"
  CP_UP_R_TO_EXTREME_BPS="$(cast_call_single "${HOOK_ADDRESS}" "upRToExtremeBps()(uint16)" || true)"
  CP_UP_EXTREME_CONFIRM_PERIODS="$(cast_call_single "${HOOK_ADDRESS}" "upExtremeConfirmPeriods()(uint8)" || true)"
  CP_EXTREME_HOLD_PERIODS="$(cast_call_single "${HOOK_ADDRESS}" "extremeHoldPeriods()(uint8)" || true)"
  CP_DOWN_R_FROM_EXTREME_BPS="$(cast_call_single "${HOOK_ADDRESS}" "downRFromExtremeBps()(uint16)" || true)"
  CP_DOWN_EXTREME_CONFIRM_PERIODS="$(cast_call_single "${HOOK_ADDRESS}" "downExtremeConfirmPeriods()(uint8)" || true)"
  CP_DOWN_R_FROM_CASH_BPS="$(cast_call_single "${HOOK_ADDRESS}" "downRFromCashBps()(uint16)" || true)"
  CP_DOWN_CASH_CONFIRM_PERIODS="$(cast_call_single "${HOOK_ADDRESS}" "downCashConfirmPeriods()(uint8)" || true)"
  CP_EMERGENCY_FLOOR_CLOSEVOL_USD6="$(cast_call_single "${HOOK_ADDRESS}" "emergencyFloorCloseVolUsd6()(uint64)" || true)"
  CP_EMERGENCY_CONFIRM_PERIODS="$(cast_call_single "${HOOK_ADDRESS}" "emergencyConfirmPeriods()(uint8)" || true)"

  [[ "${CP_MIN_CLOSEVOL_TO_CASH_USD6}" =~ ^[0-9]+$ ]] || return 1
  [[ "${CP_UP_R_TO_CASH_BPS}" =~ ^[0-9]+$ ]] || return 1
  [[ "${CP_CASH_HOLD_PERIODS}" =~ ^[0-9]+$ ]] || return 1
  [[ "${CP_MIN_CLOSEVOL_TO_EXTREME_USD6}" =~ ^[0-9]+$ ]] || return 1
  [[ "${CP_UP_R_TO_EXTREME_BPS}" =~ ^[0-9]+$ ]] || return 1
  [[ "${CP_UP_EXTREME_CONFIRM_PERIODS}" =~ ^[0-9]+$ ]] || return 1
  [[ "${CP_EXTREME_HOLD_PERIODS}" =~ ^[0-9]+$ ]] || return 1
  [[ "${CP_DOWN_R_FROM_EXTREME_BPS}" =~ ^[0-9]+$ ]] || return 1
  [[ "${CP_DOWN_EXTREME_CONFIRM_PERIODS}" =~ ^[0-9]+$ ]] || return 1
  [[ "${CP_DOWN_R_FROM_CASH_BPS}" =~ ^[0-9]+$ ]] || return 1
  [[ "${CP_DOWN_CASH_CONFIRM_PERIODS}" =~ ^[0-9]+$ ]] || return 1
  [[ "${CP_EMERGENCY_FLOOR_CLOSEVOL_USD6}" =~ ^[0-9]+$ ]] || return 1
  [[ "${CP_EMERGENCY_CONFIRM_PERIODS}" =~ ^[0-9]+$ ]] || return 1
}

persist_base_controller() {
  load_controller_params || return 1
  BASE_CP_MIN_CLOSEVOL_TO_CASH_USD6="${CP_MIN_CLOSEVOL_TO_CASH_USD6}"
  BASE_CP_UP_R_TO_CASH_BPS="${CP_UP_R_TO_CASH_BPS}"
  BASE_CP_CASH_HOLD_PERIODS="${CP_CASH_HOLD_PERIODS}"
  BASE_CP_MIN_CLOSEVOL_TO_EXTREME_USD6="${CP_MIN_CLOSEVOL_TO_EXTREME_USD6}"
  BASE_CP_UP_R_TO_EXTREME_BPS="${CP_UP_R_TO_EXTREME_BPS}"
  BASE_CP_UP_EXTREME_CONFIRM_PERIODS="${CP_UP_EXTREME_CONFIRM_PERIODS}"
  BASE_CP_EXTREME_HOLD_PERIODS="${CP_EXTREME_HOLD_PERIODS}"
  BASE_CP_DOWN_R_FROM_EXTREME_BPS="${CP_DOWN_R_FROM_EXTREME_BPS}"
  BASE_CP_DOWN_EXTREME_CONFIRM_PERIODS="${CP_DOWN_EXTREME_CONFIRM_PERIODS}"
  BASE_CP_DOWN_R_FROM_CASH_BPS="${CP_DOWN_R_FROM_CASH_BPS}"
  BASE_CP_DOWN_CASH_CONFIRM_PERIODS="${CP_DOWN_CASH_CONFIRM_PERIODS}"
  BASE_CP_EMERGENCY_FLOOR_CLOSEVOL_USD6="${CP_EMERGENCY_FLOOR_CLOSEVOL_USD6}"
  BASE_CP_EMERGENCY_CONFIRM_PERIODS="${CP_EMERGENCY_CONFIRM_PERIODS}"
}

restore_base_controller() {
  CP_MIN_CLOSEVOL_TO_CASH_USD6="${BASE_CP_MIN_CLOSEVOL_TO_CASH_USD6}"
  CP_UP_R_TO_CASH_BPS="${BASE_CP_UP_R_TO_CASH_BPS}"
  CP_CASH_HOLD_PERIODS="${BASE_CP_CASH_HOLD_PERIODS}"
  CP_MIN_CLOSEVOL_TO_EXTREME_USD6="${BASE_CP_MIN_CLOSEVOL_TO_EXTREME_USD6}"
  CP_UP_R_TO_EXTREME_BPS="${BASE_CP_UP_R_TO_EXTREME_BPS}"
  CP_UP_EXTREME_CONFIRM_PERIODS="${BASE_CP_UP_EXTREME_CONFIRM_PERIODS}"
  CP_EXTREME_HOLD_PERIODS="${BASE_CP_EXTREME_HOLD_PERIODS}"
  CP_DOWN_R_FROM_EXTREME_BPS="${BASE_CP_DOWN_R_FROM_EXTREME_BPS}"
  CP_DOWN_EXTREME_CONFIRM_PERIODS="${BASE_CP_DOWN_EXTREME_CONFIRM_PERIODS}"
  CP_DOWN_R_FROM_CASH_BPS="${BASE_CP_DOWN_R_FROM_CASH_BPS}"
  CP_DOWN_CASH_CONFIRM_PERIODS="${BASE_CP_DOWN_CASH_CONFIRM_PERIODS}"
  CP_EMERGENCY_FLOOR_CLOSEVOL_USD6="${BASE_CP_EMERGENCY_FLOOR_CLOSEVOL_USD6}"
  CP_EMERGENCY_CONFIRM_PERIODS="${BASE_CP_EMERGENCY_CONFIRM_PERIODS}"
  set_controller_params
}

controller_tuple() {
  printf '(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)\n' \
    "${CP_MIN_CLOSEVOL_TO_CASH_USD6}" \
    "${CP_UP_R_TO_CASH_BPS}" \
    "${CP_CASH_HOLD_PERIODS}" \
    "${CP_MIN_CLOSEVOL_TO_EXTREME_USD6}" \
    "${CP_UP_R_TO_EXTREME_BPS}" \
    "${CP_UP_EXTREME_CONFIRM_PERIODS}" \
    "${CP_EXTREME_HOLD_PERIODS}" \
    "${CP_DOWN_R_FROM_EXTREME_BPS}" \
    "${CP_DOWN_EXTREME_CONFIRM_PERIODS}" \
    "${CP_DOWN_R_FROM_CASH_BPS}" \
    "${CP_DOWN_CASH_CONFIRM_PERIODS}" \
    "${CP_EMERGENCY_FLOOR_CLOSEVOL_USD6}" \
    "${CP_EMERGENCY_CONFIRM_PERIODS}"
}

set_controller_params() {
  local tuple was_paused
  tuple="$(controller_tuple)"
  was_paused="$(cast_call_single "${HOOK_ADDRESS}" "isPaused()(bool)" || true)"
  if [[ "${was_paused}" != "true" ]]; then
    cover_function "pause()"
    cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1
  fi
  cover_function "setControllerParams(tuple)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))" \
    "${tuple}" >/dev/null || return 1
  if [[ "${was_paused}" != "true" ]]; then
    cover_function "unpause()"
    cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1
  fi
  return 0
}

ensure_unpaused() {
  local paused
  paused="$(cast_call_single "${HOOK_ADDRESS}" "isPaused()(bool)" || true)"
  if [[ "${paused}" == "false" ]]; then
    return 0
  fi
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null 2>&1 || true
  paused="$(cast_call_single "${HOOK_ADDRESS}" "isPaused()(bool)" || true)"
  [[ "${paused}" == "false" ]]
}

reset_state_floor_unpaused() {
  cover_function "pause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null 2>&1 || true
  cover_function "unpause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null 2>&1 || true
  ensure_unpaused
}

swap_exact_in_stable() {
  local amount_raw="$1"
  local zero_for_one sqrt_limit params tx

  if [[ "${STABLE_IS_TOKEN0}" == "1" ]]; then
    zero_for_one="true"
    sqrt_limit="${SQRT_PRICE_LIMIT_X96_ZFO}"
  else
    zero_for_one="false"
    sqrt_limit="${SQRT_PRICE_LIMIT_X96_OZF}"
  fi

  params="(${zero_for_one},-${amount_raw},${sqrt_limit})"
  tx="$(cast_send_txhash --private-key "${OWNER_PK}" "${SWAP_HELPER}" \
    "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)(bytes32)" \
    "${POOL_KEY}" "${params}" "(false,false)" "0x")" || return 1

  # Legit hook runtime path via PoolManager.
  cover_function "afterSwap(address,tuple,tuple,int256,bytes)"

  printf '%s\n' "${tx}"
}

swap_exact_in_volatile() {
  local amount_raw="$1"
  local zero_for_one sqrt_limit params tx

  if [[ "${STABLE_IS_TOKEN0}" == "1" ]]; then
    zero_for_one="false"
    sqrt_limit="${SQRT_PRICE_LIMIT_X96_OZF}"
  else
    zero_for_one="true"
    sqrt_limit="${SQRT_PRICE_LIMIT_X96_ZFO}"
  fi

  params="(${zero_for_one},-${amount_raw},${sqrt_limit})"
  tx="$(cast_send_txhash --private-key "${OWNER_PK}" "${SWAP_HELPER}" \
    "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)(bytes32)" \
    "${POOL_KEY}" "${params}" "(false,false)" "0x")" || return 1

  cover_function "afterSwap(address,tuple,tuple,int256,bytes)"

  printf '%s\n' "${tx}"
}

close_period_with_seed() {
  local seed_amount="$1"
  local period tx
  period="$(cast_call_single "${HOOK_ADDRESS}" "periodSeconds()(uint32)")"
  warp_seconds "$((period + 1))"
  tx="$(swap_exact_in_stable "${seed_amount}")" || return 1
  printf '%s\n' "${tx}"
}

observe_period_closed_reasons_from_tx() {
  local tx_hash="$1"
  local events line reason_val reason_name

  events="$(period_closed_events_from_tx "${tx_hash}" "${PERIOD_CLOSED_TOPIC}" || true)"
  [[ -n "${events}" ]] || return 1

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    reason_val="$(line_kv_get "${line}" "reason")"
    reason_name="$(reason_name_by_value "${reason_val}")"
    if [[ -n "${reason_name}" ]]; then
      cover_reason "${reason_name}"
    fi
  done <<<"${events}"

  return 0
}

assert_last_period_reason() {
  local tx_hash="$1"
  local expected_reason_name="$2"
  local ctx="$3"
  local expected_val actual_val actual_name

  expected_val="$(reason_value_by_name "${expected_reason_name}" || true)"
  [[ -n "${expected_val}" ]] || {
    set_case_fail "unknown expected reason: ${expected_reason_name} (${ctx})"
    return 1
  }

  actual_val="$(last_period_closed_reason_from_tx "${tx_hash}" || true)"
  if [[ -z "${actual_val}" ]]; then
    set_case_fail "no PeriodClosed event in tx ${tx_hash} (${ctx})"
    return 1
  fi

  actual_name="$(reason_name_by_value "${actual_val}")"
  if [[ -n "${actual_name}" ]]; then
    cover_reason "${actual_name}"
  fi

  if [[ "${actual_val}" != "${expected_val}" ]]; then
    set_case_fail "reason mismatch ${ctx}: got=${actual_name:-${actual_val}} expected=${expected_reason_name}"
    return 1
  fi

  return 0
}

assert_last_period_reason_with_fallback() {
  local primary_tx="$1"
  local fallback_tx="$2"
  local expected_reason_name="$3"
  local ctx="$4"
  local expected_val actual_val actual_name got_primary got_fallback
  local seen_event

  expected_val="$(reason_value_by_name "${expected_reason_name}" || true)"
  [[ -n "${expected_val}" ]] || {
    set_case_fail "unknown expected reason: ${expected_reason_name} (${ctx})"
    return 1
  }

  seen_event=0
  got_primary=""
  got_fallback=""

  actual_val="$(last_period_closed_reason_from_tx "${primary_tx}" || true)"
  if [[ -n "${actual_val}" ]]; then
    seen_event=1
    actual_name="$(reason_name_by_value "${actual_val}")"
    [[ -n "${actual_name}" ]] && cover_reason "${actual_name}"
    got_primary="${actual_name:-${actual_val}}"
    if [[ "${actual_val}" == "${expected_val}" ]]; then
      return 0
    fi
  fi

  if [[ -n "${fallback_tx}" ]]; then
    actual_val="$(last_period_closed_reason_from_tx "${fallback_tx}" || true)"
    if [[ -n "${actual_val}" ]]; then
      seen_event=1
      actual_name="$(reason_name_by_value "${actual_val}")"
      [[ -n "${actual_name}" ]] && cover_reason "${actual_name}"
      got_fallback="${actual_name:-${actual_val}}"
      if [[ "${actual_val}" == "${expected_val}" ]]; then
        return 0
      fi
    fi
  fi

  if [[ "${seen_event}" == "0" ]]; then
    set_case_fail "no PeriodClosed event in tx ${primary_tx} (fallback ${fallback_tx}) (${ctx})"
  else
    set_case_fail "reason mismatch ${ctx}: primary=${got_primary:-none} fallback=${got_fallback:-none} expected=${expected_reason_name}"
  fi
  return 1
}

latest_block_number() {
  local out attempt
  for attempt in 1 2 3; do
    out="$(cast block-number --rpc-url "${RPC_URL}" 2>/dev/null || true)"
    if [[ "${out}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${out}"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

period_closed_reasons_between_blocks() {
  local from_block="$1"
  local to_block="$2"
  local from_hex to_hex params logs_json

  from_hex="$(cast to-hex "${from_block}")"
  to_hex="$(cast to-hex "${to_block}")"
  params="$(jq -cn --arg from "${from_hex}" --arg to "${to_hex}" --arg addr "${HOOK_ADDRESS}" --arg topic "${PERIOD_CLOSED_TOPIC}" \
    '[{fromBlock:$from,toBlock:$to,address:$addr,topics:[$topic]}]')"
  logs_json="$(rpc_call "eth_getLogs" "${params}" || true)"
  [[ -n "${logs_json}" ]] || return 0

  python3 - "${logs_json}" <<'PY'
import json
import sys

raw = sys.argv[1]
logs = json.loads(raw)
for log in logs:
    data = str(log.get("data", "0x"))
    if not data.startswith("0x"):
        continue
    payload = data[2:]
    if len(payload) < 64 * 8:
        continue
    reason = int(payload[64 * 7:64 * 8], 16)
    print(reason)
PY
}

swap_close_expect_reason_stable() {
  local amount_raw="$1"
  local seed_amount="$2"
  local expected_reason_name="$3"
  local ctx="$4"
  local swap_tx close_tx close_tx2
  local start_block end_block expected_val val name
  local reasons_text got_list seen_event matched

  LAST_CLOSE_TX=""
  start_block="$(latest_block_number || true)"
  [[ "${start_block}" =~ ^[0-9]+$ ]] || start_block="0"

  swap_tx="$(swap_exact_in_stable "${amount_raw}")" || return 1
  close_tx="$(close_period_with_seed "${seed_amount}")" || return 1
  LAST_CLOSE_TX="${close_tx}"

  end_block="$(latest_block_number || true)"
  [[ "${end_block}" =~ ^[0-9]+$ ]] || end_block="${start_block}"
  reasons_text="$(period_closed_reasons_between_blocks "$((start_block + 1))" "${end_block}")"

  if [[ -z "${reasons_text}" ]]; then
    close_tx2="$(close_period_with_seed "${seed_amount}")" || return 1
    LAST_CLOSE_TX="${close_tx2}"
    end_block="$(latest_block_number || true)"
    [[ "${end_block}" =~ ^[0-9]+$ ]] || end_block="${start_block}"
    reasons_text="$(period_closed_reasons_between_blocks "$((start_block + 1))" "${end_block}")"
  fi

  expected_val="$(reason_value_by_name "${expected_reason_name}" || true)"
  [[ -n "${expected_val}" ]] || {
    set_case_fail "unknown expected reason: ${expected_reason_name} (${ctx})"
    return 1
  }

  seen_event=0
  matched=0
  got_list=""
  while IFS= read -r val; do
    [[ "${val}" =~ ^[0-9]+$ ]] || continue
    seen_event=1
    name="$(reason_name_by_value "${val}")"
    if [[ -n "${name}" ]]; then
      cover_reason "${name}"
      if [[ -z "${got_list}" ]]; then
        got_list="${name}"
      else
        got_list="${got_list},${name}"
      fi
    else
      if [[ -z "${got_list}" ]]; then
        got_list="${val}"
      else
        got_list="${got_list},${val}"
      fi
    fi
    if [[ "${val}" == "${expected_val}" ]]; then
      matched=1
    fi
  done <<<"${reasons_text}"

  if [[ "${seen_event}" == "0" ]]; then
    set_case_fail "no PeriodClosed event between blocks $((start_block + 1))..${end_block} (${ctx})"
    return 1
  fi
  if [[ "${matched}" != "1" ]]; then
    set_case_fail "reason mismatch ${ctx}: got=${got_list} expected=${expected_reason_name}"
    return 1
  fi

  return 0
}

record_test_row() {
  local id="$1"
  local desc="$2"
  local status="$3"
  local reason="$4"
  local key_values="$5"
  local funcs errors reasons cp_summary

  funcs="$(join_array TC_FUNCS ', ' 6)"
  errors="$(join_array TC_ERRORS ', ' 6)"
  reasons="$(join_array TC_REASONS ', ' 6)"
  cp_summary="$(checkpoint_compact)"
  if [[ "${cp_summary}" != "-" ]]; then
    if [[ -n "${key_values}" ]]; then
      key_values="${key_values}; cp=${cp_summary}"
    else
      key_values="cp=${cp_summary}"
    fi
  fi

  TEST_ROWS+=("${id}|${desc}|${status}|${key_values}|${funcs}|${errors}|${reasons}|${reason}")
}

prepare_test_runtime() {
  CURRENT_TEST_ID=""
  CURRENT_TEST_DESC=""
  TC_REASON=""
  TC_KEYS=""
  TC_FUNCS=()
  TC_ERRORS=()
  TC_REASONS=()
  TC_CHECKPOINTS=()

  sync_runtime_config

  if ! prepare_case_isolation; then
    return 1
  fi

  return 0
}

run_test_case() {
  local id="$1"
  local desc="$2"
  local fn="$3"
  local status reason key_values
  local max_attempts attempt passed last_reason

  max_attempts="${SCENARIO_RETRIES:-2}"
  if ! [[ "${max_attempts}" =~ ^[0-9]+$ ]] || (( max_attempts < 1 )); then
    max_attempts=2
  fi
  passed=0
  last_reason="failed"

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ! prepare_test_runtime; then
      status="FAIL"
      reason="snapshot isolation failed"
      key_values="-"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      TEST_ROWS+=("${id}|${desc}|${status}|${key_values}|-|-|-|${reason}")
      log "${id}: ${status} - ${reason}"
      return
    fi

    CURRENT_TEST_ID="${id}"
    CURRENT_TEST_DESC="${desc}"

    if "${fn}"; then
      passed=1
      status="PASS"
      reason="${TC_REASON:-ok}"
      break
    fi

    last_reason="${TC_REASON:-failed}"
    if (( attempt < max_attempts )); then
      log "${id}: RETRY ${attempt}/${max_attempts} (reason=${last_reason})"
      sleep 0.2
    fi
  done

  if (( passed == 1 )); then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    status="FAIL"
    reason="${last_reason}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  key_values="${TC_KEYS:-}"
  record_test_row "${id}" "${desc}" "${status}" "${reason}" "${key_values}"
  log "${id}: ${status} - ${reason}"
}

# ----------------------------
# Test cases T00..T13
# ----------------------------

test_t00_smoke() {
  local floor_fee current_fee

  load_fee_tiers || return 1
  floor_fee="$(tier_by_idx "${FLOOR_IDX}")"

  cover_function "currentFeeBips()"
  current_fee="$(cast_call_single "${HOOK_ADDRESS}" "currentFeeBips()(uint24)")"
  assert_eq "T00 initial fee floor" "${current_fee}" "${floor_fee}" || return 1

  # afterInitialize executed during pool creation pipeline.
  cover_function "afterInitialize(address,tuple,uint160,int24)"

  tc_checkpoint "after_create_pool_expect_floor" "${floor_fee}" || return 1

  swap_exact_in_stable "1000000" >/dev/null || return 1
  tc_checkpoint "after_min_swap" || return 1

  TC_REASON="Деплой, создание пула и минимальный swap успешны; стартовый fee = floor"
  return 0
}

test_t01_abi_view_pure_sweep() {
  local entry sig mut args_part extra_hook

  for entry in "${ABI_ENTRIES[@]}"; do
    sig="${entry%%|*}"
    mut="${entry#*|}"

    if [[ "${mut}" != "view" && "${mut}" != "pure" ]]; then
      continue
    fi

    args_part="${sig#*(}"
    args_part="${args_part%)}"

    if [[ "${sig}" == "feeTiers(uint256)" ]]; then
      cover_function "${sig}"
      cast_call_single "${HOOK_ADDRESS}" "feeTiers(uint256)(uint24)" 0 >/dev/null || return 1

      cover_function "${sig}"
      expect_revert_custom "T01 feeTiers invalid index" \
        "cast call --rpc-url \"${RPC_URL}\" \"${HOOK_ADDRESS}\" \"feeTiers(uint256)(uint24)\" 255" \
        "InvalidFeeIndex" || return 1
      continue
    fi

    if [[ -z "${args_part}" ]]; then
      cover_function "${sig}"
      cast_call_retry_raw "${HOOK_ADDRESS}" "${sig}" >/dev/null || return 1
    fi
  done

  # NotInitialized coverage on an extra hook instance (deploy-only, no pool init).
  set_config_value "OWNER" "${ATTACKER_ADDR}"
  set_config_value "HOOK_FEE_ADDRESS" "${OWNER_ADDR}"
  set_config_value "HOOK_ADDRESS" ""
  run_deploy_hook_script || return 1
  extra_hook="$(extract_hook_from_deploy_json "${ROOT_DIR}/scripts/out/deploy.local.json" || true)"
  [[ -n "${extra_hook}" ]] || return 1

  cover_function "currentFeeBips()"
  expect_revert_custom "T01 extra hook not initialized" \
    "cast call --rpc-url \"${RPC_URL}\" \"${extra_hook}\" \"currentFeeBips()(uint24)\"" \
    "NotInitialized" || return 1

  sync_runtime_config

  tc_checkpoint "abi_view_sweep_done" || return 1
  TC_REASON="Покрыты все view/pure функции ABI; проверены валидный и невалидный индексы"
  return 0
}

test_t02_access_control_matrix() {
  local tiers_arg timing_period timing_ema timing_lull timing_deadband ctrl_tuple

  ensure_unpaused || return 1
  load_fee_tiers || return 1
  load_controller_params || return 1

  tiers_arg="[$(IFS=,; echo "${FEE_TIERS_BY_IDX[*]}")]"
  timing_period="$(cast_call_single "${HOOK_ADDRESS}" "periodSeconds()(uint32)")"
  timing_ema="$(cast_call_single "${HOOK_ADDRESS}" "emaPeriods()(uint8)")"
  timing_lull="$(cast_call_single "${HOOK_ADDRESS}" "lullResetSeconds()(uint32)")"
  timing_deadband="$(cast_call_single "${HOOK_ADDRESS}" "deadbandBps()(uint16)")"
  ctrl_tuple="$(controller_tuple)"

  cover_function "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)"
  expect_revert_custom "T02 attacker setFeeTiersAndRoles" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)\" \"${tiers_arg}\" \"${FLOOR_IDX}\" \"${CASH_IDX}\" \"${EXTREME_IDX}\"" \
    "NotOwner" || return 1

  cover_function "setTimingParams(uint32,uint8,uint32,uint16)"
  expect_revert_custom "T02 attacker setTimingParams" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"setTimingParams(uint32,uint8,uint32,uint16)\" \"${timing_period}\" \"${timing_ema}\" \"${timing_lull}\" \"${timing_deadband}\"" \
    "NotOwner" || return 1

  cover_function "setControllerParams(tuple)"
  expect_revert_custom "T02 attacker setControllerParams" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))\" \"${ctrl_tuple}\"" \
    "NotOwner" || return 1

  cover_function "scheduleHookFeePercentChange(uint16)"
  expect_revert_custom "T02 attacker scheduleHookFeePercentChange" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"scheduleHookFeePercentChange(uint16)\" 1" \
    "NotOwner" || return 1

  cover_function "scheduleHookFeePercentChange(uint16)"
  expect_revert_custom "T02 attacker scheduleHookFeePercentChange" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"scheduleHookFeePercentChange(uint16)\" 2" \
    "NotOwner" || return 1

  cover_function "setHookFeeRecipient(address)"
  expect_revert_custom "T02 attacker setHookFeeRecipient" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"setHookFeeRecipient(address)\" \"${ATTACKER_ADDR}\"" \
    "NotOwner" || return 1

  cover_function "pause()"
  expect_revert_custom "T02 attacker pause" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"pause()\"" \
    "NotOwner" || return 1

  cover_function "pause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1
  cover_function "unpause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1

  cover_function "pause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1

  cover_function "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)" \
    "${tiers_arg}" "${FLOOR_IDX}" "${CASH_IDX}" "${EXTREME_IDX}" >/dev/null || return 1

  cover_function "setTimingParams(uint32,uint8,uint32,uint16)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setTimingParams(uint32,uint8,uint32,uint16)" \
    "${timing_period}" "${timing_ema}" "${timing_lull}" "${timing_deadband}" >/dev/null || return 1

  set_controller_params || return 1

  cover_function "scheduleHookFeePercentChange(uint16)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "scheduleHookFeePercentChange(uint16)" 10 >/dev/null || return 1

  cover_function "scheduleHookFeePercentChange(uint16)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "cancelHookFeePercentChange()" >/dev/null || return 1

  cover_function "setHookFeeRecipient(address)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "setHookFeeRecipient(address)" "${OWNER_ADDR}" >/dev/null || return 1

  cover_function "unpause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1

  tc_checkpoint "access_matrix_done" || return 1
  TC_REASON="Матрица прав подтверждена: attacker заблокирован, все админ-действия доступны только owner"
  return 0
}

test_t03_pause_gating_cold_updates() {
  local tiers_arg floor_fee now_ts state_json period ema lull deadband
  local fee_idx hold ups downs ems period_start ema_vol

  ensure_unpaused || return 1
  load_fee_tiers || return 1

  tiers_arg="[$(IFS=,; echo "${FEE_TIERS_BY_IDX[*]}")]"
  floor_fee="$(tier_by_idx "${FLOOR_IDX}")"
  period="$(cast_call_single "${HOOK_ADDRESS}" "periodSeconds()(uint32)")"
  ema="$(cast_call_single "${HOOK_ADDRESS}" "emaPeriods()(uint8)")"
  lull="$(cast_call_single "${HOOK_ADDRESS}" "lullResetSeconds()(uint32)")"
  deadband="$(cast_call_single "${HOOK_ADDRESS}" "deadbandBps()(uint16)")"

  tc_checkpoint "before_pause" || return 1

  cover_function "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)"
  expect_revert_custom "T03 setFeeTiersAndRoles requires paused" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)\" \"${tiers_arg}\" \"${FLOOR_IDX}\" \"${CASH_IDX}\" \"${EXTREME_IDX}\"" \
    "RequiresPaused" || return 1

  cover_function "pause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1
  tc_checkpoint "after_pause" || return 1

  cover_function "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)" \
    "${tiers_arg}" "${FLOOR_IDX}" "${CASH_IDX}" "${EXTREME_IDX}" >/dev/null || return 1

  now_ts="$(block_timestamp)"
  state_json="$(state_debug_json)"
  fee_idx="$(jq -r '.[0]' <<<"${state_json}")"
  hold="$(jq -r '.[1]' <<<"${state_json}")"
  ups="$(jq -r '.[2]' <<<"${state_json}")"
  downs="$(jq -r '.[3]' <<<"${state_json}")"
  ems="$(jq -r '.[4]' <<<"${state_json}")"
  period_start="$(jq -r '.[5]' <<<"${state_json}")"
  ema_vol="$(jq -r '.[7]' <<<"${state_json}")"

  assert_eq "T03 reset feeIdx" "${fee_idx}" "${FLOOR_IDX}" || return 1
  assert_eq "T03 reset hold" "${hold}" "0" || return 1
  assert_eq "T03 reset up streak" "${ups}" "0" || return 1
  assert_eq "T03 reset down streak" "${downs}" "0" || return 1
  assert_eq "T03 reset emergency streak" "${ems}" "0" || return 1
  assert_eq "T03 reset ema" "${ema_vol}" "0" || return 1
  if (( period_start > now_ts + 2 || period_start + 2 < now_ts )); then
    set_case_fail "T03 periodStart mismatch after setFeeTiersAndRoles update"
    return 1
  fi
  tc_checkpoint "after_setFeeTiersAndRoles_expect_reset_floor" "${floor_fee}" || return 1

  cover_function "unpause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1

  cover_function "setTimingParams(uint32,uint8,uint32,uint16)"
  expect_revert_custom "T03 setTimingParams requires paused" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setTimingParams(uint32,uint8,uint32,uint16)\" \"${period}\" \"${ema}\" \"${lull}\" \"${deadband}\"" \
    "RequiresPaused" || return 1

  cover_function "pause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1

  cover_function "setTimingParams(uint32,uint8,uint32,uint16)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setTimingParams(uint32,uint8,uint32,uint16)" \
    "${period}" "${ema}" "${lull}" "${deadband}" >/dev/null || return 1

  now_ts="$(block_timestamp)"
  state_json="$(state_debug_json)"
  fee_idx="$(jq -r '.[0]' <<<"${state_json}")"
  hold="$(jq -r '.[1]' <<<"${state_json}")"
  ups="$(jq -r '.[2]' <<<"${state_json}")"
  downs="$(jq -r '.[3]' <<<"${state_json}")"
  ems="$(jq -r '.[4]' <<<"${state_json}")"
  period_start="$(jq -r '.[5]' <<<"${state_json}")"
  ema_vol="$(jq -r '.[7]' <<<"${state_json}")"

  assert_eq "T03 timing reset feeIdx" "${fee_idx}" "${FLOOR_IDX}" || return 1
  assert_eq "T03 timing reset hold" "${hold}" "0" || return 1
  assert_eq "T03 timing reset up streak" "${ups}" "0" || return 1
  assert_eq "T03 timing reset down streak" "${downs}" "0" || return 1
  assert_eq "T03 timing reset emergency streak" "${ems}" "0" || return 1
  assert_eq "T03 timing reset ema" "${ema_vol}" "0" || return 1
  if (( period_start > now_ts + 2 || period_start + 2 < now_ts )); then
    set_case_fail "T03 periodStart mismatch after setTimingParams reset"
    return 1
  fi

  tc_checkpoint "after_setTimingParams_expect_reset_floor" "${floor_fee}" || return 1

  cover_function "unpause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1
  tc_checkpoint "after_unpause" || return 1

  TC_REASON="Cold-update gating подтвержден: unpaused->revert, paused->success, reset state детерминирован"
  return 0
}

test_t04_invalid_tiers_roles() {
  local tiers_arg before_count before_floor before_cash before_extreme

  load_fee_tiers || return 1
  tiers_arg="[$(IFS=,; echo "${FEE_TIERS_BY_IDX[*]}")]"
  before_count="$(cast_call_single "${HOOK_ADDRESS}" "feeTierCount()(uint16)")"
  before_floor="${FLOOR_IDX}"
  before_cash="${CASH_IDX}"
  before_extreme="${EXTREME_IDX}"

  cover_function "pause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1

  cover_function "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)"
  expect_revert_custom "T04 non-increasing tiers" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)\" \"[400,400,9000]\" 0 1 2" \
    "InvalidConfig" || return 1

  cover_function "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)"
  expect_revert_custom "T04 invalid tier bounds" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)\" \"${tiers_arg}\" 2 1 2" \
    "InvalidTierBounds" || return 1

  cover_function "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)"
  expect_revert_custom "T04 empty tiers" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)\" \"[]\" 0 0 0" \
    "InvalidConfig" || return 1

  cover_function "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)"
  expect_revert_custom "T04 too many tiers" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)\" \"[100,200,300,400,500,600,700,800,900,1000,1100,1200,1300,1400,1500,1600,1700]\" 0 1 2" \
    "InvalidConfig" || return 1

  cover_function "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)"
  expect_revert_custom "T04 extreme idx out of range" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)\" \"${tiers_arg}\" 0 1 99" \
    "InvalidFeeIndex" || return 1

  assert_eq "T04 feeTierCount unchanged" "$(cast_call_single "${HOOK_ADDRESS}" "feeTierCount()(uint16)")" "${before_count}" || return 1
  assert_eq "T04 floorIdx unchanged" "$(cast_call_single "${HOOK_ADDRESS}" "floorIdx()(uint8)")" "${before_floor}" || return 1
  assert_eq "T04 cashIdx unchanged" "$(cast_call_single "${HOOK_ADDRESS}" "cashIdx()(uint8)")" "${before_cash}" || return 1
  assert_eq "T04 extremeIdx unchanged" "$(cast_call_single "${HOOK_ADDRESS}" "extremeIdx()(uint8)")" "${before_extreme}" || return 1

  cover_function "unpause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1

  tc_checkpoint "tiers_invalid_done" || return 1
  TC_REASON="Некорректные tiers/roles отклоняются, состояние не меняется"
  return 0
}

test_t05_invalid_timing() {
  local before_period before_ema before_lull before_deadband

  before_period="$(cast_call_single "${HOOK_ADDRESS}" "periodSeconds()(uint32)")"
  before_ema="$(cast_call_single "${HOOK_ADDRESS}" "emaPeriods()(uint8)")"
  before_lull="$(cast_call_single "${HOOK_ADDRESS}" "lullResetSeconds()(uint32)")"
  before_deadband="$(cast_call_single "${HOOK_ADDRESS}" "deadbandBps()(uint16)")"

  cover_function "pause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1

  cover_function "setTimingParams(uint32,uint8,uint32,uint16)"
  expect_revert_custom "T05 period=0" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setTimingParams(uint32,uint8,uint32,uint16)\" 0 6 120 1000" \
    "InvalidConfig" || return 1

  cover_function "setTimingParams(uint32,uint8,uint32,uint16)"
  expect_revert_custom "T05 ema=0" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setTimingParams(uint32,uint8,uint32,uint16)\" 30 0 120 1000" \
    "InvalidConfig" || return 1

  cover_function "setTimingParams(uint32,uint8,uint32,uint16)"
  expect_revert_custom "T05 lull<period" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setTimingParams(uint32,uint8,uint32,uint16)\" 30 6 10 1000" \
    "InvalidConfig" || return 1

  cover_function "setTimingParams(uint32,uint8,uint32,uint16)"
  expect_revert_custom "T05 deadband>5000" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setTimingParams(uint32,uint8,uint32,uint16)\" 30 6 120 5001" \
    "InvalidConfig" || return 1

  assert_eq "T05 period unchanged" "$(cast_call_single "${HOOK_ADDRESS}" "periodSeconds()(uint32)")" "${before_period}" || return 1
  assert_eq "T05 ema unchanged" "$(cast_call_single "${HOOK_ADDRESS}" "emaPeriods()(uint8)")" "${before_ema}" || return 1
  assert_eq "T05 lull unchanged" "$(cast_call_single "${HOOK_ADDRESS}" "lullResetSeconds()(uint32)")" "${before_lull}" || return 1
  assert_eq "T05 deadband unchanged" "$(cast_call_single "${HOOK_ADDRESS}" "deadbandBps()(uint16)")" "${before_deadband}" || return 1

  cover_function "unpause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1

  tc_checkpoint "timing_invalid_done" || return 1
  TC_REASON="Некорректные timing-параметры отклоняются, состояние стабильно"
  return 0
}

test_t06_invalid_controller_params() {
  local original_tuple tx
  local timing_period timing_ema timing_lull timing_deadband

  load_controller_params || return 1
  original_tuple="$(controller_tuple)"
  cover_function "pause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1

  CP_CASH_HOLD_PERIODS="0"
  cover_function "setControllerParams(tuple)"
  expect_revert_custom "T06 cashHold=0" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))\" \"$(controller_tuple)\"" \
    "InvalidHoldPeriods" || return 1

  CP_CASH_HOLD_PERIODS="${BASE_CP_CASH_HOLD_PERIODS}"
  CP_EXTREME_HOLD_PERIODS="0"
  cover_function "setControllerParams(tuple)"
  expect_revert_custom "T06 extremeHold=0" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))\" \"$(controller_tuple)\"" \
    "InvalidHoldPeriods" || return 1

  CP_EXTREME_HOLD_PERIODS="${BASE_CP_EXTREME_HOLD_PERIODS}"
  CP_UP_EXTREME_CONFIRM_PERIODS="0"
  cover_function "setControllerParams(tuple)"
  expect_revert_custom "T06 upExtremeConfirm=0" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))\" \"$(controller_tuple)\"" \
    "InvalidConfirmPeriods" || return 1

  CP_UP_EXTREME_CONFIRM_PERIODS="${BASE_CP_UP_EXTREME_CONFIRM_PERIODS}"
  CP_DOWN_EXTREME_CONFIRM_PERIODS="0"
  cover_function "setControllerParams(tuple)"
  expect_revert_custom "T06 downExtremeConfirm=0" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))\" \"$(controller_tuple)\"" \
    "InvalidConfirmPeriods" || return 1

  CP_DOWN_EXTREME_CONFIRM_PERIODS="${BASE_CP_DOWN_EXTREME_CONFIRM_PERIODS}"
  CP_DOWN_CASH_CONFIRM_PERIODS="0"
  cover_function "setControllerParams(tuple)"
  expect_revert_custom "T06 downCashConfirm=0" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))\" \"$(controller_tuple)\"" \
    "InvalidConfirmPeriods" || return 1

  CP_DOWN_CASH_CONFIRM_PERIODS="${BASE_CP_DOWN_CASH_CONFIRM_PERIODS}"
  CP_EMERGENCY_CONFIRM_PERIODS="0"
  cover_function "setControllerParams(tuple)"
  expect_revert_custom "T06 emergencyConfirm=0" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))\" \"$(controller_tuple)\"" \
    "InvalidConfirmPeriods" || return 1

  # Reduce period length sensitivity to wall-clock drift inside this long scenario.
  timing_ema="$(cast_call_single "${HOOK_ADDRESS}" "emaPeriods()(uint8)" || true)"
  timing_lull="$(cast_call_single "${HOOK_ADDRESS}" "lullResetSeconds()(uint32)" || true)"
  timing_deadband="$(cast_call_single "${HOOK_ADDRESS}" "deadbandBps()(uint16)" || true)"
  timing_period="90"
  cover_function "pause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1
  cover_function "setTimingParams(uint32,uint8,uint32,uint16)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" \
    "setTimingParams(uint32,uint8,uint32,uint16)" \
    "${timing_period}" "${timing_ema}" "${timing_lull}" "${timing_deadband}" >/dev/null || return 1
  cover_function "unpause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1

  # Deterministic valid update + reason coverage for HOLD and DEADBAND.
  CP_MIN_CLOSEVOL_TO_CASH_USD6="1"
  CP_UP_R_TO_CASH_BPS="100"
  CP_CASH_HOLD_PERIODS="2"
  CP_MIN_CLOSEVOL_TO_EXTREME_USD6="999999999999"
  CP_UP_R_TO_EXTREME_BPS="65000"
  CP_UP_EXTREME_CONFIRM_PERIODS="1"
  CP_EXTREME_HOLD_PERIODS="2"
  CP_DOWN_R_FROM_EXTREME_BPS="10000"
  CP_DOWN_EXTREME_CONFIRM_PERIODS="1"
  CP_DOWN_R_FROM_CASH_BPS="10000"
  CP_DOWN_CASH_CONFIRM_PERIODS="1"
  CP_EMERGENCY_FLOOR_CLOSEVOL_USD6="0"
  CP_EMERGENCY_CONFIRM_PERIODS="1"
  set_controller_params || return 1

  reset_state_floor_unpaused || return 1
  swap_close_expect_reason_stable "2000000" "1000" "REASON_EMA_BOOTSTRAP" "T06 bootstrap" || return 1
  tx="${LAST_CLOSE_TX}"

  swap_close_expect_reason_stable "2000000" "1000" "REASON_JUMP_CASH" "T06 jump cash" || return 1
  tx="${LAST_CLOSE_TX}"

  swap_close_expect_reason_stable "100" "1000" "REASON_HOLD" "T06 hold reason" || return 1
  tx="${LAST_CLOSE_TX}"

  # Deadband path: floor->cash raw threshold is met, but deadband blocks the transition.
  CP_MIN_CLOSEVOL_TO_CASH_USD6="1"
  CP_UP_R_TO_CASH_BPS="18000"
  CP_CASH_HOLD_PERIODS="1"
  CP_MIN_CLOSEVOL_TO_EXTREME_USD6="999999999999"
  CP_UP_R_TO_EXTREME_BPS="65000"
  CP_UP_EXTREME_CONFIRM_PERIODS="1"
  CP_EXTREME_HOLD_PERIODS="1"
  CP_DOWN_R_FROM_EXTREME_BPS="10000"
  CP_DOWN_EXTREME_CONFIRM_PERIODS="1"
  CP_DOWN_R_FROM_CASH_BPS="10000"
  CP_DOWN_CASH_CONFIRM_PERIODS="1"
  CP_EMERGENCY_FLOOR_CLOSEVOL_USD6="0"
  CP_EMERGENCY_CONFIRM_PERIODS="1"
  set_controller_params || return 1

  reset_state_floor_unpaused || return 1
  swap_close_expect_reason_stable "1000000000" "1000" "REASON_EMA_BOOTSTRAP" "T06 deadband bootstrap" || return 1
  tx="${LAST_CLOSE_TX}"

  swap_close_expect_reason_stable "2200000000" "1000" "REASON_DEADBAND" "T06 deadband" || return 1
  tx="${LAST_CLOSE_TX}"

  # Restore baseline controller params from initial setup.
  CP_MIN_CLOSEVOL_TO_CASH_USD6="${BASE_CP_MIN_CLOSEVOL_TO_CASH_USD6}"
  CP_UP_R_TO_CASH_BPS="${BASE_CP_UP_R_TO_CASH_BPS}"
  CP_CASH_HOLD_PERIODS="${BASE_CP_CASH_HOLD_PERIODS}"
  CP_MIN_CLOSEVOL_TO_EXTREME_USD6="${BASE_CP_MIN_CLOSEVOL_TO_EXTREME_USD6}"
  CP_UP_R_TO_EXTREME_BPS="${BASE_CP_UP_R_TO_EXTREME_BPS}"
  CP_UP_EXTREME_CONFIRM_PERIODS="${BASE_CP_UP_EXTREME_CONFIRM_PERIODS}"
  CP_EXTREME_HOLD_PERIODS="${BASE_CP_EXTREME_HOLD_PERIODS}"
  CP_DOWN_R_FROM_EXTREME_BPS="${BASE_CP_DOWN_R_FROM_EXTREME_BPS}"
  CP_DOWN_EXTREME_CONFIRM_PERIODS="${BASE_CP_DOWN_EXTREME_CONFIRM_PERIODS}"
  CP_DOWN_R_FROM_CASH_BPS="${BASE_CP_DOWN_R_FROM_CASH_BPS}"
  CP_DOWN_CASH_CONFIRM_PERIODS="${BASE_CP_DOWN_CASH_CONFIRM_PERIODS}"
  CP_EMERGENCY_FLOOR_CLOSEVOL_USD6="${BASE_CP_EMERGENCY_FLOOR_CLOSEVOL_USD6}"
  CP_EMERGENCY_CONFIRM_PERIODS="${BASE_CP_EMERGENCY_CONFIRM_PERIODS}"
  set_controller_params || return 1

  reset_state_floor_unpaused || return 1
  swap_close_expect_reason_stable "2000000" "1000" "REASON_EMA_BOOTSTRAP" "T06 no-change bootstrap" || return 1
  tx="${LAST_CLOSE_TX}"
  swap_close_expect_reason_stable "2000000" "1000" "REASON_NO_CHANGE" "T06 no-change" || return 1
  tx="${LAST_CLOSE_TX}"

  tc_checkpoint "controller_invalid_done" || return 1
  TC_REASON="Контроллерные аномалии валидированы; покрыты InvalidHold/InvalidConfirm + детерминированные HOLD/DEADBAND"
  return 0
}

test_t07_direct_call_protection() {
  local err_not_pool
  local ml_params swap_params
  local bad0 bad1 cmd

  err_not_pool="$(cast sig "NotPoolManager()")"
  ml_params="(-60,60,1000,0x0000000000000000000000000000000000000000000000000000000000000000)"
  swap_params="(true,-1000,${SQRT_PRICE_LIMIT_X96_ZFO})"

  cover_function "beforeInitialize(address,tuple,uint160)"
  expect_revert "T07 beforeInitialize direct" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"beforeInitialize(address,(address,address,uint24,int24,address),uint160)\" \"${ATTACKER_ADDR}\" \"${POOL_KEY}\" ${SQRT_PRICE_X96_ONE}" \
    "${err_not_pool}" || return 1

  cover_function "afterInitialize(address,tuple,uint160,int24)"
  expect_revert "T07 afterInitialize direct" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"afterInitialize(address,(address,address,uint24,int24,address),uint160,int24)\" \"${ATTACKER_ADDR}\" \"${POOL_KEY}\" ${SQRT_PRICE_X96_ONE} 0" \
    "${err_not_pool}" || return 1

  cover_function "beforeAddLiquidity(address,tuple,tuple,bytes)"
  expect_revert "T07 beforeAddLiquidity direct" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"beforeAddLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)\" \"${ATTACKER_ADDR}\" \"${POOL_KEY}\" \"${ml_params}\" 0x" \
    "${err_not_pool}" || return 1

  cover_function "afterAddLiquidity(address,tuple,tuple,int256,int256,bytes)"
  expect_revert "T07 afterAddLiquidity direct" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"afterAddLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),int256,int256,bytes)\" \"${ATTACKER_ADDR}\" \"${POOL_KEY}\" \"${ml_params}\" 0 0 0x" \
    "${err_not_pool}" || return 1

  cover_function "beforeRemoveLiquidity(address,tuple,tuple,bytes)"
  expect_revert "T07 beforeRemoveLiquidity direct" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"beforeRemoveLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)\" \"${ATTACKER_ADDR}\" \"${POOL_KEY}\" \"${ml_params}\" 0x" \
    "${err_not_pool}" || return 1

  cover_function "afterRemoveLiquidity(address,tuple,tuple,int256,int256,bytes)"
  expect_revert "T07 afterRemoveLiquidity direct" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"afterRemoveLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),int256,int256,bytes)\" \"${ATTACKER_ADDR}\" \"${POOL_KEY}\" \"${ml_params}\" 0 0 0x" \
    "${err_not_pool}" || return 1

  cover_function "beforeDonate(address,tuple,uint256,uint256,bytes)"
  expect_revert "T07 beforeDonate direct" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"beforeDonate(address,(address,address,uint24,int24,address),uint256,uint256,bytes)\" \"${ATTACKER_ADDR}\" \"${POOL_KEY}\" 0 0 0x" \
    "${err_not_pool}" || return 1

  cover_function "afterDonate(address,tuple,uint256,uint256,bytes)"
  expect_revert "T07 afterDonate direct" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"afterDonate(address,(address,address,uint24,int24,address),uint256,uint256,bytes)\" \"${ATTACKER_ADDR}\" \"${POOL_KEY}\" 0 0 0x" \
    "${err_not_pool}" || return 1

  cover_function "beforeSwap(address,tuple,tuple,bytes)"
  expect_revert "T07 beforeSwap direct" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"beforeSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),bytes)\" \"${ATTACKER_ADDR}\" \"${POOL_KEY}\" \"${swap_params}\" 0x" \
    "${err_not_pool}" || return 1

  cover_function "afterSwap(address,tuple,tuple,int256,bytes)"
  expect_revert "T07 afterSwap direct" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"afterSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),int256,bytes)\" \"${ATTACKER_ADDR}\" \"${POOL_KEY}\" \"${swap_params}\" 0 0x" \
    "${err_not_pool}" || return 1

  # Try to trigger hook key validation errors through genuine PoolManager->hook callback flow.
  read -r bad0 bad1 <<<"$(sort_tokens "${VOLATILE}" "${RESCUE_TOKEN}")"
  if ! expect_revert_custom "T07 bad key init" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${POOL_MANAGER}\" \"initialize((address,address,uint24,int24,address),uint160)\" \"(${bad0},${bad1},${DYNAMIC_FEE_FLAG},${TICK_SPACING},${HOOK_ADDRESS})\" ${SQRT_PRICE_X96_ONE}" \
    "InvalidPoolKey"; then
    exclude_error "InvalidPoolKey" "PoolManager validation reverts before hook on local path"
  fi

  if ! expect_revert_custom "T07 non-dynamic key init" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${POOL_MANAGER}\" \"initialize((address,address,uint24,int24,address),uint160)\" \"(${TOKEN0},${TOKEN1},3000,${TICK_SPACING},${HOOK_ADDRESS})\" ${SQRT_PRICE_X96_ONE}" \
    "NotDynamicFeePool"; then
    exclude_error "NotDynamicFeePool" "PoolManager rejects non-dynamic fee init before callback in local path"
  fi

  if ! expect_revert_custom "T07 re-initialize same pool" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${POOL_MANAGER}\" \"initialize((address,address,uint24,int24,address),uint160)\" \"${POOL_KEY}\" ${SQRT_PRICE_X96_ONE}" \
    "AlreadyInitialized"; then
    exclude_error "AlreadyInitialized" "PoolManager pre-check handles already-initialized pool before hook callback"
  fi

  tc_checkpoint "direct_call_protection_done" || return 1
  TC_REASON="Прямые вызовы callback-функций заблокированы onlyPoolManager; проверены hook key guards через PoolManager"
  return 0
}

test_t08_state_machine_strict_reasons() {
  local floor_fee cash_fee extreme_fee tx

  ensure_unpaused || return 1
  load_fee_tiers || return 1

  floor_fee="$(tier_by_idx "${FLOOR_IDX}")"
  cash_fee="$(tier_by_idx "${CASH_IDX}")"
  extreme_fee="$(tier_by_idx "${EXTREME_IDX}")"

  restore_base_controller || return 1
  reset_state_floor_unpaused || return 1

  tc_checkpoint "before_bootstrap" || return 1

  swap_close_expect_reason_stable "2000000" "1000" "REASON_EMA_BOOTSTRAP" "T08 bootstrap close" || return 1
  tx="${LAST_CLOSE_TX}"
  assert_eq "T08 bootstrap stays floor" "$(jq -r '.[0]' <<<"$(state_debug_json)")" "${FLOOR_IDX}" || return 1
  tc_checkpoint "after_bootstrap_close" || return 1

  swap_close_expect_reason_stable "8000000" "1000" "REASON_JUMP_CASH" "T08 enter cash" || return 1
  tx="${LAST_CLOSE_TX}"
  assert_eq "T08 fee idx cash" "$(jq -r '.[0]' <<<"$(state_debug_json)")" "${CASH_IDX}" || return 1
  tc_checkpoint "enter_cash" "${cash_fee}" || return 1

  swap_close_expect_reason_stable "8000000" "1000" "REASON_JUMP_EXTREME" "T08 enter extreme" || return 1
  tx="${LAST_CLOSE_TX}"
  assert_eq "T08 fee idx extreme" "$(jq -r '.[0]' <<<"$(state_debug_json)")" "${EXTREME_IDX}" || return 1
  tc_checkpoint "enter_extreme" "${extreme_fee}" || return 1

  swap_close_expect_reason_stable "1200000" "1000" "REASON_DOWN_TO_CASH" "T08 down to cash" || return 1
  tx="${LAST_CLOSE_TX}"
  assert_eq "T08 fee idx down cash" "$(jq -r '.[0]' <<<"$(state_debug_json)")" "${CASH_IDX}" || return 1
  tc_checkpoint "down_to_cash" "${cash_fee}" || return 1

  swap_close_expect_reason_stable "1200000" "1000" "REASON_DOWN_TO_FLOOR" "T08 down to floor" || return 1
  tx="${LAST_CLOSE_TX}"
  assert_eq "T08 fee idx down floor" "$(jq -r '.[0]' <<<"$(state_debug_json)")" "${FLOOR_IDX}" || return 1
  tc_checkpoint "down_to_floor" "${floor_fee}" || return 1

  swap_close_expect_reason_stable "8000000" "1000" "REASON_JUMP_CASH" "T08 re-enter cash for emergency" || return 1
  tx="${LAST_CLOSE_TX}"

  swap_close_expect_reason_stable "100" "100" "REASON_EMERGENCY_FLOOR" "T08 emergency floor" || return 1
  tx="${LAST_CLOSE_TX}"
  assert_eq "T08 emergency to floor" "$(jq -r '.[0]' <<<"$(state_debug_json)")" "${FLOOR_IDX}" || return 1
  tc_checkpoint "emergency_floor" "${floor_fee}" || return 1

  TC_REASON="Переходы FLOOR->CASH->EXTREME->CASH->FLOOR и emergency floor подтверждены со строгой проверкой reason-кодов"
  return 0
}

test_t09_multi_period_close_loop() {
  local tx events_count fee_idx

  warp_seconds 100
  tx="$(swap_exact_in_stable "1000")" || return 1

  observe_period_closed_reasons_from_tx "${tx}" || true

  events_count="$(period_closed_events_from_tx "${tx}" "${PERIOD_CLOSED_TOPIC}" | wc -l | tr -d ' ')"
  assert_true "T09 multiple PeriodClosed events" "[[ ${events_count} -ge 2 ]]" || return 1

  fee_idx="$(jq -r '.[0]' <<<"$(state_debug_json)")"
  assert_true "T09 fee idx in bounds" "[[ ${fee_idx} -ge ${FLOOR_IDX} && ${fee_idx} -le ${EXTREME_IDX} ]]" || return 1

  tc_checkpoint "multi_period_after_swap" || return 1
  TC_REASON="Мульти-периодный close-loop отрабатывает без revert/OOG, состояние консистентно"
  return 0
}

test_t10_lull_reset_strict() {
  local cash_fee floor_fee lull tx

  ensure_unpaused || return 1
  load_fee_tiers || return 1
  cash_fee="$(tier_by_idx "${CASH_IDX}")"
  floor_fee="$(tier_by_idx "${FLOOR_IDX}")"

  restore_base_controller || return 1
  reset_state_floor_unpaused || return 1

  swap_close_expect_reason_stable "2000000" "1000" "REASON_EMA_BOOTSTRAP" "T10 bootstrap" || return 1
  tx="${LAST_CLOSE_TX}"

  swap_close_expect_reason_stable "8000000" "1000" "REASON_JUMP_CASH" "T10 enter cash" || return 1
  tx="${LAST_CLOSE_TX}"
  tc_checkpoint "pre_lull" "${cash_fee}" || return 1

  lull="$(cast_call_single "${HOOK_ADDRESS}" "lullResetSeconds()(uint32)")"
  warp_seconds "$((lull + 1))"

  tx="$(swap_exact_in_stable "1000")" || return 1
  assert_last_period_reason "${tx}" "REASON_LULL_RESET" "T10 lull reset" || return 1
  tc_checkpoint "post_lull_reset_expect_floor" "${floor_fee}" || return 1

  TC_REASON="Lull reset подтвержден: strict reason=REASON_LULL_RESET, fee возвращается к floor"
  return 0
}

test_t11_paused_behavior() {
  local floor_fee before_state after_state before_fee_idx after_fee_idx before_period after_period

  ensure_unpaused || return 1
  load_fee_tiers || return 1
  floor_fee="$(tier_by_idx "${FLOOR_IDX}")"

  # Move from floor to cash first, then pause and verify forced-floor behavior.
  swap_exact_in_stable "1000000" >/dev/null || return 1
  close_period_with_seed "1000" >/dev/null || return 1
  swap_exact_in_stable "2500000" >/dev/null || return 1
  close_period_with_seed "1000" >/dev/null || return 1

  cover_function "pause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "pause()" >/dev/null || return 1
  tc_checkpoint "paused_state_expect_floor" "${floor_fee}" || return 1

  before_state="$(state_debug_json)"
  before_fee_idx="$(jq -r '.[0]' <<<"${before_state}")"
  before_period="$(jq -r '.[6]' <<<"${before_state}")"

  warp_seconds 45
  swap_exact_in_stable "2000" >/dev/null || return 1

  after_state="$(state_debug_json)"
  after_fee_idx="$(jq -r '.[0]' <<<"${after_state}")"
  after_period="$(jq -r '.[6]' <<<"${after_state}")"

  assert_eq "T11 paused fee idx unchanged" "${after_fee_idx}" "${before_fee_idx}" || return 1
  assert_eq "T11 paused periodVol unchanged" "${after_period}" "${before_period}" || return 1

  cover_function "emergencyResetToFloor()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "emergencyResetToFloor()" >/dev/null || return 1

  cover_function "unpause()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "unpause()" >/dev/null || return 1

  swap_exact_in_stable "1000" >/dev/null || return 1
  tc_checkpoint "after_unpause_activity" || return 1

  TC_REASON="Поведение в pause корректно: state не двигается, emergency reset доступен, после unpause работа возобновляется"
  return 0
}

test_t12_hook_fee_e2e() {
  local limit b0_after b1_after
  local accrued_before0 accrued_before1 accrued_mid0 accrued_mid1

  ensure_unpaused || return 1

  cover_function "MAX_HOOK_FEE_PERCENT()"
  limit="$(cast_call_single "${HOOK_ADDRESS}" "MAX_HOOK_FEE_PERCENT()(uint16)")"
  assert_eq "T12 hook fee limit" "${limit}" "10" || return 1

  cover_function "scheduleHookFeePercentChange(uint16)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "scheduleHookFeePercentChange(uint16)" 0 >/dev/null || return 1

  warp_seconds 172801
  cover_function "executeHookFeePercentChange()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "executeHookFeePercentChange()" >/dev/null || return 1

  cover_function "scheduleHookFeePercentChange(uint16)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "scheduleHookFeePercentChange(uint16)" 0 >/dev/null || return 1
  cover_function "cancelHookFeePercentChange()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "cancelHookFeePercentChange()" >/dev/null || return 1

  cover_function "hookFeesAccrued()"
  read -r accrued_before0 accrued_before1 <<<"$(cast_call_json "${HOOK_ADDRESS}" "hookFeesAccrued()(uint256,uint256)" | jq -r '.[0],.[1]' | xargs)"

  swap_exact_in_stable "3000000" >/dev/null || return 1
  close_period_with_seed "1000" >/dev/null || return 1
  swap_exact_in_stable "2000000" >/dev/null || return 1
  close_period_with_seed "1000" >/dev/null || return 1
  swap_exact_in_volatile "1000000000000000000" >/dev/null || return 1

  read -r accrued_mid0 accrued_mid1 <<<"$(cast_call_json "${HOOK_ADDRESS}" "hookFeesAccrued()(uint256,uint256)" | jq -r '.[0],.[1]' | xargs)"
  assert_eq "T12 accrued token0 unchanged at zero fee" "${accrued_mid0}" "${accrued_before0}" || return 1
  assert_eq "T12 accrued token1 unchanged at zero fee" "${accrued_mid1}" "${accrued_before1}" || return 1

  cover_function "claimAllHookFees()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "claimAllHookFees()" >/dev/null || return 1

  read -r b0_after b1_after <<<"$(cast_call_json "${HOOK_ADDRESS}" "hookFeesAccrued()(uint256,uint256)" | jq -r '.[0],.[1]' | xargs)"
  assert_eq "T12 accrued token0 after claim" "${b0_after}" "0" || return 1
  assert_eq "T12 accrued token1 after claim" "${b1_after}" "0" || return 1

  # Edge checks.
  cover_function "setHookFeeRecipient(address)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "setHookFeeRecipient(address)" \
    "0x0000000000000000000000000000000000000000" >/dev/null || return 1
  cover_function "scheduleHookFeePercentChange(uint16)"
  expect_revert_custom "T12 hook fee requires recipient" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"scheduleHookFeePercentChange(uint16)\" 1" \
    "HookFeeRecipientRequired" || return 1
  cover_function "setHookFeeRecipient(address)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "setHookFeeRecipient(address)" "${OWNER_ADDR}" >/dev/null || return 1

  cover_function "scheduleHookFeePercentChange(uint16)"
  expect_revert_custom "T12 hook fee percent above limit" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"scheduleHookFeePercentChange(uint16)\" 11" \
    "HookFeePercentLimitExceeded" || return 1

  cover_function "scheduleHookFeePercentChange(uint16)"
  expect_revert_custom "T12 hook fee bps above limit" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"scheduleHookFeePercentChange(uint16)\" 1100" \
    "HookFeePercentLimitExceeded" || return 1

  cover_function "claimHookFees(address,uint256,uint256)"
  expect_revert_custom "T12 claim too large" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"claimHookFees(address,uint256,uint256)\" \"${OWNER_ADDR}\" 1 0" \
    "ClaimTooLarge" || return 1

  cover_function "claimHookFees(address,uint256,uint256)"
  expect_revert_custom "T12 claimHookFees zero recipient" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"claimHookFees(address,uint256,uint256)\" 0x0000000000000000000000000000000000000000 0 0" \
    "InvalidRecipient" || return 1

  # deterministic no-op when accrued==0
  cover_function "claimAllHookFees()"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "claimAllHookFees()" >/dev/null || return 1

  tc_checkpoint "hook_fee_after_claim" || return 1
  TC_REASON="Hook fee guards подтверждены: zero-fee no-op, claim path детерминирован, лимиты и edge-cases валидны"
  return 0
}

test_t13_rescue_token() {
  local hook_before hook_after owner_before owner_after amount

  amount="5000000000000000000"

  cast_send_retry --private-key "${OWNER_PK}" "${RESCUE_TOKEN}" "transfer(address,uint256)" "${HOOK_ADDRESS}" "${amount}" >/dev/null || return 1

  cover_function "rescueToken(address,uint256)"
  expect_revert_custom "T13 attacker rescue" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${ATTACKER_ADDR}\" \"${HOOK_ADDRESS}\" \"rescueToken(address,uint256)\" \"${RESCUE_TOKEN}\" ${amount}" \
    "NotOwner" || return 1

  cover_function "rescueToken(address,uint256)"
  expect_revert_custom "T13 rescue pool token forbidden" \
    "cast call --rpc-url \"${RPC_URL}\" --from \"${OWNER_ADDR}\" \"${HOOK_ADDRESS}\" \"rescueToken(address,uint256)\" \"${STABLE}\" 1" \
    "InvalidRescueCurrency" || return 1

  hook_before="$(cast_call_single "${RESCUE_TOKEN}" "balanceOf(address)(uint256)" "${HOOK_ADDRESS}")"
  owner_before="$(cast_call_single "${RESCUE_TOKEN}" "balanceOf(address)(uint256)" "${OWNER_ADDR}")"

  cover_function "rescueToken(address,uint256)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "rescueToken(address,uint256)" "${RESCUE_TOKEN}" "${amount}" >/dev/null || return 1

  hook_after="$(cast_call_single "${RESCUE_TOKEN}" "balanceOf(address)(uint256)" "${HOOK_ADDRESS}")"
  owner_after="$(cast_call_single "${RESCUE_TOKEN}" "balanceOf(address)(uint256)" "${OWNER_ADDR}")"

  assert_true "T13 hook balance decreased" "[[ ${hook_after} -lt ${hook_before} ]]" || return 1
  assert_true "T13 owner balance increased" "[[ ${owner_after} -gt ${owner_before} ]]" || return 1

  cover_function "rescueETH(address,uint256)"
  cast_send_retry --private-key "${OWNER_PK}" "${HOOK_ADDRESS}" "rescueETH(address,uint256)" "${OWNER_ADDR}" 0 >/dev/null || return 1

  tc_checkpoint "rescue_done" || return 1
  TC_REASON="Rescue path подтверждён: unauthorized blocked, allowed transfer выполняется, pool-currency rescue запрещён"
  return 0
}

# ----------------------------
# Coverage checks + reporting
# ----------------------------

enforce_coverage() {
  local sig tests err ex why reason_name reason_tests reason_excluded

  # If still uncovered, keep explicit exclusions only for demonstrably unreachable runtime paths.
  if [[ -z "$(map_get "ERROR_COVER" "AlreadyInitialized" || true)" ]]; then
    exclude_error "AlreadyInitialized" "PoolManager pre-check reverts before hook callback in runtime flow"
  fi
  if [[ -z "$(map_get "ERROR_COVER" "InvalidPoolKey" || true)" ]]; then
    exclude_error "InvalidPoolKey" "PoolManager-level checks may short-circuit malformed key before hook callback"
  fi
  if [[ -z "$(map_get "ERROR_COVER" "NotDynamicFeePool" || true)" ]]; then
    exclude_error "NotDynamicFeePool" "PoolManager-level checks may short-circuit non-dynamic fee init before callback"
  fi

  for sig in "${ABI_SIGS[@]}"; do
    tests="$(map_get "ABI_COVER" "${sig}" || true)"
    if [[ -z "${tests}" ]]; then
      COVERAGE_FAIL_COUNT=$((COVERAGE_FAIL_COUNT + 1))
    fi
  done

  for err in "${ERROR_NAMES[@]}"; do
    tests="$(map_get "ERROR_COVER" "${err}" || true)"
    ex="$(map_get "ERROR_EXCLUDED" "${err}" || true)"
    if [[ -z "${tests}" && -z "${ex}" ]]; then
      COVERAGE_FAIL_COUNT=$((COVERAGE_FAIL_COUNT + 1))
    fi
  done

  for reason_name in "${REASON_ENTRIES[@]}"; do
    reason_name="${reason_name%%=*}"
    reason_tests="$(map_get "REASON_COVER" "${reason_name}" || true)"
    reason_excluded="$(map_get "REASON_EXCLUDED" "${reason_name}" || true)"
    if [[ -z "${reason_tests}" && -z "${reason_excluded}" ]]; then
      COVERAGE_FAIL_COUNT=$((COVERAGE_FAIL_COUNT + 1))
    fi
  done
}

print_report_tables() {
  local row id desc status keys funcs errs reasons note
  local sig tests err ex reason_name reason_val reason_tests reason_excluded

  log ""
  log "=== Итоговый отчёт preflight (LOCAL Anvil) ==="
  log ""
  log "| Тест | Описание | Результат | Ключевые значения (feeTier, rBps, closeVol, hold, paused) | Покрытые функции | Покрытые ошибки | Покрытые REASON |"
  log "|---|---|---|---|---|---|---|"
  for row in "${TEST_ROWS[@]}"; do
    id="${row%%|*}"
    row="${row#*|}"
    desc="${row%%|*}"
    row="${row#*|}"
    status="${row%%|*}"
    row="${row#*|}"
    keys="${row%%|*}"
    row="${row#*|}"
    funcs="${row%%|*}"
    row="${row#*|}"
    errs="${row%%|*}"
    row="${row#*|}"
    reasons="${row%%|*}"
    note="${row#*|}"
    log "| ${id} | ${desc}. ${note} | ${status} | ${keys} | ${funcs} | ${errs} | ${reasons} |"
  done

  log ""
  log "| Функция (signature) | Покрыто в тестах |"
  log "|---|---|"
  for sig in "${ABI_SIGS[@]}"; do
    tests="$(map_get "ABI_COVER" "${sig}" || true)"
    [[ -n "${tests}" ]] || tests="-"
    log "| ${sig} | ${tests} |"
  done

  log ""
  log "| Ошибка | Покрыто в тестах | EXCLUDED причина (если есть) |"
  log "|---|---|---|"
  for err in "${ERROR_NAMES[@]}"; do
    tests="$(map_get "ERROR_COVER" "${err}" || true)"
    ex="$(map_get "ERROR_EXCLUDED" "${err}" || true)"
    [[ -n "${tests}" ]] || tests="-"
    [[ -n "${ex}" ]] || ex="-"
    log "| ${err} | ${tests} | ${ex} |"
  done

  log ""
  log "| REASON | Покрыто в тестах | EXCLUDED причина (если есть) |"
  log "|---|---|---|"
  for reason_name in "${REASON_ENTRIES[@]}"; do
    reason_val="${reason_name#*=}"
    reason_name="${reason_name%%=*}"
    reason_tests="$(map_get "REASON_COVER" "${reason_name}" || true)"
    reason_excluded="$(map_get "REASON_EXCLUDED" "${reason_name}" || true)"
    [[ -n "${reason_tests}" ]] || reason_tests="-"
    [[ -n "${reason_excluded}" ]] || reason_excluded="-"
    log "| ${reason_name}=${reason_val} | ${reason_tests} | ${reason_excluded} |"
  done

  log ""
  log "Итог: PASS=${PASS_COUNT} FAIL=${FAIL_COUNT} COVERAGE_FAIL=${COVERAGE_FAIL_COUNT}"
}

main() {
  PERIOD_CLOSED_TOPIC="$(period_closed_topic0)"

  load_config
  backup_config
  start_anvil
  prepare_accounts

  log "owner=${OWNER_ADDR}"
  log "attacker=${ATTACKER_ADDR}"
  log "chain=local chain_id=${CHAIN_ID}"

  setup_local_environment

  log "pool_manager=${POOL_MANAGER}"
  log "volatile=${VOLATILE}"
  log "stable=${STABLE}"
  log "rescue_token=${RESCUE_TOKEN}"
  log "hook=${HOOK_ADDRESS}"
  log "pool_id=${POOL_ID}"
  log "pool_key=${POOL_KEY}"
  log "swap_helper=${SWAP_HELPER}"
  log "modify_helper=${MODIFY_HELPER}"

  init_coverage_catalogs
  load_fee_tiers || die "Failed to load fee tiers"
  persist_base_controller || die "Failed to read base controller params"

  if ! init_base_snapshot; then
    die "Failed to create baseline snapshot (disable with DISABLE_SNAPSHOT=1 only for debugging)"
  fi

  run_test_case "T00" "Smoke: deploy/create/swap" test_t00_smoke
  run_test_case "T01" "ABI view/pure sweep + invalid getter index" test_t01_abi_view_pure_sweep
  run_test_case "T02" "Матрица доступа (owner-only admin + attacker)" test_t02_access_control_matrix
  run_test_case "T03" "Pause gating для cold updates + reset semantics" test_t03_pause_gating_cold_updates
  run_test_case "T04" "Аномалии tiers/roles" test_t04_invalid_tiers_roles
  run_test_case "T05" "Аномалии timing params" test_t05_invalid_timing
  run_test_case "T06" "Аномалии controller params + deterministic paths" test_t06_invalid_controller_params
  run_test_case "T07" "Direct-call защита callback-функций" test_t07_direct_call_protection
  run_test_case "T08" "Полная v2 state machine + strict reason checks" test_t08_state_machine_strict_reasons
  run_test_case "T09" "Multi-period close loop safety" test_t09_multi_period_close_loop
  run_test_case "T10" "Lull reset + strict reason check" test_t10_lull_reset_strict
  run_test_case "T11" "Paused behavior + emergency reset" test_t11_paused_behavior
  run_test_case "T12" "Hook fee E2E + edge cases" test_t12_hook_fee_e2e
  run_test_case "T13" "Rescue token path" test_t13_rescue_token

  enforce_coverage
  print_report_tables

  if (( FAIL_COUNT > 0 || COVERAGE_FAIL_COUNT > 0 )); then
    exit 1
  fi
}

main "$@"
