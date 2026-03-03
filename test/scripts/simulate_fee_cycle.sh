#!/usr/bin/env bash
set -euo pipefail

# Auto-load local .env (ignored by git) if present.
if [[ -f "./.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "./.env"
  set +a
fi

# Modes:
# - cases  : deterministic scenario suite for hook behavior coverage.
# - random : long-running random swaps for live traffic simulation.
#
# The script expects an already deployed hook + pool + swap helper.
#
# Usage:
#   ./test/scripts/simulate_fee_cycle.sh
#   ./test/scripts/simulate_fee_cycle.sh --mode random
#   ./test/scripts/simulate_fee_cycle.sh --cases-runs 3
#
# Optional env overrides:
#   SWAP_TEST_ADDRESS, STATE_VIEW_ADDRESS, HIGH_SWAP_AMOUNT, LOW_SWAP_AMOUNT,
#   RANDOM_MIN_AMOUNT, RANDOM_MAX_AMOUNT, AUTO_REBALANCE_ENABLED,
#   AUTO_REBALANCE_ETH_UTIL_PCT, MAX_BALANCE_SPEND_PCT,
#   CASES_SOFT_MIN_AMOUNT, CASES_SOFT_MAX_AMOUNT
#
# Notes:
# - This script sends real transactions (broadcast only).
# - Designed for local/sepolia/prod flows in this repository.

CHAIN="sepolia"
MODE="cases"
RPC_URL=""
SWAP_TEST_ADDRESS="${SWAP_TEST_ADDRESS:-}"
STATE_VIEW_ADDRESS="${STATE_VIEW_ADDRESS:-}"
HOOK_ADDRESS_OVERRIDE=""
# Optional fixed amounts; if empty, the script computes adaptive amounts from EMA.
HIGH_SWAP_AMOUNT="${HIGH_SWAP_AMOUNT:-}"
LOW_SWAP_AMOUNT="${LOW_SWAP_AMOUNT:-}"
# Random/cases mode options.
MIN_WAIT_SECONDS=0
MAX_WAIT_SECONDS=0
RANDOM_MIN_AMOUNT="${RANDOM_MIN_AMOUNT:-}"
RANDOM_MAX_AMOUNT="${RANDOM_MAX_AMOUNT:-}"
DURATION_SECONDS=0
STATS_FILE=""
NO_LIVE=0
CASES_MODE=0
CASES_RUNS=1
CASES_COMPLETED_RUNS=0
CASES_STAGE="up_to_cap"
CASES_STAGE_STEP=0
CASES_NEXT_SIDE=""
CASES_NEXT_REASON="case-step"
CASES_NEXT_TARGET_VOL=1000000
CASES_NEXT_AMOUNT=0
CASES_RUN_CAP_OK=0
CASES_RUN_FLOOR_OK=0
CASES_RUN_REV_OK=0
CASES_RUN_DEADBAND_OK=0
CASES_RUN_LULL_OK=0
CASES_BASE_CAP_PASS=0
CASES_BASE_FLOOR_PASS=0
CASES_BASE_REV_PASS=0
CASES_BASE_DEADBAND_PASS=0
CASES_BASE_LULL_PASS=0
CASES_FORCE_WAIT_SECONDS=0
CASES_FORCE_WAIT_REASON=""
RND_WAIT_PICK_SECONDS=0
RND_WAIT_PICK_REASON="no-wait"
# Built-in anti-drift defaults for random mode.
ARB_GUARD_TICK_BAND=120
ARB_GUARD_CORRECTION_MULTIPLIER=2
ARB_GUARD_STREAK_LIMIT=4
ARB_GUARD_REANCHOR_TICK_DELTA=5000
ARB_GUARD_SUSPEND_ATTEMPTS=12
EDGE_FORCE_ATTEMPTS=12
EDGE_BLOCK_ATTEMPTS=16
PRICE_LIMIT_BLOCK_ATTEMPTS=10
PRICE_LIMIT_FORCE_ATTEMPTS=14
TICK_MIN=-887272
TICK_MAX=887272
TICK_EDGE_GUARD=2
HOOK_DUST_CLOSE_VOL_USD6=1000000
MAX_BALANCE_SPEND_PCT="${MAX_BALANCE_SPEND_PCT:-10}"
BALANCE_ERROR_FORCE_ATTEMPTS=8
NATIVE_GAS_SYMBOL="${NATIVE_GAS_SYMBOL:-ETH}"
NATIVE_CURRENCY_ADDRESS="0x0000000000000000000000000000000000000000"
NATIVE_CURRENCY_ADDRESS_LC="$(printf '%s' "${NATIVE_CURRENCY_ADDRESS}" | tr '[:upper:]' '[:lower:]')"
RANDOM_SOFT_MIN_AMOUNT="${RANDOM_SOFT_MIN_AMOUNT:-500000}"
RANDOM_SOFT_MAX_AMOUNT="${RANDOM_SOFT_MAX_AMOUNT:-3000000}"
CASES_SOFT_MIN_AMOUNT="${CASES_SOFT_MIN_AMOUNT:-500000}"
CASES_SOFT_MAX_AMOUNT="${CASES_SOFT_MAX_AMOUNT:-3000000}"
# Wallet rebalance: keep wallet close to 50/50 by value using a % of free native gas token.
AUTO_REBALANCE_ENABLED="${AUTO_REBALANCE_ENABLED:-0}"
AUTO_REBALANCE_ETH_UTIL_PCT="${AUTO_REBALANCE_ETH_UTIL_PCT:-30}"
AUTO_REBALANCE_MIN_INTERVAL_ATTEMPTS="${AUTO_REBALANCE_MIN_INTERVAL_ATTEMPTS:-80}"
AUTO_REBALANCE_TARGET_PCT="${AUTO_REBALANCE_TARGET_PCT:-50}"
AUTO_REBALANCE_TOLERANCE_PCT="${AUTO_REBALANCE_TOLERANCE_PCT:-8}"

# Compatibility with orchestrator:
# - Orchestrator may pass --private-key and --broadcast (forge-style). This script uses cast and treats --broadcast as a no-op.
PRIVATE_KEY_CLI=""
HAS_BROADCAST=1
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      cat <<'EOF'
Usage:
  ./test/scripts/simulate_fee_cycle.sh [options]

Options:
  --mode <cases|random>        Mode to run (default: cases).
  --chain <chain>              Optional; only sepolia is supported in this workflow.
  --rpc-url <url>              Override RPC URL.
  --swap-test-address <addr>   Swap helper contract address.
  --state-view-address <addr>  Optional StateView address for slot0 checks.
  --hook-address <addr>        Override HOOK_ADDRESS.
  --high-amount <int>          Fixed high amount target helper (optional).
  --low-amount <int>           Fixed low amount target helper (optional).
  --min-wait-seconds <int>     Random mode: minimum pause after swap (default: 0).
  --max-wait-seconds <int>     Random mode: maximum pause after swap (default: 0).
  --min-amount <int>           Random mode: force minimum random amountSpecified.
  --max-amount <int>           Random mode: force maximum random amountSpecified.
  --cases-runs <int>           Cases mode: number of full suites to execute (default: 1).
  --duration-seconds <int>     Stop after N seconds (0 = no time limit).
  --stats-file <path>          Path to persist live stats snapshot.
  --no-live                    Disable terminal dashboard redraw.
  (Cases mode runs deterministic suite: UP/cap, DOWN/floor, reversal, deadband, lull reset.)
  (Random mode keeps anti-drift and adaptive traffic heuristics.)
  --private-key <hex>           Signer key (optional if PRIVATE_KEY is in config).
  --broadcast                    No-op compatibility flag (broadcast is enabled by default).
  --dry-run                      Skip sending transactions.
EOF
      exit 0
      ;;
    --chain)
      CHAIN="${2:-}"
      if [[ -z "${CHAIN}" ]]; then echo "ERROR: --chain requires a value"; exit 1; fi
      shift 2
      ;;
    --mode)
      MODE="${2:-}"
      if [[ -z "${MODE}" ]]; then echo "ERROR: --mode requires a value"; exit 1; fi
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
    --min-wait-seconds)
      MIN_WAIT_SECONDS="${2:-}"
      if [[ -z "${MIN_WAIT_SECONDS}" ]]; then echo "ERROR: --min-wait-seconds requires a value"; exit 1; fi
      shift 2
      ;;
    --max-wait-seconds)
      MAX_WAIT_SECONDS="${2:-}"
      if [[ -z "${MAX_WAIT_SECONDS}" ]]; then echo "ERROR: --max-wait-seconds requires a value"; exit 1; fi
      shift 2
      ;;
    --min-amount)
      RANDOM_MIN_AMOUNT="${2:-}"
      if [[ -z "${RANDOM_MIN_AMOUNT}" ]]; then echo "ERROR: --min-amount requires a value"; exit 1; fi
      shift 2
      ;;
    --max-amount)
      RANDOM_MAX_AMOUNT="${2:-}"
      if [[ -z "${RANDOM_MAX_AMOUNT}" ]]; then echo "ERROR: --max-amount requires a value"; exit 1; fi
      shift 2
      ;;
    --duration-seconds)
      DURATION_SECONDS="${2:-}"
      if [[ -z "${DURATION_SECONDS}" ]]; then echo "ERROR: --duration-seconds requires a value"; exit 1; fi
      shift 2
      ;;
    --cases-runs)
      CASES_RUNS="${2:-}"
      if [[ -z "${CASES_RUNS}" ]]; then echo "ERROR: --cases-runs requires a value"; exit 1; fi
      shift 2
      ;;
    --stats-file)
      STATS_FILE="${2:-}"
      if [[ -z "${STATS_FILE}" ]]; then echo "ERROR: --stats-file requires a value"; exit 1; fi
      shift 2
      ;;
    --no-live)
      NO_LIVE=1
      shift
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

case "${MODE}" in
  random|cases) ;;
  *)
    echo "ERROR: unsupported --mode=${MODE}; expected cases or random."
    exit 1
    ;;
esac

if [[ "${CHAIN}" != "sepolia" ]]; then
  echo "ERROR: only --chain sepolia is supported by this workflow."
  exit 1
fi

if [[ "${MODE}" == "cases" ]]; then
  CASES_MODE=1
fi
MODE="random"

cast_rpc() {
  cast "$@"
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

if [[ -z "${VOLATILE:-}" || -z "${STABLE:-}" || -z "${STABLE_DECIMALS:-}" || -z "${TICK_SPACING:-}" ]]; then
  echo "ERROR: VOLATILE, STABLE, STABLE_DECIMALS and TICK_SPACING must be set in ${HOOK_CONF}."
  exit 1
fi

if [[ -n "${PRIVATE_KEY_CLI}" ]]; then
  PRIVATE_KEY="${PRIVATE_KEY_CLI}"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "==> simulate_fee_cycle: skipping (dry-run)."
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

CHAIN_ID="$(cast_rpc chain-id --rpc-url "${RPC_URL}" | awk '{print $1}')"
if [[ -z "${CHAIN_ID}" ]]; then
  echo "ERROR: failed to resolve chain-id from RPC."
  exit 1
fi

if [[ -z "${HOOK_ADDRESS:-}" ]]; then
  HOOK_DEPLOY_PATH="./scripts/out/deploy.${CHAIN}.json"
  if [[ -f "${HOOK_DEPLOY_PATH}" ]]; then
    HOOK_ADDRESS="$(python3 - "${HOOK_DEPLOY_PATH}" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
hook = data.get("hook") or data.get("HOOK_ADDRESS") or ""
print(str(hook).strip())
PY
    )"
  fi
fi

if [[ -z "${HOOK_ADDRESS:-}" ]]; then
  HOOK_BROADCAST_PATH="./scripts/out/broadcast/DeployHook.s.sol/${CHAIN_ID}/run-latest.json"
  if [[ -f "${HOOK_BROADCAST_PATH}" ]]; then
    HOOK_ADDRESS="$(python3 - "${HOOK_BROADCAST_PATH}" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
for tx in data.get("transactions", []):
    addr = (tx.get("contractAddress") or "").strip()
    if addr:
        print(addr)
        break
else:
    print("")
PY
    )"
  fi
fi

if [[ -z "${HOOK_ADDRESS:-}" ]]; then
  echo "ERROR: HOOK_ADDRESS must be set in ${HOOK_CONF}, passed via --hook-address, or present in scripts/out deploy artifacts."
  exit 1
fi

HOOK_CODE_SIZE="$(cast_rpc code --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" | wc -c | xargs)"
if [[ "${HOOK_CODE_SIZE}" -le 3 ]]; then
  echo "ERROR: no contract code at HOOK_ADDRESS=${HOOK_ADDRESS}"
  exit 1
fi

if [[ -z "${SWAP_TEST_ADDRESS}" ]]; then
  SWAP_BROADCAST_PATH="./scripts/out/broadcast/03_PoolSwapTest.s.sol/${CHAIN_ID}/run-latest.json"
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
  SWAP_BROADCAST_PATH="./lib/v4-periphery/broadcast/03_PoolSwapTest.s.sol/${CHAIN_ID}/run-latest.json"
  if [[ -f "${SWAP_BROADCAST_PATH}" ]]; then
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

if [[ -z "${STATE_VIEW_ADDRESS}" ]]; then
  STATE_VIEW_BROADCAST_PATH="./lib/v4-periphery/broadcast/DeployStateView.s.sol/${CHAIN_ID}/run-latest.json"
  if [[ -f "${STATE_VIEW_BROADCAST_PATH}" ]]; then
    STATE_VIEW_ADDRESS="$(python3 - "${STATE_VIEW_BROADCAST_PATH}" <<'PY'
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

if [[ -n "${STATE_VIEW_ADDRESS}" ]]; then
  if state_view_code_size="$(cast_rpc code --rpc-url "${RPC_URL}" "${STATE_VIEW_ADDRESS}" 2>/dev/null | wc -c | xargs)"; then
    if [[ "${state_view_code_size}" -le 3 ]]; then
      STATE_VIEW_ADDRESS=""
    fi
  else
    STATE_VIEW_ADDRESS=""
  fi
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
CURRENCY0_LC="$(printf '%s' "${CURRENCY0}" | tr '[:upper:]' '[:lower:]')"
CURRENCY1_LC="$(printf '%s' "${CURRENCY1}" | tr '[:upper:]' '[:lower:]')"
STABLE_LC="$(printf '%s' "${STABLE}" | tr '[:upper:]' '[:lower:]')"
STABLE_SIDE="unknown"
if [[ "${CURRENCY0_LC}" == "${STABLE_LC}" ]]; then
  STABLE_SIDE="token0"
elif [[ "${CURRENCY1_LC}" == "${STABLE_LC}" ]]; then
  STABLE_SIDE="token1"
fi

TOKEN0_DECIMALS_RAW="$(cast_rpc call --rpc-url "${RPC_URL}" "${CURRENCY0}" "decimals()(uint8)" 2>/dev/null | awk '{print $1}')"
TOKEN1_DECIMALS_RAW="$(cast_rpc call --rpc-url "${RPC_URL}" "${CURRENCY1}" "decimals()(uint8)" 2>/dev/null | awk '{print $1}')"
if [[ "${CURRENCY0_LC}" == "${NATIVE_CURRENCY_ADDRESS_LC}" ]]; then
  TOKEN0_DECIMALS=18
elif [[ "${TOKEN0_DECIMALS_RAW}" =~ ^[0-9]+$ ]]; then
  TOKEN0_DECIMALS="${TOKEN0_DECIMALS_RAW}"
else
  TOKEN0_DECIMALS="${STABLE_DECIMALS}"
fi
if [[ "${CURRENCY1_LC}" == "${NATIVE_CURRENCY_ADDRESS_LC}" ]]; then
  TOKEN1_DECIMALS=18
elif [[ "${TOKEN1_DECIMALS_RAW}" =~ ^[0-9]+$ ]]; then
  TOKEN1_DECIMALS="${TOKEN1_DECIMALS_RAW}"
else
  TOKEN1_DECIMALS=18
fi

INIT_PRICE_USD_INT="${INIT_PRICE_USD:-3000}"
if [[ ! "${INIT_PRICE_USD_INT}" =~ ^[0-9]+$ || "${INIT_PRICE_USD_INT}" -le 0 ]]; then
  INIT_PRICE_USD_INT=3000
fi
ONE_FOR_ZERO_SCALE=1
if [[ "${CURRENCY0_LC}" == "${STABLE_LC}" && "${CURRENCY1_LC}" != "${STABLE_LC}" ]]; then
  scale_pow=1
  if (( TOKEN1_DECIMALS > STABLE_DECIMALS )); then
    i=0
    while (( i < TOKEN1_DECIMALS - STABLE_DECIMALS )); do
      if (( scale_pow > 922337203685477580 / 10 )); then
        break
      fi
      scale_pow=$((scale_pow * 10))
      i=$((i + 1))
    done
  fi
  if (( scale_pow > INIT_PRICE_USD_INT )); then
    ONE_FOR_ZERO_SCALE=$((scale_pow / INIT_PRICE_USD_INT))
  fi
  if (( ONE_FOR_ZERO_SCALE < 1 )); then
    ONE_FOR_ZERO_SCALE=1
  fi
fi

DYNAMIC_FEE_FLAG=8388608
# TickMath bounds: min+1 / max-1.
SQRT_PRICE_LIMIT_X96_ZFO=4295128740
SQRT_PRICE_LIMIT_X96_OZF=1461446703485210103287273052203988822378723970341
TEST_SETTINGS="(false,false)"
SWAP_SIG="swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)(bytes32)"
POOL_KEY="(${CURRENCY0},${CURRENCY1},${DYNAMIC_FEE_FLAG},${TICK_SPACING},${HOOK_ADDRESS})"
POOL_ID=""
set -f
POOL_KEY_ENC="$(cast abi-encode 'f((address,address,uint24,int24,address))' "${POOL_KEY}")"
set +f
POOL_ID="$(cast keccak "${POOL_KEY_ENC}")"

PERIOD_SECONDS="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "periodSeconds()(uint32)" | awk '{print $1}')"
if [[ -z "${PERIOD_SECONDS}" || "${PERIOD_SECONDS}" -le 0 ]]; then
  echo "ERROR: failed to read periodSeconds() from hook."
  exit 1
fi

HOOK_FLOOR_IDX="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "floorIdx()(uint8)" | awk '{print $1}')"
HOOK_CAP_IDX="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "capIdx()(uint8)" | awk '{print $1}')"
HOOK_FEE_TIER_COUNT="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "feeTierCount()(uint16)" | awk '{print $1}')"
HOOK_EMA_PERIODS="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "emaPeriods()(uint8)" | awk '{print $1}')"
HOOK_DEADBAND_BPS="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "deadbandBps()(uint16)" | awk '{print $1}')"
HOOK_LULL_RESET_SECONDS="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "lullResetSeconds()(uint32)" | awk '{print $1}')"
if ! [[ "${HOOK_FLOOR_IDX}" =~ ^[0-9]+$ && "${HOOK_CAP_IDX}" =~ ^[0-9]+$ && "${HOOK_FEE_TIER_COUNT}" =~ ^[0-9]+$ && "${HOOK_EMA_PERIODS}" =~ ^[0-9]+$ && "${HOOK_DEADBAND_BPS}" =~ ^[0-9]+$ && "${HOOK_LULL_RESET_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: failed to read hook runtime params."
  exit 1
fi
if (( HOOK_FEE_TIER_COUNT <= 0 )); then
  echo "ERROR: invalid feeTierCount()=${HOOK_FEE_TIER_COUNT}."
  exit 1
fi

percent_to_pips() {
  local pct="$1"
  awk -v pct="${pct}" 'BEGIN {
    if (pct !~ /^[0-9]+([.][0-9]+)?$/) exit 1;
    v = pct * 10000;
    p = int(v + 0.5);
    if (p < 1 || p > 1000000) exit 1;
    print p;
  }' 2>/dev/null
}

declare -a HOOK_FEE_TIER_VALUES=()
for (( i = 0; i < HOOK_FEE_TIER_COUNT; i++ )); do
  tier_value="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "feeTiers(uint256)(uint24)" "${i}" | awk '{print $1}')"
  if ! [[ "${tier_value}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: failed to read feeTiers(${i}) from hook."
    exit 1
  fi
  HOOK_FEE_TIER_VALUES[$i]="${tier_value}"
done

if [[ -n "${FLOOR_TIER:-}" && -n "${CAP_TIER:-}" ]]; then
  cfg_floor_pips="$(percent_to_pips "$(printf '%s' "${FLOOR_TIER}" | tr -d '[:space:]')" || true)"
  cfg_cap_pips="$(percent_to_pips "$(printf '%s' "${CAP_TIER}" | tr -d '[:space:]')" || true)"
  if [[ -z "${cfg_floor_pips}" || -z "${cfg_cap_pips}" ]]; then
    echo "ERROR: invalid FLOOR_TIER/CAP_TIER in config. Use decimal percent values (for example 0.04 and 0.45)."
    exit 1
  fi
  hook_floor_pips="${HOOK_FEE_TIER_VALUES[$HOOK_FLOOR_IDX]-}"
  hook_cap_pips="${HOOK_FEE_TIER_VALUES[$HOOK_CAP_IDX]-}"
  if [[ -z "${hook_floor_pips}" || -z "${hook_cap_pips}" ]]; then
    echo "ERROR: failed to map on-chain floor/cap indices to fee tiers."
    exit 1
  fi

  deadband_mismatch=0
  if [[ "${DEADBAND_BPS:-}" =~ ^[0-9]+$ ]] && (( HOOK_DEADBAND_BPS != DEADBAND_BPS )); then
    deadband_mismatch=1
  fi
  if [[ "${hook_floor_pips}" != "${cfg_floor_pips}" || "${hook_cap_pips}" != "${cfg_cap_pips}" || "${deadband_mismatch}" -eq 1 ]]; then
    echo "ERROR: hook params mismatch with config."
    echo "       on-chain: floor=i${HOOK_FLOOR_IDX}/f${hook_floor_pips} cap=i${HOOK_CAP_IDX}/f${hook_cap_pips} deadband=${HOOK_DEADBAND_BPS}"
    echo "       config:   floor=${FLOOR_TIER}% (f${cfg_floor_pips}) cap=${CAP_TIER}% (f${cfg_cap_pips}) deadband=${DEADBAND_BPS:-?}"
    echo "       Deploy a new hook/pool with current config, then rerun simulate_fee_cycle."
    exit 1
  fi
fi

now_ts() {
  cast_rpc block --rpc-url "${RPC_URL}" latest --field timestamp | awk '{print $1}'
}

read_token_symbol() {
  local token="$1"
  local fallback="$2"
  local out
  if [[ "$(printf '%s' "${token}" | tr '[:upper:]' '[:lower:]')" == "${NATIVE_CURRENCY_ADDRESS_LC}" ]]; then
    echo "${NATIVE_GAS_SYMBOL}"
    return
  fi
  if out="$(cast_rpc call --rpc-url "${RPC_URL}" "${token}" "symbol()(string)" 2>/dev/null)"; then
    out="$(printf '%s\n' "${out}" | sed -n '1p' | tr -d '"')"
    out="$(printf '%s' "${out}" | tr -d '\r\n')"
    if [[ -n "${out}" && "${out}" != "0x" ]]; then
      echo "${out}"
      return
    fi
  fi
  echo "${fallback}"
}

TOKEN0_SYMBOL="$(read_token_symbol "${CURRENCY0}" "token0")"
TOKEN1_SYMBOL="$(read_token_symbol "${CURRENCY1}" "token1")"

format_token_amount() {
  local raw="$1"
  local decimals="$2"
  if ! [[ "${raw}" =~ ^[0-9]+$ && "${decimals}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  python3 - "${raw}" "${decimals}" <<'PY'
import sys
raw = int(sys.argv[1])
dec = int(sys.argv[2])
if dec == 0:
    print(f"{raw:,}")
    raise SystemExit
s = str(raw)
if len(s) <= dec:
    s = "0" * (dec + 1 - len(s)) + s
whole = s[:-dec]
frac = s[-dec:].rstrip("0")
if len(frac) > 6:
    frac = frac[:6].rstrip("0")
whole_fmt = f"{int(whole):,}"
print(whole_fmt if not frac else f"{whole_fmt}.{frac}")
PY
}

format_int_commas() {
  local value="$1"
  if ! [[ "${value}" =~ ^-?[0-9]+$ ]]; then
    echo "${value}"
    return
  fi
  python3 - "${value}" <<'PY'
import sys
print(f"{int(sys.argv[1]):,}")
PY
}

dir_to_label() {
  case "$1" in
    1) echo "UP" ;;
    2) echo "DOWN" ;;
    0) echo "NONE" ;;
    *) echo "-" ;;
  esac
}

sqrt_price_x96_to_price() {
  local sqrt_x96="$1"
  local dec0="$2"
  local dec1="$3"
  if ! [[ "${sqrt_x96}" =~ ^[0-9]+$ && "${dec0}" =~ ^[0-9]+$ && "${dec1}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  python3 - "${sqrt_x96}" "${dec0}" "${dec1}" <<'PY'
from decimal import Decimal, getcontext
import sys
sqrt_x96 = Decimal(sys.argv[1])
dec0 = int(sys.argv[2])
dec1 = int(sys.argv[3])
getcontext().prec = 70
ratio = (sqrt_x96 * sqrt_x96) / (Decimal(2) ** 192)
scale = Decimal(10) ** (dec0 - dec1)
price = ratio * scale
if price == 0:
    print("0")
elif price < Decimal("0.000001") or price >= Decimal("1000000000"):
    print(f"{price:.6E}")
else:
    s = f"{price:.12f}".rstrip("0").rstrip(".")
    print(s)
PY
}

read_state() {
  local fee pv ema ps idx dir out
  fee="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "currentFeeBips()(uint24)" | awk '{print $1}')"
  out="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "unpackedState()(uint64,uint96,uint64,uint8,uint8)")"
  pv="$(printf '%s\n' "${out}" | sed -n '1p' | awk '{print $1}')"
  ema="$(printf '%s\n' "${out}" | sed -n '2p' | awk '{print $1}')"
  ps="$(printf '%s\n' "${out}" | sed -n '3p' | awk '{print $1}')"
  idx="$(printf '%s\n' "${out}" | sed -n '4p' | awk '{print $1}')"
  dir="$(printf '%s\n' "${out}" | sed -n '5p' | awk '{print $1}')"
  echo "${fee}|${pv}|${ema}|${ps}|${idx}|${dir}"
}

read_pause_flag() {
  local out
  out="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "isPaused()(bool)" 2>/dev/null | awk '{print $1}')"
  if [[ "${out}" == "true" || "${out}" == "false" ]]; then
    echo "${out}"
    return 0
  fi
  return 1
}

read_creator_fees() {
  local out f0 f1
  out="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "creatorFeesAccrued()(uint256,uint256)" 2>/dev/null || true)"
  f0="$(printf '%s\n' "${out}" | sed -n '1p' | awk '{print $1}')"
  f1="$(printf '%s\n' "${out}" | sed -n '2p' | awk '{print $1}')"
  if [[ "${f0}" =~ ^[0-9]+$ && "${f1}" =~ ^[0-9]+$ ]]; then
    echo "${f0}|${f1}"
    return 0
  fi
  return 1
}

hook_pause() {
  cast_rpc send --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" "${HOOK_ADDRESS}" "pause()"
}

hook_unpause() {
  cast_rpc send --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" "${HOOK_ADDRESS}" "unpause()"
}

hook_claim_all_creator_fees() {
  cast_rpc send --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" "${HOOK_ADDRESS}" "claimAllCreatorFees(address)" "${DEPLOYER}"
}

run_cases_final_checks() {
  local pause_tx unpause_tx probe_tx before_fee0 before_fee1 after_fee0 after_fee1 claimed_fee0 claimed_fee1
  local pause_flag_after unpause_flag_after fee idx pv ema ps dir amount side_bool
  local state_after_pause state_after_unpause read_creator_fees_before read_creator_fees_after read_creator_fees_claimed
  local attempt_n wait_roll target_vol amount_raw amount_probe
  local pause_static_ok unpause_resume_ok
  local state_before_probe state_after_probe
  local fee_before_probe pv_before_probe ema_before_probe ps_before_probe idx_before_probe dir_before_probe
  local fee_after_probe pv_after_probe ema_after_probe ps_after_probe idx_after_probe dir_after_probe

  if (( CASES_MODE != 1 )); then
    return
  fi

  TC_PAUSE_OBS=$((TC_PAUSE_OBS + 1))
  if pause_tx="$(hook_pause 2>/dev/null)"; then
    if pause_flag_after="$(read_pause_flag 2>/dev/null)" && state_after_pause="$(read_state 2>/dev/null)"; then
      IFS='|' read -r fee pv ema ps idx dir <<<"${state_after_pause}"
      if [[ "${pause_flag_after}" == "true" && "${idx}" =~ ^[0-9]+$ && "${idx}" -eq "${HOOK_FLOOR_IDX}" ]]; then
        TC_PAUSE_PASS=$((TC_PAUSE_PASS + 1))
      else
        TC_PAUSE_FAIL=$((TC_PAUSE_FAIL + 1))
      fi
    else
      TC_PAUSE_FAIL=$((TC_PAUSE_FAIL + 1))
    fi
  else
    TC_PAUSE_FAIL=$((TC_PAUSE_FAIL + 1))
  fi

  TC_PAUSE_STATIC_OBS=$((TC_PAUSE_STATIC_OBS + 1))
  pause_static_ok=0
  if pause_flag_after="$(read_pause_flag 2>/dev/null)" && [[ "${pause_flag_after}" == "true" ]]; then
    for attempt_n in 1 2; do
      if ! state_before_probe="$(read_state 2>/dev/null)"; then
        continue
      fi
      IFS='|' read -r fee_before_probe pv_before_probe ema_before_probe ps_before_probe idx_before_probe dir_before_probe <<<"${state_before_probe}"
      if ! state_fields_valid "${fee_before_probe}" "${pv_before_probe}" "${ema_before_probe}" "${ps_before_probe}" "${idx_before_probe}" "${dir_before_probe}"; then
        continue
      fi
      if (( idx_before_probe != HOOK_FLOOR_IDX )); then
        break
      fi

      wait_roll="$(seconds_to_next_period "${ps_before_probe}")"
      if [[ "${wait_roll}" =~ ^[0-9]+$ ]] && (( wait_roll > 0 )); then
        random_sleep_with_dashboard "${wait_roll}"
      fi

      if ! state_before_probe="$(read_state 2>/dev/null)"; then
        continue
      fi
      IFS='|' read -r fee_before_probe pv_before_probe ema_before_probe ps_before_probe idx_before_probe dir_before_probe <<<"${state_before_probe}"
      if ! state_fields_valid "${fee_before_probe}" "${pv_before_probe}" "${ema_before_probe}" "${ps_before_probe}" "${idx_before_probe}" "${dir_before_probe}"; then
        continue
      fi

      target_vol="$(cases_target_up_volume "${ema_before_probe}" "$((4 + attempt_n))")"
      amount_raw="$(amount_for_period_target_vol "${target_vol}" "${pv_before_probe}")"
      if ! [[ "${amount_raw}" =~ ^[0-9]+$ ]] || (( amount_raw <= 0 )); then
        amount_raw=1000000
      fi
      amount_probe="$(scale_amount_for_side "${amount_raw}" "zeroForOne")"
      if ! [[ "${amount_probe}" =~ ^[0-9]+$ ]] || (( amount_probe <= 0 )); then
        continue
      fi

      if ! probe_tx="$(run_swap_step "FINAL_PAUSE_STATIC_${attempt_n}" "${amount_probe}" true 2>/dev/null)"; then
        continue
      fi
      if ! state_after_probe="$(read_state 2>/dev/null)"; then
        continue
      fi
      IFS='|' read -r fee_after_probe pv_after_probe ema_after_probe ps_after_probe idx_after_probe dir_after_probe <<<"${state_after_probe}"
      if ! state_fields_valid "${fee_after_probe}" "${pv_after_probe}" "${ema_after_probe}" "${ps_after_probe}" "${idx_after_probe}" "${dir_after_probe}"; then
        continue
      fi
      if (( ps_after_probe <= ps_before_probe )); then
        continue
      fi

      if pause_flag_after="$(read_pause_flag 2>/dev/null)" \
        && [[ "${pause_flag_after}" == "true" ]] \
        && (( idx_after_probe == HOOK_FLOOR_IDX )) \
        && (( idx_after_probe == idx_before_probe )); then
        pause_static_ok=1
        break
      fi
      pause_static_ok=0
      break
    done
  fi
  if (( pause_static_ok == 1 )); then
    TC_PAUSE_STATIC_PASS=$((TC_PAUSE_STATIC_PASS + 1))
  else
    TC_PAUSE_STATIC_FAIL=$((TC_PAUSE_STATIC_FAIL + 1))
  fi

  TC_UNPAUSE_OBS=$((TC_UNPAUSE_OBS + 1))
  if unpause_tx="$(hook_unpause 2>/dev/null)"; then
    if unpause_flag_after="$(read_pause_flag 2>/dev/null)" && state_after_unpause="$(read_state 2>/dev/null)"; then
      IFS='|' read -r fee pv ema ps idx dir <<<"${state_after_unpause}"
      if [[ "${unpause_flag_after}" == "false" && "${idx}" =~ ^[0-9]+$ && "${idx}" -eq "${HOOK_FLOOR_IDX}" ]]; then
        TC_UNPAUSE_PASS=$((TC_UNPAUSE_PASS + 1))
      else
        TC_UNPAUSE_FAIL=$((TC_UNPAUSE_FAIL + 1))
      fi
    else
      TC_UNPAUSE_FAIL=$((TC_UNPAUSE_FAIL + 1))
    fi
  else
    TC_UNPAUSE_FAIL=$((TC_UNPAUSE_FAIL + 1))
  fi

  TC_UNPAUSE_RESUME_OBS=$((TC_UNPAUSE_RESUME_OBS + 1))
  unpause_resume_ok=0
  if unpause_flag_after="$(read_pause_flag 2>/dev/null)" && [[ "${unpause_flag_after}" == "false" ]]; then
    for attempt_n in 1 2 3; do
      if ! state_before_probe="$(read_state 2>/dev/null)"; then
        continue
      fi
      IFS='|' read -r fee_before_probe pv_before_probe ema_before_probe ps_before_probe idx_before_probe dir_before_probe <<<"${state_before_probe}"
      if ! state_fields_valid "${fee_before_probe}" "${pv_before_probe}" "${ema_before_probe}" "${ps_before_probe}" "${idx_before_probe}" "${dir_before_probe}"; then
        continue
      fi

      wait_roll="$(seconds_to_next_period "${ps_before_probe}")"
      if [[ "${wait_roll}" =~ ^[0-9]+$ ]] && (( wait_roll > 0 )); then
        random_sleep_with_dashboard "${wait_roll}"
      fi

      if ! state_before_probe="$(read_state 2>/dev/null)"; then
        continue
      fi
      IFS='|' read -r fee_before_probe pv_before_probe ema_before_probe ps_before_probe idx_before_probe dir_before_probe <<<"${state_before_probe}"
      if ! state_fields_valid "${fee_before_probe}" "${pv_before_probe}" "${ema_before_probe}" "${ps_before_probe}" "${idx_before_probe}" "${dir_before_probe}"; then
        continue
      fi

      target_vol="$(cases_target_up_volume "${ema_before_probe}" "$((6 + attempt_n))")"
      amount_raw="$(amount_for_period_target_vol "${target_vol}" "${pv_before_probe}")"
      if ! [[ "${amount_raw}" =~ ^[0-9]+$ ]] || (( amount_raw <= 0 )); then
        amount_raw=1000000
      fi
      amount_probe="$(scale_amount_for_side "${amount_raw}" "zeroForOne")"
      if ! [[ "${amount_probe}" =~ ^[0-9]+$ ]] || (( amount_probe <= 0 )); then
        continue
      fi

      if ! probe_tx="$(run_swap_step "FINAL_UNPAUSE_RESUME_${attempt_n}" "${amount_probe}" true 2>/dev/null)"; then
        continue
      fi
      if ! state_after_probe="$(read_state 2>/dev/null)"; then
        continue
      fi
      IFS='|' read -r fee_after_probe pv_after_probe ema_after_probe ps_after_probe idx_after_probe dir_after_probe <<<"${state_after_probe}"
      if ! state_fields_valid "${fee_after_probe}" "${pv_after_probe}" "${ema_after_probe}" "${ps_after_probe}" "${idx_after_probe}" "${dir_after_probe}"; then
        continue
      fi
      if (( ps_after_probe <= ps_before_probe )); then
        continue
      fi

      if unpause_flag_after="$(read_pause_flag 2>/dev/null)" && [[ "${unpause_flag_after}" == "false" ]]; then
        if (( idx_after_probe > idx_before_probe )); then
          unpause_resume_ok=1
          break
        fi
        if (( idx_after_probe < idx_before_probe )); then
          unpause_resume_ok=0
          break
        fi
      fi
    done
  fi
  if (( unpause_resume_ok == 1 )); then
    TC_UNPAUSE_RESUME_PASS=$((TC_UNPAUSE_RESUME_PASS + 1))
  else
    TC_UNPAUSE_RESUME_FAIL=$((TC_UNPAUSE_RESUME_FAIL + 1))
  fi

  if ! read_creator_fees_before="$(read_creator_fees 2>/dev/null)"; then
    read_creator_fees_before="0|0"
  fi
  IFS='|' read -r before_fee0 before_fee1 <<<"${read_creator_fees_before}"
  if ! [[ "${before_fee0}" =~ ^[0-9]+$ ]]; then before_fee0=0; fi
  if ! [[ "${before_fee1}" =~ ^[0-9]+$ ]]; then before_fee1=0; fi

  amount=1000000
  side_bool=true
  TC_MON_ACCRUE_OBS=$((TC_MON_ACCRUE_OBS + 1))
  if probe_tx="$(run_swap_step "FINAL_MON_ACCRUE" "${amount}" "${side_bool}" 2>/dev/null)"; then
    if read_creator_fees_after="$(read_creator_fees 2>/dev/null)"; then
      IFS='|' read -r after_fee0 after_fee1 <<<"${read_creator_fees_after}"
      if ! [[ "${after_fee0}" =~ ^[0-9]+$ ]]; then after_fee0=0; fi
      if ! [[ "${after_fee1}" =~ ^[0-9]+$ ]]; then after_fee1=0; fi
      if (( after_fee0 > before_fee0 || after_fee1 > before_fee1 )); then
        TC_MON_ACCRUE_PASS=$((TC_MON_ACCRUE_PASS + 1))
      else
        TC_MON_ACCRUE_FAIL=$((TC_MON_ACCRUE_FAIL + 1))
      fi
    else
      TC_MON_ACCRUE_FAIL=$((TC_MON_ACCRUE_FAIL + 1))
    fi
  else
    TC_MON_ACCRUE_FAIL=$((TC_MON_ACCRUE_FAIL + 1))
  fi

  TC_MON_CLAIM_OBS=$((TC_MON_CLAIM_OBS + 1))
  if hook_claim_all_creator_fees >/dev/null 2>&1; then
    if read_creator_fees_claimed="$(read_creator_fees 2>/dev/null)"; then
      IFS='|' read -r claimed_fee0 claimed_fee1 <<<"${read_creator_fees_claimed}"
      if ! [[ "${claimed_fee0}" =~ ^[0-9]+$ ]]; then claimed_fee0=1; fi
      if ! [[ "${claimed_fee1}" =~ ^[0-9]+$ ]]; then claimed_fee1=1; fi
      if (( claimed_fee0 == 0 && claimed_fee1 == 0 )); then
        TC_MON_CLAIM_PASS=$((TC_MON_CLAIM_PASS + 1))
      else
        TC_MON_CLAIM_FAIL=$((TC_MON_CLAIM_FAIL + 1))
      fi
    else
      TC_MON_CLAIM_FAIL=$((TC_MON_CLAIM_FAIL + 1))
    fi
  else
    TC_MON_CLAIM_FAIL=$((TC_MON_CLAIM_FAIL + 1))
  fi
}

state_fields_valid() {
  local fee="$1"
  local pv="$2"
  local ema="$3"
  local ps="$4"
  local idx="$5"
  local dir="$6"
  if [[ "${fee}" =~ ^[0-9]+$ \
     && "${pv}" =~ ^[0-9]+$ \
     && "${ema}" =~ ^[0-9]+$ \
     && "${ps}" =~ ^[0-9]+$ \
     && "${idx}" =~ ^[0-9]+$ \
     && "${dir}" =~ ^[0-2]$ ]]; then
    return 0
  fi
  return 1
}

read_pool_slot0() {
  local out sqrt_price tick protocol_fee lp_fee
  if [[ -z "${STATE_VIEW_ADDRESS}" || -z "${POOL_ID}" ]]; then
    return 1
  fi
  if ! out="$(cast_rpc call --rpc-url "${RPC_URL}" "${STATE_VIEW_ADDRESS}" "getSlot0(bytes32)(uint160,int24,uint24,uint24)" "${POOL_ID}" 2>&1)"; then
    echo "${out}"
    return 1
  fi
  sqrt_price="$(printf '%s\n' "${out}" | sed -n '1p' | awk '{print $1}')"
  tick="$(printf '%s\n' "${out}" | sed -n '2p' | awk '{print $1}')"
  protocol_fee="$(printf '%s\n' "${out}" | sed -n '3p' | awk '{print $1}')"
  lp_fee="$(printf '%s\n' "${out}" | sed -n '4p' | awk '{print $1}')"
  if [[ ! "${sqrt_price}" =~ ^[0-9]+$ || ! "${tick}" =~ ^-?[0-9]+$ || ! "${protocol_fee}" =~ ^[0-9]+$ || ! "${lp_fee}" =~ ^[0-9]+$ ]]; then
    echo "failed to parse slot0 from getSlot0 output"
    return 1
  fi
  echo "${sqrt_price}|${tick}|${protocol_fee}|${lp_fee}"
}

read_pool_tick() {
  local slot0 sqrt_price tick protocol_fee lp_fee
  if ! slot0="$(read_pool_slot0 2>/dev/null)"; then
    return 1
  fi
  IFS='|' read -r sqrt_price tick protocol_fee lp_fee <<<"${slot0}"
  RND_SLOT0_SQRT_PRICE_X96="${sqrt_price}"
  RND_SLOT0_TICK="${tick}"
  RND_SLOT0_PROTOCOL_FEE="${protocol_fee}"
  RND_SLOT0_LP_FEE="${lp_fee}"
  RND_POOL_PRICE_T1_PER_T0="$(sqrt_price_x96_to_price "${sqrt_price}" "${TOKEN0_DECIMALS}" "${TOKEN1_DECIMALS}")"
  echo "${tick}"
}

read_pool_liquidity() {
  local out liq
  if [[ -z "${STATE_VIEW_ADDRESS}" || -z "${POOL_ID}" ]]; then
    return 1
  fi
  if ! out="$(cast_rpc call --rpc-url "${RPC_URL}" "${STATE_VIEW_ADDRESS}" "getLiquidity(bytes32)(uint128)" "${POOL_ID}" 2>&1)"; then
    echo "${out}"
    return 1
  fi
  liq="$(printf '%s\n' "${out}" | sed -n '1p' | awk '{print $1}')"
  if [[ ! "${liq}" =~ ^[0-9]+$ ]]; then
    echo "failed to parse liquidity from getLiquidity output"
    return 1
  fi
  echo "${liq}"
}

read_token_balance() {
  local token="$1"
  local out
  if [[ "$(printf '%s' "${token}" | tr '[:upper:]' '[:lower:]')" == "${NATIVE_CURRENCY_ADDRESS_LC}" ]]; then
    read_native_balance_wei
    return $?
  fi
  if ! out="$(cast_rpc call --rpc-url "${RPC_URL}" "${token}" "balanceOf(address)(uint256)" "${DEPLOYER}" 2>/dev/null | awk '{print $1}')"; then
    return 1
  fi
  if [[ ! "${out}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  echo "${out}"
}

read_native_balance_wei() {
  local out
  if ! out="$(cast_rpc balance --rpc-url "${RPC_URL}" "${DEPLOYER}" 2>/dev/null | awk '{print $1}')"; then
    return 1
  fi
  if [[ ! "${out}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  echo "${out}"
}

run_swap_step() {
  local label="$1"
  local amount="$2"
  local zero_for_one="$3"
  local out tx send_attempt
  local params
  local sqrt_price_limit
  local token_in_lc

  if [[ "${zero_for_one}" == "true" ]]; then
    sqrt_price_limit="${SQRT_PRICE_LIMIT_X96_ZFO}"
    token_in_lc="${CURRENCY0_LC}"
  else
    sqrt_price_limit="${SQRT_PRICE_LIMIT_X96_OZF}"
    token_in_lc="${CURRENCY1_LC}"
  fi
  params="(${zero_for_one},-${amount},${sqrt_price_limit})"
  send_attempt=0
  while true; do
    if [[ "${token_in_lc}" == "${NATIVE_CURRENCY_ADDRESS_LC}" ]]; then
      if out="$(cast_rpc send --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" --value "${amount}" "${SWAP_TEST_ADDRESS}" "${SWAP_SIG}" "${POOL_KEY}" "${params}" "${TEST_SETTINGS}" 0x 2>&1)"; then
        break
      fi
    elif out="$(cast_rpc send --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" "${SWAP_TEST_ADDRESS}" "${SWAP_SIG}" "${POOL_KEY}" "${params}" "${TEST_SETTINGS}" 0x 2>&1)"; then
      break
    fi
    send_attempt=$((send_attempt + 1))
    if (( send_attempt < 3 )) && [[ "${out}" == *"replacement transaction underpriced"* || "${out}" == *"nonce too low"* ]]; then
      sleep 1
      continue
    fi
    echo "ERROR: swap tx failed for step ${label}" >&2
    echo "${out}" >&2
    return 1
  done
  tx="$(echo "${out}" | awk '/^transactionHash[[:space:]]/{print $2; exit}')"
  if [[ -z "${tx}" ]]; then
    echo "ERROR: failed to parse transaction hash for step ${label}" >&2
    echo "${out}" >&2
    return 1
  fi
  echo "${tx}"
}

run_wrap_step() {
  local label="$1"
  local weth_token="$2"
  local amount_wei="$3"
  local out tx send_attempt
  if ! [[ "${amount_wei}" =~ ^[0-9]+$ ]] || (( amount_wei <= 0 )); then
    echo "ERROR: invalid wrap amount for ${label}" >&2
    return 1
  fi
  send_attempt=0
  while true; do
    if out="$(cast_rpc send --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" --value "${amount_wei}" "${weth_token}" "deposit()" 2>&1)"; then
      break
    fi
    send_attempt=$((send_attempt + 1))
    if (( send_attempt < 3 )) && [[ "${out}" == *"replacement transaction underpriced"* || "${out}" == *"nonce too low"* ]]; then
      sleep 1
      continue
    fi
    echo "ERROR: wrap tx failed for step ${label}" >&2
    echo "${out}" >&2
    return 1
  done
  tx="$(echo "${out}" | awk '/^transactionHash[[:space:]]/{print $2; exit}')"
  if [[ -z "${tx}" ]]; then
    echo "ERROR: failed to parse wrap transaction hash for step ${label}" >&2
    echo "${out}" >&2
    return 1
  fi
  echo "${tx}"
}

compute_wallet_rebalance_plan() {
  local native_wei="$1"
  local stable_raw="$2"
  local volatile_raw="$3"
  local price_ratio="$4"
  local stable_dec="$5"
  local volatile_dec="$6"
  local util_pct="$7"
  local target_pct="$8"
  local tolerance_pct="$9"
  local plan
  if ! plan="$(python3 - "${native_wei}" "${stable_raw}" "${volatile_raw}" "${price_ratio}" "${STABLE_SIDE}" "${stable_dec}" "${volatile_dec}" "${util_pct}" "${target_pct}" "${tolerance_pct}" <<'PY'
from decimal import Decimal, getcontext, InvalidOperation, ROUND_FLOOR
import sys

native_wei = int(sys.argv[1])
stable_raw = int(sys.argv[2])
volatile_raw = int(sys.argv[3])
ratio_str = sys.argv[4]
stable_side = sys.argv[5]
stable_dec = int(sys.argv[6])
volatile_dec = int(sys.argv[7])
util_pct = int(sys.argv[8])
target_pct = int(sys.argv[9])
tolerance_pct = int(sys.argv[10])

getcontext().prec = 70
try:
  ratio = Decimal(ratio_str)
except (InvalidOperation, ValueError):
  ratio = Decimal(0)

if ratio <= 0 or stable_side not in ("token0", "token1") or util_pct <= 0:
  print("0|none|0")
  raise SystemExit

# ratio is token1 per token0.
if stable_side == "token0":
    price_stable_per_volatile = Decimal(1) / ratio
else:
    price_stable_per_volatile = ratio

native_units = Decimal(native_wei) / (Decimal(10) ** 18)
max_wrap_units = native_units * Decimal(util_pct) / Decimal(100)
if max_wrap_units < 0:
    max_wrap_units = Decimal(0)
stable_units = Decimal(stable_raw) / (Decimal(10) ** stable_dec)
volatile_units = Decimal(volatile_raw) / (Decimal(10) ** volatile_dec)
total_value = stable_units + (volatile_units + max_wrap_units) * price_stable_per_volatile
if total_value <= 0:
    print("0|none|0")
    raise SystemExit

if target_pct <= 0:
    target_pct = 50
if target_pct >= 100:
    target_pct = 50
if tolerance_pct < 0:
    tolerance_pct = 0

target = total_value * Decimal(target_pct) / Decimal(100)
tolerance = total_value * Decimal(tolerance_pct) / Decimal(100)
delta = stable_units - target
action = "none"
swap_raw = 0
wrap_wei = 0

if delta > tolerance:
    # Need more volatile: buy volatile with stable.
    spend_stable = delta
    swap_raw = int((spend_stable * (Decimal(10) ** stable_dec)).to_integral_value(rounding=ROUND_FLOOR))
    max_buy = int((Decimal(stable_raw) * Decimal("0.80")).to_integral_value(rounding=ROUND_FLOOR))
    min_buy = max(1, stable_raw // 500)
    if max_buy < min_buy:
        max_buy = min_buy
    if swap_raw > max_buy:
        swap_raw = max_buy
    if swap_raw >= min_buy:
        action = "buy_volatile_with_stable"
    else:
        swap_raw = 0
elif delta < -tolerance:
    # Need more stable: sell volatile.
    need_stable = -delta
    sell_volatile = need_stable / price_stable_per_volatile
    if sell_volatile < 0:
        sell_volatile = Decimal(0)
    wrap_units = sell_volatile - volatile_units
    if wrap_units < 0:
        wrap_units = Decimal(0)
    if wrap_units > max_wrap_units:
        wrap_units = max_wrap_units
    sell_cap = volatile_units + wrap_units
    if sell_volatile > sell_cap:
        sell_volatile = sell_cap
    swap_raw = int((sell_volatile * (Decimal(10) ** volatile_dec)).to_integral_value(rounding=ROUND_FLOOR))
    wrap_wei = int((wrap_units * (Decimal(10) ** 18)).to_integral_value(rounding=ROUND_FLOOR))
    wrap_raw_equiv = int((wrap_units * (Decimal(10) ** volatile_dec)).to_integral_value(rounding=ROUND_FLOOR))
    max_sell = int((Decimal(volatile_raw + wrap_raw_equiv) * Decimal("0.80")).to_integral_value(rounding=ROUND_FLOOR))
    min_sell = max(1, (volatile_raw + wrap_raw_equiv) // 500)
    if max_sell < min_sell:
        max_sell = min_sell
    if swap_raw > max_sell:
        swap_raw = max_sell
    if swap_raw >= min_sell:
        action = "sell_volatile_for_stable"
    else:
        swap_raw = 0
        wrap_wei = 0

print(f"{wrap_wei}|{action}|{swap_raw}")
PY
)"; then
    return 1
  fi
  echo "${plan}"
}

suggest_balance_target_side() {
  local stable_raw="$1"
  local volatile_raw="$2"
  local price_ratio="$3"
  local stable_dec="$4"
  local volatile_dec="$5"
  local target_pct="$6"
  local tolerance_pct="$7"
  local tick_now="$8"
  local tick_anchor="$9"
  local tick_band="${10}"
  local out
  if ! out="$(python3 - "${stable_raw}" "${volatile_raw}" "${price_ratio}" "${STABLE_SIDE}" "${stable_dec}" "${volatile_dec}" "${target_pct}" "${tolerance_pct}" "${tick_now}" "${tick_anchor}" "${tick_band}" <<'PY'
from decimal import Decimal, getcontext, InvalidOperation
import sys

stable_raw = int(sys.argv[1])
volatile_raw = int(sys.argv[2])
ratio_str = sys.argv[3]
stable_side = sys.argv[4]
stable_dec = int(sys.argv[5])
volatile_dec = int(sys.argv[6])
target_pct = int(sys.argv[7])
tolerance_pct = int(sys.argv[8])
tick_now_str = sys.argv[9]
tick_anchor_str = sys.argv[10]
tick_band = int(sys.argv[11])

getcontext().prec = 70
try:
    ratio = Decimal(ratio_str)
except (InvalidOperation, ValueError):
    ratio = Decimal(0)

wallet_side = "none"
pool_side = "none"
reason = "none"

if ratio > 0 and stable_side in ("token0", "token1"):
    if stable_side == "token0":
        price_stable_per_volatile = Decimal(1) / ratio
        to_volatile = "zeroForOne"
        to_stable = "oneForZero"
    else:
        price_stable_per_volatile = ratio
        to_volatile = "oneForZero"
        to_stable = "zeroForOne"
    stable_units = Decimal(stable_raw) / (Decimal(10) ** stable_dec)
    volatile_units = Decimal(volatile_raw) / (Decimal(10) ** volatile_dec)
    total_value = stable_units + volatile_units * price_stable_per_volatile
    if total_value > 0:
        if target_pct <= 0 or target_pct >= 100:
            target_pct = 50
        if tolerance_pct < 0:
            tolerance_pct = 0
        stable_pct = (stable_units * Decimal(100)) / total_value
        lower = Decimal(target_pct - tolerance_pct)
        upper = Decimal(target_pct + tolerance_pct)
        if stable_pct > upper:
            wallet_side = to_volatile
        elif stable_pct < lower:
            wallet_side = to_stable

try:
    tick_now = int(tick_now_str)
    tick_anchor = int(tick_anchor_str)
except ValueError:
    tick_now = None
    tick_anchor = None
if tick_now is not None and tick_anchor is not None and tick_band > 0:
    delta = tick_now - tick_anchor
    trigger = max(1, tick_band // 2)
    if delta > trigger:
        pool_side = "zeroForOne"
    elif delta < -trigger:
        pool_side = "oneForZero"

if pool_side != "none" and wallet_side != "none":
    if pool_side == wallet_side:
        print(f"{pool_side}|wallet+pool-balance")
    else:
        print(f"{pool_side}|pool-balance")
elif pool_side != "none":
    print(f"{pool_side}|pool-balance")
elif wallet_side != "none":
    print(f"{wallet_side}|wallet-balance")
else:
    print("none|none")
PY
)"; then
    return 1
  fi
  echo "${out}"
}

maybe_rebalance_wallet() {
  local force="${1:-0}"
  local native_raw stable_raw volatile_raw
  local stable_token volatile_token
  local stable_dec volatile_dec
  local plan wrap_wei action swap_amount
  local side zero_for_one wrap_tx swap_tx attempt_no ts

  if (( AUTO_REBALANCE_ENABLED == 0 )); then
    return 1
  fi
  if [[ "${STABLE_SIDE}" == "unknown" ]]; then
    return 1
  fi
  if (( force == 0 && RND_ATTEMPTS > 0 && (RND_ATTEMPTS - RND_REBALANCE_LAST_ATTEMPT) < AUTO_REBALANCE_MIN_INTERVAL_ATTEMPTS )); then
    return 1
  fi

  if [[ "${STABLE_SIDE}" == "token0" ]]; then
    stable_token="${CURRENCY0}"
    volatile_token="${CURRENCY1}"
    stable_dec="${TOKEN0_DECIMALS}"
    volatile_dec="${TOKEN1_DECIMALS}"
  else
    stable_token="${CURRENCY1}"
    volatile_token="${CURRENCY0}"
    stable_dec="${TOKEN1_DECIMALS}"
    volatile_dec="${TOKEN0_DECIMALS}"
  fi

  if ! native_raw="$(read_native_balance_wei 2>/dev/null)"; then
    return 1
  fi
  if ! stable_raw="$(read_token_balance "${stable_token}" 2>/dev/null)"; then
    return 1
  fi
  if ! volatile_raw="$(read_token_balance "${volatile_token}" 2>/dev/null)"; then
    return 1
  fi
  if ! [[ "${native_raw}" =~ ^[0-9]+$ && "${stable_raw}" =~ ^[0-9]+$ && "${volatile_raw}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if [[ -z "${RND_POOL_PRICE_T1_PER_T0}" || "${RND_POOL_PRICE_T1_PER_T0}" == "-" ]]; then
    read_pool_tick >/dev/null 2>&1 || true
  fi
  if [[ -z "${RND_POOL_PRICE_T1_PER_T0}" || "${RND_POOL_PRICE_T1_PER_T0}" == "-" ]]; then
    return 1
  fi

  if ! plan="$(compute_wallet_rebalance_plan \
    "${native_raw}" \
    "${stable_raw}" \
    "${volatile_raw}" \
    "${RND_POOL_PRICE_T1_PER_T0}" \
    "${stable_dec}" \
    "${volatile_dec}" \
    "${AUTO_REBALANCE_ETH_UTIL_PCT}" \
    "${AUTO_REBALANCE_TARGET_PCT}" \
    "${AUTO_REBALANCE_TOLERANCE_PCT}")"; then
    return 1
  fi

  wrap_wei="${plan%%|*}"
  plan="${plan#*|}"
  action="${plan%%|*}"
  swap_amount="${plan#*|}"
  if ! [[ "${wrap_wei}" =~ ^[0-9]+$ && "${swap_amount}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if (( wrap_wei == 0 && swap_amount == 0 )); then
    return 1
  fi

  if (( wrap_wei > 0 )); then
    wrap_tx="$(run_wrap_step "REBAL_WRAP_$(printf '%06d' "$((RND_ATTEMPTS + 1))")" "${volatile_token}" "${wrap_wei}" 2>&1)" || {
      RND_LAST_ERROR="rebalance wrap failed: $(sanitize_inline "${wrap_tx}")"
      return 1
    }
  fi

  if (( swap_amount > 0 )) && [[ "${action}" != "none" ]]; then
    if [[ "${action}" == "sell_volatile_for_stable" ]]; then
      if [[ "${STABLE_SIDE}" == "token0" ]]; then
        zero_for_one=false
        side="oneForZero"
      else
        zero_for_one=true
        side="zeroForOne"
      fi
    else
      if [[ "${STABLE_SIDE}" == "token0" ]]; then
        zero_for_one=true
        side="zeroForOne"
      else
        zero_for_one=false
        side="oneForZero"
      fi
    fi
    swap_tx="$(run_swap_step "REBAL_SWAP_$(printf '%06d' "$((RND_ATTEMPTS + 1))")" "${swap_amount}" "${zero_for_one}" 2>&1)" || {
      RND_LAST_ERROR="rebalance swap failed: $(sanitize_inline "${swap_tx}")"
      return 1
    }
    attempt_no=$((RND_ATTEMPTS + 1))
    if [[ "${side}" == "zeroForOne" ]]; then
      RND_ZFO_COUNT=$((RND_ZFO_COUNT + 1))
    else
      RND_OZF_COUNT=$((RND_OZF_COUNT + 1))
    fi
    RND_LAST_TX_HASH="${swap_tx}"
    RND_LAST_TX_STATUS="ok"
    RND_LAST_TX_SIDE="${side}"
    RND_LAST_TX_AMOUNT="${swap_amount}"
    RND_LAST_TX_REASON="wallet-rebalance"
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    random_append_tx_log "${ts}" "${attempt_no}" "REBALANCE" "ok" "${side}" "${swap_amount}" "wallet-rebalance" "${swap_tx}" "-" "-" "-" "-" "-" "-" "-"
  else
    RND_LAST_TX_REASON="wallet-rebalance-wrap-only"
  fi

  RND_REBALANCE_LAST_ATTEMPT="${RND_ATTEMPTS}"
  RND_REBALANCE_COUNT=$((RND_REBALANCE_COUNT + 1))
  random_refresh_runtime_metrics
  return 0
}

amount_for_target_vol() {
  local target_vol="$1"
  local amount
  local max_amount
  local bal_raw
  # For zeroForOne exact-input swaps in this pool, amountSpecified is token0 (USDC, 6 decimals).
  # Approximation: ~2 USDC per 1 USD of target period volume.
  amount=$(( (target_vol + 1) / 2 ))
  # Keep volume meaningful in USD6 units to avoid dust-only closes.
  if (( amount < 500000 )); then amount=500000; fi
  if [[ "${CURRENCY0_LC}" == "${NATIVE_CURRENCY_ADDRESS_LC}" ]]; then
    bal_raw="$(read_native_balance_wei 2>/dev/null || true)"
  elif bal_raw="$(cast_rpc call --rpc-url "${RPC_URL}" "${CURRENCY0}" "balanceOf(address)(uint256)" "${DEPLOYER}" 2>/dev/null | awk '{print $1}')"; then
    :
  else
    bal_raw=""
  fi
  if [[ -n "${bal_raw}" && "${bal_raw}" =~ ^[0-9]+$ ]]; then
    max_amount=$(( bal_raw * MAX_BALANCE_SPEND_PCT / 100 ))
    if (( bal_raw > 0 && max_amount <= 0 )); then
      max_amount="${bal_raw}"
    fi
    if (( max_amount <= 0 )); then
      amount=0
    elif (( amount > max_amount )); then
      amount=${max_amount}
    fi
  fi
  echo "${amount}"
}

amount_for_period_target_vol() {
  local target_vol="$1"
  local current_vol="$2"
  local delta cushion
  if ! [[ "${target_vol}" =~ ^[0-9]+$ ]]; then
    target_vol=0
  fi
  if ! [[ "${current_vol}" =~ ^[0-9]+$ ]]; then
    current_vol=0
  fi
  delta=$((target_vol - current_vol))
  if (( delta <= 0 )); then
    delta="${HOOK_DUST_CLOSE_VOL_USD6}"
  fi
  cushion=$((delta / 8))
  if (( cushion < 500000 )); then cushion=500000; fi
  delta=$((delta + cushion))
  if (( delta < 1000000 )); then delta=1000000; fi
  amount_for_target_vol "${delta}"
}

scale_amount_for_side() {
  local amount="$1"
  local side="$2"
  local token_in bal_raw max_amount
  if ! [[ "${amount}" =~ ^[0-9]+$ ]]; then
    echo "1"
    return
  fi
  if [[ "${side}" == "oneForZero" && "${ONE_FOR_ZERO_SCALE}" =~ ^[0-9]+$ && "${ONE_FOR_ZERO_SCALE}" -gt 1 ]]; then
    if (( amount > 9223372036854775807 / ONE_FOR_ZERO_SCALE )); then
      amount=9223372036854775807
    else
      amount=$((amount * ONE_FOR_ZERO_SCALE))
    fi
  fi
  token_in="${CURRENCY0}"
  if [[ "${side}" == "oneForZero" ]]; then
    token_in="${CURRENCY1}"
  fi
  if [[ "$(printf '%s' "${token_in}" | tr '[:upper:]' '[:lower:]')" == "${NATIVE_CURRENCY_ADDRESS_LC}" ]]; then
    bal_raw="$(read_native_balance_wei 2>/dev/null || true)"
  elif bal_raw="$(cast_rpc call --rpc-url "${RPC_URL}" "${token_in}" "balanceOf(address)(uint256)" "${DEPLOYER}" 2>/dev/null | awk '{print $1}')"; then
    if [[ "${bal_raw}" =~ ^[0-9]+$ ]]; then
      max_amount=$(( bal_raw * MAX_BALANCE_SPEND_PCT / 100 ))
      if (( bal_raw > 0 && max_amount <= 0 )); then
        max_amount="${bal_raw}"
      fi
      if (( max_amount <= 0 )); then
        amount=0
      elif (( amount > max_amount )); then
        amount="${max_amount}"
      fi
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
    target=150000000
  else
    target=$(( ema * 3 ))
    if (( target < ema + 20000000 )); then target=$(( ema + 20000000 )); fi
    if (( target < 120000000 )); then target=120000000; fi
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
    target=3000000
  else
    target=$(( ema / 20 ))
    if (( target < 1500000 )); then target=1500000; fi
  fi
  echo "$(amount_for_target_vol "${target}")"
}

pick_case_amount_bounds() {
  local bal_raw max_case min_case cases_min cases_max
  if [[ "${CURRENCY0_LC}" == "${NATIVE_CURRENCY_ADDRESS_LC}" ]]; then
    if ! bal_raw="$(read_native_balance_wei 2>/dev/null)"; then
      return 1
    fi
  elif ! bal_raw="$(cast_rpc call --rpc-url "${RPC_URL}" "${CURRENCY0}" "balanceOf(address)(uint256)" "${DEPLOYER}" 2>/dev/null | awk '{print $1}')"; then
    return 1
  fi
  if ! [[ "${bal_raw}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  cases_min="${CASES_SOFT_MIN_AMOUNT}"
  cases_max="${CASES_SOFT_MAX_AMOUNT}"
  if ! [[ "${cases_min}" =~ ^[0-9]+$ ]]; then
    cases_min=500000
  fi
  if ! [[ "${cases_max}" =~ ^[0-9]+$ ]]; then
    cases_max=3000000
  fi
  if (( cases_min <= 0 )); then
    cases_min=500000
  fi
  if (( cases_max < cases_min )); then
    cases_max="${cases_min}"
  fi
  max_case=$(( bal_raw * 25 / 100 ))
  if (( bal_raw > 0 && max_case <= 0 )); then
    max_case="${bal_raw}"
  fi
  if (( CASES_MODE == 1 )); then
    # Cases mode defaults are intentionally conservative: test mechanics with small swaps.
    if (( max_case > cases_max )); then
      max_case="${cases_max}"
    fi
    if (( max_case < cases_min )); then
      max_case="${cases_min}"
    fi
    min_case="${cases_min}"
  else
    if (( max_case > RANDOM_SOFT_MAX_AMOUNT )); then
      max_case="${RANDOM_SOFT_MAX_AMOUNT}"
    fi
    if (( max_case < 500000 )); then
      max_case=500000
    fi
    min_case=$((max_case / 20))
    if (( min_case < RANDOM_SOFT_MIN_AMOUNT )); then
      min_case="${RANDOM_SOFT_MIN_AMOUNT}"
    fi
  fi
  if (( min_case > max_case )); then
    min_case="${max_case}"
  fi
  echo "${min_case}|${max_case}"
}

random_between() {
  local min="$1"
  local max="$2"
  local span rnd
  if (( max <= min )); then
    echo "${min}"
    return
  fi
  span=$((max - min + 1))
  rnd="$(od -An -N4 -tu4 /dev/urandom | tr -d '[:space:]')"
  if [[ -z "${rnd}" ]]; then
    rnd="${RANDOM}"
  fi
  echo $((min + (rnd % span)))
}

fmt_duration() {
  local total="$1"
  local h m s
  h=$((total / 3600))
  m=$(((total % 3600) / 60))
  s=$((total % 60))
  printf '%02d:%02d:%02d' "${h}" "${m}" "${s}"
}

sanitize_inline() {
  printf '%s' "$1" | tr '\n\r' '  ' | tr ',' ';'
}

fee_tier_for_idx() {
  local idx="$1"
  if [[ "${idx}" =~ ^[0-9]+$ ]] && (( idx >= 0 && idx < ${#HOOK_FEE_TIER_VALUES[@]} )); then
    echo "${HOOK_FEE_TIER_VALUES[$idx]}"
  else
    echo "-"
  fi
}

fee_bips_to_percent() {
  local bips="$1"
  if ! [[ "${bips}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  awk -v v="${bips}" 'BEGIN { x = v / 10000.0; s = sprintf("%.4f", x); sub(/0+$/, "", s); sub(/\.$/, "", s); printf "%s%%", s }'
}

bps_to_percent() {
  local bps="$1"
  if ! [[ "${bps}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  awk -v v="${bps}" 'BEGIN { x = v / 100.0; s = sprintf("%.2f", x); sub(/0+$/, "", s); sub(/\.$/, "", s); printf "%s%%", s }'
}

ema_periods_human() {
  local period_s="$1"
  local ema_n="$2"
  local total_s
  if ! [[ "${period_s}" =~ ^[0-9]+$ && "${ema_n}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  total_s=$((period_s * ema_n))
  if (( total_s % 3600 == 0 )); then
    echo "$((total_s / 3600))h"
  elif (( total_s >= 3600 )); then
    awk -v s="${total_s}" 'BEGIN { printf "%.1fh", s/3600.0 }'
  else
    echo "$((total_s / 60))m"
  fi
}

format_number_compact() {
  local value="$1"
  if ! [[ "${value}" =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
    echo "-"
    return
  fi
  awk -v x="${value}" 'BEGIN {
    if (x == 0) { print "0"; exit }
    ax = (x < 0 ? -x : x)
    if (ax < 0.000001 || ax >= 1000000000) {
      printf "%.6E", x
    } else {
      s = sprintf("%.6f", x)
      sub(/0+$/, "", s)
      sub(/\.$/, "", s)
      print s
    }
  }'
}

pool_price_usd_display() {
  local ratio="$1"
  local raw value token_label
  if ! [[ "${ratio}" =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
    echo "n/a"
    return
  fi
  if [[ "${STABLE_SIDE}" == "token0" ]]; then
    raw="$(awk -v r="${ratio}" 'BEGIN { if (r == 0) { print "nan"; exit }; printf "%.18g", (1 / r) }')"
    token_label="${TOKEN1_SYMBOL}"
  elif [[ "${STABLE_SIDE}" == "token1" ]]; then
    raw="${ratio}"
    token_label="${TOKEN0_SYMBOL}"
  else
    echo "${TOKEN1_SYMBOL}/${TOKEN0_SYMBOL}=${ratio}"
    return
  fi
  if [[ "${raw}" == "nan" || "${raw}" == "inf" || "${raw}" == "-inf" ]]; then
    echo "n/a"
    return
  fi
  value="$(awk -v x="${raw}" 'BEGIN { printf "%.2f", x }')"
  echo "${token_label}=${value}"
}

add_int_str() {
  local a="$1"
  local b="$2"
  python3 - "${a}" "${b}" <<'PY'
import sys
try:
    a = int(sys.argv[1])
    b = int(sys.argv[2])
except Exception:
    print("0")
    raise SystemExit
print(a + b)
PY
}

usd6_to_dollar() {
  local usd6="$1"
  if ! [[ "${usd6}" =~ ^[0-9]+$ ]]; then
    echo "n/a"
    return
  fi
  python3 - "${usd6}" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys
v = Decimal(sys.argv[1]) / Decimal(1_000_000)
q = v.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
print(f"${format(q, ',.2f')}")
PY
}

usd6_ratio_percent() {
  local num="$1"
  local den="$2"
  if ! [[ "${num}" =~ ^[0-9]+$ && "${den}" =~ ^[0-9]+$ ]] || (( den == 0 )); then
    echo "-"
    return
  fi
  python3 - "${num}" "${den}" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys
num = Decimal(sys.argv[1])
den = Decimal(sys.argv[2])
pct = (num * Decimal(100)) / den
q = pct.quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP)
print(f"{q}%")
PY
}

estimate_swap_economics() {
  local side="$1"
  local amount_raw="$2"
  local fee_bips="$3"
  local price_ratio="$4"
  if ! [[ "${amount_raw}" =~ ^[0-9]+$ && "${fee_bips}" =~ ^[0-9]+$ ]]; then
    echo "0|0|0|0|0|0"
    return
  fi
  python3 - "${side}" "${amount_raw}" "${fee_bips}" "${price_ratio}" "${STABLE_SIDE}" "${TOKEN0_DECIMALS}" "${TOKEN1_DECIMALS}" <<'PY'
from decimal import Decimal, ROUND_HALF_UP, InvalidOperation
import sys

side = sys.argv[1]
amount = int(sys.argv[2])
fee_bips = int(sys.argv[3])
ratio_str = sys.argv[4]
stable_side = sys.argv[5]
dec0 = int(sys.argv[6])
dec1 = int(sys.argv[7])

ratio = None
try:
    ratio = Decimal(ratio_str)
except (InvalidOperation, ValueError):
    ratio = None

vol0 = amount if side == "zeroForOne" else 0
vol1 = amount if side == "oneForZero" else 0
fee0 = (vol0 * fee_bips) // 1_000_000
fee1 = (vol1 * fee_bips) // 1_000_000

def stable_to_usd6(raw: int, dec: int) -> int:
    if raw <= 0:
        return 0
    return (raw * 1_000_000) // (10 ** dec)

def token0_to_usd6(raw: int) -> int:
    if raw <= 0:
        return 0
    if stable_side == "token0":
        return stable_to_usd6(raw, dec0)
    if ratio is None or ratio <= 0:
        return 0
    usd = (Decimal(raw) / (Decimal(10) ** dec0)) * ratio
    return int((usd * Decimal(1_000_000)).to_integral_value(rounding=ROUND_HALF_UP))

def token1_to_usd6(raw: int) -> int:
    if raw <= 0:
        return 0
    if stable_side == "token1":
        return stable_to_usd6(raw, dec1)
    if ratio is None or ratio <= 0:
        return 0
    usd = (Decimal(raw) / (Decimal(10) ** dec1)) / ratio
    return int((usd * Decimal(1_000_000)).to_integral_value(rounding=ROUND_HALF_UP))

vol_usd6 = token0_to_usd6(vol0) + token1_to_usd6(vol1)
fee_usd6 = token0_to_usd6(fee0) + token1_to_usd6(fee1)
print(f"{vol_usd6}|{vol0}|{vol1}|{fee0}|{fee1}|{fee_usd6}")
PY
}

random_refresh_runtime_metrics() {
  local native_raw bal0_raw bal1_raw liq_now
  if native_raw="$(read_native_balance_wei 2>/dev/null)"; then
    RND_BAL_NATIVE_WEI="${native_raw}"
    RND_BAL_NATIVE_FMT="$(format_token_amount "${native_raw}" 18)"
  fi
  if bal0_raw="$(read_token_balance "${CURRENCY0}" 2>/dev/null)"; then
    RND_BAL_TOKEN0_RAW="${bal0_raw}"
    RND_BAL_TOKEN0_FMT="$(format_token_amount "${bal0_raw}" "${TOKEN0_DECIMALS}")"
  fi
  if bal1_raw="$(read_token_balance "${CURRENCY1}" 2>/dev/null)"; then
    RND_BAL_TOKEN1_RAW="${bal1_raw}"
    RND_BAL_TOKEN1_FMT="$(format_token_amount "${bal1_raw}" "${TOKEN1_DECIMALS}")"
  fi
  if read_pool_tick >/dev/null 2>&1; then
    :
  fi
  if liq_now="$(read_pool_liquidity 2>/dev/null)"; then
    RND_POOL_LIQUIDITY="${liq_now}"
  fi
}

RND_STOP_REQUESTED=0
RND_FINALIZED=0
RND_REASON="running"
RND_PHASE="bootstrap"
RND_START_TS=0
RND_START_ISO=""
RND_LAST_UPDATE_ISO=""
RND_STATS_FILE=""
RND_TX_LOG_FILE=""
RND_CURRENT_WAIT=0
RND_ATTEMPTS=0
RND_SUCCESS=0
RND_FAILED=0
RND_RPC_ERRORS=0
RND_ZFO_COUNT=0
RND_OZF_COUNT=0
RND_TOTAL_AMOUNT=0
RND_MIN_AMOUNT_OBS=0
RND_MAX_AMOUNT_OBS=0
RND_ECON_VOL_USD6=0
RND_ECON_VOL_TOKEN0_RAW=0
RND_ECON_VOL_TOKEN1_RAW=0
RND_ECON_FEE_TOKEN0_RAW=0
RND_ECON_FEE_TOKEN1_RAW=0
RND_ECON_FEE_USD6=0
RND_ECON_FEE_BIPS_SUM=0
RND_ECON_FEE_SAMPLES=0
RND_FEE_UP=0
RND_FEE_DOWN=0
RND_FEE_FLAT=0
RND_CURRENT_FEE="-"
RND_CURRENT_PV="-"
RND_CURRENT_EMA="-"
RND_CURRENT_IDX="-"
RND_CURRENT_DIR="-"
RND_LAST_TX_HASH="-"
RND_LAST_TX_STATUS="-"
RND_LAST_TX_SIDE="-"
RND_LAST_TX_AMOUNT="-"
RND_LAST_TX_REASON="-"
RND_LAST_ERROR="-"
RND_SLOT0_SQRT_PRICE_X96="-"
RND_SLOT0_TICK="-"
RND_SLOT0_PROTOCOL_FEE="-"
RND_SLOT0_LP_FEE="-"
RND_POOL_PRICE_T1_PER_T0="-"
RND_BAL_NATIVE_WEI="-"
RND_BAL_TOKEN0_RAW="-"
RND_BAL_TOKEN1_RAW="-"
RND_BAL_NATIVE_FMT="-"
RND_BAL_TOKEN0_FMT="-"
RND_BAL_TOKEN1_FMT="-"
RND_ARB_MODE="off"
RND_ARB_ENABLED=0
RND_ARB_ANCHOR_TICK=0
RND_ARB_CURRENT_TICK=0
RND_ARB_TICK_DEV=0
RND_ARB_FORCED=0
RND_ARB_REANCHOR=0
RND_ARB_SUSPEND_UNTIL=0
RND_ARB_FALLBACK_FORCED=0
RND_SIDE_STREAK=0
RND_LAST_SIDE_SEEN="-"
RND_LAST_WAIT_STRATEGY="short-random"
RND_REBALANCE_LAST_ATTEMPT=0
RND_REBALANCE_COUNT=0
RND_LULL_LAST_PROBE_ATTEMPT=0
RND_BLOCK_ZFO_UNTIL=0
RND_BLOCK_OZF_UNTIL=0
RND_PRICE_LIMIT_BLOCKS=0
RND_PRICE_LIMIT_STREAK=0
RND_PRICE_LIMIT_RECOVERY_FORCED=0
RND_FORCE_SIDE=""
RND_FORCE_SIDE_UNTIL=0
RND_NEXT_WAIT_OVERRIDE=0
RND_TICK_EDGE_FLIPS=0
RND_POOL_LIQUIDITY="-"
RND_NO_STATE_CHANGE_STREAK=0
RND_NO_STATE_CHANGE_TOTAL=0
RND_NO_STATE_CHANGE_WARNED=0
RND_FEE_CHANGE_EVENTS=0
RND_LAST_FEE_CHANGE_TS="-"
RND_LAST_FEE_CHANGE_ATTEMPT="-"
RND_LAST_FEE_CHANGE_HASH="-"
RND_LAST_FEE_CHANGE_SIDE="-"
RND_LAST_FEE_CHANGE_REASON="-"
RND_LAST_FEE_CHANGE_DIR="-"
RND_LAST_FEE_FROM_IDX="-"
RND_LAST_FEE_TO_IDX="-"
RND_LAST_FEE_FROM_BIPS="-"
RND_LAST_FEE_TO_BIPS="-"
RND_FEE_EVENT_MAX=8
RND_FAIL_NONCE=0
RND_FAIL_PRICE_LIMIT=0
RND_FAIL_BALANCE_REVERT=0
RND_FAIL_HOOKLIKE_REVERT=0
RND_FAIL_OTHER=0
RND_SKIP_BALANCE=0
RND_BALANCE_UNBLOCK_FORCED=0
RND_MODEL_MISMATCH_COUNT=0
RND_MODEL_MISMATCH_LAST="-"
declare -a RND_FEE_EVENT_TS=()
declare -a RND_FEE_EVENT_ATTEMPT=()
declare -a RND_FEE_EVENT_DIR=()
declare -a RND_FEE_EVENT_FROM=()
declare -a RND_FEE_EVENT_TO=()
declare -a RND_FEE_EVENT_SIDE=()
declare -a RND_FEE_EVENT_REASON=()
declare -a RND_FEE_EVENT_HASH=()

TC_INV_BOUNDS_OBS=0
TC_INV_BOUNDS_PASS=0
TC_INV_BOUNDS_FAIL=0
TC_INV_FEE_TIER_OBS=0
TC_INV_FEE_TIER_PASS=0
TC_INV_FEE_TIER_FAIL=0
TC_MODEL_CLOSE_OBS=0
TC_MODEL_CLOSE_PASS=0
TC_MODEL_CLOSE_FAIL=0
TC_LULL_RESET_OBS=0
TC_LULL_RESET_PASS=0
TC_LULL_RESET_FAIL=0
TC_REVERSAL_LOCK_OBS=0
TC_REVERSAL_LOCK_PASS=0
TC_REVERSAL_LOCK_FAIL=0
TC_DEADBAND_OBS=0
TC_DEADBAND_PASS=0
TC_DEADBAND_FAIL=0
TC_CAP_CLAMP_OBS=0
TC_CAP_CLAMP_PASS=0
TC_CAP_CLAMP_FAIL=0
TC_FLOOR_CLAMP_OBS=0
TC_FLOOR_CLAMP_PASS=0
TC_FLOOR_CLAMP_FAIL=0
TC_PAUSE_OBS=0
TC_PAUSE_PASS=0
TC_PAUSE_FAIL=0
TC_PAUSE_STATIC_OBS=0
TC_PAUSE_STATIC_PASS=0
TC_PAUSE_STATIC_FAIL=0
TC_UNPAUSE_OBS=0
TC_UNPAUSE_PASS=0
TC_UNPAUSE_FAIL=0
TC_UNPAUSE_RESUME_OBS=0
TC_UNPAUSE_RESUME_PASS=0
TC_UNPAUSE_RESUME_FAIL=0
TC_MON_ACCRUE_OBS=0
TC_MON_ACCRUE_PASS=0
TC_MON_ACCRUE_FAIL=0
TC_MON_CLAIM_OBS=0
TC_MON_CLAIM_PASS=0
TC_MON_CLAIM_FAIL=0

tc_status() {
  local pass="$1"
  local fail="$2"
  if (( fail > 0 )); then
    echo "FAIL"
  elif (( pass > 0 )); then
    echo "PASS"
  else
    echo "PENDING"
  fi
}

cases_case_allowed_for_stage() {
  local case_key="$1"
  if (( CASES_MODE != 1 )); then
    return 0
  fi
  case "${case_key}:${CASES_STAGE}" in
    cap:cap_probe) return 0 ;;
    floor:floor_probe) return 0 ;;
    reversal:reversal_opposite) return 0 ;;
    deadband:deadband_probe) return 0 ;;
    lull:lull_wait|lull:post_lull_trigger|lull:await_lull_validation) return 0 ;;
    *) return 1 ;;
  esac
}

evaluate_hook_invariants() {
  local fee="$1"
  local idx="$2"
  local expected_fee

  TC_INV_BOUNDS_OBS=$((TC_INV_BOUNDS_OBS + 1))
  if (( idx >= HOOK_FLOOR_IDX && idx <= HOOK_CAP_IDX )); then
    TC_INV_BOUNDS_PASS=$((TC_INV_BOUNDS_PASS + 1))
  else
    TC_INV_BOUNDS_FAIL=$((TC_INV_BOUNDS_FAIL + 1))
  fi

  TC_INV_FEE_TIER_OBS=$((TC_INV_FEE_TIER_OBS + 1))
  expected_fee="${HOOK_FEE_TIER_VALUES[$idx]-}"
  if [[ -n "${expected_fee}" && "${fee}" == "${expected_fee}" ]]; then
    TC_INV_FEE_TIER_PASS=$((TC_INV_FEE_TIER_PASS + 1))
  else
    TC_INV_FEE_TIER_FAIL=$((TC_INV_FEE_TIER_FAIL + 1))
  fi
}

evaluate_hook_transition_cases() {
  local before="$1"
  local after="$2"
  local b_fee b_pv b_ema b_ps b_idx b_dir
  local a_fee a_pv a_ema a_ps a_idx a_dir
  local delta_ps periods close_eff ema1 signal lower upper
  local sim_ema sim_idx sim_dir model_ok
  local i v_raw v_eff dir
  local case_rev case_deadband case_cap case_floor

  IFS='|' read -r b_fee b_pv b_ema b_ps b_idx b_dir <<<"${before}"
  IFS='|' read -r a_fee a_pv a_ema a_ps a_idx a_dir <<<"${after}"

  if ! [[ "${b_pv}" =~ ^[0-9]+$ && "${b_ema}" =~ ^[0-9]+$ && "${b_ps}" =~ ^[0-9]+$ && "${b_idx}" =~ ^[0-9]+$ && "${b_dir}" =~ ^[0-2]$ && "${a_ema}" =~ ^[0-9]+$ && "${a_ps}" =~ ^[0-9]+$ && "${a_idx}" =~ ^[0-9]+$ && "${a_dir}" =~ ^[0-2]$ ]]; then
    return
  fi

  delta_ps=$((a_ps - b_ps))
  if (( delta_ps < 0 )); then
    return
  fi

  if (( delta_ps >= HOOK_LULL_RESET_SECONDS )); then
    if cases_case_allowed_for_stage "lull"; then
      TC_LULL_RESET_OBS=$((TC_LULL_RESET_OBS + 1))
      if (( a_idx == HOOK_FLOOR_IDX && a_ema == 0 && a_dir == 0 )); then
        TC_LULL_RESET_PASS=$((TC_LULL_RESET_PASS + 1))
        cases_mark_completion_for_stage "lull"
      else
        TC_LULL_RESET_FAIL=$((TC_LULL_RESET_FAIL + 1))
      fi
    fi
    return
  fi

  if (( delta_ps < PERIOD_SECONDS )); then
    return
  fi

  periods=$((delta_ps / PERIOD_SECONDS))
  if (( periods <= 0 )); then
    return
  fi

  if (( b_pv <= HOOK_DUST_CLOSE_VOL_USD6 )); then
    close_eff=0
  else
    close_eff="${b_pv}"
  fi

  ema1="${b_ema}"
  if (( ema1 == 0 )); then
    if (( close_eff == 0 )); then
      ema1=0
    else
      ema1="${close_eff}"
    fi
  else
    ema1=$(( (ema1 * (HOOK_EMA_PERIODS - 1) + close_eff) / HOOK_EMA_PERIODS ))
  fi

  signal=0
  if (( ema1 > 0 )); then
    lower=$(( ema1 * (10000 - HOOK_DEADBAND_BPS) / 10000 ))
    upper=$(( ema1 * (10000 + HOOK_DEADBAND_BPS) / 10000 ))
    if (( close_eff > upper )); then
      signal=1
    elif (( close_eff < lower )); then
      signal=2
    fi
  fi

  case_rev=0
  case_deadband=0
  case_cap=0
  case_floor=0
  if (( periods == 1 )); then
    if (( b_dir != 0 && signal != 0 && signal != b_dir )); then
      case_rev=1
    fi
    if (( ema1 > 0 && signal == 0 )); then
      case_deadband=1
    fi
    if (( ema1 > 0 && signal == 1 && b_idx == HOOK_CAP_IDX )); then
      case_cap=1
    fi
    if (( ema1 > 0 && signal == 2 && b_idx == HOOK_FLOOR_IDX )); then
      case_floor=1
    fi
  fi

  sim_ema="${b_ema}"
  sim_idx="${b_idx}"
  sim_dir="${b_dir}"
  i=0
  while (( i < periods )); do
    if (( i == 0 )); then
      v_raw="${b_pv}"
    else
      v_raw=0
    fi
    if (( v_raw <= HOOK_DUST_CLOSE_VOL_USD6 )); then
      v_eff=0
    else
      v_eff="${v_raw}"
    fi

    if (( sim_ema == 0 )); then
      if (( v_eff == 0 )); then
        sim_ema=0
      else
        sim_ema="${v_eff}"
      fi
    else
      sim_ema=$(( (sim_ema * (HOOK_EMA_PERIODS - 1) + v_eff) / HOOK_EMA_PERIODS ))
    fi

    if (( sim_ema == 0 )); then
      if (( v_eff == 0 && sim_idx > HOOK_FLOOR_IDX )); then
        sim_idx=$((sim_idx - 1))
      fi
      sim_dir=0
    else
      lower=$(( sim_ema * (10000 - HOOK_DEADBAND_BPS) / 10000 ))
      upper=$(( sim_ema * (10000 + HOOK_DEADBAND_BPS) / 10000 ))
      dir=0
      if (( v_eff > upper )); then
        dir=1
      elif (( v_eff < lower )); then
        dir=2
      fi

      if (( dir != 0 && sim_dir != 0 && dir != sim_dir )); then
        sim_dir=0
      elif (( dir == 1 )); then
        if (( sim_idx < HOOK_CAP_IDX )); then
          sim_idx=$((sim_idx + 1))
          sim_dir=1
        else
          sim_dir=0
        fi
      elif (( dir == 2 )); then
        if (( sim_idx > HOOK_FLOOR_IDX )); then
          sim_idx=$((sim_idx - 1))
          sim_dir=2
        else
          sim_dir=0
        fi
      else
        sim_dir=0
      fi
    fi
    i=$((i + 1))
  done

  TC_MODEL_CLOSE_OBS=$((TC_MODEL_CLOSE_OBS + 1))
  model_ok=0
  if (( a_ema == sim_ema && a_idx == sim_idx && a_dir == sim_dir )); then
    model_ok=1
    TC_MODEL_CLOSE_PASS=$((TC_MODEL_CLOSE_PASS + 1))
  else
    TC_MODEL_CLOSE_FAIL=$((TC_MODEL_CLOSE_FAIL + 1))
    RND_MODEL_MISMATCH_COUNT=$((RND_MODEL_MISMATCH_COUNT + 1))
    RND_MODEL_MISMATCH_LAST="psDelta=${delta_ps} periods=${periods} before(i=${b_idx},d=${b_dir},pv=${b_pv},ema=${b_ema}) sim(i=${sim_idx},d=${sim_dir},ema=${sim_ema}) chain(i=${a_idx},d=${a_dir},ema=${a_ema})"
  fi

  if (( case_rev == 1 )) && cases_case_allowed_for_stage "reversal"; then
    TC_REVERSAL_LOCK_OBS=$((TC_REVERSAL_LOCK_OBS + 1))
    if (( model_ok == 1 )); then
      TC_REVERSAL_LOCK_PASS=$((TC_REVERSAL_LOCK_PASS + 1))
      cases_mark_completion_for_stage "reversal"
    else
      TC_REVERSAL_LOCK_FAIL=$((TC_REVERSAL_LOCK_FAIL + 1))
    fi
  fi
  if (( case_deadband == 1 )) && cases_case_allowed_for_stage "deadband"; then
    TC_DEADBAND_OBS=$((TC_DEADBAND_OBS + 1))
    if (( model_ok == 1 )); then
      TC_DEADBAND_PASS=$((TC_DEADBAND_PASS + 1))
      cases_mark_completion_for_stage "deadband"
    else
      TC_DEADBAND_FAIL=$((TC_DEADBAND_FAIL + 1))
    fi
  fi
  if (( case_cap == 1 )) && cases_case_allowed_for_stage "cap"; then
    TC_CAP_CLAMP_OBS=$((TC_CAP_CLAMP_OBS + 1))
    if (( model_ok == 1 )); then
      TC_CAP_CLAMP_PASS=$((TC_CAP_CLAMP_PASS + 1))
      cases_mark_completion_for_stage "cap"
    else
      TC_CAP_CLAMP_FAIL=$((TC_CAP_CLAMP_FAIL + 1))
    fi
  fi
  if (( case_floor == 1 )) && cases_case_allowed_for_stage "floor"; then
    TC_FLOOR_CLAMP_OBS=$((TC_FLOOR_CLAMP_OBS + 1))
    if (( model_ok == 1 )); then
      TC_FLOOR_CLAMP_PASS=$((TC_FLOOR_CLAMP_PASS + 1))
      cases_mark_completion_for_stage "floor"
    else
      TC_FLOOR_CLAMP_FAIL=$((TC_FLOOR_CLAMP_FAIL + 1))
    fi
  fi
}

print_hook_case_row() {
  local case_id="$1"
  local label="$2"
  local obs="$3"
  local pass="$4"
  local fail="$5"
  local status_override="${6:-}"
  local status_text
  if [[ -n "${status_override}" ]]; then
    status_text="${status_override}"
  else
    status_text="$(tc_status "${pass}" "${fail}")"
  fi
  printf "  %-6s %-34s | %-7s | %5s | %5s | %5s\n" \
    "${case_id}" "${label}" "${status_text}" "${obs}" "${pass}" "${fail}"
}

render_hook_cases_table() {
  echo "Hook test-cases (live mapping):"
  echo "  ------------------------------------------+---------+-------+-------+-------"
  printf "  %-6s %-34s | %-7s | %5s | %5s | %5s\n" "ID" "Case" "Status" "Obs" "Pass" "Fail"
  echo "  ------------------------------------------+---------+-------+-------+-------"
  print_hook_case_row "ED-1" "cap clamp" "${TC_CAP_CLAMP_OBS}" "${TC_CAP_CLAMP_PASS}" "${TC_CAP_CLAMP_FAIL}"
  print_hook_case_row "FZ-1" "reversal lock" "${TC_REVERSAL_LOCK_OBS}" "${TC_REVERSAL_LOCK_PASS}" "${TC_REVERSAL_LOCK_FAIL}"
  print_hook_case_row "ED-2" "floor clamp" "${TC_FLOOR_CLAMP_OBS}" "${TC_FLOOR_CLAMP_PASS}" "${TC_FLOOR_CLAMP_FAIL}"
  print_hook_case_row "FZ-2" "deadband no-change" "${TC_DEADBAND_OBS}" "${TC_DEADBAND_PASS}" "${TC_DEADBAND_FAIL}"
  print_hook_case_row "FZ-3" "lull reset semantics" "${TC_LULL_RESET_OBS}" "${TC_LULL_RESET_PASS}" "${TC_LULL_RESET_FAIL}"
  print_hook_case_row "GV-1" "pause toggles + floor lock" "${TC_PAUSE_OBS}" "${TC_PAUSE_PASS}" "${TC_PAUSE_FAIL}"
  print_hook_case_row "GV-2" "paused level freeze" "${TC_PAUSE_STATIC_OBS}" "${TC_PAUSE_STATIC_PASS}" "${TC_PAUSE_STATIC_FAIL}"
  print_hook_case_row "GV-3" "unpause restores running" "${TC_UNPAUSE_OBS}" "${TC_UNPAUSE_PASS}" "${TC_UNPAUSE_FAIL}"
  print_hook_case_row "GV-4" "post-unpause level move" "${TC_UNPAUSE_RESUME_OBS}" "${TC_UNPAUSE_RESUME_PASS}" "${TC_UNPAUSE_RESUME_FAIL}"
  print_hook_case_row "MN-1" "creator fee accrual" "${TC_MON_ACCRUE_OBS}" "${TC_MON_ACCRUE_PASS}" "${TC_MON_ACCRUE_FAIL}"
  print_hook_case_row "MN-2" "creator fee claim" "${TC_MON_CLAIM_OBS}" "${TC_MON_CLAIM_PASS}" "${TC_MON_CLAIM_FAIL}"
  print_hook_case_row "RT-1" "close transition model" "${TC_MODEL_CLOSE_OBS}" "${TC_MODEL_CLOSE_PASS}" "${TC_MODEL_CLOSE_FAIL}"
  print_hook_case_row "INV-1" "feeIdx in [floor,cap]" "${TC_INV_BOUNDS_OBS}" "${TC_INV_BOUNDS_PASS}" "${TC_INV_BOUNDS_FAIL}"
  print_hook_case_row "INV-2" "currentFee matches tier" "${TC_INV_FEE_TIER_OBS}" "${TC_INV_FEE_TIER_PASS}" "${TC_INV_FEE_TIER_FAIL}"
  echo "  ------------------------------------------+---------+-------+-------+-------"
}

random_record_fee_change_event() {
  local ts="$1"
  local attempt="$2"
  local side="$3"
  local reason="$4"
  local tx_hash="$5"
  local fee_before="$6"
  local fee_after="$7"
  local idx_before="$8"
  local idx_after="$9"
  local dir

  dir="FLAT"
  if (( idx_after > idx_before )); then
    dir="UP"
  elif (( idx_after < idx_before )); then
    dir="DOWN"
  elif (( fee_after > fee_before )); then
    dir="UP"
  elif (( fee_after < fee_before )); then
    dir="DOWN"
  fi

  RND_FEE_CHANGE_EVENTS=$((RND_FEE_CHANGE_EVENTS + 1))
  RND_LAST_FEE_CHANGE_TS="${ts}"
  RND_LAST_FEE_CHANGE_ATTEMPT="${attempt}"
  RND_LAST_FEE_CHANGE_HASH="${tx_hash}"
  RND_LAST_FEE_CHANGE_SIDE="${side}"
  RND_LAST_FEE_CHANGE_REASON="${reason}"
  RND_LAST_FEE_CHANGE_DIR="${dir}"
  RND_LAST_FEE_FROM_IDX="${idx_before}"
  RND_LAST_FEE_TO_IDX="${idx_after}"
  RND_LAST_FEE_FROM_BIPS="${fee_before}"
  RND_LAST_FEE_TO_BIPS="${fee_after}"

  RND_FEE_EVENT_TS+=("${ts}")
  RND_FEE_EVENT_ATTEMPT+=("${attempt}")
  RND_FEE_EVENT_DIR+=("${dir}")
  RND_FEE_EVENT_FROM+=("i${idx_before}/f${fee_before}")
  RND_FEE_EVENT_TO+=("i${idx_after}/f${fee_after}")
  RND_FEE_EVENT_SIDE+=("${side}")
  RND_FEE_EVENT_REASON+=("${reason}")
  RND_FEE_EVENT_HASH+=("${tx_hash}")

  while (( ${#RND_FEE_EVENT_TS[@]} > RND_FEE_EVENT_MAX )); do
    RND_FEE_EVENT_TS=("${RND_FEE_EVENT_TS[@]:1}")
    RND_FEE_EVENT_ATTEMPT=("${RND_FEE_EVENT_ATTEMPT[@]:1}")
    RND_FEE_EVENT_DIR=("${RND_FEE_EVENT_DIR[@]:1}")
    RND_FEE_EVENT_FROM=("${RND_FEE_EVENT_FROM[@]:1}")
    RND_FEE_EVENT_TO=("${RND_FEE_EVENT_TO[@]:1}")
    RND_FEE_EVENT_SIDE=("${RND_FEE_EVENT_SIDE[@]:1}")
    RND_FEE_EVENT_REASON=("${RND_FEE_EVENT_REASON[@]:1}")
    RND_FEE_EVENT_HASH=("${RND_FEE_EVENT_HASH[@]:1}")
  done
}

print_fee_change_row() {
  local ts="$1"
  local attempt="$2"
  local dir="$3"
  local from="$4"
  local to="$5"
  local side="$6"
  local reason="$7"
  printf "  %-19s | %6s | %-4s | %-12s -> %-12s | %-10s | %-24.24s\n" \
    "${ts}" "${attempt}" "${dir}" "${from}" "${to}" "${side}" "${reason}"
}

render_fee_change_table() {
  local n i last_level short_hash
  echo "Fee change events:"
  echo "  total=${RND_FEE_CHANGE_EVENTS} | up=${RND_FEE_UP} down=${RND_FEE_DOWN} flat=${RND_FEE_FLAT}"
  if (( RND_FEE_CHANGE_EVENTS == 0 )); then
    echo "  (none yet)"
    return
  fi
  last_level="i${RND_LAST_FEE_FROM_IDX}/f${RND_LAST_FEE_FROM_BIPS}->i${RND_LAST_FEE_TO_IDX}/f${RND_LAST_FEE_TO_BIPS}"
  short_hash="${RND_LAST_FEE_CHANGE_HASH}"
  if [[ "${short_hash}" == 0x* && ${#short_hash} -gt 18 ]]; then
    short_hash="${short_hash:0:10}..${short_hash: -6}"
  fi
  echo "  Last: at=${RND_LAST_FEE_CHANGE_TS} try=${RND_LAST_FEE_CHANGE_ATTEMPT} dir=${RND_LAST_FEE_CHANGE_DIR} side=${RND_LAST_FEE_CHANGE_SIDE} level=${last_level} reason=${RND_LAST_FEE_CHANGE_REASON} tx=${short_hash}"
  echo "  -------------------+--------+------+-----------------------------+------------+--------------------------"
  printf "  %-19s | %6s | %-4s | %-29s | %-10s | %-24s\n" "Time (UTC)" "Try#" "Dir" "Level change" "Side" "Reason"
  echo "  -------------------+--------+------+-----------------------------+------------+--------------------------"
  n="${#RND_FEE_EVENT_TS[@]}"
  for ((i = 0; i < n; i++)); do
    print_fee_change_row \
      "${RND_FEE_EVENT_TS[$i]}" \
      "${RND_FEE_EVENT_ATTEMPT[$i]}" \
      "${RND_FEE_EVENT_DIR[$i]}" \
      "${RND_FEE_EVENT_FROM[$i]}" \
      "${RND_FEE_EVENT_TO[$i]}" \
      "${RND_FEE_EVENT_SIDE[$i]}" \
      "${RND_FEE_EVENT_REASON[$i]}"
  done
  echo "  -------------------+--------+------+-----------------------------+------------+--------------------------"
}

cases_all_required_done() {
  if (( TC_PAUSE_PASS == 0 \
        || TC_PAUSE_STATIC_PASS == 0 \
        || TC_UNPAUSE_PASS == 0 \
        || TC_UNPAUSE_RESUME_PASS == 0 \
        || TC_MON_ACCRUE_PASS == 0 \
        || TC_MON_CLAIM_PASS == 0 )); then
    return 1
  fi
  if (( CASES_RUN_CAP_OK != 1 \
        || CASES_RUN_FLOOR_OK != 1 \
        || CASES_RUN_REV_OK != 1 \
        || CASES_RUN_DEADBAND_OK != 1 \
        || CASES_RUN_LULL_OK != 1 )); then
    return 1
  fi
  return 0
}

cases_refresh_checklist_from_counters() {
  # No-op in strict cases mode: checklist is advanced only by stage-gated hits.
  :
}

cases_set_stage() {
  local next_stage="$1"
  if [[ "${CASES_STAGE}" != "${next_stage}" ]]; then
    CASES_STAGE="${next_stage}"
    CASES_STAGE_STEP=0
  fi
}

cases_reversal_mid_idx() {
  local mid
  mid=$(((HOOK_FLOOR_IDX + HOOK_CAP_IDX) / 2))
  if (( mid <= HOOK_FLOOR_IDX )); then
    mid=$((HOOK_FLOOR_IDX + 1))
  fi
  if (( mid >= HOOK_CAP_IDX )); then
    mid=$((HOOK_CAP_IDX - 1))
  fi
  if (( mid < HOOK_FLOOR_IDX )); then
    mid="${HOOK_FLOOR_IDX}"
  fi
  if (( mid > HOOK_CAP_IDX )); then
    mid="${HOOK_CAP_IDX}"
  fi
  echo "${mid}"
}

cases_mark_completion_for_stage() {
  local case_key="$1"
  if (( CASES_MODE != 1 )); then
    return
  fi
  case "${case_key}:${CASES_STAGE}" in
    cap:cap_probe)
      CASES_RUN_CAP_OK=1
      cases_set_stage "reversal_mid"
      ;;
    floor:floor_probe)
      CASES_RUN_FLOOR_OK=1
      cases_set_stage "deadband_probe"
      ;;
    reversal:reversal_opposite)
      CASES_RUN_REV_OK=1
      cases_set_stage "down_to_floor"
      ;;
    deadband:deadband_probe)
      CASES_RUN_DEADBAND_OK=1
      cases_set_stage "lull_wait"
      ;;
    lull:lull_wait|lull:post_lull_trigger|lull:await_lull_validation)
      CASES_RUN_LULL_OK=1
      cases_set_stage "post_checks"
      ;;
  esac
}

seconds_to_next_period() {
  local ps="$1"
  local now target wait
  if ! [[ "${ps}" =~ ^[0-9]+$ ]]; then
    echo 0
    return
  fi
  if ! now="$(now_ts 2>/dev/null)"; then
    echo 0
    return
  fi
  if ! [[ "${now}" =~ ^[0-9]+$ ]]; then
    echo 0
    return
  fi
  target=$((ps + PERIOD_SECONDS + 2))
  wait=$((target - now))
  if (( wait < 0 )); then
    wait=0
  fi
  if (( wait > PERIOD_SECONDS + 3 )); then
    wait=$((PERIOD_SECONDS + 3))
  fi
  echo "${wait}"
}

cases_select_stage() {
  local idx="$1"
  local dir="$2"
  local mid_idx
  cases_refresh_checklist_from_counters
  if ! [[ "${idx}" =~ ^[0-9]+$ ]]; then
    idx="${HOOK_FLOOR_IDX}"
  fi
  if ! [[ "${dir}" =~ ^[0-2]$ ]]; then
    dir=0
  fi

  if cases_all_required_done; then
    cases_set_stage "cycle_done"
    return
  fi
  mid_idx="$(cases_reversal_mid_idx)"
  if ! [[ "${mid_idx}" =~ ^[0-9]+$ ]]; then
    mid_idx=$((HOOK_FLOOR_IDX + 1))
  fi

  case "${CASES_STAGE}" in
    up_to_cap)
      if (( idx >= HOOK_CAP_IDX )); then
        cases_set_stage "cap_probe"
      fi
      ;;
    cap_probe)
      if (( CASES_RUN_CAP_OK == 1 )); then
        if (( mid_idx > HOOK_FLOOR_IDX && mid_idx < HOOK_CAP_IDX )); then
          cases_set_stage "reversal_mid"
        else
          cases_set_stage "reversal_seed"
        fi
      fi
      ;;
    reversal_mid)
      if (( idx <= mid_idx )); then
        cases_set_stage "reversal_seed"
      fi
      ;;
    down_to_floor)
      if (( idx <= HOOK_FLOOR_IDX )); then
        cases_set_stage "floor_probe"
      fi
      ;;
    floor_probe)
      if (( CASES_RUN_FLOOR_OK == 1 )); then
        cases_set_stage "deadband_probe"
      fi
      ;;
    reversal_seed)
      if (( CASES_RUN_REV_OK == 1 )); then
        cases_set_stage "down_to_floor"
      elif (( dir == 1 || dir == 2 )); then
        cases_set_stage "reversal_opposite"
      fi
      ;;
    reversal_opposite)
      if (( CASES_RUN_REV_OK == 1 )); then
        cases_set_stage "down_to_floor"
      fi
      ;;
    deadband_probe)
      if (( CASES_RUN_DEADBAND_OK == 1 )); then
        cases_set_stage "lull_wait"
      fi
      ;;
    lull_wait|post_lull_trigger|await_lull_validation)
      if (( CASES_RUN_LULL_OK == 1 )); then
        cases_set_stage "post_checks"
      fi
      ;;
    post_checks)
      ;;
    cycle_done)
      ;;
    *)
      if (( idx >= HOOK_CAP_IDX )); then
        cases_set_stage "cap_probe"
      else
        cases_set_stage "up_to_cap"
      fi
      ;;
  esac
}

cases_reset_cycle_context() {
  local idx="$1"
  local dir="$2"
  if ! [[ "${idx}" =~ ^[0-9]+$ ]]; then
    idx="${HOOK_FLOOR_IDX}"
  fi
  if ! [[ "${dir}" =~ ^[0-2]$ ]]; then
    dir=0
  fi

  CASES_RUN_CAP_OK=0
  CASES_RUN_FLOOR_OK=0
  CASES_RUN_REV_OK=0
  CASES_RUN_DEADBAND_OK=0
  CASES_RUN_LULL_OK=0
  CASES_STAGE_STEP=0
  CASES_BASE_CAP_PASS="${TC_CAP_CLAMP_PASS}"
  CASES_BASE_FLOOR_PASS="${TC_FLOOR_CLAMP_PASS}"
  CASES_BASE_REV_PASS="${TC_REVERSAL_LOCK_PASS}"
  CASES_BASE_DEADBAND_PASS="${TC_DEADBAND_PASS}"
  CASES_BASE_LULL_PASS="${TC_LULL_RESET_PASS}"
  if (( idx >= HOOK_CAP_IDX )); then
    cases_set_stage "cap_probe"
  else
    cases_set_stage "up_to_cap"
  fi
}

cases_target_up_volume() {
  local ema="$1"
  local step="$2"
  local upper margin target
  if ! [[ "${ema}" =~ ^[0-9]+$ ]]; then
    ema=0
  fi
  if ! [[ "${step}" =~ ^[0-9]+$ ]]; then
    step=0
  fi
  upper=$(( ema * (10000 + HOOK_DEADBAND_BPS) / 10000 ))
  if (( upper < HOOK_DUST_CLOSE_VOL_USD6 )); then
    upper="${HOOK_DUST_CLOSE_VOL_USD6}"
  fi
  margin=$(( upper / 20 ))
  if (( margin < 1500000 )); then margin=1500000; fi
  if (( margin > 12000000 )); then margin=12000000; fi
  target=$(( upper + margin + step * 1000000 ))
  if (( target < 6000000 )); then target=6000000; fi
  if (( target > 260000000 )); then target=260000000; fi
  echo "${target}"
}

cases_target_down_volume() {
  local ema="$1"
  local step="$2"
  local lower margin ceiling target
  if ! [[ "${ema}" =~ ^[0-9]+$ ]]; then
    ema=0
  fi
  if ! [[ "${step}" =~ ^[0-9]+$ ]]; then
    step=0
  fi
  lower=$(( ema * (10000 - HOOK_DEADBAND_BPS) / 10000 ))
  if (( lower <= 0 )); then
    echo "1000000"
    return
  fi
  margin=$(( lower / 20 ))
  if (( margin < 1000000 )); then margin=1000000; fi
  if (( margin > 8000000 )); then margin=8000000; fi
  ceiling=$(( lower - margin ))
  if (( ceiling < 1000000 )); then ceiling=1000000; fi
  target=$(( 1000000 + step * 1000000 ))
  if (( target > ceiling )); then target="${ceiling}"; fi
  if (( target < 1000000 )); then target=1000000; fi
  echo "${target}"
}

cases_target_deadband_volume() {
  local ema="$1"
  local lower upper target
  if ! [[ "${ema}" =~ ^[0-9]+$ ]]; then
    ema=0
  fi
  if (( ema <= 0 )); then
    echo "1000000"
    return
  fi
  lower=$(( ema * (10000 - HOOK_DEADBAND_BPS) / 10000 ))
  upper=$(( ema * (10000 + HOOK_DEADBAND_BPS) / 10000 ))
  target=$(( lower + (upper - lower) / 2 ))
  if (( target < lower )); then target="${lower}"; fi
  if (( target > upper )); then target="${upper}"; fi
  echo "${target}"
}

cases_plan_next_action() {
  local state="$1"
  local fee pv ema ps idx dir
  local side reason target_vol amount wait_roll mid_idx

  IFS='|' read -r fee pv ema ps idx dir <<<"${state}"
  cases_select_stage "${idx}" "${dir}"
  mid_idx="$(cases_reversal_mid_idx)"
  if ! [[ "${mid_idx}" =~ ^[0-9]+$ ]]; then
    mid_idx=$((HOOK_FLOOR_IDX + 1))
  fi
  CASES_FORCE_WAIT_SECONDS=0
  CASES_FORCE_WAIT_REASON=""
  side="zeroForOne"
  reason="case-step"
  target_vol=1000000

  while true; do
    case "${CASES_STAGE}" in
      up_to_cap)
        if (( idx >= HOOK_CAP_IDX )); then
          cases_set_stage "cap_probe"
          continue
        fi
        side="zeroForOne"
        target_vol="$(cases_target_up_volume "${ema}" "${CASES_STAGE_STEP}")"
        reason="case-up-ramp"
        CASES_STAGE_STEP=$((CASES_STAGE_STEP + 1))
        break
        ;;
      cap_probe)
        side="zeroForOne"
        target_vol="$(cases_target_up_volume "${ema}" "$((CASES_STAGE_STEP + 2))")"
        reason="case-cap-clamp-probe"
        CASES_STAGE_STEP=$((CASES_STAGE_STEP + 1))
        break
        ;;
      reversal_mid)
        if (( idx <= mid_idx )); then
          cases_set_stage "reversal_seed"
          continue
        fi
        side="oneForZero"
        target_vol="$(cases_target_down_volume "${ema}" "$((CASES_STAGE_STEP + 2))")"
        reason="case-reversal-mid-shift"
        CASES_STAGE_STEP=$((CASES_STAGE_STEP + 1))
        break
        ;;
      down_to_floor)
        if (( idx <= HOOK_FLOOR_IDX )); then
          cases_set_stage "floor_probe"
          continue
        fi
        side="oneForZero"
        target_vol="$(cases_target_down_volume "${ema}" "${CASES_STAGE_STEP}")"
        reason="case-down-ramp"
        CASES_STAGE_STEP=$((CASES_STAGE_STEP + 1))
        break
        ;;
      floor_probe)
        side="oneForZero"
        target_vol="$(cases_target_down_volume "${ema}" "$((CASES_STAGE_STEP + 2))")"
        reason="case-floor-clamp-probe"
        CASES_STAGE_STEP=$((CASES_STAGE_STEP + 1))
        break
        ;;
      reversal_seed)
        # Strict sequence: seed UP direction first, then probe opposite (DOWN).
        if (( idx >= HOOK_CAP_IDX )); then
          side="oneForZero"
          target_vol="$(cases_target_down_volume "${ema}" "3")"
          reason="case-reversal-seed-down"
        else
          side="zeroForOne"
          target_vol="$(cases_target_up_volume "${ema}" "3")"
          reason="case-reversal-seed-up"
        fi
        if (( CASES_STAGE_STEP == 0 )); then
          wait_roll="$(seconds_to_next_period "${ps}")"
          if [[ "${wait_roll}" =~ ^[0-9]+$ ]] && (( wait_roll > 0 )); then
            CASES_FORCE_WAIT_SECONDS="${wait_roll}"
            CASES_FORCE_WAIT_REASON="case-reversal-rollover-wait"
            CASES_STAGE_STEP=1
          fi
        else
          CASES_STAGE_STEP=$((CASES_STAGE_STEP + 1))
          if (( CASES_STAGE_STEP % 6 == 0 )); then
            wait_roll="$(seconds_to_next_period "${ps}")"
            if [[ "${wait_roll}" =~ ^[0-9]+$ ]] && (( wait_roll > 0 )); then
              CASES_FORCE_WAIT_SECONDS="${wait_roll}"
              CASES_FORCE_WAIT_REASON="case-reversal-rollover-retry"
            fi
          fi
        fi
        # Wait until hook sets a directional memory before opposite probe.
        if [[ "${dir}" == "1" || "${dir}" == "2" ]]; then
          cases_set_stage "reversal_opposite"
        fi
        break
        ;;
      reversal_opposite)
        if [[ "${dir}" == "1" ]]; then
          side="oneForZero"
          target_vol="$(cases_target_down_volume "${ema}" "3")"
          reason="case-reversal-opposite-down"
          break
        fi
        if [[ "${dir}" == "2" ]]; then
          side="zeroForOne"
          target_vol="$(cases_target_up_volume "${ema}" "3")"
          reason="case-reversal-opposite-up"
          break
        fi
        side="zeroForOne"
        target_vol="$(cases_target_up_volume "${ema}" "1")"
        reason="case-reversal-wait-dir"
        CASES_STAGE_STEP=$((CASES_STAGE_STEP + 1))
        if (( CASES_STAGE_STEP % 6 == 0 )); then
          wait_roll="$(seconds_to_next_period "${ps}")"
          if [[ "${wait_roll}" =~ ^[0-9]+$ ]] && (( wait_roll > 0 )); then
            CASES_FORCE_WAIT_SECONDS="${wait_roll}"
            CASES_FORCE_WAIT_REASON="case-reversal-rollover-retry"
          fi
        fi
        break
        ;;
      deadband_probe)
        side="zeroForOne"
        target_vol="$(cases_target_deadband_volume "${ema}")"
        reason="case-deadband-probe"
        if (( CASES_STAGE_STEP == 0 )); then
          wait_roll="$(seconds_to_next_period "${ps}")"
          if [[ "${wait_roll}" =~ ^[0-9]+$ ]] && (( wait_roll > 0 )); then
            CASES_FORCE_WAIT_SECONDS="${wait_roll}"
            CASES_FORCE_WAIT_REASON="case-deadband-rollover-wait"
            CASES_STAGE_STEP=1
          fi
        else
          CASES_STAGE_STEP=$((CASES_STAGE_STEP + 1))
        fi
        break
        ;;
      lull_wait)
        side="zeroForOne"
        target_vol="$(cases_target_deadband_volume "${ema}")"
        reason="case-lull-prewait"
        break
        ;;
      post_lull_trigger)
        side="zeroForOne"
        target_vol="$(cases_target_deadband_volume "${ema}")"
        reason="case-lull-post-trigger"
        cases_set_stage "await_lull_validation"
        break
        ;;
      await_lull_validation)
        side="zeroForOne"
        target_vol="$(cases_target_deadband_volume "${ema}")"
        reason="case-lull-post-retry"
        break
        ;;
      post_checks)
        side="zeroForOne"
        target_vol="$(cases_target_deadband_volume "${ema}")"
        reason="case-post-checks"
        break
        ;;
      cycle_done)
        side="zeroForOne"
        target_vol="$(cases_target_deadband_volume "${ema}")"
        reason="case-cycle-done-hold"
        break
        ;;
      *)
        cases_select_stage "${idx}" "${dir}"
        CASES_STAGE_STEP=0
        continue
        ;;
    esac
  done

  amount="$(amount_for_period_target_vol "${target_vol}" "${pv}")"
  if ! [[ "${amount}" =~ ^[0-9]+$ ]]; then
    amount=0
  fi
  CASES_NEXT_SIDE="${side}"
  CASES_NEXT_REASON="${reason}"
  CASES_NEXT_TARGET_VOL="${target_vol}"
  CASES_NEXT_AMOUNT="${amount}"
}

pick_amount_with_case_bias() {
  local min_amount="$1"
  local max_amount="$2"
  local state="$3"
  local fee pv ema ps idx dir
  local amount reason side roll span
  local low_hi high_lo mid_target mid_lo mid_hi

  IFS='|' read -r fee pv ema ps idx dir <<<"${state}"
  amount="$(random_between "${min_amount}" "${max_amount}")"
  reason="biased-mid"
  side=""

  span=$((max_amount - min_amount))
  if (( span < 0 )); then span=0; fi
  low_hi=$((min_amount + span / 6))
  high_lo=$((max_amount - span / 6))
  if (( low_hi < min_amount )); then low_hi="${min_amount}"; fi
  if (( high_lo > max_amount )); then high_lo="${max_amount}"; fi
  if (( high_lo < min_amount )); then high_lo="${min_amount}"; fi

  if (( ema > 0 )); then
    if mid_target="$(amount_for_target_vol "${ema}" 2>/dev/null)"; then
      :
    else
      mid_target=$((min_amount + span / 2))
    fi
  else
    mid_target=$((min_amount + span / 2))
  fi
  if (( mid_target < min_amount )); then mid_target="${min_amount}"; fi
  if (( mid_target > max_amount )); then mid_target="${max_amount}"; fi
  mid_lo=$((mid_target - span / 10))
  mid_hi=$((mid_target + span / 10))
  if (( mid_lo < min_amount )); then mid_lo="${min_amount}"; fi
  if (( mid_hi > max_amount )); then mid_hi="${max_amount}"; fi
  if (( mid_hi < mid_lo )); then mid_hi="${mid_lo}"; fi

  roll="$(random_between 1 100)"
  if (( roll <= 20 )); then
    amount="$(random_between "${min_amount}" "${low_hi}")"
    reason="biased-low"
  elif (( roll <= 80 )); then
    amount="$(random_between "${high_lo}" "${max_amount}")"
    reason="biased-high"
  else
    amount="$(random_between "${mid_lo}" "${mid_hi}")"
    reason="biased-mid"
  fi

  if (( amount < min_amount )); then amount="${min_amount}"; fi
  if (( amount > max_amount )); then amount="${max_amount}"; fi
  echo "${amount}|${reason}|${side}"
}

pick_wait_with_case_bias() {
  local state="$1"
  local now elapsed ps
  local wait reason

  IFS='|' read -r _ _ _ ps _ _ <<<"${state}"
  wait=0
  reason="no-wait"
  RND_WAIT_PICK_SECONDS=0
  RND_WAIT_PICK_REASON="no-wait"

  if (( CASES_MODE == 1 )); then
    if (( CASES_FORCE_WAIT_SECONDS > 0 )); then
      RND_WAIT_PICK_SECONDS="${CASES_FORCE_WAIT_SECONDS}"
      if [[ -n "${CASES_FORCE_WAIT_REASON}" ]]; then
        RND_WAIT_PICK_REASON="${CASES_FORCE_WAIT_REASON}"
      else
        RND_WAIT_PICK_REASON="case-rollover-wait"
      fi
      CASES_FORCE_WAIT_SECONDS=0
      CASES_FORCE_WAIT_REASON=""
      return
    fi
    if [[ "${CASES_STAGE}" == "lull_wait" ]]; then
      wait=$((HOOK_LULL_RESET_SECONDS + 3))
      reason="case-lull-reset-wait"
      cases_set_stage "post_lull_trigger"
      RND_LULL_LAST_PROBE_ATTEMPT="${RND_ATTEMPTS}"
      RND_WAIT_PICK_SECONDS="${wait}"
      RND_WAIT_PICK_REASON="${reason}"
      return
    fi
    # In strict cases mode, run one controlled close per period.
    wait="$(seconds_to_next_period "${ps}")"
    if ! [[ "${wait}" =~ ^[0-9]+$ ]]; then
      wait=0
    fi
    if (( wait < 0 )); then
      wait=0
    fi
    RND_WAIT_PICK_SECONDS="${wait}"
    RND_WAIT_PICK_REASON="case-period-sync"
    return
  fi

  if now="$(now_ts 2>/dev/null)" && [[ "${now}" =~ ^[0-9]+$ && "${ps}" =~ ^[0-9]+$ ]]; then
    elapsed=$((now - ps))
    if (( elapsed < 0 )); then elapsed=0; fi

    if (( TC_LULL_RESET_PASS == 0 \
          && RND_ATTEMPTS >= 160 \
          && TC_MODEL_CLOSE_PASS > 0 \
          && TC_REVERSAL_LOCK_PASS > 0 \
          && TC_DEADBAND_PASS > 0 \
          && TC_CAP_CLAMP_PASS > 0 \
          && TC_FLOOR_CLAMP_PASS > 0 \
          && (RND_LULL_LAST_PROBE_ATTEMPT == 0 || (RND_ATTEMPTS - RND_LULL_LAST_PROBE_ATTEMPT) >= 320) )); then
      wait=$((HOOK_LULL_RESET_SECONDS + 3))
      reason="case-lull-reset-probe"
      RND_LULL_LAST_PROBE_ATTEMPT="${RND_ATTEMPTS}"
      RND_WAIT_PICK_SECONDS="${wait}"
      RND_WAIT_PICK_REASON="${reason}"
      return
    fi
  fi

  if (( wait < MIN_WAIT_SECONDS )); then wait="${MIN_WAIT_SECONDS}"; fi
  if (( wait > PERIOD_SECONDS + 20 )) && [[ "${reason}" != "case-lull-reset-probe" ]]; then
    wait=$((PERIOD_SECONDS + 20))
  fi
  RND_WAIT_PICK_SECONDS="${wait}"
  RND_WAIT_PICK_REASON="${reason}"
}

random_write_stats_snapshot() {
  local now elapsed avg_amount success_pct
  local current_tier floor_tier cap_tier
  local mode_label
  local i recent_count
  now="$(date +%s)"
  elapsed=$((now - RND_START_TS))
  avg_amount=0
  success_pct=0
  if (( RND_ATTEMPTS > 0 )); then
    avg_amount=$((RND_TOTAL_AMOUNT / RND_ATTEMPTS))
    success_pct=$((100 * RND_SUCCESS / RND_ATTEMPTS))
  fi
  current_tier="$(fee_tier_for_idx "${RND_CURRENT_IDX}")"
  floor_tier="$(fee_tier_for_idx "${HOOK_FLOOR_IDX}")"
  cap_tier="$(fee_tier_for_idx "${HOOK_CAP_IDX}")"
  mode_label="random"
  if (( CASES_MODE == 1 )); then
    mode_label="cases"
  fi
  recent_count="${#RND_FEE_EVENT_TS[@]}"
  RND_LAST_UPDATE_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  {
    echo "version=1"
    echo "mode=${mode_label}"
    echo "chain=${CHAIN}"
    echo "rpc_url=${RPC_URL}"
    echo "hook_address=${HOOK_ADDRESS}"
    echo "pool_id=${POOL_ID}"
    echo "swap_test_address=${SWAP_TEST_ADDRESS}"
    echo "deployer=${DEPLOYER}"
    echo "token0_address=${CURRENCY0}"
    echo "token0_symbol=${TOKEN0_SYMBOL}"
    echo "token0_decimals=${TOKEN0_DECIMALS}"
    echo "token1_address=${CURRENCY1}"
    echo "token1_symbol=${TOKEN1_SYMBOL}"
    echo "token1_decimals=${TOKEN1_DECIMALS}"
    echo "stable_side=${STABLE_SIDE}"
    echo "started_at=${RND_START_ISO}"
    echo "updated_at=${RND_LAST_UPDATE_ISO}"
    echo "elapsed_seconds=${elapsed}"
    echo "status=${RND_REASON}"
    echo "phase=${RND_PHASE}"
    echo "wait_strategy=${RND_LAST_WAIT_STRATEGY}"
    echo "cases_mode=${CASES_MODE}"
    echo "cases_runs_target=${CASES_RUNS}"
    echo "cases_runs_completed=${CASES_COMPLETED_RUNS}"
    echo "cases_stage=${CASES_STAGE}"
    echo "cases_stage_step=${CASES_STAGE_STEP}"
    echo "cases_run_cap_ok=${CASES_RUN_CAP_OK}"
    echo "cases_run_floor_ok=${CASES_RUN_FLOOR_OK}"
    echo "cases_run_reversal_ok=${CASES_RUN_REV_OK}"
    echo "cases_run_deadband_ok=${CASES_RUN_DEADBAND_OK}"
    echo "cases_run_lull_ok=${CASES_RUN_LULL_OK}"
    echo "lull_last_probe_attempt=${RND_LULL_LAST_PROBE_ATTEMPT}"
    echo "attempts=${RND_ATTEMPTS}"
    echo "success=${RND_SUCCESS}"
    echo "failed=${RND_FAILED}"
    echo "success_pct=${success_pct}"
    echo "rpc_errors=${RND_RPC_ERRORS}"
    echo "zero_for_one_count=${RND_ZFO_COUNT}"
    echo "one_for_zero_count=${RND_OZF_COUNT}"
    echo "arb_mode=${RND_ARB_MODE}"
    echo "arb_enabled=${RND_ARB_ENABLED}"
    echo "arb_anchor_tick=${RND_ARB_ANCHOR_TICK}"
    echo "arb_current_tick=${RND_ARB_CURRENT_TICK}"
    echo "arb_tick_deviation=${RND_ARB_TICK_DEV}"
    echo "arb_forced_count=${RND_ARB_FORCED}"
    echo "arb_reanchor_count=${RND_ARB_REANCHOR}"
    echo "arb_suspend_until_attempt=${RND_ARB_SUSPEND_UNTIL}"
    echo "arb_fallback_forced_count=${RND_ARB_FALLBACK_FORCED}"
    echo "price_limit_blocks=${RND_PRICE_LIMIT_BLOCKS}"
    echo "price_limit_streak=${RND_PRICE_LIMIT_STREAK}"
    echo "price_limit_recovery_forced_count=${RND_PRICE_LIMIT_RECOVERY_FORCED}"
    echo "tick_edge_flips=${RND_TICK_EDGE_FLIPS}"
    echo "pool_liquidity=${RND_POOL_LIQUIDITY}"
    echo "pool_tick=${RND_SLOT0_TICK}"
    echo "pool_slot0_lp_fee_bips=${RND_SLOT0_LP_FEE}"
    echo "pool_slot0_protocol_fee=${RND_SLOT0_PROTOCOL_FEE}"
    echo "pool_mid_price_t1_per_t0=${RND_POOL_PRICE_T1_PER_T0}"
    echo "no_state_change_streak=${RND_NO_STATE_CHANGE_STREAK}"
    echo "no_state_change_total=${RND_NO_STATE_CHANGE_TOTAL}"
    echo "force_side=${RND_FORCE_SIDE}"
    echo "force_side_until_attempt=${RND_FORCE_SIDE_UNTIL}"
    echo "side_block_zfo_until_attempt=${RND_BLOCK_ZFO_UNTIL}"
    echo "side_block_ozf_until_attempt=${RND_BLOCK_OZF_UNTIL}"
    echo "side_streak=${RND_SIDE_STREAK}"
    echo "fail_nonce=${RND_FAIL_NONCE}"
    echo "fail_price_limit=${RND_FAIL_PRICE_LIMIT}"
    echo "fail_balance_revert=${RND_FAIL_BALANCE_REVERT}"
    echo "fail_hooklike_revert=${RND_FAIL_HOOKLIKE_REVERT}"
    echo "fail_other=${RND_FAIL_OTHER}"
    echo "skip_balance=${RND_SKIP_BALANCE}"
    echo "balance_unblock_forced=${RND_BALANCE_UNBLOCK_FORCED}"
    echo "wallet_rebalance_count=${RND_REBALANCE_COUNT}"
    echo "wallet_rebalance_last_attempt=${RND_REBALANCE_LAST_ATTEMPT}"
    echo "model_mismatch_count=${RND_MODEL_MISMATCH_COUNT}"
    echo "model_mismatch_last=$(sanitize_inline "${RND_MODEL_MISMATCH_LAST}")"
    echo "tc_inv_fee_idx_bounds_status=$(tc_status "${TC_INV_BOUNDS_PASS}" "${TC_INV_BOUNDS_FAIL}")"
    echo "tc_inv_fee_idx_bounds_obs=${TC_INV_BOUNDS_OBS}"
    echo "tc_inv_fee_idx_bounds_pass=${TC_INV_BOUNDS_PASS}"
    echo "tc_inv_fee_idx_bounds_fail=${TC_INV_BOUNDS_FAIL}"
    echo "tc_inv_current_fee_matches_tier_status=$(tc_status "${TC_INV_FEE_TIER_PASS}" "${TC_INV_FEE_TIER_FAIL}")"
    echo "tc_inv_current_fee_matches_tier_obs=${TC_INV_FEE_TIER_OBS}"
    echo "tc_inv_current_fee_matches_tier_pass=${TC_INV_FEE_TIER_PASS}"
    echo "tc_inv_current_fee_matches_tier_fail=${TC_INV_FEE_TIER_FAIL}"
    echo "tc_runtime_close_model_status=$(tc_status "${TC_MODEL_CLOSE_PASS}" "${TC_MODEL_CLOSE_FAIL}")"
    echo "tc_runtime_close_model_obs=${TC_MODEL_CLOSE_OBS}"
    echo "tc_runtime_close_model_pass=${TC_MODEL_CLOSE_PASS}"
    echo "tc_runtime_close_model_fail=${TC_MODEL_CLOSE_FAIL}"
    echo "tc_fuzz_reversal_lock_status=$(tc_status "${TC_REVERSAL_LOCK_PASS}" "${TC_REVERSAL_LOCK_FAIL}")"
    echo "tc_fuzz_reversal_lock_obs=${TC_REVERSAL_LOCK_OBS}"
    echo "tc_fuzz_reversal_lock_pass=${TC_REVERSAL_LOCK_PASS}"
    echo "tc_fuzz_reversal_lock_fail=${TC_REVERSAL_LOCK_FAIL}"
    echo "tc_fuzz_deadband_status=$(tc_status "${TC_DEADBAND_PASS}" "${TC_DEADBAND_FAIL}")"
    echo "tc_fuzz_deadband_obs=${TC_DEADBAND_OBS}"
    echo "tc_fuzz_deadband_pass=${TC_DEADBAND_PASS}"
    echo "tc_fuzz_deadband_fail=${TC_DEADBAND_FAIL}"
    echo "tc_fuzz_lull_reset_status=$(tc_status "${TC_LULL_RESET_PASS}" "${TC_LULL_RESET_FAIL}")"
    echo "tc_fuzz_lull_reset_obs=${TC_LULL_RESET_OBS}"
    echo "tc_fuzz_lull_reset_pass=${TC_LULL_RESET_PASS}"
    echo "tc_fuzz_lull_reset_fail=${TC_LULL_RESET_FAIL}"
    echo "tc_edges_cap_clamp_status=$(tc_status "${TC_CAP_CLAMP_PASS}" "${TC_CAP_CLAMP_FAIL}")"
    echo "tc_edges_cap_clamp_obs=${TC_CAP_CLAMP_OBS}"
    echo "tc_edges_cap_clamp_pass=${TC_CAP_CLAMP_PASS}"
    echo "tc_edges_cap_clamp_fail=${TC_CAP_CLAMP_FAIL}"
    echo "tc_edges_floor_clamp_status=$(tc_status "${TC_FLOOR_CLAMP_PASS}" "${TC_FLOOR_CLAMP_FAIL}")"
    echo "tc_edges_floor_clamp_obs=${TC_FLOOR_CLAMP_OBS}"
    echo "tc_edges_floor_clamp_pass=${TC_FLOOR_CLAMP_PASS}"
    echo "tc_edges_floor_clamp_fail=${TC_FLOOR_CLAMP_FAIL}"
    echo "tc_governance_pause_status=$(tc_status "${TC_PAUSE_PASS}" "${TC_PAUSE_FAIL}")"
    echo "tc_governance_pause_obs=${TC_PAUSE_OBS}"
    echo "tc_governance_pause_pass=${TC_PAUSE_PASS}"
    echo "tc_governance_pause_fail=${TC_PAUSE_FAIL}"
    echo "tc_governance_pause_freeze_status=$(tc_status "${TC_PAUSE_STATIC_PASS}" "${TC_PAUSE_STATIC_FAIL}")"
    echo "tc_governance_pause_freeze_obs=${TC_PAUSE_STATIC_OBS}"
    echo "tc_governance_pause_freeze_pass=${TC_PAUSE_STATIC_PASS}"
    echo "tc_governance_pause_freeze_fail=${TC_PAUSE_STATIC_FAIL}"
    echo "tc_governance_unpause_status=$(tc_status "${TC_UNPAUSE_PASS}" "${TC_UNPAUSE_FAIL}")"
    echo "tc_governance_unpause_obs=${TC_UNPAUSE_OBS}"
    echo "tc_governance_unpause_pass=${TC_UNPAUSE_PASS}"
    echo "tc_governance_unpause_fail=${TC_UNPAUSE_FAIL}"
    echo "tc_governance_unpause_resume_status=$(tc_status "${TC_UNPAUSE_RESUME_PASS}" "${TC_UNPAUSE_RESUME_FAIL}")"
    echo "tc_governance_unpause_resume_obs=${TC_UNPAUSE_RESUME_OBS}"
    echo "tc_governance_unpause_resume_pass=${TC_UNPAUSE_RESUME_PASS}"
    echo "tc_governance_unpause_resume_fail=${TC_UNPAUSE_RESUME_FAIL}"
    echo "tc_monetization_accrue_status=$(tc_status "${TC_MON_ACCRUE_PASS}" "${TC_MON_ACCRUE_FAIL}")"
    echo "tc_monetization_accrue_obs=${TC_MON_ACCRUE_OBS}"
    echo "tc_monetization_accrue_pass=${TC_MON_ACCRUE_PASS}"
    echo "tc_monetization_accrue_fail=${TC_MON_ACCRUE_FAIL}"
    echo "tc_monetization_claim_status=$(tc_status "${TC_MON_CLAIM_PASS}" "${TC_MON_CLAIM_FAIL}")"
    echo "tc_monetization_claim_obs=${TC_MON_CLAIM_OBS}"
    echo "tc_monetization_claim_pass=${TC_MON_CLAIM_PASS}"
    echo "tc_monetization_claim_fail=${TC_MON_CLAIM_FAIL}"
    echo "total_amount=${RND_TOTAL_AMOUNT}"
    echo "avg_amount=${avg_amount}"
    echo "min_amount=${RND_MIN_AMOUNT_OBS}"
    echo "max_amount=${RND_MAX_AMOUNT_OBS}"
    echo "econ_volume_usd6=${RND_ECON_VOL_USD6}"
    echo "econ_volume_token0_raw=${RND_ECON_VOL_TOKEN0_RAW}"
    echo "econ_volume_token1_raw=${RND_ECON_VOL_TOKEN1_RAW}"
    echo "econ_fees_token0_raw=${RND_ECON_FEE_TOKEN0_RAW}"
    echo "econ_fees_token1_raw=${RND_ECON_FEE_TOKEN1_RAW}"
    echo "econ_fees_usd6=${RND_ECON_FEE_USD6}"
    echo "econ_fee_bips_sum=${RND_ECON_FEE_BIPS_SUM}"
    echo "econ_fee_samples=${RND_ECON_FEE_SAMPLES}"
    echo "one_for_zero_amount_scale=${ONE_FOR_ZERO_SCALE}"
    echo "fee_moves_up=${RND_FEE_UP}"
    echo "fee_moves_down=${RND_FEE_DOWN}"
    echo "fee_moves_flat=${RND_FEE_FLAT}"
    echo "fee_change_events_total=${RND_FEE_CHANGE_EVENTS}"
    echo "last_fee_change_at=${RND_LAST_FEE_CHANGE_TS}"
    echo "last_fee_change_attempt=${RND_LAST_FEE_CHANGE_ATTEMPT}"
    echo "last_fee_change_direction=${RND_LAST_FEE_CHANGE_DIR}"
    echo "last_fee_change_side=${RND_LAST_FEE_CHANGE_SIDE}"
    echo "last_fee_change_reason=$(sanitize_inline "${RND_LAST_FEE_CHANGE_REASON}")"
    echo "last_fee_change_hash=${RND_LAST_FEE_CHANGE_HASH}"
    echo "last_fee_change_from_idx=${RND_LAST_FEE_FROM_IDX}"
    echo "last_fee_change_to_idx=${RND_LAST_FEE_TO_IDX}"
    echo "last_fee_change_from_fee_bips=${RND_LAST_FEE_FROM_BIPS}"
    echo "last_fee_change_to_fee_bips=${RND_LAST_FEE_TO_BIPS}"
    echo "recent_fee_change_events_count=${recent_count}"
    i=0
    while (( i < recent_count )); do
      echo "recent_fee_change_${i}_at=${RND_FEE_EVENT_TS[$i]}"
      echo "recent_fee_change_${i}_attempt=${RND_FEE_EVENT_ATTEMPT[$i]}"
      echo "recent_fee_change_${i}_direction=${RND_FEE_EVENT_DIR[$i]}"
      echo "recent_fee_change_${i}_from=${RND_FEE_EVENT_FROM[$i]}"
      echo "recent_fee_change_${i}_to=${RND_FEE_EVENT_TO[$i]}"
      echo "recent_fee_change_${i}_side=${RND_FEE_EVENT_SIDE[$i]}"
      echo "recent_fee_change_${i}_reason=$(sanitize_inline "${RND_FEE_EVENT_REASON[$i]}")"
      echo "recent_fee_change_${i}_hash=${RND_FEE_EVENT_HASH[$i]}"
      i=$((i + 1))
    done
    echo "current_fee_bips=${RND_CURRENT_FEE}"
    echo "current_fee_tier_bips=${current_tier}"
    echo "current_period_vol_usd6=${RND_CURRENT_PV}"
    echo "current_ema_usd6=${RND_CURRENT_EMA}"
    echo "current_fee_idx=${RND_CURRENT_IDX}"
    echo "current_last_dir=${RND_CURRENT_DIR}"
    echo "fee_level_floor_idx=${HOOK_FLOOR_IDX}"
    echo "fee_level_floor_tier_bips=${floor_tier}"
    echo "fee_level_cap_idx=${HOOK_CAP_IDX}"
    echo "fee_level_cap_tier_bips=${cap_tier}"
    echo "wallet_native_symbol=${NATIVE_GAS_SYMBOL}"
    echo "wallet_native_balance_wei=${RND_BAL_NATIVE_WEI}"
    echo "wallet_token0_balance_raw=${RND_BAL_TOKEN0_RAW}"
    echo "wallet_token1_balance_raw=${RND_BAL_TOKEN1_RAW}"
    echo "last_tx_hash=${RND_LAST_TX_HASH}"
    echo "last_tx_status=${RND_LAST_TX_STATUS}"
    echo "last_tx_side=${RND_LAST_TX_SIDE}"
    echo "last_tx_amount=${RND_LAST_TX_AMOUNT}"
    echo "last_tx_reason=${RND_LAST_TX_REASON}"
    echo "last_error=${RND_LAST_ERROR}"
    echo "stats_file=${RND_STATS_FILE}"
    echo "tx_log_file=${RND_TX_LOG_FILE}"
  } > "${RND_STATS_FILE}"
}

random_render_dashboard() {
  local now elapsed success_pct
  local current_tier floor_tier cap_tier
  local current_pct floor_pct cap_pct
  local mode_label pool_id_display live_lp_fee price_usd_display deadband_pct ema_human
  local econ_vol_usd econ_fee_usd econ_fee0_fmt econ_fee1_fmt
  local econ_avg_fee_bips econ_avg_fee_pct
  local econ_avg_fee_bips_fmt tick_fmt liq_fmt
  local attempts_fmt success_fmt failed_fmt rpc_errors_fmt skip_balance_fmt
  local zfo_fmt ozf_fmt
  local hook_period_vol_usd hook_ema_usd hook_last_dir
  local last_tx_amount_display
  now="$(date +%s)"
  elapsed=$((now - RND_START_TS))
  success_pct=0
  if (( RND_ATTEMPTS > 0 )); then
    success_pct=$((100 * RND_SUCCESS / RND_ATTEMPTS))
  fi
  current_tier="$(fee_tier_for_idx "${RND_CURRENT_IDX}")"
  floor_tier="$(fee_tier_for_idx "${HOOK_FLOOR_IDX}")"
  cap_tier="$(fee_tier_for_idx "${HOOK_CAP_IDX}")"
  current_pct="$(fee_bips_to_percent "${current_tier}")"
  floor_pct="$(fee_bips_to_percent "${floor_tier}")"
  cap_pct="$(fee_bips_to_percent "${cap_tier}")"
  pool_id_display="${POOL_ID:-n/a}"
  live_lp_fee="${RND_SLOT0_LP_FEE}"
  if ! [[ "${live_lp_fee}" =~ ^[0-9]+$ ]]; then
    live_lp_fee="${RND_CURRENT_FEE}"
  fi
  price_usd_display="$(pool_price_usd_display "${RND_POOL_PRICE_T1_PER_T0}")"
  deadband_pct="$(bps_to_percent "${HOOK_DEADBAND_BPS}")"
  ema_human="$(ema_periods_human "${PERIOD_SECONDS}" "${HOOK_EMA_PERIODS}")"
  econ_vol_usd="$(usd6_to_dollar "${RND_ECON_VOL_USD6}")"
  econ_fee_usd="$(usd6_to_dollar "${RND_ECON_FEE_USD6}")"
  econ_fee0_fmt="$(format_token_amount "${RND_ECON_FEE_TOKEN0_RAW}" "${TOKEN0_DECIMALS}")"
  econ_fee1_fmt="$(format_token_amount "${RND_ECON_FEE_TOKEN1_RAW}" "${TOKEN1_DECIMALS}")"
  econ_avg_fee_bips=0
  econ_avg_fee_pct="-"
  if (( RND_ECON_FEE_SAMPLES > 0 )); then
    econ_avg_fee_bips=$((RND_ECON_FEE_BIPS_SUM / RND_ECON_FEE_SAMPLES))
    econ_avg_fee_pct="$(fee_bips_to_percent "${econ_avg_fee_bips}")"
  fi
  econ_avg_fee_bips_fmt="$(format_int_commas "${econ_avg_fee_bips}")"
  tick_fmt="$(format_int_commas "${RND_SLOT0_TICK}")"
  liq_fmt="$(format_int_commas "${RND_POOL_LIQUIDITY}")"
  attempts_fmt="$(format_int_commas "${RND_ATTEMPTS}")"
  success_fmt="$(format_int_commas "${RND_SUCCESS}")"
  failed_fmt="$(format_int_commas "${RND_FAILED}")"
  rpc_errors_fmt="$(format_int_commas "${RND_RPC_ERRORS}")"
  skip_balance_fmt="$(format_int_commas "${RND_SKIP_BALANCE}")"
  zfo_fmt="$(format_int_commas "${RND_ZFO_COUNT}")"
  ozf_fmt="$(format_int_commas "${RND_OZF_COUNT}")"
  hook_period_vol_usd="$(usd6_to_dollar "${RND_CURRENT_PV}")"
  hook_ema_usd="$(usd6_to_dollar "${RND_CURRENT_EMA}")"
  hook_last_dir="$(dir_to_label "${RND_CURRENT_DIR}")"
  last_tx_amount_display="${RND_LAST_TX_AMOUNT}"
  if [[ "${RND_LAST_TX_AMOUNT}" =~ ^-?[0-9]+$ ]]; then
    last_tx_amount_display="$(format_int_commas "${RND_LAST_TX_AMOUNT}")"
  fi
  mode_label="random"
  if (( CASES_MODE == 1 )); then
    mode_label="cases"
  fi
  if [[ -t 1 && "${NO_LIVE}" -eq 0 ]]; then
    printf '\033[2J\033[H'
  fi
  echo "===== Dynamic Fee Traffic Simulator ====="
  echo "Mode: ${mode_label} | Chain: ${CHAIN} | Status: ${RND_REASON} | Runtime: $(fmt_duration "${elapsed}")"
  if (( CASES_MODE == 1 )); then
    echo "Cases progress: run ${CASES_COMPLETED_RUNS}/${CASES_RUNS} | stage=${CASES_STAGE}"
    echo "Cases checklist: cap=${CASES_RUN_CAP_OK} reversal=${CASES_RUN_REV_OK} floor=${CASES_RUN_FLOOR_OK} deadband=${CASES_RUN_DEADBAND_OK} lull=${CASES_RUN_LULL_OK}"
    echo "Cases controls: pause=$(tc_status "${TC_PAUSE_PASS}" "${TC_PAUSE_FAIL}") pauseFreeze=$(tc_status "${TC_PAUSE_STATIC_PASS}" "${TC_PAUSE_STATIC_FAIL}") unpause=$(tc_status "${TC_UNPAUSE_PASS}" "${TC_UNPAUSE_FAIL}") resume=$(tc_status "${TC_UNPAUSE_RESUME_PASS}" "${TC_UNPAUSE_RESUME_FAIL}") monAccrue=$(tc_status "${TC_MON_ACCRUE_PASS}" "${TC_MON_ACCRUE_FAIL}") monClaim=$(tc_status "${TC_MON_CLAIM_PASS}" "${TC_MON_CLAIM_FAIL}")"
  fi
  echo
  echo "Hook:"
  echo "  Address: ${HOOK_ADDRESS}"
  echo "  Deploy: floor=${floor_pct} (${floor_tier}, i${HOOK_FLOOR_IDX}) | cap=${cap_pct} (${cap_tier}, i${HOOK_CAP_IDX})"
  echo "  Algo: period=${PERIOD_SECONDS}s | emaPeriods=${HOOK_EMA_PERIODS} (~${ema_human}) | deadband=${HOOK_DEADBAND_BPS}bps (${deadband_pct}) | lullReset=${HOOK_LULL_RESET_SECONDS}s | tickSpacing=${TICK_SPACING} | stableSide=${STABLE_SIDE}"
  echo "  Live: periodVol=${hook_period_vol_usd} | ema=${hook_ema_usd} | lastDir=${hook_last_dir}"
  echo
  echo "Pool:"
  echo "  Id: ${pool_id_display}"
  echo "  Tick: ${tick_fmt} | Active Liquidity: ${liq_fmt} | Price USD: ${price_usd_display}"
  echo "  Fee Level: ${current_pct} (${current_tier}, i${RND_CURRENT_IDX}) | Avg Fee Level: ${econ_avg_fee_pct} (${econ_avg_fee_bips_fmt})"
  echo "  Volume: ${econ_vol_usd} | Fees: ${econ_fee_usd} (${TOKEN0_SYMBOL}=${econ_fee0_fmt} + ${TOKEN1_SYMBOL}=${econ_fee1_fmt})"
  echo
  echo "Wallet:"
  echo "  Address: ${DEPLOYER}"
  echo "  Balances: ${NATIVE_GAS_SYMBOL}=${RND_BAL_NATIVE_FMT} | ${TOKEN0_SYMBOL}=${RND_BAL_TOKEN0_FMT} | ${TOKEN1_SYMBOL}=${RND_BAL_TOKEN1_FMT}"
  echo
  echo "Execution: tx=${attempts_fmt} | ok=${success_fmt} fail=${failed_fmt} | rpcErr=${rpc_errors_fmt} | skipped(noBalance)=${skip_balance_fmt} | rebalances=${RND_REBALANCE_COUNT} | successRate=${success_pct}%"
  echo "Directions: zeroForOne=${zfo_fmt} | oneForZero=${ozf_fmt}"
  echo
  render_hook_cases_table
  echo "  Note: GV/MN are governance+monetization checks; INV are on-chain invariants; RT/FZ/ED are transition checks."
  if (( RND_MODEL_MISMATCH_COUNT > 0 )); then
    echo "  Model mismatch: count=${RND_MODEL_MISMATCH_COUNT} last=${RND_MODEL_MISMATCH_LAST}"
  fi
  echo
  render_fee_change_table
  echo
  echo "Last tx: status=${RND_LAST_TX_STATUS} side=${RND_LAST_TX_SIDE} amount=${last_tx_amount_display} reason=${RND_LAST_TX_REASON} hash=${RND_LAST_TX_HASH}"
  echo "Last error: ${RND_LAST_ERROR}"
  echo "Stats: ${RND_STATS_FILE}"
  echo "Tx log: ${RND_TX_LOG_FILE}"
  echo
  echo "Press Ctrl+C to stop gracefully and persist stats."
}

random_append_tx_log() {
  local ts="$1"
  local attempt="$2"
  local label="$3"
  local status="$4"
  local side="$5"
  local amount="$6"
  local reason="$7"
  local tx_hash="$8"
  local fee_before="$9"
  local fee_after="${10}"
  local idx_before="${11}"
  local idx_after="${12}"
  local dir_before="${13}"
  local dir_after="${14}"
  local err="${15}"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${ts}" "${attempt}" "${label}" "${status}" "${side}" "${amount}" "${reason}" "${tx_hash}" \
    "${fee_before}" "${fee_after}" "${idx_before}" "${idx_after}" "${dir_before}" "${dir_after}" "${err}" >> "${RND_TX_LOG_FILE}"
}

random_request_stop() {
  if (( RND_STOP_REQUESTED == 0 )); then
    RND_STOP_REQUESTED=1
    RND_REASON="stopping"
    RND_PHASE="shutdown"
  fi
}

random_finalize() {
  if (( RND_FINALIZED == 1 )); then
    return
  fi
  RND_FINALIZED=1
  if [[ "${RND_REASON}" == "running" ]]; then
    if (( RND_STOP_REQUESTED == 1 )); then
      RND_REASON="stopped-by-signal"
    else
      if (( CASES_MODE == 1 && CASES_COMPLETED_RUNS < CASES_RUNS )); then
        RND_REASON="incomplete-exit"
      else
        RND_REASON="completed"
      fi
    fi
  elif [[ "${RND_REASON}" == "stopping" ]]; then
    RND_REASON="stopped-by-signal"
  fi
  RND_PHASE="finalize"
  random_write_stats_snapshot || true
  random_render_dashboard || true
  echo
  echo "===== Simulation finished ====="
  echo "Reason: ${RND_REASON}"
  echo "Stats snapshot: ${RND_STATS_FILE}"
  echo "Tx log: ${RND_TX_LOG_FILE}"
}

random_sleep_with_dashboard() {
  local seconds="$1"
  local left
  if (( seconds <= 0 )); then
    RND_CURRENT_WAIT=0
    return
  fi
  if [[ ! -t 1 || "${NO_LIVE}" -eq 1 ]]; then
    sleep "${seconds}" || true
    RND_CURRENT_WAIT=0
    return
  fi
  left="${seconds}"
  while (( left > 0 )); do
    if (( RND_STOP_REQUESTED == 1 )); then
      break
    fi
    RND_CURRENT_WAIT="${left}"
    random_render_dashboard
    sleep 1 || true
    left=$((left - 1))
  done
  RND_CURRENT_WAIT=0
}

run_random_mode() {
  local state_before state_after
  local fee_before pv_before ema_before ps_before idx_before dir_before
  local fee_after pv_after ema_after ps_after idx_after dir_after
  local min_amount max_amount amount
  local amount_pick amount_pick_rest planned_side bounds_pick wait_reason
  local attempt_no side_roll
  local side zero_for_one tx_hash tx_out tx_reason
  local side_hint side_hint_reason side_hint_raw allow_hint
  local econ_metrics econ_vol_usd6 econ_vol0 econ_vol1 econ_fee0 econ_fee1 econ_fee_usd6
  local bal0_raw bal1_raw zfo_budget ozf_budget
  local tick_now tick_delta tick_abs force_correction correction_min correction_max
  local wait_seconds label ts

  if ! [[ "${MIN_WAIT_SECONDS}" =~ ^[0-9]+$ && "${MAX_WAIT_SECONDS}" =~ ^[0-9]+$ && "${DURATION_SECONDS}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: wait and duration options must be non-negative integers."
    exit 1
  fi
  if (( MAX_WAIT_SECONDS < MIN_WAIT_SECONDS )); then
    echo "ERROR: --max-wait-seconds must be >= --min-wait-seconds."
    exit 1
  fi
  if [[ -n "${RANDOM_MIN_AMOUNT}" && ! "${RANDOM_MIN_AMOUNT}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --min-amount must be a non-negative integer."
    exit 1
  fi
  if [[ -n "${RANDOM_MAX_AMOUNT}" && ! "${RANDOM_MAX_AMOUNT}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --max-amount must be a non-negative integer."
    exit 1
  fi
  if [[ -n "${RANDOM_MIN_AMOUNT}" && -n "${RANDOM_MAX_AMOUNT}" ]] && (( RANDOM_MAX_AMOUNT < RANDOM_MIN_AMOUNT )); then
    echo "ERROR: --max-amount must be >= --min-amount."
    exit 1
  fi
  if ! [[ "${CASES_RUNS}" =~ ^[0-9]+$ ]] || (( CASES_RUNS <= 0 )); then
    echo "ERROR: --cases-runs must be a positive integer."
    exit 1
  fi

  if [[ -z "${STATS_FILE}" ]]; then
    STATS_FILE="./tmp/simulate_fee_cycle_stats_${CHAIN}_$(date -u +%Y%m%d_%H%M%S).txt"
  fi
  mkdir -p "$(dirname "${STATS_FILE}")"
  RND_STATS_FILE="${STATS_FILE}"
  if [[ "${RND_STATS_FILE##*/}" == *.* ]]; then
    RND_TX_LOG_FILE="${RND_STATS_FILE%.*}.tx.csv"
  else
    RND_TX_LOG_FILE="${RND_STATS_FILE}.tx.csv"
  fi
  {
    echo "timestamp_utc,attempt,label,status,side,amount,reason,tx_hash,fee_before,fee_after,fee_idx_before,fee_idx_after,last_dir_before,last_dir_after,error"
  } > "${RND_TX_LOG_FILE}"

  if ! state_before="$(read_state 2>&1)"; then
    echo "ERROR: failed to read initial hook state: ${state_before}"
    exit 1
  fi
  IFS='|' read -r RND_CURRENT_FEE RND_CURRENT_PV RND_CURRENT_EMA ps_before RND_CURRENT_IDX RND_CURRENT_DIR <<<"${state_before}"
  if ! state_fields_valid "${RND_CURRENT_FEE}" "${RND_CURRENT_PV}" "${RND_CURRENT_EMA}" "${ps_before}" "${RND_CURRENT_IDX}" "${RND_CURRENT_DIR}"; then
    echo "ERROR: malformed initial hook state: ${state_before}"
    exit 1
  fi
  evaluate_hook_invariants "${RND_CURRENT_FEE}" "${RND_CURRENT_IDX}"
  random_refresh_runtime_metrics
  RND_START_TS="$(date +%s)"
  RND_START_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  RND_LAST_UPDATE_ISO="${RND_START_ISO}"
  RND_LAST_TX_REASON="-"
  RND_REBALANCE_LAST_ATTEMPT=0
  RND_REBALANCE_COUNT=0
  if (( CASES_MODE == 1 )); then
    CASES_COMPLETED_RUNS=0
    cases_reset_cycle_context "${RND_CURRENT_IDX}" "${RND_CURRENT_DIR}"
  fi
  if maybe_rebalance_wallet 1; then
    if state_before="$(read_state 2>&1)"; then
      IFS='|' read -r RND_CURRENT_FEE RND_CURRENT_PV RND_CURRENT_EMA ps_before RND_CURRENT_IDX RND_CURRENT_DIR <<<"${state_before}"
      if state_fields_valid "${RND_CURRENT_FEE}" "${RND_CURRENT_PV}" "${RND_CURRENT_EMA}" "${ps_before}" "${RND_CURRENT_IDX}" "${RND_CURRENT_DIR}"; then
        evaluate_hook_invariants "${RND_CURRENT_FEE}" "${RND_CURRENT_IDX}"
      fi
    fi
  fi

  if [[ -n "${STATE_VIEW_ADDRESS}" && -n "${POOL_ID}" ]]; then
    if tick_now="$(read_pool_tick 2>/dev/null)"; then
      RND_ARB_MODE="tick-band"
      RND_ARB_ENABLED=1
      RND_ARB_ANCHOR_TICK="${tick_now}"
      RND_ARB_CURRENT_TICK="${tick_now}"
      RND_ARB_TICK_DEV=0
      if liq_now="$(read_pool_liquidity 2>/dev/null)"; then
        RND_POOL_LIQUIDITY="${liq_now}"
        if [[ "${RND_POOL_LIQUIDITY}" =~ ^[0-9]+$ ]] && (( RND_POOL_LIQUIDITY == 0 )); then
          echo "ERROR: pool liquidity is zero for poolId=${POOL_ID}"
          echo "       Swaps may succeed, but hook period volume will stay zero and fee tiers will not change."
          echo "       Add active liquidity to this pool, then rerun simulate_fee_cycle."
          exit 1
        fi
      else
        RND_LAST_ERROR="failed to read pool liquidity; continuing."
      fi
    else
      RND_ARB_MODE="fallback-streak"
      RND_ARB_ENABLED=0
      RND_LAST_ERROR="StateView is not readable; using side-streak fallback."
    fi
  else
    RND_ARB_MODE="fallback-streak"
    RND_ARB_ENABLED=0
    RND_LAST_ERROR="StateView not configured; using side-streak fallback."
  fi
  if (( CASES_MODE == 1 )); then
    RND_ARB_ENABLED=0
    RND_ARB_MODE="cases-scripted"
  fi

  trap random_request_stop INT TERM
  trap random_finalize EXIT

  random_write_stats_snapshot
  random_render_dashboard

  while (( RND_STOP_REQUESTED == 0 )); do
    if (( CASES_MODE == 1 && CASES_COMPLETED_RUNS >= CASES_RUNS )); then
      RND_REASON="cases-runs-reached"
      break
    fi
    if (( DURATION_SECONDS > 0 )); then
      if (( $(date +%s) - RND_START_TS >= DURATION_SECONDS )); then
        RND_REASON="duration-reached"
        break
      fi
    fi

    if ! state_before="$(read_state 2>&1)"; then
      RND_RPC_ERRORS=$((RND_RPC_ERRORS + 1))
      RND_LAST_ERROR="read_state failed: $(sanitize_inline "${state_before}")"
      RND_PHASE="read-state-retry"
      random_write_stats_snapshot
      random_render_dashboard
      random_sleep_with_dashboard 3
      continue
    fi
    IFS='|' read -r fee_before pv_before ema_before ps_before idx_before dir_before <<<"${state_before}"
    if ! state_fields_valid "${fee_before}" "${pv_before}" "${ema_before}" "${ps_before}" "${idx_before}" "${dir_before}"; then
      RND_RPC_ERRORS=$((RND_RPC_ERRORS + 1))
      RND_LAST_ERROR="read_state malformed: $(sanitize_inline "${state_before}")"
      RND_PHASE="read-state-retry"
      random_write_stats_snapshot
      random_render_dashboard
      random_sleep_with_dashboard 2
      continue
    fi
    RND_CURRENT_FEE="${fee_before}"
    RND_CURRENT_PV="${pv_before}"
    RND_CURRENT_EMA="${ema_before}"
    RND_CURRENT_IDX="${idx_before}"
    RND_CURRENT_DIR="${dir_before}"
    evaluate_hook_invariants "${fee_before}" "${idx_before}"
    random_refresh_runtime_metrics
    if maybe_rebalance_wallet 0; then
      RND_PHASE="wait"
      RND_LAST_WAIT_STRATEGY="wallet-rebalance"
      random_write_stats_snapshot
      random_render_dashboard
      random_sleep_with_dashboard 2
      continue
    fi

    bounds_pick=""
    if [[ -n "${RANDOM_MIN_AMOUNT}" ]]; then
      min_amount="${RANDOM_MIN_AMOUNT}"
    elif (( CASES_MODE == 1 )); then
      if bounds_pick="$(pick_case_amount_bounds 2>/dev/null)"; then
        min_amount="${bounds_pick%%|*}"
      else
        min_amount=500000
      fi
    else
      if ! min_amount="$(pick_low_amount "${state_before}" 2>/dev/null)"; then
        RND_RPC_ERRORS=$((RND_RPC_ERRORS + 1))
        RND_LAST_ERROR="pick_low_amount failed; using fallback=100"
        min_amount=100
      fi
    fi
    if [[ -n "${RANDOM_MAX_AMOUNT}" ]]; then
      max_amount="${RANDOM_MAX_AMOUNT}"
    elif (( CASES_MODE == 1 )); then
      if [[ -n "${bounds_pick:-}" ]]; then
        max_amount="${bounds_pick#*|}"
      elif bounds_pick="$(pick_case_amount_bounds 2>/dev/null)"; then
        max_amount="${bounds_pick#*|}"
      else
        max_amount=$((min_amount * 4))
      fi
    else
      if ! max_amount="$(pick_high_amount "${state_before}" 2>/dev/null)"; then
        RND_RPC_ERRORS=$((RND_RPC_ERRORS + 1))
        RND_LAST_ERROR="pick_high_amount failed; using fallback=min"
        max_amount="${min_amount}"
      fi
    fi
    if (( min_amount <= 0 )); then
      if (( CASES_MODE == 1 )); then
        min_amount=500000
      else
        min_amount=100
      fi
    fi
    if [[ -z "${RANDOM_MIN_AMOUNT}" ]] && (( max_amount >= RANDOM_SOFT_MIN_AMOUNT && min_amount < RANDOM_SOFT_MIN_AMOUNT )); then
      min_amount="${RANDOM_SOFT_MIN_AMOUNT}"
    fi
    if [[ -z "${RANDOM_MAX_AMOUNT}" ]] && (( max_amount > RANDOM_SOFT_MAX_AMOUNT )); then
      max_amount="${RANDOM_SOFT_MAX_AMOUNT}"
    fi
    if (( max_amount < min_amount )); then max_amount="${min_amount}"; fi
    if (( CASES_MODE == 1 )); then
      cases_plan_next_action "${state_before}"
      amount="${CASES_NEXT_AMOUNT}"
      tx_reason="${CASES_NEXT_REASON}"
      planned_side="${CASES_NEXT_SIDE}"
      if ! [[ "${amount}" =~ ^[0-9]+$ ]]; then
        amount="${min_amount}"
      fi
      if (( amount < min_amount )); then amount="${min_amount}"; fi
      if (( amount > max_amount )); then amount="${max_amount}"; fi
    else
      amount_pick="$(pick_amount_with_case_bias "${min_amount}" "${max_amount}" "${state_before}")"
      amount="${amount_pick%%|*}"
      amount_pick_rest="${amount_pick#*|}"
      tx_reason="${amount_pick_rest%%|*}"
      planned_side="${amount_pick_rest#*|}"
      if [[ "${planned_side}" == "${amount_pick_rest}" ]]; then
        planned_side=""
      fi
    fi
    if (( CASES_MODE == 1 )) && [[ "${CASES_STAGE}" == "post_checks" ]]; then
      run_cases_final_checks || true
      if state_after_checks="$(read_state 2>/dev/null)"; then
        IFS='|' read -r fee_after_checks pv_after_checks ema_after_checks ps_after_checks idx_after_checks dir_after_checks <<<"${state_after_checks}"
        if state_fields_valid "${fee_after_checks}" "${pv_after_checks}" "${ema_after_checks}" "${ps_after_checks}" "${idx_after_checks}" "${dir_after_checks}"; then
          evaluate_hook_invariants "${fee_after_checks}" "${idx_after_checks}"
          RND_CURRENT_FEE="${fee_after_checks}"
          RND_CURRENT_PV="${pv_after_checks}"
          RND_CURRENT_EMA="${ema_after_checks}"
          RND_CURRENT_IDX="${idx_after_checks}"
          RND_CURRENT_DIR="${dir_after_checks}"
          cases_select_stage "${idx_after_checks}" "${dir_after_checks}"
        fi
      fi
      if cases_all_required_done; then
        cases_set_stage "cycle_done"
      fi
      RND_PHASE="wait"
      RND_LAST_WAIT_STRATEGY="case-post-checks"
      random_refresh_runtime_metrics
      random_write_stats_snapshot
      random_render_dashboard
      random_sleep_with_dashboard 1
      continue
    fi
    if (( CASES_MODE == 1 && CASES_FORCE_WAIT_SECONDS > 0 )); then
      RND_PHASE="wait"
      wait_seconds="${CASES_FORCE_WAIT_SECONDS}"
      if [[ -n "${CASES_FORCE_WAIT_REASON}" ]]; then
        wait_reason="${CASES_FORCE_WAIT_REASON}"
      else
        wait_reason="case-rollover-wait"
      fi
      CASES_FORCE_WAIT_SECONDS=0
      CASES_FORCE_WAIT_REASON=""
      RND_LAST_WAIT_STRATEGY="${wait_reason}"
      random_refresh_runtime_metrics
      random_write_stats_snapshot
      random_render_dashboard
      random_sleep_with_dashboard "${wait_seconds}"
      continue
    fi
    force_correction=0
    attempt_no=$((RND_ATTEMPTS + 1))
    if (( RND_FORCE_SIDE_UNTIL > 0 && attempt_no >= RND_FORCE_SIDE_UNTIL )); then
      RND_FORCE_SIDE=""
      RND_FORCE_SIDE_UNTIL=0
    fi

    if (( RND_ARB_ENABLED == 1 )); then
      if (( attempt_no >= RND_ARB_SUSPEND_UNTIL )); then
        if tick_now="$(read_pool_tick 2>/dev/null)"; then
          RND_ARB_CURRENT_TICK="${tick_now}"
          if (( tick_now <= TICK_MIN + TICK_EDGE_GUARD )); then
            RND_FORCE_SIDE="oneForZero"
            RND_FORCE_SIDE_UNTIL=$((attempt_no + EDGE_FORCE_ATTEMPTS))
            RND_BLOCK_ZFO_UNTIL=$((attempt_no + EDGE_BLOCK_ATTEMPTS))
            RND_TICK_EDGE_FLIPS=$((RND_TICK_EDGE_FLIPS + 1))
            tx_reason="tick-edge-min-recovery"
          elif (( tick_now >= TICK_MAX - TICK_EDGE_GUARD )); then
            RND_FORCE_SIDE="zeroForOne"
            RND_FORCE_SIDE_UNTIL=$((attempt_no + EDGE_FORCE_ATTEMPTS))
            RND_BLOCK_OZF_UNTIL=$((attempt_no + EDGE_BLOCK_ATTEMPTS))
            RND_TICK_EDGE_FLIPS=$((RND_TICK_EDGE_FLIPS + 1))
            tx_reason="tick-edge-max-recovery"
          fi

          tick_delta=$((tick_now - RND_ARB_ANCHOR_TICK))
          tick_abs=${tick_delta#-}
          if (( tick_abs > ARB_GUARD_REANCHOR_TICK_DELTA )); then
            RND_ARB_ANCHOR_TICK="${tick_now}"
            RND_ARB_TICK_DEV=0
            RND_ARB_REANCHOR=$((RND_ARB_REANCHOR + 1))
          else
            RND_ARB_TICK_DEV="${tick_delta}"
            if (( tick_abs > ARB_GUARD_TICK_BAND )) && [[ -z "${RND_FORCE_SIDE}" ]]; then
              force_correction=1
              tx_reason="arb-correction"
              RND_ARB_FORCED=$((RND_ARB_FORCED + 1))
              if (( tick_delta > 0 )); then
                zero_for_one=true
                side="zeroForOne"
              else
                zero_for_one=false
                side="oneForZero"
              fi
              correction_min="${max_amount}"
              if (( correction_min < min_amount )); then correction_min="${min_amount}"; fi
              if (( correction_min > 4611686018427387903 )); then
                correction_max="${correction_min}"
              else
                correction_max=$((correction_min * ARB_GUARD_CORRECTION_MULTIPLIER))
              fi
              if (( correction_max < correction_min )); then correction_max="${correction_min}"; fi
              amount="$(random_between "${correction_min}" "${correction_max}")"
            fi
          fi
        else
          RND_RPC_ERRORS=$((RND_RPC_ERRORS + 1))
          RND_LAST_ERROR="tick read failed; switching to side-streak fallback."
          RND_ARB_ENABLED=0
          RND_ARB_MODE="fallback-streak"
        fi
      else
        RND_ARB_MODE="tick-band-suspended"
      fi
    fi

    if (( attempt_no < RND_BLOCK_ZFO_UNTIL && attempt_no < RND_BLOCK_OZF_UNTIL )); then
      # If both sides are blocked, unblock the side that would expire earlier.
      if (( RND_BLOCK_ZFO_UNTIL <= RND_BLOCK_OZF_UNTIL )); then
        RND_BLOCK_ZFO_UNTIL=0
      else
        RND_BLOCK_OZF_UNTIL=0
      fi
    fi

    if (( force_correction == 0 )); then
      if [[ -n "${RND_FORCE_SIDE}" && ${attempt_no} -lt ${RND_FORCE_SIDE_UNTIL} ]]; then
        tx_reason="price-limit-recovery"
        if [[ "${RND_FORCE_SIDE}" == "zeroForOne" ]]; then
          zero_for_one=true
          side="zeroForOne"
        else
          zero_for_one=false
          side="oneForZero"
        fi
      elif (( CASES_MODE == 0 && RND_ARB_ENABLED == 0 && RND_SIDE_STREAK >= ARB_GUARD_STREAK_LIMIT )) && [[ "${RND_LAST_SIDE_SEEN}" != "-" ]]; then
        tx_reason="fallback-reverse-streak"
        RND_ARB_FALLBACK_FORCED=$((RND_ARB_FALLBACK_FORCED + 1))
        if [[ "${RND_LAST_SIDE_SEEN}" == "zeroForOne" ]]; then
          zero_for_one=false
          side="oneForZero"
        else
          zero_for_one=true
          side="zeroForOne"
        fi
      elif [[ -n "${planned_side}" ]]; then
        side="${planned_side}"
        if [[ "${side}" == "zeroForOne" ]]; then
          zero_for_one=true
        else
          zero_for_one=false
        fi
      else
        zfo_bias=55
        if [[ "${idx_before}" =~ ^[0-9]+$ ]]; then
          if (( idx_before >= HOOK_CAP_IDX )); then
            zfo_bias=20
          elif (( idx_before == HOOK_CAP_IDX - 1 )); then
            zfo_bias=35
          elif (( idx_before <= HOOK_FLOOR_IDX )); then
            zfo_bias=80
          elif (( idx_before == HOOK_FLOOR_IDX + 1 )); then
            zfo_bias=65
          fi
          if (( TC_CAP_CLAMP_PASS == 0 && idx_before < HOOK_CAP_IDX )); then
            zfo_bias=$((zfo_bias + 10))
          fi
          if (( TC_FLOOR_CLAMP_PASS == 0 && idx_before > HOOK_FLOOR_IDX )); then
            zfo_bias=$((zfo_bias - 10))
          fi
        fi
        if (( zfo_bias < 15 )); then zfo_bias=15; fi
        if (( zfo_bias > 85 )); then zfo_bias=85; fi
        side_roll="$(random_between 1 100)"
        if (( side_roll <= zfo_bias )); then
          zero_for_one=true
          side="zeroForOne"
        else
          zero_for_one=false
          side="oneForZero"
        fi
      fi
    fi

    side_hint="none"
    side_hint_reason="none"
    bal0_raw=""
    bal1_raw=""
    if [[ "${STABLE_SIDE}" != "unknown" ]]; then
      if bal0_raw="$(read_token_balance "${CURRENCY0}" 2>/dev/null)" && bal1_raw="$(read_token_balance "${CURRENCY1}" 2>/dev/null)"; then
        if [[ "${bal0_raw}" =~ ^[0-9]+$ && "${bal1_raw}" =~ ^[0-9]+$ ]]; then
          if [[ "${STABLE_SIDE}" == "token0" ]]; then
            side_hint_raw="$(suggest_balance_target_side \
              "${bal0_raw}" \
              "${bal1_raw}" \
              "${RND_POOL_PRICE_T1_PER_T0}" \
              "${TOKEN0_DECIMALS}" \
              "${TOKEN1_DECIMALS}" \
              "${AUTO_REBALANCE_TARGET_PCT}" \
              "${AUTO_REBALANCE_TOLERANCE_PCT}" \
              "${RND_ARB_CURRENT_TICK}" \
              "${RND_ARB_ANCHOR_TICK}" \
              "${ARB_GUARD_TICK_BAND}" 2>/dev/null || true)"
          else
            side_hint_raw="$(suggest_balance_target_side \
              "${bal1_raw}" \
              "${bal0_raw}" \
              "${RND_POOL_PRICE_T1_PER_T0}" \
              "${TOKEN1_DECIMALS}" \
              "${TOKEN0_DECIMALS}" \
              "${AUTO_REBALANCE_TARGET_PCT}" \
              "${AUTO_REBALANCE_TOLERANCE_PCT}" \
              "${RND_ARB_CURRENT_TICK}" \
              "${RND_ARB_ANCHOR_TICK}" \
              "${ARB_GUARD_TICK_BAND}" 2>/dev/null || true)"
          fi
          side_hint="${side_hint_raw%%|*}"
          side_hint_reason="${side_hint_raw#*|}"
          if [[ "${side_hint_reason}" == "${side_hint_raw}" ]]; then
            side_hint_reason="balance-guidance"
          fi
        fi
      fi
    fi
    if [[ "${side_hint}" == "zeroForOne" || "${side_hint}" == "oneForZero" ]]; then
      allow_hint=1
      if (( CASES_MODE == 1 )); then
        case "${CASES_STAGE}" in
          up_to_cap|cap_probe|down_to_floor|floor_probe|reversal_seed|reversal_opposite)
            allow_hint=0
            ;;
        esac
      fi
      if (( force_correction == 0 && allow_hint == 1 )) && [[ "${side}" != "${side_hint}" ]]; then
        side="${side_hint}"
        if [[ "${side}" == "zeroForOne" ]]; then
          zero_for_one=true
        else
          zero_for_one=false
        fi
        tx_reason="${tx_reason}+${side_hint_reason}"
      fi
    fi

    if [[ "${side}" == "zeroForOne" && ${attempt_no} -lt ${RND_BLOCK_ZFO_UNTIL} ]]; then
      if (( attempt_no >= RND_BLOCK_OZF_UNTIL )); then
        zero_for_one=false
        side="oneForZero"
        tx_reason="${tx_reason}+side-fallback"
      else
        if (( RND_BLOCK_ZFO_UNTIL <= RND_BLOCK_OZF_UNTIL )); then
          RND_BLOCK_ZFO_UNTIL=0
        else
          RND_BLOCK_OZF_UNTIL=0
          zero_for_one=false
          side="oneForZero"
        fi
        tx_reason="${tx_reason}+side-unblock"
      fi
    elif [[ "${side}" == "oneForZero" && ${attempt_no} -lt ${RND_BLOCK_OZF_UNTIL} ]]; then
      if (( attempt_no >= RND_BLOCK_ZFO_UNTIL )); then
        zero_for_one=true
        side="zeroForOne"
        tx_reason="${tx_reason}+side-fallback"
      else
        if (( RND_BLOCK_OZF_UNTIL <= RND_BLOCK_ZFO_UNTIL )); then
          RND_BLOCK_OZF_UNTIL=0
        else
          RND_BLOCK_ZFO_UNTIL=0
          zero_for_one=true
          side="zeroForOne"
        fi
        tx_reason="${tx_reason}+side-unblock"
      fi
    fi

    if [[ "${RND_ARB_CURRENT_TICK}" =~ ^-?[0-9]+$ ]]; then
      if (( RND_ARB_CURRENT_TICK <= TICK_MIN + TICK_EDGE_GUARD )) && [[ "${side}" == "zeroForOne" ]]; then
        zero_for_one=false
        side="oneForZero"
        RND_TICK_EDGE_FLIPS=$((RND_TICK_EDGE_FLIPS + 1))
        tx_reason="${tx_reason}+tick-boundary-guard"
      elif (( RND_ARB_CURRENT_TICK >= TICK_MAX - TICK_EDGE_GUARD )) && [[ "${side}" == "oneForZero" ]]; then
        zero_for_one=true
        side="zeroForOne"
        RND_TICK_EDGE_FLIPS=$((RND_TICK_EDGE_FLIPS + 1))
        tx_reason="${tx_reason}+tick-boundary-guard"
      fi
    fi

    if [[ "${bal0_raw}" =~ ^[0-9]+$ && "${bal1_raw}" =~ ^[0-9]+$ ]]; then
      zfo_budget=$(( bal0_raw * MAX_BALANCE_SPEND_PCT / 100 ))
      ozf_budget=$(( bal1_raw * MAX_BALANCE_SPEND_PCT / 100 ))
      if (( bal0_raw > 0 && zfo_budget <= 0 )); then zfo_budget="${bal0_raw}"; fi
      if (( bal1_raw > 0 && ozf_budget <= 0 )); then ozf_budget="${bal1_raw}"; fi
      # If one input side is depleted, force the opposite direction to restore spendable balance.
      if [[ "${side}" == "zeroForOne" && ${zfo_budget} -le 0 ]]; then
        if (( attempt_no < RND_BLOCK_OZF_UNTIL )); then
          RND_BLOCK_OZF_UNTIL=0
          RND_BALANCE_UNBLOCK_FORCED=$((RND_BALANCE_UNBLOCK_FORCED + 1))
        fi
        side="oneForZero"
        zero_for_one=false
        tx_reason="${tx_reason}+balance-reseed"
      elif [[ "${side}" == "oneForZero" && ${ozf_budget} -le 0 ]]; then
        if (( attempt_no < RND_BLOCK_ZFO_UNTIL )); then
          RND_BLOCK_ZFO_UNTIL=0
          RND_BALANCE_UNBLOCK_FORCED=$((RND_BALANCE_UNBLOCK_FORCED + 1))
        fi
        side="zeroForOne"
        zero_for_one=true
        tx_reason="${tx_reason}+balance-reseed"
      fi
    fi

    amount_raw="${amount}"
    amount="$(scale_amount_for_side "${amount_raw}" "${side}")"
    if (( amount <= 0 )); then
      alt_side="zeroForOne"
      alt_zero_for_one=true
      if [[ "${side}" == "zeroForOne" ]]; then
        alt_side="oneForZero"
        alt_zero_for_one=false
      fi
      alt_unblocked=0
      if [[ "${alt_side}" == "zeroForOne" && ${attempt_no} -lt ${RND_BLOCK_ZFO_UNTIL} ]]; then
        RND_BLOCK_ZFO_UNTIL=0
        alt_unblocked=1
      elif [[ "${alt_side}" == "oneForZero" && ${attempt_no} -lt ${RND_BLOCK_OZF_UNTIL} ]]; then
        RND_BLOCK_OZF_UNTIL=0
        alt_unblocked=1
      fi
      alt_amount="$(scale_amount_for_side "${amount_raw}" "${alt_side}")"
      if (( alt_amount > 0 )); then
        side="${alt_side}"
        zero_for_one="${alt_zero_for_one}"
        amount="${alt_amount}"
        tx_reason="${tx_reason}+balance-fallback"
        if (( alt_unblocked == 1 )); then
          tx_reason="${tx_reason}+guard-unblock"
          RND_BALANCE_UNBLOCK_FORCED=$((RND_BALANCE_UNBLOCK_FORCED + 1))
        fi
      else
        if maybe_rebalance_wallet 1; then
          RND_PHASE="wait"
          RND_LAST_WAIT_STRATEGY="wallet-rebalance"
          random_write_stats_snapshot
          random_render_dashboard
          random_sleep_with_dashboard 2
          continue
        fi
        RND_SKIP_BALANCE=$((RND_SKIP_BALANCE + 1))
        RND_LAST_ERROR="insufficient token-in balance for both directions; skipping attempt"
        RND_LAST_TX_STATUS="skipped"
        RND_LAST_TX_HASH="-"
        RND_LAST_TX_SIDE="-"
        RND_LAST_TX_AMOUNT="-"
        RND_PHASE="wait"
        RND_LAST_WAIT_STRATEGY="balance-skip"
        random_write_stats_snapshot
        random_render_dashboard
        random_sleep_with_dashboard 2
        continue
      fi
    fi

    if [[ "${side}" == "${RND_LAST_SIDE_SEEN}" ]]; then
      RND_SIDE_STREAK=$((RND_SIDE_STREAK + 1))
    else
      RND_SIDE_STREAK=1
      RND_LAST_SIDE_SEEN="${side}"
    fi
    if [[ "${side}" == "zeroForOne" ]]; then
      RND_ZFO_COUNT=$((RND_ZFO_COUNT + 1))
    else
      RND_OZF_COUNT=$((RND_OZF_COUNT + 1))
    fi

    RND_ATTEMPTS=$((RND_ATTEMPTS + 1))
    label="$(printf 'RND_%06d' "${RND_ATTEMPTS}")"
    RND_PHASE="send"
    RND_LAST_TX_SIDE="${side}"
    RND_LAST_TX_AMOUNT="${amount}"
    RND_LAST_TX_REASON="${tx_reason}"
    RND_TOTAL_AMOUNT=$((RND_TOTAL_AMOUNT + amount))
    if (( RND_MIN_AMOUNT_OBS == 0 || amount < RND_MIN_AMOUNT_OBS )); then RND_MIN_AMOUNT_OBS="${amount}"; fi
    if (( amount > RND_MAX_AMOUNT_OBS )); then RND_MAX_AMOUNT_OBS="${amount}"; fi

    if tx_hash="$(run_swap_step "${label}" "${amount}" "${zero_for_one}" 2>&1)"; then
      RND_SUCCESS=$((RND_SUCCESS + 1))
      RND_LAST_TX_HASH="${tx_hash}"
      RND_LAST_TX_STATUS="ok"
      RND_LAST_ERROR="-"
      econ_metrics="$(estimate_swap_economics "${side}" "${amount}" "${fee_before}" "${RND_POOL_PRICE_T1_PER_T0}")"
      IFS='|' read -r econ_vol_usd6 econ_vol0 econ_vol1 econ_fee0 econ_fee1 econ_fee_usd6 <<<"${econ_metrics}"
      if [[ "${econ_vol_usd6}" =~ ^[0-9]+$ ]]; then
        RND_ECON_VOL_USD6="$(add_int_str "${RND_ECON_VOL_USD6}" "${econ_vol_usd6}")"
      fi
      if [[ "${econ_vol0}" =~ ^[0-9]+$ ]]; then
        RND_ECON_VOL_TOKEN0_RAW="$(add_int_str "${RND_ECON_VOL_TOKEN0_RAW}" "${econ_vol0}")"
      fi
      if [[ "${econ_vol1}" =~ ^[0-9]+$ ]]; then
        RND_ECON_VOL_TOKEN1_RAW="$(add_int_str "${RND_ECON_VOL_TOKEN1_RAW}" "${econ_vol1}")"
      fi
      if [[ "${econ_fee0}" =~ ^[0-9]+$ ]]; then
        RND_ECON_FEE_TOKEN0_RAW="$(add_int_str "${RND_ECON_FEE_TOKEN0_RAW}" "${econ_fee0}")"
      fi
      if [[ "${econ_fee1}" =~ ^[0-9]+$ ]]; then
        RND_ECON_FEE_TOKEN1_RAW="$(add_int_str "${RND_ECON_FEE_TOKEN1_RAW}" "${econ_fee1}")"
      fi
      if [[ "${econ_fee_usd6}" =~ ^[0-9]+$ ]]; then
        RND_ECON_FEE_USD6="$(add_int_str "${RND_ECON_FEE_USD6}" "${econ_fee_usd6}")"
      fi
      if [[ "${fee_before}" =~ ^[0-9]+$ ]]; then
        RND_ECON_FEE_BIPS_SUM="$(add_int_str "${RND_ECON_FEE_BIPS_SUM}" "${fee_before}")"
        RND_ECON_FEE_SAMPLES=$((RND_ECON_FEE_SAMPLES + 1))
      fi
      RND_PRICE_LIMIT_STREAK=0
      if [[ "${side}" == "zeroForOne" ]]; then
        RND_BLOCK_ZFO_UNTIL=0
      else
        RND_BLOCK_OZF_UNTIL=0
      fi
      if state_after="$(read_state 2>&1)"; then
        IFS='|' read -r fee_after pv_after ema_after ps_after idx_after dir_after <<<"${state_after}"
        if state_fields_valid "${fee_after}" "${pv_after}" "${ema_after}" "${ps_after}" "${idx_after}" "${dir_after}"; then
          RND_CURRENT_FEE="${fee_after}"
          RND_CURRENT_PV="${pv_after}"
          RND_CURRENT_EMA="${ema_after}"
          RND_CURRENT_IDX="${idx_after}"
          RND_CURRENT_DIR="${dir_after}"
          evaluate_hook_invariants "${fee_after}" "${idx_after}"
          evaluate_hook_transition_cases "${state_before}" "${state_after}"
          if (( CASES_MODE == 1 )); then
            cases_refresh_checklist_from_counters
            if (( CASES_RUN_LULL_OK == 0 )) && [[ "${CASES_STAGE}" == "await_lull_validation" ]]; then
              cases_set_stage "post_lull_trigger"
            fi
            cases_select_stage "${idx_after}" "${dir_after}"
            if cases_all_required_done; then
              CASES_COMPLETED_RUNS=$((CASES_COMPLETED_RUNS + 1))
              cases_reset_cycle_context "${idx_after}" "${dir_after}"
            fi
          fi
          if [[ "${fee_after}" == "${fee_before}" && "${pv_after}" == "${pv_before}" && "${ema_after}" == "${ema_before}" && "${idx_after}" == "${idx_before}" && "${dir_after}" == "${dir_before}" ]]; then
            RND_NO_STATE_CHANGE_STREAK=$((RND_NO_STATE_CHANGE_STREAK + 1))
            RND_NO_STATE_CHANGE_TOTAL=$((RND_NO_STATE_CHANGE_TOTAL + 1))
            if (( RND_NO_STATE_CHANGE_STREAK >= 12 && RND_NO_STATE_CHANGE_WARNED == 0 )); then
              RND_NO_STATE_CHANGE_WARNED=1
              RND_LAST_ERROR="warning: ${RND_NO_STATE_CHANGE_STREAK} successful swaps without hook state changes; likely zero active liquidity or wrong pool key."
            fi
          else
            RND_NO_STATE_CHANGE_STREAK=0
          fi
        else
          RND_RPC_ERRORS=$((RND_RPC_ERRORS + 1))
          RND_LAST_ERROR="post-send read_state malformed: $(sanitize_inline "${state_after}")"
          fee_after="${fee_before}"
          pv_after="${pv_before}"
          ema_after="${ema_before}"
          ps_after="${ps_before}"
          idx_after="${idx_before}"
          dir_after="${dir_before}"
        fi
      else
        RND_RPC_ERRORS=$((RND_RPC_ERRORS + 1))
        RND_LAST_ERROR="post-send read_state failed: $(sanitize_inline "${state_after}")"
        fee_after="${fee_before}"
        pv_after="${pv_before}"
        ema_after="${ema_before}"
        ps_after="${ps_before}"
        idx_after="${idx_before}"
        dir_after="${dir_before}"
      fi
      if [[ "${fee_after}" =~ ^[0-9]+$ && "${fee_before}" =~ ^[0-9]+$ ]]; then
        if (( fee_after > fee_before )); then
          RND_FEE_UP=$((RND_FEE_UP + 1))
        elif (( fee_after < fee_before )); then
          RND_FEE_DOWN=$((RND_FEE_DOWN + 1))
        else
          RND_FEE_FLAT=$((RND_FEE_FLAT + 1))
        fi
      else
        RND_FEE_FLAT=$((RND_FEE_FLAT + 1))
      fi
      ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
      if (( idx_after != idx_before || fee_after != fee_before )); then
        random_record_fee_change_event \
          "${ts}" \
          "${RND_ATTEMPTS}" \
          "${side}" \
          "${tx_reason}" \
          "${tx_hash}" \
          "${fee_before}" \
          "${fee_after}" \
          "${idx_before}" \
          "${idx_after}"
      fi
      random_append_tx_log "${ts}" "${RND_ATTEMPTS}" "${label}" "ok" "${side}" "${amount}" "${tx_reason}" "${tx_hash}" "${fee_before}" "${fee_after}" "${idx_before}" "${idx_after}" "${dir_before}" "${dir_after}" "-"
    else
      tx_out="$(sanitize_inline "${tx_hash}")"
      RND_FAILED=$((RND_FAILED + 1))
      RND_LAST_TX_HASH="-"
      RND_LAST_TX_STATUS="failed"
      RND_LAST_ERROR="${tx_out}"
      if [[ "${tx_out}" == *"replacement transaction underpriced"* || "${tx_out}" == *"nonce too low"* ]]; then
        RND_FAIL_NONCE=$((RND_FAIL_NONCE + 1))
        RND_PRICE_LIMIT_STREAK=0
      elif [[ "${tx_out}" == *"PriceLimitAlreadyExceeded"* ]]; then
        RND_FAIL_PRICE_LIMIT=$((RND_FAIL_PRICE_LIMIT + 1))
        RND_PRICE_LIMIT_BLOCKS=$((RND_PRICE_LIMIT_BLOCKS + 1))
        RND_PRICE_LIMIT_STREAK=$((RND_PRICE_LIMIT_STREAK + 1))
        RND_ARB_SUSPEND_UNTIL=$((RND_ATTEMPTS + ARB_GUARD_SUSPEND_ATTEMPTS))
        RND_ARB_MODE="tick-band-suspended"
        if [[ "${side}" == "zeroForOne" ]]; then
          RND_BLOCK_ZFO_UNTIL=$((RND_ATTEMPTS + PRICE_LIMIT_BLOCK_ATTEMPTS))
          RND_FORCE_SIDE="oneForZero"
          RND_LAST_ERROR="${tx_out}; block zeroForOne until attempt ${RND_BLOCK_ZFO_UNTIL}; force oneForZero"
        else
          RND_BLOCK_OZF_UNTIL=$((RND_ATTEMPTS + PRICE_LIMIT_BLOCK_ATTEMPTS))
          RND_FORCE_SIDE="zeroForOne"
          RND_LAST_ERROR="${tx_out}; block oneForZero until attempt ${RND_BLOCK_OZF_UNTIL}; force zeroForOne"
        fi
        RND_FORCE_SIDE_UNTIL=$((RND_ATTEMPTS + PRICE_LIMIT_FORCE_ATTEMPTS))
        RND_PRICE_LIMIT_RECOVERY_FORCED=$((RND_PRICE_LIMIT_RECOVERY_FORCED + 1))
        RND_NEXT_WAIT_OVERRIDE=1
        if (( RND_PRICE_LIMIT_STREAK >= 6 )); then
          RND_ARB_ENABLED=0
          RND_ARB_MODE="fallback-streak"
          RND_LAST_ERROR="${RND_LAST_ERROR}; disable arb guard after repeated price-limit errors"
        fi
      elif [[ "${tx_out}" == *"transfer amount exceeds balance"* ]]; then
        RND_FAIL_BALANCE_REVERT=$((RND_FAIL_BALANCE_REVERT + 1))
        if [[ "${side}" == "zeroForOne" ]]; then
          RND_BLOCK_ZFO_UNTIL=$((RND_ATTEMPTS + BALANCE_ERROR_FORCE_ATTEMPTS))
          RND_FORCE_SIDE="oneForZero"
          RND_LAST_ERROR="${tx_out}; block zeroForOne until attempt ${RND_BLOCK_ZFO_UNTIL}; force oneForZero"
        else
          RND_BLOCK_OZF_UNTIL=$((RND_ATTEMPTS + BALANCE_ERROR_FORCE_ATTEMPTS))
          RND_FORCE_SIDE="zeroForOne"
          RND_LAST_ERROR="${tx_out}; block oneForZero until attempt ${RND_BLOCK_OZF_UNTIL}; force zeroForOne"
        fi
        RND_FORCE_SIDE_UNTIL=$((RND_ATTEMPTS + BALANCE_ERROR_FORCE_ATTEMPTS + 8))
        RND_NEXT_WAIT_OVERRIDE=1
        RND_PRICE_LIMIT_STREAK=0
        maybe_rebalance_wallet 1 || true
      elif [[ "${tx_out}" == *"execution reverted"* ]]; then
        RND_FAIL_HOOKLIKE_REVERT=$((RND_FAIL_HOOKLIKE_REVERT + 1))
        RND_PRICE_LIMIT_STREAK=0
      else
        RND_FAIL_OTHER=$((RND_FAIL_OTHER + 1))
        RND_PRICE_LIMIT_STREAK=0
      fi
      ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
      random_append_tx_log "${ts}" "${RND_ATTEMPTS}" "${label}" "failed" "${side}" "${amount}" "${tx_reason}" "-" "${fee_before}" "-" "${idx_before}" "-" "${dir_before}" "-" "${tx_out}"
    fi

    RND_PHASE="wait"
    if (( RND_NEXT_WAIT_OVERRIDE > 0 )); then
      wait_seconds="${RND_NEXT_WAIT_OVERRIDE}"
      wait_reason="price-limit-retry"
      RND_NEXT_WAIT_OVERRIDE=0
    else
      pick_wait_with_case_bias "${state_before}"
      wait_seconds="${RND_WAIT_PICK_SECONDS}"
      wait_reason="${RND_WAIT_PICK_REASON}"
    fi
    RND_LAST_WAIT_STRATEGY="${wait_reason}"
    random_refresh_runtime_metrics
    random_write_stats_snapshot
    random_render_dashboard
    random_sleep_with_dashboard "${wait_seconds}"
  done
}

run_random_mode
exit 0
