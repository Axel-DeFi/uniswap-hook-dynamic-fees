#!/usr/bin/env bash
set -euo pipefail

# Data-driven Sepolia live runner for VolumeDynamicFeeHook.
# - Test cases are loaded from config/testcases.sepolia.json
# - Hook params are loaded from config/hook.sepolia.conf
# - Uses existing deploy/create pipeline scripts for Step1/Step2

# shellcheck disable=SC2034
SCRIPT_NAME="$(basename "$0")"

if [[ -f "./.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "./.env"
  set +a
fi

CHAIN="sepolia"
HOOK_CONF="./config/hook.sepolia.conf"
TESTCASES_FILE="./config/testcases.sepolia.json"
RPC_URL_CLI=""
PRIVATE_KEY_CLI=""
HOOK_ADDRESS_CLI=""
SWAP_TEST_ADDRESS_CLI=""
DRY_RUN=0
MODE="cases"

RPC_RETRIES="${RPC_RETRIES:-6}"
RPC_RETRY_SLEEP="${RPC_RETRY_SLEEP:-2}"
TX_WAIT_TIMEOUT_SECONDS="${TX_WAIT_TIMEOUT_SECONDS:-600}"
TX_MAX_FEE_GWEI="${TX_MAX_FEE_GWEI:-35}"
TX_PRIORITY_FEE_GWEI="${TX_PRIORITY_FEE_GWEI:-2}"

# Default per-period sleep uses timing from testcases JSON.
TEST_PERIOD_SECONDS=60
TEST_SLEEP_PAD_SECONDS=10

NATIVE_CURRENCY_ADDRESS="0x0000000000000000000000000000000000000000"
NATIVE_CURRENCY_ADDRESS_LC="$(printf '%s' "${NATIVE_CURRENCY_ADDRESS}" | tr '[:upper:]' '[:lower:]')"
DYNAMIC_FEE_FLAG=8388608
SQRT_PRICE_LIMIT_X96_ZFO=4295128740
SQRT_PRICE_LIMIT_X96_OZF=1461446703485210103287273052203988822378723970341
TEST_SETTINGS="(false,false)"
SWAP_SIG="swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)(bytes32)"
PERIOD_CLOSED_TOPIC0="0x3497b7d706817e8171c86d5c4c9657261e6fcfb36b9ae85c1cd7b3e840dce2c3"

# Runtime globals.
RPC_URL=""
PRIVATE_KEY=""
CREATOR=""
CHAIN_ID=""
HOOK_ADDRESS=""
SWAP_TEST_ADDRESS=""
POOL_KEY=""
POOL_ID=""

VOLATILE=""
STABLE=""
TICK_SPACING=""
STABLE_DECIMALS=""
STABLE_SIDE="unknown"
CURRENCY0=""
CURRENCY1=""
CURRENCY0_LC=""
CURRENCY1_LC=""

FEE_TIERS=""
FLOOR_TIER=""
CAP_TIER=""
CASH_TIER=""
EXTREME_TIER=""
CREATOR_FEE_LIMIT=""
CREATOR_FEE_PERCENT=""
CREATOR_FEE_BPS=""

PERIOD_SECONDS=""
EMA_PERIODS=""
LULL_RESET_SECONDS=""
DEADBAND_BPS=""

MIN_CLOSEVOL_TO_CASH_USD6=""
UP_R_TO_CASH_BPS=""
CASH_HOLD_PERIODS=""
MIN_CLOSEVOL_TO_EXTREME_USD6=""
UP_R_TO_EXTREME_BPS=""
UP_EXTREME_CONFIRM_PERIODS=""
EXTREME_HOLD_PERIODS=""
DOWN_R_FROM_EXTREME_BPS=""
DOWN_EXTREME_CONFIRM_PERIODS=""
DOWN_R_FROM_CASH_BPS=""
DOWN_CASH_CONFIRM_PERIODS=""
EMERGENCY_FLOOR_CLOSEVOL_USD6=""
EMERGENCY_CONFIRM_PERIODS=""

FLOOR_IDX=""
CASH_IDX=""
EXTREME_IDX=""
CAP_IDX=""
FEE_TIERS_ARG=""
declare -a FEE_TIER_PIPS=()

declare -a RESULT_TEST=()
declare -a RESULT_DESC=()
declare -a RESULT_STATUS=()
declare -a RESULT_KEYS=()
declare -a RESULT_NOTE=()

CURRENT_CASE_ID=""
CURRENT_CASE_NAME=""
CURRENT_CASE_MANDATORY=0
CURRENT_CASE_LAST_TX="-"
CURRENT_CASE_NOTE=""

LAST_FEE_TIER="-"
LAST_R_BPS="-"
LAST_CLOSE_VOL="-"
LAST_HOLD="-"
LAST_PAUSED="-"
LAST_FEE_IDX="-"
LAST_UP_STREAK="-"
LAST_DOWN_STREAK="-"
LAST_EMERGENCY_STREAK="-"
LAST_REASON_CODE=""
LAST_REASON_LABEL=""

CREATOR_FEES_BASE_0=""
CREATOR_FEES_BASE_1=""

ERR_CREATOR_FEE_PERCENT_LIMIT_SELECTOR=""

log() {
  echo "[sepolia-runner] $*"
}

warn() {
  echo "[sepolia-runner][WARN] $*" >&2
}

die() {
  echo "[sepolia-runner][ERROR] $*" >&2
  exit 1
}

lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

trim() {
  printf '%s' "${1:-}" | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print}'
}

show_help() {
  cat <<'USAGE'
Usage:
  ./test/scripts/simulate_fee_cycle.sh [options]

Options:
  --chain <sepolia>                 Default: sepolia
  --config <path>                   Hook config path (default: ./config/hook.sepolia.conf)
  --testcases <path>                Testcases JSON path (default: ./config/testcases.sepolia.json)
  --rpc-url <url>                   Override RPC_URL
  --private-key <hex>               Override PRIVATE_KEY
  --hook-address <addr>             Override HOOK_ADDRESS
  --swap-test-address <addr>        Override SwapTest helper address
  --mode <cases>                    Legacy compatibility (only cases supported)
  --dry-run                         Skip tx-sending operations
  --help                            Show help

Notes:
  - This runner is data-driven and executes steps from testcases JSON.
  - Uses existing scripts/deploy_hook.sh and scripts/create_pool.sh for Step1/Step2.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      show_help
      exit 0
      ;;
    --chain)
      CHAIN="${2:-}"
      [[ -n "${CHAIN}" ]] || die "--chain requires a value"
      shift 2
      ;;
    --config)
      HOOK_CONF="${2:-}"
      [[ -n "${HOOK_CONF}" ]] || die "--config requires a value"
      shift 2
      ;;
    --testcases)
      TESTCASES_FILE="${2:-}"
      [[ -n "${TESTCASES_FILE}" ]] || die "--testcases requires a value"
      shift 2
      ;;
    --rpc-url)
      RPC_URL_CLI="${2:-}"
      [[ -n "${RPC_URL_CLI}" ]] || die "--rpc-url requires a value"
      shift 2
      ;;
    --private-key)
      PRIVATE_KEY_CLI="${2:-}"
      [[ -n "${PRIVATE_KEY_CLI}" ]] || die "--private-key requires a value"
      shift 2
      ;;
    --hook-address)
      HOOK_ADDRESS_CLI="${2:-}"
      [[ -n "${HOOK_ADDRESS_CLI}" ]] || die "--hook-address requires a value"
      shift 2
      ;;
    --swap-test-address)
      SWAP_TEST_ADDRESS_CLI="${2:-}"
      [[ -n "${SWAP_TEST_ADDRESS_CLI}" ]] || die "--swap-test-address requires a value"
      shift 2
      ;;
    --mode)
      MODE="${2:-}"
      [[ -n "${MODE}" ]] || die "--mode requires a value"
      shift 2
      ;;
    --dry-run|dry)
      DRY_RUN=1
      shift
      ;;
    --broadcast)
      # compatibility no-op
      shift
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

CHAIN="$(lower "${CHAIN}")"
MODE="$(lower "${MODE}")"
[[ "${CHAIN}" == "sepolia" ]] || die "Only --chain sepolia is supported"
[[ "${MODE}" == "cases" ]] || die "Only --mode cases is supported"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_cmd cast
require_cmd jq
require_cmd awk
require_cmd sed
require_cmd python3

is_retryable_error() {
  local msg_lc
  msg_lc="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "${msg_lc}" == *"timeout"* ]] || \
  [[ "${msg_lc}" == *"timed out"* ]] || \
  [[ "${msg_lc}" == *"econnreset"* ]] || \
  [[ "${msg_lc}" == *"connection reset"* ]] || \
  [[ "${msg_lc}" == *"connection refused"* ]] || \
  [[ "${msg_lc}" == *"temporary failure"* ]] || \
  [[ "${msg_lc}" == *"try again"* ]] || \
  [[ "${msg_lc}" == *"429"* ]] || \
  [[ "${msg_lc}" == *"502"* ]] || \
  [[ "${msg_lc}" == *"503"* ]] || \
  [[ "${msg_lc}" == *"504"* ]] || \
  [[ "${msg_lc}" == *"header not found"* ]] || \
  [[ "${msg_lc}" == *"replacement transaction underpriced"* ]] || \
  [[ "${msg_lc}" == *"nonce too low"* ]]
}

cast_with_retry() {
  local label="$1"
  shift
  local out attempt sleep_s rc
  sleep_s="${RPC_RETRY_SLEEP}"
  attempt=1
  while (( attempt <= RPC_RETRIES )); do
    if out="$(cast "$@" 2>&1)"; then
      printf '%s\n' "${out}"
      return 0
    fi
    rc=$?
    if (( attempt >= RPC_RETRIES )) || ! is_retryable_error "${out}"; then
      echo "${out}" >&2
      return "${rc}"
    fi
    warn "${label}: retry ${attempt}/${RPC_RETRIES}"
    sleep "${sleep_s}" || true
    if (( sleep_s < 8 )); then
      sleep_s=$((sleep_s + 1))
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

first_token() {
  printf '%s\n' "${1:-}" | sed -n '1p' | awk '{print $1}'
}

cast_call_retry() {
  local to="$1"
  local sig="$2"
  shift 2
  cast_with_retry "cast call ${sig}" call --rpc-url "${RPC_URL}" "${to}" "${sig}" "$@"
}

cast_call_single() {
  local to="$1"
  local sig="$2"
  shift 2
  local out
  out="$(cast_call_retry "${to}" "${sig}" "$@")" || return 1
  first_token "${out}"
}

extract_tx_hash() {
  printf '%s\n' "${1:-}" | awk '/^0x[0-9a-fA-F]+$/{print $1; exit} /^transactionHash[[:space:]]/{print $2; exit}'
}

wait_tx_mined() {
  local tx_hash="$1"
  local label="$2"
  local started now receipt_json status
  started="$(date +%s)"

  while true; do
    if receipt_json="$(cast_with_retry "receipt ${label}" receipt --json --rpc-url "${RPC_URL}" "${tx_hash}" 2>/dev/null)"; then
      status="$(printf '%s\n' "${receipt_json}" | jq -r '.status // empty' 2>/dev/null || true)"
      if [[ "${status}" == "1" || "${status}" == "0x1" ]]; then
        return 0
      fi
      if [[ "${status}" == "0" || "${status}" == "0x0" ]]; then
        echo "tx reverted: ${tx_hash}" >&2
        return 1
      fi
    fi

    now="$(date +%s)"
    if (( now - started > TX_WAIT_TIMEOUT_SECONDS )); then
      echo "timeout waiting tx receipt: ${label} ${tx_hash}" >&2
      return 1
    fi
    sleep 1 || true
  done
}

cast_send_tx() {
  local label="$1"
  local value_wei="$2"
  local to="$3"
  local sig="$4"
  shift 4
  local -a cmd
  local out tx attempt rc sleep_s

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN ${label}: cast send ${to} ${sig} $*"
    printf '%s\n' "dry-run-${label}"
    return 0
  fi

  cmd=(cast send --async --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}")
  cmd+=(--gas-price "${TX_MAX_FEE_GWEI}gwei" --priority-gas-price "${TX_PRIORITY_FEE_GWEI}gwei")
  if [[ -n "${value_wei}" ]]; then
    cmd+=(--value "${value_wei}")
  fi
  cmd+=("${to}" "${sig}")
  while [[ $# -gt 0 ]]; do
    cmd+=("$1")
    shift
  done

  attempt=1
  sleep_s="${RPC_RETRY_SLEEP}"
  while (( attempt <= RPC_RETRIES )); do
    if out="$("${cmd[@]}" 2>&1)"; then
      tx="$(extract_tx_hash "${out}")"
      [[ -n "${tx}" ]] || {
        echo "failed to parse tx hash (${label})" >&2
        echo "${out}" >&2
        return 1
      }
      wait_tx_mined "${tx}" "${label}" || return 1
      printf '%s\n' "${tx}"
      return 0
    fi
    rc=$?
    if (( attempt >= RPC_RETRIES )) || ! is_retryable_error "${out}"; then
      echo "send failed (${label})" >&2
      echo "${out}" >&2
      return "${rc}"
    fi
    warn "${label}: retry ${attempt}/${RPC_RETRIES}"
    sleep "${sleep_s}" || true
    if (( sleep_s < 8 )); then
      sleep_s=$((sleep_s + 1))
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

cast_send_expect_revert() {
  local label="$1"
  local expected_substr="$2"
  local to="$3"
  local sig="$4"
  shift 4
  local -a cmd
  local out rc attempt sleep_s

  cmd=(cast send --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}")
  cmd+=(--gas-price "${TX_MAX_FEE_GWEI}gwei" --priority-gas-price "${TX_PRIORITY_FEE_GWEI}gwei")
  cmd+=("${to}" "${sig}")
  while [[ $# -gt 0 ]]; do
    cmd+=("$1")
    shift
  done

  attempt=1
  sleep_s="${RPC_RETRY_SLEEP}"
  while (( attempt <= RPC_RETRIES )); do
    if out="$("${cmd[@]}" 2>&1)"; then
      echo "unexpected success in ${label}" >&2
      echo "${out}" >&2
      return 1
    fi
    rc=$?

    if is_retryable_error "${out}"; then
      if (( attempt < RPC_RETRIES )); then
        warn "${label}: retry ${attempt}/${RPC_RETRIES} after rpc flake"
        sleep "${sleep_s}" || true
        if (( sleep_s < 8 )); then
          sleep_s=$((sleep_s + 1))
        fi
        attempt=$((attempt + 1))
        continue
      fi
    fi

    if [[ -n "${expected_substr}" ]] && [[ "${out}" == *"${expected_substr}"* ]]; then
      return 0
    fi

    if [[ -n "${ERR_CREATOR_FEE_PERCENT_LIMIT_SELECTOR}" ]] && [[ "${out}" == *"${ERR_CREATOR_FEE_PERCENT_LIMIT_SELECTOR}"* ]]; then
      return 0
    fi

    echo "revert mismatch for ${label}" >&2
    echo "expected substring: ${expected_substr}" >&2
    echo "output: ${out}" >&2
    return "${rc}"
  done

  return 1
}

percent_to_pips() {
  local pct
  pct="$(trim "$1")"
  awk -v pct="${pct}" 'BEGIN {
    if (pct !~ /^[0-9]+([.][0-9]+)?$/) exit 1;
    v = pct * 10000;
    p = int(v + 0.5);
    if (p < 1 || p > 1000000) exit 1;
    print p;
  }' 2>/dev/null
}

require_uint_env() {
  local name="$1"
  local val="${!name:-}"
  [[ -n "${val}" ]] || die "Missing ${name} in ${HOOK_CONF}"
  [[ "${val}" =~ ^[0-9]+$ ]] || die "${name} must be uint, got: ${val}"
}

find_idx_for_tier_percent() {
  local tier_percent="$1"
  local tier_pips i
  tier_pips="$(percent_to_pips "${tier_percent}" || true)"
  [[ -n "${tier_pips}" ]] || return 1
  for (( i = 0; i < ${#FEE_TIER_PIPS[@]}; i++ )); do
    if [[ "${FEE_TIER_PIPS[$i]}" == "${tier_pips}" ]]; then
      printf '%s\n' "${i}"
      return 0
    fi
  done
  return 1
}

load_hook_conf() {
  [[ -f "${HOOK_CONF}" ]] || die "Hook config not found: ${HOOK_CONF}"

  set -a
  # shellcheck disable=SC1090
  source "${HOOK_CONF}"
  set +a

  RPC_URL="${RPC_URL_CLI:-${RPC_URL:-}}"
  PRIVATE_KEY="${PRIVATE_KEY_CLI:-${PRIVATE_KEY:-}}"
  HOOK_ADDRESS="${HOOK_ADDRESS_CLI:-${HOOK_ADDRESS:-}}"
  SWAP_TEST_ADDRESS="${SWAP_TEST_ADDRESS_CLI:-${SWAP_TEST_ADDRESS:-}}"

  [[ -n "${RPC_URL}" ]] || die "RPC_URL is required"
  [[ -n "${PRIVATE_KEY}" ]] || die "PRIVATE_KEY is required"

  VOLATILE="${VOLATILE:-}"
  STABLE="${STABLE:-}"
  TICK_SPACING="${TICK_SPACING:-}"
  STABLE_DECIMALS="${STABLE_DECIMALS:-}"
  [[ -n "${VOLATILE}" && -n "${STABLE}" && -n "${TICK_SPACING}" && -n "${STABLE_DECIMALS}" ]] \
    || die "VOLATILE/STABLE/TICK_SPACING/STABLE_DECIMALS are required in ${HOOK_CONF}"

  FEE_TIERS="${FEE_TIERS:-}"
  FLOOR_TIER="${FLOOR_TIER:-}"
  CAP_TIER="${CAP_TIER:-}"
  CASH_TIER="${CASH_TIER:-}"
  EXTREME_TIER="${EXTREME_TIER:-}"
  [[ -n "${FEE_TIERS}" && -n "${FLOOR_TIER}" && -n "${CAP_TIER}" && -n "${CASH_TIER}" && -n "${EXTREME_TIER}" ]] \
    || die "FEE_TIERS/FLOOR_TIER/CAP_TIER/CASH_TIER/EXTREME_TIER are required in ${HOOK_CONF}"

  require_uint_env PERIOD_SECONDS
  require_uint_env EMA_PERIODS
  require_uint_env LULL_RESET_SECONDS
  require_uint_env DEADBAND_BPS

  require_uint_env MIN_CLOSEVOL_TO_CASH_USD6
  require_uint_env UP_R_TO_CASH_BPS
  require_uint_env CASH_HOLD_PERIODS
  require_uint_env MIN_CLOSEVOL_TO_EXTREME_USD6
  require_uint_env UP_R_TO_EXTREME_BPS
  require_uint_env UP_EXTREME_CONFIRM_PERIODS
  require_uint_env EXTREME_HOLD_PERIODS
  require_uint_env DOWN_R_FROM_EXTREME_BPS
  require_uint_env DOWN_EXTREME_CONFIRM_PERIODS
  require_uint_env DOWN_R_FROM_CASH_BPS
  require_uint_env DOWN_CASH_CONFIRM_PERIODS
  require_uint_env EMERGENCY_FLOOR_CLOSEVOL_USD6
  require_uint_env EMERGENCY_CONFIRM_PERIODS
  require_uint_env CREATOR_FEE_LIMIT
  require_uint_env CREATOR_FEE_PERCENT

  PERIOD_SECONDS="${PERIOD_SECONDS}"
  EMA_PERIODS="${EMA_PERIODS}"
  LULL_RESET_SECONDS="${LULL_RESET_SECONDS}"
  DEADBAND_BPS="${DEADBAND_BPS}"

  MIN_CLOSEVOL_TO_CASH_USD6="${MIN_CLOSEVOL_TO_CASH_USD6}"
  UP_R_TO_CASH_BPS="${UP_R_TO_CASH_BPS}"
  CASH_HOLD_PERIODS="${CASH_HOLD_PERIODS}"
  MIN_CLOSEVOL_TO_EXTREME_USD6="${MIN_CLOSEVOL_TO_EXTREME_USD6}"
  UP_R_TO_EXTREME_BPS="${UP_R_TO_EXTREME_BPS}"
  UP_EXTREME_CONFIRM_PERIODS="${UP_EXTREME_CONFIRM_PERIODS}"
  EXTREME_HOLD_PERIODS="${EXTREME_HOLD_PERIODS}"
  DOWN_R_FROM_EXTREME_BPS="${DOWN_R_FROM_EXTREME_BPS}"
  DOWN_EXTREME_CONFIRM_PERIODS="${DOWN_EXTREME_CONFIRM_PERIODS}"
  DOWN_R_FROM_CASH_BPS="${DOWN_R_FROM_CASH_BPS}"
  DOWN_CASH_CONFIRM_PERIODS="${DOWN_CASH_CONFIRM_PERIODS}"
  EMERGENCY_FLOOR_CLOSEVOL_USD6="${EMERGENCY_FLOOR_CLOSEVOL_USD6}"
  EMERGENCY_CONFIRM_PERIODS="${EMERGENCY_CONFIRM_PERIODS}"

  CREATOR_FEE_LIMIT="${CREATOR_FEE_LIMIT}"
  CREATOR_FEE_PERCENT="${CREATOR_FEE_PERCENT}"
  CREATOR_FEE_BPS=$((CREATOR_FEE_PERCENT * 100))

  parse_fee_tiers
}

parse_fee_tiers() {
  local -a raw_items
  local item pips prev i

  IFS=',' read -r -a raw_items <<< "${FEE_TIERS}"
  (( ${#raw_items[@]} > 0 )) || die "FEE_TIERS must not be empty"

  FEE_TIER_PIPS=()
  prev=""
  for (( i = 0; i < ${#raw_items[@]}; i++ )); do
    item="$(trim "${raw_items[$i]}")"
    pips="$(percent_to_pips "${item}" || true)"
    [[ -n "${pips}" ]] || die "Invalid fee tier in FEE_TIERS: ${item}"
    if [[ -n "${prev}" ]] && (( pips <= prev )); then
      die "FEE_TIERS must be strictly increasing"
    fi
    FEE_TIER_PIPS+=("${pips}")
    prev="${pips}"
  done

  FLOOR_IDX="$(find_idx_for_tier_percent "${FLOOR_TIER}" || true)"
  CASH_IDX="$(find_idx_for_tier_percent "${CASH_TIER}" || true)"
  EXTREME_IDX="$(find_idx_for_tier_percent "${EXTREME_TIER}" || true)"
  CAP_IDX="$(find_idx_for_tier_percent "${CAP_TIER}" || true)"

  [[ -n "${FLOOR_IDX}" && -n "${CASH_IDX}" && -n "${EXTREME_IDX}" && -n "${CAP_IDX}" ]] \
    || die "FLOOR/CASH/EXTREME/CAP tiers must exist in FEE_TIERS"

  if (( FLOOR_IDX > CASH_IDX || CASH_IDX > EXTREME_IDX || EXTREME_IDX > CAP_IDX )); then
    die "Tier ordering invalid: expected FLOOR <= CASH <= EXTREME <= CAP"
  fi

  FEE_TIERS_ARG="[$(IFS=,; echo "${FEE_TIER_PIPS[*]}")]"
}

load_testcases_conf() {
  [[ -f "${TESTCASES_FILE}" ]] || die "Testcases file not found: ${TESTCASES_FILE}"
  jq -e '.tests and (.tests | type == "array")' "${TESTCASES_FILE}" >/dev/null \
    || die "Invalid testcases JSON: missing .tests array"

  TEST_PERIOD_SECONDS="$(jq -r '.timing.period_seconds // empty' "${TESTCASES_FILE}")"
  TEST_SLEEP_PAD_SECONDS="$(jq -r '.timing.sleep_pad_seconds // 10' "${TESTCASES_FILE}")"

  if ! [[ "${TEST_PERIOD_SECONDS}" =~ ^[0-9]+$ ]] || (( TEST_PERIOD_SECONDS <= 0 )); then
    TEST_PERIOD_SECONDS="${PERIOD_SECONDS}"
  fi
  if ! [[ "${TEST_SLEEP_PAD_SECONDS}" =~ ^[0-9]+$ ]]; then
    TEST_SLEEP_PAD_SECONDS=10
  fi
}

sort_pool_tokens() {
  local a="$1"
  local b="$2"
  local al bl
  al="$(lower "${a}")"
  bl="$(lower "${b}")"
  if [[ "${al}" < "${bl}" ]]; then
    printf '%s %s\n' "${a}" "${b}"
  else
    printf '%s %s\n' "${b}" "${a}"
  fi
}

resolve_chain_context() {
  CHAIN_ID="$(cast_with_retry "chain-id" chain-id --rpc-url "${RPC_URL}" | awk '{print $1}')"
  [[ "${CHAIN_ID}" =~ ^[0-9]+$ ]] || die "Failed to resolve chain id"

  CREATOR="$(cast_with_retry "wallet address" wallet address --private-key "${PRIVATE_KEY}" | awk '{print $1}')"
  [[ -n "${CREATOR}" ]] || die "Failed to derive CREATOR from private key"

  ERR_CREATOR_FEE_PERCENT_LIMIT_SELECTOR="$(cast sig 'CreatorFeePercentLimitExceeded(uint16,uint16)' 2>/dev/null || true)"
}

resolve_hook_address() {
  local path candidate code

  if [[ -z "${HOOK_ADDRESS}" ]]; then
    path="./scripts/out/deploy.${CHAIN}.json"
    if [[ -f "${path}" ]]; then
      candidate="$(jq -r '.hook // .HOOK_ADDRESS // empty' "${path}" 2>/dev/null || true)"
      if [[ -n "${candidate}" && "${candidate}" != "null" ]]; then
        HOOK_ADDRESS="${candidate}"
      fi
    fi
  fi

  [[ -n "${HOOK_ADDRESS}" ]] || die "HOOK_ADDRESS is missing (config/CLI/scripts/out/deploy.${CHAIN}.json)"

  code="$(cast_with_retry "hook code" code --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" | tr -d '[:space:]')"
  [[ -n "${code}" && "${code}" != "0x" ]] || die "No bytecode at HOOK_ADDRESS=${HOOK_ADDRESS}"
}

resolve_swap_test_address() {
  local candidate code
  local -a paths
  local p

  if [[ -z "${SWAP_TEST_ADDRESS}" ]]; then
    paths=(
      "./scripts/out/broadcast/03_PoolSwapTest.s.sol/${CHAIN_ID}/run-latest.json"
      "./lib/v4-periphery/broadcast/03_PoolSwapTest.s.sol/${CHAIN_ID}/run-latest.json"
    )
    for p in "${paths[@]}"; do
      if [[ -f "${p}" ]]; then
        candidate="$(jq -r '.transactions[]?.contractAddress // empty' "${p}" | sed -n '1p')"
        if [[ -n "${candidate}" ]]; then
          SWAP_TEST_ADDRESS="${candidate}"
          break
        fi
      fi
    done
  fi

  [[ -n "${SWAP_TEST_ADDRESS}" ]] || die "SWAP_TEST_ADDRESS not found (CLI/env/artifacts)"

  code="$(cast_with_retry "swap helper code" code --rpc-url "${RPC_URL}" "${SWAP_TEST_ADDRESS}" | tr -d '[:space:]')"
  [[ -n "${code}" && "${code}" != "0x" ]] || die "No bytecode at SWAP_TEST_ADDRESS=${SWAP_TEST_ADDRESS}"
}

build_pool_runtime() {
  read -r CURRENCY0 CURRENCY1 <<< "$(sort_pool_tokens "${VOLATILE}" "${STABLE}")"
  CURRENCY0_LC="$(lower "${CURRENCY0}")"
  CURRENCY1_LC="$(lower "${CURRENCY1}")"

  if [[ "${CURRENCY0_LC}" == "$(lower "${STABLE}")" ]]; then
    STABLE_SIDE="token0"
  elif [[ "${CURRENCY1_LC}" == "$(lower "${STABLE}")" ]]; then
    STABLE_SIDE="token1"
  else
    die "STABLE token not found in sorted pool tokens"
  fi

  POOL_KEY="(${CURRENCY0},${CURRENCY1},${DYNAMIC_FEE_FLAG},${TICK_SPACING},${HOOK_ADDRESS})"
  set -f
  local pool_key_enc
  pool_key_enc="$(cast abi-encode 'f((address,address,uint24,int24,address))' "${POOL_KEY}")"
  set +f
  POOL_ID="$(cast keccak "${pool_key_enc}")"
}

refresh_runtime() {
  resolve_hook_address
  resolve_swap_test_address
  build_pool_runtime
}

tier_name_to_idx() {
  local tier
  tier="$(upper_tier_name "$1")"
  case "${tier}" in
    FLOOR) printf '%s\n' "${FLOOR_IDX}" ;;
    CASH) printf '%s\n' "${CASH_IDX}" ;;
    EXTREME) printf '%s\n' "${EXTREME_IDX}" ;;
    CAP) printf '%s\n' "${CAP_IDX}" ;;
    *) return 1 ;;
  esac
}

upper_tier_name() {
  printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]'
}

fee_tier_by_idx() {
  local idx="$1"
  cast_call_single "${HOOK_ADDRESS}" "feeTiers(uint256)(uint24)" "${idx}"
}

read_state_snapshot() {
  local debug fee_idx hold up down emergency period_start period_vol ema_vol paused fee_tier r_bps

  debug="$(cast_call_retry "${HOOK_ADDRESS}" "getStateDebug()(uint8,uint8,uint8,uint8,uint8,uint64,uint64,uint96,bool)")" || return 1

  fee_idx="$(printf '%s\n' "${debug}" | sed -n '1p' | awk '{print $1}')"
  hold="$(printf '%s\n' "${debug}" | sed -n '2p' | awk '{print $1}')"
  up="$(printf '%s\n' "${debug}" | sed -n '3p' | awk '{print $1}')"
  down="$(printf '%s\n' "${debug}" | sed -n '4p' | awk '{print $1}')"
  emergency="$(printf '%s\n' "${debug}" | sed -n '5p' | awk '{print $1}')"
  period_start="$(printf '%s\n' "${debug}" | sed -n '6p' | awk '{print $1}')"
  period_vol="$(printf '%s\n' "${debug}" | sed -n '7p' | awk '{print $1}')"
  ema_vol="$(printf '%s\n' "${debug}" | sed -n '8p' | awk '{print $1}')"
  paused="$(printf '%s\n' "${debug}" | sed -n '9p' | awk '{print $1}')"

  [[ "${fee_idx}" =~ ^[0-9]+$ ]] || return 1
  [[ "${hold}" =~ ^[0-9]+$ ]] || return 1
  [[ "${up}" =~ ^[0-9]+$ ]] || return 1
  [[ "${down}" =~ ^[0-9]+$ ]] || return 1
  [[ "${emergency}" =~ ^[0-9]+$ ]] || return 1
  [[ "${period_start}" =~ ^[0-9]+$ ]] || return 1
  [[ "${period_vol}" =~ ^[0-9]+$ ]] || return 1
  [[ "${ema_vol}" =~ ^[0-9]+$ ]] || return 1

  fee_tier="$(fee_tier_by_idx "${fee_idx}")" || return 1
  [[ "${fee_tier}" =~ ^[0-9]+$ ]] || return 1

  if (( ema_vol > 0 )); then
    r_bps=$(( period_vol * 10000 / ema_vol ))
  else
    r_bps=0
  fi

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${fee_tier}" "${r_bps}" "${period_vol}" "${hold}" "${paused}" \
    "${fee_idx}" "${up}" "${down}" "${emergency}" "${period_start}" "${ema_vol}"
}

decode_period_reason_label() {
  case "${1:-}" in
    1) echo "FEE_UP" ;;
    2) echo "FEE_DOWN" ;;
    3) echo "REVERSAL_LOCK" ;;
    4) echo "CAP" ;;
    5) echo "FLOOR" ;;
    6) echo "ZERO_EMA_DECAY" ;;
    7) echo "NO_SWAPS" ;;
    8) echo "LULL_RESET" ;;
    9) echo "DEADBAND" ;;
    10) echo "EMA_BOOTSTRAP" ;;
    11) echo "JUMP_CASH" ;;
    12) echo "JUMP_EXTREME" ;;
    13) echo "DOWN_TO_CASH" ;;
    14) echo "DOWN_TO_FLOOR" ;;
    15) echo "HOLD" ;;
    16) echo "EMERGENCY_FLOOR" ;;
    17) echo "BOOTSTRAP_V2" ;;
    *) echo "UNKNOWN" ;;
  esac
}

decode_period_reason_from_tx() {
  local tx_hash="$1"
  local receipt data reason_code
  receipt="$(cast_with_retry "receipt reason" receipt --json --rpc-url "${RPC_URL}" "${tx_hash}" 2>/dev/null || true)"
  [[ -n "${receipt}" ]] || return 1

  data="$(printf '%s\n' "${receipt}" | jq -r --arg t "$(lower "${PERIOD_CLOSED_TOPIC0}")" '.logs[]? | select((.topics[0] // "" | ascii_downcase) == $t) | .data // empty' | tail -n 1)"
  [[ -n "${data}" && "${data}" == 0x* ]] || return 1

  reason_code="$(python3 -S - "${data}" <<'PY'
import sys
s = sys.argv[1]
if not s.startswith("0x"):
    raise SystemExit(1)
hex_data = s[2:]
if len(hex_data) < 64:
    raise SystemExit(1)
print(int(hex_data[-64:], 16))
PY
  )" || return 1

  [[ "${reason_code}" =~ ^[0-9]+$ ]] || return 1
  printf '%s|%s\n' "${reason_code}" "$(decode_period_reason_label "${reason_code}")"
}

capture_state() {
  local tag="$1"
  local snapshot
  snapshot="$(read_state_snapshot)" || die "Failed to read state"

  IFS='|' read -r \
    LAST_FEE_TIER \
    LAST_R_BPS \
    LAST_CLOSE_VOL \
    LAST_HOLD \
    LAST_PAUSED \
    LAST_FEE_IDX \
    LAST_UP_STREAK \
    LAST_DOWN_STREAK \
    LAST_EMERGENCY_STREAK \
    _last_period_start \
    _last_ema_vol <<< "${snapshot}"

  log "state(${tag}): feeTier=${LAST_FEE_TIER} feeIdx=${LAST_FEE_IDX} rBps=${LAST_R_BPS} closeVol=${LAST_CLOSE_VOL} hold=${LAST_HOLD} paused=${LAST_PAUSED}"
}

read_creator_fees() {
  local out f0 f1
  out="$(cast_call_retry "${HOOK_ADDRESS}" "creatorFeesAccrued()(uint256,uint256)")" || return 1
  f0="$(printf '%s\n' "${out}" | sed -n '1p' | awk '{print $1}')"
  f1="$(printf '%s\n' "${out}" | sed -n '2p' | awk '{print $1}')"
  [[ "${f0}" =~ ^[0-9]+$ && "${f1}" =~ ^[0-9]+$ ]] || return 1
  printf '%s|%s\n' "${f0}" "${f1}"
}

read_token_balance() {
  local token="$1"
  local holder="$2"
  local token_lc out
  token_lc="$(lower "${token}")"

  if [[ "${token_lc}" == "${NATIVE_CURRENCY_ADDRESS_LC}" ]]; then
    out="$(cast_with_retry "native balance" balance --rpc-url "${RPC_URL}" "${holder}" | awk '{print $1}')" || return 1
    [[ "${out}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${out}"
    return 0
  fi

  out="$(cast_call_single "${token}" "balanceOf(address)(uint256)" "${holder}" 2>/dev/null || true)"
  [[ "${out}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${out}"
}

assert_fee_tier() {
  local tier_name="$1"
  local expected_idx
  expected_idx="$(tier_name_to_idx "${tier_name}" || true)"
  [[ -n "${expected_idx}" ]] || die "Unknown tier name: ${tier_name}"
  capture_state "assert_fee:${tier_name}"
  if [[ "${LAST_FEE_IDX}" != "${expected_idx}" ]]; then
    die "Expected fee idx ${expected_idx} (${tier_name}), got ${LAST_FEE_IDX}"
  fi
}

assert_no_fee_change_tier() {
  local tier_name="$1"
  assert_fee_tier "${tier_name}"
}

sleep_periods_internal() {
  local periods="$1"
  local i sleep_s
  [[ "${periods}" =~ ^[0-9]+$ ]] || die "sleep_periods expects uint"
  sleep_s=$((TEST_PERIOD_SECONDS + TEST_SLEEP_PAD_SECONDS))
  for (( i = 0; i < periods; i++ )); do
    log "sleep: ${sleep_s}s (period ${i}/${periods})"
    sleep "${sleep_s}" || true
  done
}

direction_to_zero_for_one() {
  local dir
  dir="$(lower "$1")"
  case "${dir}" in
    zeroforone|zfo|token0_to_token1|token0) echo "true" ;;
    oneforzero|ofz|token1_to_token0|token1) echo "false" ;;
    stable_to_volatile)
      if [[ "${STABLE_SIDE}" == "token0" ]]; then echo "true"; else echo "false"; fi
      ;;
    volatile_to_stable)
      if [[ "${STABLE_SIDE}" == "token0" ]]; then echo "false"; else echo "true"; fi
      ;;
    *)
      return 1
      ;;
  esac
}

run_swap() {
  local mode="$1"
  local direction="$2"
  local amount="$3"
  local label="$4"

  local zero_for_one amount_spec sqrt_limit token_in token_in_lc tx value_wei

  [[ "${amount}" =~ ^[0-9]+$ ]] || die "swap amount must be uint: ${amount}"
  (( amount > 0 )) || die "swap amount must be > 0"

  zero_for_one="$(direction_to_zero_for_one "${direction}" || true)"
  [[ -n "${zero_for_one}" ]] || die "Unknown swap direction: ${direction}"

  if [[ "${mode}" == "exact_in" ]]; then
    amount_spec="${amount}"
  elif [[ "${mode}" == "exact_out" ]]; then
    amount_spec="-$amount"
  else
    die "Unknown swap mode: ${mode}"
  fi

  if [[ "${zero_for_one}" == "true" ]]; then
    sqrt_limit="${SQRT_PRICE_LIMIT_X96_ZFO}"
    token_in="${CURRENCY0}"
  else
    sqrt_limit="${SQRT_PRICE_LIMIT_X96_OZF}"
    token_in="${CURRENCY1}"
  fi

  token_in_lc="$(lower "${token_in}")"
  value_wei=""
  if [[ "${token_in_lc}" == "${NATIVE_CURRENCY_ADDRESS_LC}" ]]; then
    value_wei="${amount}"
  fi

  set -f
  tx="$(cast_send_tx "${label}" "${value_wei}" "${SWAP_TEST_ADDRESS}" "${SWAP_SIG}" \
      "${POOL_KEY}" "(${zero_for_one},${amount_spec},${sqrt_limit})" "${TEST_SETTINGS}" "0x")" || {
    set +f
    return 1
  }
  set +f

  CURRENT_CASE_LAST_TX="${tx}"

  if reason_data="$(decode_period_reason_from_tx "${tx}" 2>/dev/null || true)"; then
    if [[ -n "${reason_data}" ]]; then
      IFS='|' read -r LAST_REASON_CODE LAST_REASON_LABEL <<< "${reason_data}"
      log "period reason tx=${tx}: code=${LAST_REASON_CODE} label=${LAST_REASON_LABEL}"
    fi
  fi

  printf '%s\n' "${tx}"
}

run_hook_admin_tx() {
  local label="$1"
  local sig="$2"
  shift 2
  local tx
  tx="$(cast_send_tx "${label}" "" "${HOOK_ADDRESS}" "${sig}" "$@")" || return 1
  CURRENT_CASE_LAST_TX="${tx}"
  printf '%s\n' "${tx}"
}

configure_hook_from_conf_onchain() {
  local controller_tuple
  controller_tuple="(${MIN_CLOSEVOL_TO_CASH_USD6},${UP_R_TO_CASH_BPS},${CASH_HOLD_PERIODS},${MIN_CLOSEVOL_TO_EXTREME_USD6},${UP_R_TO_EXTREME_BPS},${UP_EXTREME_CONFIRM_PERIODS},${EXTREME_HOLD_PERIODS},${DOWN_R_FROM_EXTREME_BPS},${DOWN_EXTREME_CONFIRM_PERIODS},${DOWN_R_FROM_CASH_BPS},${DOWN_CASH_CONFIRM_PERIODS},${EMERGENCY_FLOOR_CLOSEVOL_USD6},${EMERGENCY_CONFIRM_PERIODS})"

  run_hook_admin_tx "HOOK_PAUSE" "pause()" >/dev/null
  run_hook_admin_tx "HOOK_SET_TIERS" "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8,uint8)" \
    "${FEE_TIERS_ARG}" "${FLOOR_IDX}" "${CASH_IDX}" "${EXTREME_IDX}" "${CAP_IDX}" >/dev/null
  run_hook_admin_tx "HOOK_SET_TIMING" "setTimingParams(uint32,uint8,uint32,uint16)" \
    "${PERIOD_SECONDS}" "${EMA_PERIODS}" "${LULL_RESET_SECONDS}" "${DEADBAND_BPS}" >/dev/null
  run_hook_admin_tx "HOOK_SET_CONTROLLER" "setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))" \
    "${controller_tuple}" >/dev/null
  run_hook_admin_tx "HOOK_SET_CREATOR_FEE_CONFIG" "setCreatorFeeConfig(address,uint16)" \
    "${CREATOR}" "${CREATOR_FEE_BPS}" >/dev/null
  run_hook_admin_tx "HOOK_UNPAUSE" "unpause()" >/dev/null
}

op_deploy_hook() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN deploy_hook"
    return 0
  fi
  log "Step deploy_hook: scripts/deploy_hook.sh"
  ./scripts/deploy_hook.sh --chain "${CHAIN}" --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" --broadcast
  HOOK_ADDRESS=""
  refresh_runtime
}

op_create_pool() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN create_pool"
    return 0
  fi
  log "Step create_pool: scripts/create_pool.sh"
  ./scripts/create_pool.sh --chain "${CHAIN}" --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" --broadcast
}

ensure_tier() {
  local tier_name="$1"
  local target_idx
  target_idx="$(tier_name_to_idx "${tier_name}" || true)"
  [[ -n "${target_idx}" ]] || die "ensure_tier unknown tier: ${tier_name}"

  capture_state "ensure_tier:start"
  if [[ "${LAST_FEE_IDX}" == "${target_idx}" ]]; then
    return 0
  fi

  # Deterministic baseline: reset to FLOOR via config sequence.
  configure_hook_from_conf_onchain
  capture_state "ensure_tier:after-config"
  if [[ "${LAST_FEE_IDX}" != "${FLOOR_IDX}" ]]; then
    die "Expected FLOOR after configure_hook_from_conf, got idx=${LAST_FEE_IDX}"
  fi

  if [[ "${target_idx}" == "${FLOOR_IDX}" ]]; then
    return 0
  fi

  # Build EMA bootstrap period then jump to CASH.
  sleep_periods_internal 1
  run_swap "exact_in" "stable_to_volatile" "5000000" "SEED_BOOTSTRAP_CASH" >/dev/null
  capture_state "ensure_tier:seed-cash"

  sleep_periods_internal 1
  run_swap "exact_in" "stable_to_volatile" "15000000" "JUMP_TO_CASH" >/dev/null
  capture_state "ensure_tier:cash"
  [[ "${LAST_FEE_IDX}" == "${CASH_IDX}" ]] || die "Failed to reach CASH tier"

  if [[ "${target_idx}" == "${CASH_IDX}" ]]; then
    return 0
  fi

  # Move CASH -> EXTREME using configured confirmations.
  local i
  for (( i = 1; i <= UP_EXTREME_CONFIRM_PERIODS; i++ )); do
    sleep_periods_internal 1
    run_swap "exact_in" "stable_to_volatile" "25000000" "UP_EXTREME_PREP_${i}" >/dev/null
    capture_state "ensure_tier:extreme-${i}"
    if (( i < UP_EXTREME_CONFIRM_PERIODS )); then
      [[ "${LAST_FEE_IDX}" == "${CASH_IDX}" ]] || die "Expected CASH on N-1 while preparing EXTREME"
    else
      [[ "${LAST_FEE_IDX}" == "${EXTREME_IDX}" ]] || die "Failed to reach EXTREME tier"
    fi
  done

  if [[ "${target_idx}" == "${EXTREME_IDX}" || "${target_idx}" == "${CAP_IDX}" ]]; then
    return 0
  fi

  die "Unsupported ensure_tier target idx=${target_idx}"
}

clear_hold_if_needed() {
  local max_loops loops start_idx
  max_loops=16
  loops=0

  capture_state "clear_hold:start"
  start_idx="${LAST_FEE_IDX}"

  while [[ "${LAST_HOLD}" =~ ^[0-9]+ ]] && (( LAST_HOLD > 0 )); do
    (( loops < max_loops )) || die "clear_hold exceeded ${max_loops} loops"
    sleep_periods_internal 1
    run_swap "exact_in" "stable_to_volatile" "2000000" "HOLD_DECAY_${loops}" >/dev/null
    capture_state "clear_hold:loop-${loops}"

    # While hold is active, down transitions must be blocked.
    if [[ "${LAST_FEE_IDX}" != "${start_idx}" ]]; then
      die "Fee tier changed while clearing hold (expected idx=${start_idx}, got idx=${LAST_FEE_IDX})"
    fi

    loops=$((loops + 1))
  done
}

assert_confirm_logic() {
  local kind="$1"
  local start_tier="$2"
  local target_tier="$3"
  local confirm_periods="$4"
  local direction="$5"
  local amount="$6"
  local require_hold_zero="$7"
  local start_idx target_idx i

  [[ "${confirm_periods}" =~ ^[0-9]+$ ]] || die "confirm_periods must be uint"
  (( confirm_periods > 0 )) || die "confirm_periods must be > 0"

  start_idx="$(tier_name_to_idx "${start_tier}" || true)"
  target_idx="$(tier_name_to_idx "${target_tier}" || true)"
  [[ -n "${start_idx}" && -n "${target_idx}" ]] || die "assert_confirm_logic: bad tiers"

  log "assert_confirm_logic kind=${kind}: ${start_tier} -> ${target_tier}, N=${confirm_periods}, amount=${amount}, dir=${direction}"

  ensure_tier "${start_tier}"
  capture_state "confirm:${kind}:start"
  [[ "${LAST_FEE_IDX}" == "${start_idx}" ]] || die "assert_confirm_logic: failed to ensure start tier"

  if [[ "${require_hold_zero}" == "true" ]]; then
    clear_hold_if_needed
    capture_state "confirm:${kind}:after-hold-clear"
    [[ "${LAST_HOLD}" == "0" ]] || die "Expected hold=0 before confirm test"
    [[ "${LAST_FEE_IDX}" == "${start_idx}" ]] || die "Tier changed while clearing hold"
  fi

  for (( i = 1; i <= confirm_periods; i++ )); do
    sleep_periods_internal 1
    run_swap "exact_in" "${direction}" "${amount}" "CONFIRM_${kind}_${i}" >/dev/null
    capture_state "confirm:${kind}:step-${i}"

    if (( i < confirm_periods )); then
      # Explicit N-1 assertion: transition must NOT happen.
      if [[ "${LAST_FEE_IDX}" != "${start_idx}" ]]; then
        die "N-1 assertion failed for ${kind}: expected idx=${start_idx}, got idx=${LAST_FEE_IDX} at step ${i}"
      fi
    else
      # Explicit N assertion: transition must happen exactly at N.
      if [[ "${LAST_FEE_IDX}" != "${target_idx}" ]]; then
        die "N assertion failed for ${kind}: expected idx=${target_idx}, got idx=${LAST_FEE_IDX} at step ${i}"
      fi
    fi
  done
}

op_set_hot_params() {
  local step_json="$1"
  local p_min_cash p_up_cash p_cash_hold p_min_extreme p_up_extreme p_up_confirm p_extreme_hold
  local p_down_extreme p_down_extreme_confirm p_down_cash p_down_cash_confirm p_em_floor p_em_confirm
  local tuple

  p_min_cash="$(jq -r '.min_closevol_to_cash_usd6 // empty' <<<"${step_json}")"
  p_up_cash="$(jq -r '.up_r_to_cash_bps // empty' <<<"${step_json}")"
  p_cash_hold="$(jq -r '.cash_hold_periods // empty' <<<"${step_json}")"
  p_min_extreme="$(jq -r '.min_closevol_to_extreme_usd6 // empty' <<<"${step_json}")"
  p_up_extreme="$(jq -r '.up_r_to_extreme_bps // empty' <<<"${step_json}")"
  p_up_confirm="$(jq -r '.up_extreme_confirm_periods // empty' <<<"${step_json}")"
  p_extreme_hold="$(jq -r '.extreme_hold_periods // empty' <<<"${step_json}")"
  p_down_extreme="$(jq -r '.down_r_from_extreme_bps // empty' <<<"${step_json}")"
  p_down_extreme_confirm="$(jq -r '.down_extreme_confirm_periods // empty' <<<"${step_json}")"
  p_down_cash="$(jq -r '.down_r_from_cash_bps // empty' <<<"${step_json}")"
  p_down_cash_confirm="$(jq -r '.down_cash_confirm_periods // empty' <<<"${step_json}")"
  p_em_floor="$(jq -r '.emergency_floor_closevol_usd6 // empty' <<<"${step_json}")"
  p_em_confirm="$(jq -r '.emergency_confirm_periods // empty' <<<"${step_json}")"

  [[ -n "${p_min_cash}" ]] || p_min_cash="${MIN_CLOSEVOL_TO_CASH_USD6}"
  [[ -n "${p_up_cash}" ]] || p_up_cash="${UP_R_TO_CASH_BPS}"
  [[ -n "${p_cash_hold}" ]] || p_cash_hold="${CASH_HOLD_PERIODS}"
  [[ -n "${p_min_extreme}" ]] || p_min_extreme="${MIN_CLOSEVOL_TO_EXTREME_USD6}"
  [[ -n "${p_up_extreme}" ]] || p_up_extreme="${UP_R_TO_EXTREME_BPS}"
  [[ -n "${p_up_confirm}" ]] || p_up_confirm="${UP_EXTREME_CONFIRM_PERIODS}"
  [[ -n "${p_extreme_hold}" ]] || p_extreme_hold="${EXTREME_HOLD_PERIODS}"
  [[ -n "${p_down_extreme}" ]] || p_down_extreme="${DOWN_R_FROM_EXTREME_BPS}"
  [[ -n "${p_down_extreme_confirm}" ]] || p_down_extreme_confirm="${DOWN_EXTREME_CONFIRM_PERIODS}"
  [[ -n "${p_down_cash}" ]] || p_down_cash="${DOWN_R_FROM_CASH_BPS}"
  [[ -n "${p_down_cash_confirm}" ]] || p_down_cash_confirm="${DOWN_CASH_CONFIRM_PERIODS}"
  [[ -n "${p_em_floor}" ]] || p_em_floor="${EMERGENCY_FLOOR_CLOSEVOL_USD6}"
  [[ -n "${p_em_confirm}" ]] || p_em_confirm="${EMERGENCY_CONFIRM_PERIODS}"

  tuple="(${p_min_cash},${p_up_cash},${p_cash_hold},${p_min_extreme},${p_up_extreme},${p_up_confirm},${p_extreme_hold},${p_down_extreme},${p_down_extreme_confirm},${p_down_cash},${p_down_cash_confirm},${p_em_floor},${p_em_confirm})"

  run_hook_admin_tx "SET_HOT_PARAMS" "setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))" "${tuple}" >/dev/null
}

op_set_creator_fee_to_creator() {
  run_hook_admin_tx "SET_CREATOR_FEE_TO_CREATOR" "setCreatorFeeConfig(address,uint16)" "${CREATOR}" "${CREATOR_FEE_BPS}" >/dev/null
}

op_assert_creator_fee_accrued() {
  local min_delta_any
  local now0 now1 d0 d1
  min_delta_any="$1"
  [[ "${min_delta_any}" =~ ^[0-9]+$ ]] || min_delta_any=1

  [[ -n "${CREATOR_FEES_BASE_0}" && -n "${CREATOR_FEES_BASE_1}" ]] \
    || die "Creator fees baseline is not set. Run read_state with capture_creator_fees=true first."

  IFS='|' read -r now0 now1 <<< "$(read_creator_fees)"
  d0=$((now0 - CREATOR_FEES_BASE_0))
  d1=$((now1 - CREATOR_FEES_BASE_1))

  if (( d0 < min_delta_any && d1 < min_delta_any )); then
    die "creator fees did not accrue enough: delta0=${d0}, delta1=${d1}, min=${min_delta_any}"
  fi

  log "creator fees accrued: delta0=${d0}, delta1=${d1}"
}

op_claim_creator_fee_and_assert() {
  local before0 before1 after0 after1
  local bal0_before bal1_before bal0_after bal1_after
  local increased0 increased1

  IFS='|' read -r before0 before1 <<< "$(read_creator_fees)"

  bal0_before="$(read_token_balance "${CURRENCY0}" "${CREATOR}" || echo 0)"
  bal1_before="$(read_token_balance "${CURRENCY1}" "${CREATOR}" || echo 0)"

  run_hook_admin_tx "CLAIM_ALL_CREATOR_FEES" "claimAllCreatorFees(address)" "${CREATOR}" >/dev/null

  IFS='|' read -r after0 after1 <<< "$(read_creator_fees)"
  bal0_after="$(read_token_balance "${CURRENCY0}" "${CREATOR}" || echo 0)"
  bal1_after="$(read_token_balance "${CURRENCY1}" "${CREATOR}" || echo 0)"

  (( after0 == 0 && after1 == 0 )) || die "creator fees not fully claimed: after0=${after0}, after1=${after1}"

  increased0=0
  increased1=0
  if (( before0 > 0 && bal0_after > bal0_before )); then increased0=1; fi
  if (( before1 > 0 && bal1_after > bal1_before )); then increased1=1; fi

  if (( before0 > 0 || before1 > 0 )); then
    if (( increased0 == 0 && increased1 == 0 )); then
      die "creator recipient balances did not increase after claim"
    fi
  fi

  log "creator fee claim ok: before=(${before0},${before1}) after=(${after0},${after1})"
}

run_step() {
  local step_json="$1"
  local op
  op="$(jq -r '.op // empty' <<<"${step_json}")"
  [[ -n "${op}" ]] || die "Step has no op"

  case "${op}" in
    deploy_hook)
      op_deploy_hook
      ;;
    configure_hook_from_conf)
      configure_hook_from_conf_onchain
      ;;
    create_pool)
      op_create_pool
      ;;
    pause)
      run_hook_admin_tx "PAUSE" "pause()" >/dev/null
      ;;
    unpause)
      run_hook_admin_tx "UNPAUSE" "unpause()" >/dev/null
      ;;
    set_hot_params)
      op_set_hot_params "${step_json}"
      ;;
    set_creator_fee_address_to_creator)
      op_set_creator_fee_to_creator
      ;;
    swap_exact_in)
      run_swap "exact_in" \
        "$(jq -r '.direction // "stable_to_volatile"' <<<"${step_json}")" \
        "$(jq -r '.amount // empty' <<<"${step_json}")" \
        "SWAP_EXACT_IN_${CURRENT_CASE_ID}" >/dev/null
      ;;
    swap_exact_out)
      run_swap "exact_out" \
        "$(jq -r '.direction // "stable_to_volatile"' <<<"${step_json}")" \
        "$(jq -r '.amount // empty' <<<"${step_json}")" \
        "SWAP_EXACT_OUT_${CURRENT_CASE_ID}" >/dev/null
      ;;
    sleep_periods)
      sleep_periods_internal "$(jq -r '.n // 1' <<<"${step_json}")"
      ;;
    assert_fee)
      assert_fee_tier "$(jq -r '.tier // empty' <<<"${step_json}")"
      ;;
    assert_no_fee_change)
      assert_no_fee_change_tier "$(jq -r '.tier // empty' <<<"${step_json}")"
      ;;
    read_state)
      capture_state "read_state"
      if [[ "$(jq -r '.capture_creator_fees // false' <<<"${step_json}")" == "true" ]]; then
        IFS='|' read -r CREATOR_FEES_BASE_0 CREATOR_FEES_BASE_1 <<< "$(read_creator_fees)"
        log "creator fees baseline captured: ${CREATOR_FEES_BASE_0}|${CREATOR_FEES_BASE_1}"
      fi
      ;;
    assert_confirm_logic)
      assert_confirm_logic \
        "$(jq -r '.kind // empty' <<<"${step_json}")" \
        "$(jq -r '.start_tier // empty' <<<"${step_json}")" \
        "$(jq -r '.target_tier // empty' <<<"${step_json}")" \
        "$(jq -r '.confirm_periods // empty' <<<"${step_json}")" \
        "$(jq -r '.direction // "stable_to_volatile"' <<<"${step_json}")" \
        "$(jq -r '.amount // empty' <<<"${step_json}")" \
        "$(jq -r '.require_hold_zero // false' <<<"${step_json}")"
      ;;
    assert_creator_fee_accrued)
      op_assert_creator_fee_accrued "$(jq -r '.min_delta_any // 1' <<<"${step_json}")"
      ;;
    claim_creator_fee_and_assert)
      op_claim_creator_fee_and_assert
      ;;
    expect_revert)
      local call_op expected_sub value_percent
      call_op="$(jq -r '.call.op // empty' <<<"${step_json}")"
      expected_sub="$(jq -r '.expected // empty' <<<"${step_json}")"
      case "${call_op}" in
        set_creator_fee_percent)
          value_percent="$(jq -r '.call.value_percent // empty' <<<"${step_json}")"
          [[ "${value_percent}" =~ ^[0-9]+$ ]] || die "expect_revert.set_creator_fee_percent requires uint call.value_percent"
          cast_send_expect_revert "EXPECT_REVERT_SET_CREATOR_FEE_PERCENT" "${expected_sub}" \
            "${HOOK_ADDRESS}" "setCreatorFeePercent(uint16)" "${value_percent}"
          ;;
        *)
          die "expect_revert unsupported call.op=${call_op}"
          ;;
      esac
      ;;
    *)
      die "Unsupported step op: ${op}"
      ;;
  esac
}

safe_cell() {
  printf '%s' "${1:-}" | tr '\n' ' ' | sed 's/|/\\|/g'
}

record_case_result() {
  local test_id="$1"
  local desc="$2"
  local status="$3"
  local note="$4"
  local keyvals

  capture_state "case:${test_id}:final"
  keyvals="feeTier=${LAST_FEE_TIER}, rBps=${LAST_R_BPS}, closeVol=${LAST_CLOSE_VOL}, hold=${LAST_HOLD}, paused=${LAST_PAUSED}"

  RESULT_TEST+=("${test_id}")
  RESULT_DESC+=("${desc}")
  RESULT_STATUS+=("${status}")
  RESULT_KEYS+=("${keyvals}")

  if [[ -n "${CURRENT_CASE_LAST_TX}" && "${CURRENT_CASE_LAST_TX}" != "-" ]]; then
    if [[ -n "${LAST_REASON_LABEL}" ]]; then
      RESULT_NOTE+=("${CURRENT_CASE_LAST_TX}; reason=${LAST_REASON_LABEL}")
    else
      RESULT_NOTE+=("${CURRENT_CASE_LAST_TX}")
    fi
  else
    RESULT_NOTE+=("${note}")
  fi
}

run_all_tests() {
  local test_count ti step_count si
  local test_id name_ru mandatory desc_ru step_json
  local status note
  local failures_mandatory failures_total

  test_count="$(jq '.tests | length' "${TESTCASES_FILE}")"
  [[ "${test_count}" =~ ^[0-9]+$ ]] || die "Invalid tests count"

  failures_mandatory=0
  failures_total=0

  for (( ti = 0; ti < test_count; ti++ )); do
    test_id="$(jq -r ".tests[${ti}].id" "${TESTCASES_FILE}")"
    name_ru="$(jq -r ".tests[${ti}].name_ru // \"\"" "${TESTCASES_FILE}")"
    desc_ru="$(jq -r ".tests[${ti}].description_ru // \"\"" "${TESTCASES_FILE}")"
    mandatory="$(jq -r ".tests[${ti}].mandatory // true" "${TESTCASES_FILE}")"
    step_count="$(jq ".tests[${ti}].steps | length" "${TESTCASES_FILE}")"

    CURRENT_CASE_ID="${test_id}"
    CURRENT_CASE_NAME="${name_ru}"
    CURRENT_CASE_LAST_TX="-"
    CURRENT_CASE_NOTE=""
    LAST_REASON_CODE=""
    LAST_REASON_LABEL=""

    if [[ "${mandatory}" == "true" ]]; then
      CURRENT_CASE_MANDATORY=1
    else
      CURRENT_CASE_MANDATORY=0
    fi

    log "=== ${test_id}: ${name_ru} ==="
    status="PASS"
    note="ok"

    for (( si = 0; si < step_count; si++ )); do
      step_json="$(jq -c ".tests[${ti}].steps[${si}]" "${TESTCASES_FILE}")"
      if ! run_step "${step_json}"; then
        status="FAIL"
        note="step#${si} failed"
        warn "${test_id}: ${note}"
        break
      fi
    done

    if [[ "${status}" == "FAIL" ]]; then
      failures_total=$((failures_total + 1))
      if (( CURRENT_CASE_MANDATORY == 1 )); then
        failures_mandatory=$((failures_mandatory + 1))
      fi
    fi

    if [[ -z "${desc_ru}" || "${desc_ru}" == "null" ]]; then
      desc_ru="${name_ru}"
    fi

    record_case_result "${test_id}" "${desc_ru}" "${status}" "${note}"
  done

  print_summary_table

  log "completed: tests=${test_count}, failed=${failures_total}, mandatory_failed=${failures_mandatory}"

  if (( failures_mandatory > 0 )); then
    return 1
  fi
  return 0
}

print_summary_table() {
  local i count
  count="${#RESULT_TEST[@]}"

  echo
  echo "| Тест | Описание | Результат | Ключевые значения (feeTier, rBps, closeVol, hold, paused) | tx hash / примечание |"
  echo "|---|---|---|---|---|"

  for (( i = 0; i < count; i++ )); do
    echo "| $(safe_cell "${RESULT_TEST[$i]}") | $(safe_cell "${RESULT_DESC[$i]}") | $(safe_cell "${RESULT_STATUS[$i]}") | $(safe_cell "${RESULT_KEYS[$i]}") | $(safe_cell "${RESULT_NOTE[$i]}") |"
  done
  echo
}

main() {
  load_hook_conf
  load_testcases_conf
  resolve_chain_context
  refresh_runtime

  log "chain=${CHAIN} chainId=${CHAIN_ID}"
  log "rpc=${RPC_URL}"
  log "hook=${HOOK_ADDRESS}"
  log "swap_test=${SWAP_TEST_ADDRESS}"
  log "creator=${CREATOR}"
  log "pool_key=${POOL_KEY}"
  log "timing: period=${TEST_PERIOD_SECONDS}s pad=${TEST_SLEEP_PAD_SECONDS}s"

  run_all_tests
}

main "$@"
