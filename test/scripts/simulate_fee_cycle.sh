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
# - cycle  : deterministic fee cycle validation:
#            1) 400 -> 900 (UP)
#            2) reversal-lock check (still 900)
#            3) 900 -> 400 (DOWN)
# - random : long-running random swaps for live traffic simulation.
#
# The script expects an already deployed hook + pool + swap helper.
#
# Usage:
#   ./test/scripts/simulate_fee_cycle.sh --chain sepolia --mode random --broadcast
#   ./test/scripts/simulate_fee_cycle.sh --chain arbitrum --mode cycle --broadcast
#   ./test/scripts/simulate_fee_cycle.sh --chain arbitrum --swap-test-address <addr> --broadcast
#
# Optional env overrides:
#   SWAP_TEST_ADDRESS, STATE_VIEW_ADDRESS, HIGH_SWAP_AMOUNT, LOW_SWAP_AMOUNT,
#   RANDOM_MIN_AMOUNT, RANDOM_MAX_AMOUNT
#
# Notes:
# - This script sends real transactions (broadcast only).
# - Designed for local/sepolia/prod flows in this repository.

CHAIN="local"
MODE="cycle"
RPC_URL=""
SWAP_TEST_ADDRESS="${SWAP_TEST_ADDRESS:-}"
STATE_VIEW_ADDRESS="${STATE_VIEW_ADDRESS:-}"
HOOK_ADDRESS_OVERRIDE=""
# Optional fixed amounts; if empty, the script computes adaptive amounts from EMA.
HIGH_SWAP_AMOUNT="${HIGH_SWAP_AMOUNT:-}"
LOW_SWAP_AMOUNT="${LOW_SWAP_AMOUNT:-}"
POLL_SECONDS=20
# Random/cases mode options.
MIN_WAIT_SECONDS=0
MAX_WAIT_SECONDS=0
RANDOM_MIN_AMOUNT="${RANDOM_MIN_AMOUNT:-}"
RANDOM_MAX_AMOUNT="${RANDOM_MAX_AMOUNT:-}"
DURATION_SECONDS=0
STATS_FILE=""
NO_LIVE=0
CASE_DRIVEN=0
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
HOOK_DUST_CLOSE_VOL_USD6=2000000
MAX_BALANCE_SPEND_PCT=20
BALANCE_ERROR_FORCE_ATTEMPTS=8
NATIVE_GAS_SYMBOL="${NATIVE_GAS_SYMBOL:-ETH}"
RANDOM_SOFT_MIN_AMOUNT=1000000
RANDOM_SOFT_MAX_AMOUNT=8000000

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
  ./test/scripts/simulate_fee_cycle.sh --chain <chain> [options]

Options:
  --mode <cycle|random|cases>  Mode to run (default: cycle).
  --rpc-url <url>              Override RPC URL.
  --swap-test-address <addr>   Swap helper contract address.
  --state-view-address <addr>  Optional StateView address for slot0 checks.
  --hook-address <addr>        Override HOOK_ADDRESS.
  --high-amount <int>          Fixed amountSpecified for U1_HIGH (optional).
  --low-amount <int>           Fixed amountSpecified for LOW steps (optional).
  --poll-seconds <int>         Poll interval while waiting period close (default: 20).
  --min-wait-seconds <int>     Random/cases mode: minimum pause after swap (default: 0).
  --max-wait-seconds <int>     Random/cases mode: maximum pause after swap (default: 0).
  --min-amount <int>           Random mode: force minimum random amountSpecified.
  --max-amount <int>           Random mode: force maximum random amountSpecified.
  --duration-seconds <int>     Random mode: stop after N seconds (0 = infinite).
  --stats-file <path>          Random mode: where to persist stats snapshot.
  --no-live                    Random mode: disable terminal dashboard redraw.
  (Random mode auto-enables anti-drift arb guard with built-in defaults.)
  (Random mode auto-biases traffic/waits toward hook test-case coverage.)
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
    --poll-seconds)
      POLL_SECONDS="${2:-}"
      if [[ -z "${POLL_SECONDS}" ]]; then echo "ERROR: --poll-seconds requires a value"; exit 1; fi
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
  cycle|random|cases) ;;
  *)
    echo "ERROR: unsupported --mode=${MODE}; expected cycle, random or cases."
    exit 1
    ;;
esac

if [[ "${MODE}" == "random" ]]; then
  CASE_DRIVEN=1
fi
if [[ "${MODE}" == "cases" ]]; then
  CASE_DRIVEN=1
  MODE="random"
fi

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
if [[ "${TOKEN0_DECIMALS_RAW}" =~ ^[0-9]+$ ]]; then
  TOKEN0_DECIMALS="${TOKEN0_DECIMALS_RAW}"
else
  TOKEN0_DECIMALS="${STABLE_DECIMALS}"
fi
if [[ "${TOKEN1_DECIMALS_RAW}" =~ ^[0-9]+$ ]]; then
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

HOOK_INITIAL_IDX="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "initialFeeIdx()(uint8)" | awk '{print $1}')"
HOOK_PAUSE_IDX="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "pauseFeeIdx()(uint8)" | awk '{print $1}')"
HOOK_FLOOR_IDX="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "floorIdx()(uint8)" | awk '{print $1}')"
HOOK_CAP_IDX="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "capIdx()(uint8)" | awk '{print $1}')"
HOOK_EMA_PERIODS="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "emaPeriods()(uint8)" | awk '{print $1}')"
HOOK_DEADBAND_BPS="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "deadbandBps()(uint16)" | awk '{print $1}')"
HOOK_LULL_RESET_SECONDS="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "lullResetSeconds()(uint32)" | awk '{print $1}')"
if ! [[ "${HOOK_INITIAL_IDX}" =~ ^[0-9]+$ && "${HOOK_PAUSE_IDX}" =~ ^[0-9]+$ && "${HOOK_FLOOR_IDX}" =~ ^[0-9]+$ && "${HOOK_CAP_IDX}" =~ ^[0-9]+$ && "${HOOK_EMA_PERIODS}" =~ ^[0-9]+$ && "${HOOK_DEADBAND_BPS}" =~ ^[0-9]+$ && "${HOOK_LULL_RESET_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: failed to read hook runtime params."
  exit 1
fi
declare -a HOOK_FEE_TIER_VALUES=(0 0 0 0 0 0 0)
for i in 0 1 2 3 4 5 6; do
  tier_value="$(cast_rpc call --rpc-url "${RPC_URL}" "${HOOK_ADDRESS}" "feeTiers(uint256)(uint24)" "${i}" | awk '{print $1}')"
  if ! [[ "${tier_value}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: failed to read feeTiers(${i}) from hook."
    exit 1
  fi
  HOOK_FEE_TIER_VALUES[$i]="${tier_value}"
done

now_ts() {
  cast_rpc block --rpc-url "${RPC_URL}" latest --field timestamp | awk '{print $1}'
}

read_token_symbol() {
  local token="$1"
  local fallback="$2"
  local out
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
  local zero_for_one="$3"
  local out tx send_attempt
  local params
  local sqrt_price_limit

  if [[ "${zero_for_one}" == "true" ]]; then
    sqrt_price_limit="${SQRT_PRICE_LIMIT_X96_ZFO}"
  else
    sqrt_price_limit="${SQRT_PRICE_LIMIT_X96_OZF}"
  fi
  params="(${zero_for_one},-${amount},${sqrt_price_limit})"
  if [[ "${MODE}" != "random" ]]; then
    echo "==> ${label}: swap amountSpecified=${amount} zeroForOne=${zero_for_one}" >&2
  fi
  send_attempt=0
  while true; do
    if out="$(cast_rpc send --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" "${SWAP_TEST_ADDRESS}" "${SWAP_SIG}" "${POOL_KEY}" "${params}" "${TEST_SETTINGS}" 0x 2>&1)"; then
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

amount_for_target_vol() {
  local target_vol="$1"
  local amount
  local max_amount
  local bal_raw
  # For zeroForOne exact-input swaps in this pool, amountSpecified is token0 (USDC, 6 decimals).
  # Approximation: ~2 USDC per 1 USD of target period volume.
  amount=$(( (target_vol + 1) / 2 ))
  # Keep volume meaningful in USD6 units to avoid dust-only closes.
  if (( amount < 250000 )); then amount=250000; fi
  if bal_raw="$(cast_rpc call --rpc-url "${RPC_URL}" "${CURRENCY0}" "balanceOf(address)(uint256)" "${DEPLOYER}" 2>/dev/null | awk '{print $1}')"; then
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
  if bal_raw="$(cast_rpc call --rpc-url "${RPC_URL}" "${token_in}" "balanceOf(address)(uint256)" "${DEPLOYER}" 2>/dev/null | awk '{print $1}')"; then
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
  local bal_raw max_case min_case
  if ! bal_raw="$(cast_rpc call --rpc-url "${RPC_URL}" "${CURRENCY0}" "balanceOf(address)(uint256)" "${DEPLOYER}" 2>/dev/null | awk '{print $1}')"; then
    return 1
  fi
  if ! [[ "${bal_raw}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  max_case=$(( bal_raw * 15 / 100 ))
  if (( bal_raw > 0 && max_case <= 0 )); then
    max_case="${bal_raw}"
  fi
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
TC_ZERO_EMA_DOWN_OBS=0
TC_ZERO_EMA_DOWN_PASS=0
TC_ZERO_EMA_DOWN_FAIL=0

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
  local case_rev case_deadband case_cap case_floor case_zero_ema

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
    TC_LULL_RESET_OBS=$((TC_LULL_RESET_OBS + 1))
    if (( a_idx == HOOK_INITIAL_IDX && a_ema == 0 && a_dir == 0 )); then
      TC_LULL_RESET_PASS=$((TC_LULL_RESET_PASS + 1))
    else
      TC_LULL_RESET_FAIL=$((TC_LULL_RESET_FAIL + 1))
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
  case_zero_ema=0
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
    if (( b_ema == 0 && close_eff == 0 && b_idx > HOOK_FLOOR_IDX )); then
      case_zero_ema=1
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

  if (( case_rev == 1 )); then
    TC_REVERSAL_LOCK_OBS=$((TC_REVERSAL_LOCK_OBS + 1))
    if (( model_ok == 1 )); then
      TC_REVERSAL_LOCK_PASS=$((TC_REVERSAL_LOCK_PASS + 1))
    else
      TC_REVERSAL_LOCK_FAIL=$((TC_REVERSAL_LOCK_FAIL + 1))
    fi
  fi
  if (( case_deadband == 1 )); then
    TC_DEADBAND_OBS=$((TC_DEADBAND_OBS + 1))
    if (( model_ok == 1 )); then
      TC_DEADBAND_PASS=$((TC_DEADBAND_PASS + 1))
    else
      TC_DEADBAND_FAIL=$((TC_DEADBAND_FAIL + 1))
    fi
  fi
  if (( case_cap == 1 )); then
    TC_CAP_CLAMP_OBS=$((TC_CAP_CLAMP_OBS + 1))
    if (( model_ok == 1 )); then
      TC_CAP_CLAMP_PASS=$((TC_CAP_CLAMP_PASS + 1))
    else
      TC_CAP_CLAMP_FAIL=$((TC_CAP_CLAMP_FAIL + 1))
    fi
  fi
  if (( case_floor == 1 )); then
    TC_FLOOR_CLAMP_OBS=$((TC_FLOOR_CLAMP_OBS + 1))
    if (( model_ok == 1 )); then
      TC_FLOOR_CLAMP_PASS=$((TC_FLOOR_CLAMP_PASS + 1))
    else
      TC_FLOOR_CLAMP_FAIL=$((TC_FLOOR_CLAMP_FAIL + 1))
    fi
  fi
  if (( case_zero_ema == 1 )); then
    TC_ZERO_EMA_DOWN_OBS=$((TC_ZERO_EMA_DOWN_OBS + 1))
    if (( model_ok == 1 )); then
      TC_ZERO_EMA_DOWN_PASS=$((TC_ZERO_EMA_DOWN_PASS + 1))
    else
      TC_ZERO_EMA_DOWN_FAIL=$((TC_ZERO_EMA_DOWN_FAIL + 1))
    fi
  fi
}

print_hook_case_row() {
  local case_id="$1"
  local label="$2"
  local obs="$3"
  local pass="$4"
  local fail="$5"
  printf "  %-6s %-34s | %-7s | %5s | %5s | %5s\n" \
    "${case_id}" "${label}" "$(tc_status "${pass}" "${fail}")" "${obs}" "${pass}" "${fail}"
}

render_hook_cases_table() {
  echo "Hook test-cases (live mapping):"
  echo "  ------------------------------------------+---------+-------+-------+-------"
  printf "  %-6s %-34s | %-7s | %5s | %5s | %5s\n" "ID" "Case" "Status" "Obs" "Pass" "Fail"
  echo "  ------------------------------------------+---------+-------+-------+-------"
  print_hook_case_row "INV-1" "feeIdx in [floor,cap]" "${TC_INV_BOUNDS_OBS}" "${TC_INV_BOUNDS_PASS}" "${TC_INV_BOUNDS_FAIL}"
  print_hook_case_row "INV-2" "currentFee matches tier" "${TC_INV_FEE_TIER_OBS}" "${TC_INV_FEE_TIER_PASS}" "${TC_INV_FEE_TIER_FAIL}"
  print_hook_case_row "RT-1" "close transition model" "${TC_MODEL_CLOSE_OBS}" "${TC_MODEL_CLOSE_PASS}" "${TC_MODEL_CLOSE_FAIL}"
  print_hook_case_row "FZ-1" "reversal lock" "${TC_REVERSAL_LOCK_OBS}" "${TC_REVERSAL_LOCK_PASS}" "${TC_REVERSAL_LOCK_FAIL}"
  print_hook_case_row "FZ-2" "deadband no-change" "${TC_DEADBAND_OBS}" "${TC_DEADBAND_PASS}" "${TC_DEADBAND_FAIL}"
  print_hook_case_row "FZ-3" "lull reset semantics" "${TC_LULL_RESET_OBS}" "${TC_LULL_RESET_PASS}" "${TC_LULL_RESET_FAIL}"
  print_hook_case_row "ED-1" "cap clamp" "${TC_CAP_CLAMP_OBS}" "${TC_CAP_CLAMP_PASS}" "${TC_CAP_CLAMP_FAIL}"
  print_hook_case_row "ED-2" "floor clamp" "${TC_FLOOR_CLAMP_OBS}" "${TC_FLOOR_CLAMP_PASS}" "${TC_FLOOR_CLAMP_FAIL}"
  print_hook_case_row "ED-3" "zero-ema zero-close down" "${TC_ZERO_EMA_DOWN_OBS}" "${TC_ZERO_EMA_DOWN_PASS}" "${TC_ZERO_EMA_DOWN_FAIL}"
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

  if (( CASE_DRIVEN == 1 )); then
    if (( TC_CAP_CLAMP_PASS == 0 )); then
      side="zeroForOne"
      if (( idx < HOOK_CAP_IDX )); then
        amount="$(random_between "${high_lo}" "${max_amount}")"
        reason="tc-cap-up"
      else
        amount="$(random_between "${mid_target}" "${max_amount}")"
        reason="tc-cap-clamp-probe"
      fi
    elif (( TC_FLOOR_CLAMP_PASS == 0 )); then
      side="oneForZero"
      if (( idx > HOOK_FLOOR_IDX )); then
        amount="$(random_between "${min_amount}" "${low_hi}")"
        reason="tc-floor-down"
      else
        amount="$(random_between "${min_amount}" "${mid_lo}")"
        reason="tc-floor-clamp-probe"
      fi
    elif (( TC_REVERSAL_LOCK_PASS == 0 )); then
      if (( dir == 1 )); then
        side="oneForZero"
        amount="$(random_between "${min_amount}" "${low_hi}")"
        reason="tc-reversal-block-up"
      elif (( dir == 2 )); then
        side="zeroForOne"
        amount="$(random_between "${high_lo}" "${max_amount}")"
        reason="tc-reversal-block-down"
      elif (( idx <= HOOK_FLOOR_IDX + 1 )); then
        side="zeroForOne"
        amount="$(random_between "${high_lo}" "${max_amount}")"
        reason="tc-reversal-seed-up"
      else
        side="oneForZero"
        amount="$(random_between "${min_amount}" "${low_hi}")"
        reason="tc-reversal-seed-down"
      fi
    elif (( TC_DEADBAND_PASS == 0 && ema > 0 )); then
      if (( dir == 2 )); then
        side="oneForZero"
      else
        side="zeroForOne"
      fi
      amount="$(random_between "${mid_lo}" "${mid_hi}")"
      reason="tc-deadband-probe"
    elif (( TC_ZERO_EMA_DOWN_PASS == 0 && ema == 0 && idx > HOOK_FLOOR_IDX )); then
      side="zeroForOne"
      amount="$(random_between "${min_amount}" "${low_hi}")"
      reason="tc-zero-ema-down"
    else
      if (( idx <= HOOK_FLOOR_IDX )); then
        side="zeroForOne"
        amount="$(random_between "${high_lo}" "${max_amount}")"
        reason="tc-cycle-up"
      elif (( idx >= HOOK_CAP_IDX )); then
        side="oneForZero"
        amount="$(random_between "${min_amount}" "${low_hi}")"
        reason="tc-cycle-down"
      elif (( dir == 1 )); then
        side="oneForZero"
        amount="$(random_between "${min_amount}" "${mid_lo}")"
        reason="tc-cycle-reverse-down"
      else
        side="zeroForOne"
        amount="$(random_between "${mid_lo}" "${mid_hi}")"
        reason="tc-cycle-reverse-up"
      fi
    fi
  else
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
      echo "${wait}|${reason}"
      return
    fi
  fi

  if (( wait < MIN_WAIT_SECONDS )); then wait="${MIN_WAIT_SECONDS}"; fi
  if (( wait > PERIOD_SECONDS + 20 )) && [[ "${reason}" != "case-lull-reset-probe" ]]; then
    wait=$((PERIOD_SECONDS + 20))
  fi
  echo "${wait}|${reason}"
}

random_write_stats_snapshot() {
  local now elapsed avg_amount success_pct
  local current_tier floor_tier cap_tier initial_tier pause_tier
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
  initial_tier="$(fee_tier_for_idx "${HOOK_INITIAL_IDX}")"
  pause_tier="$(fee_tier_for_idx "${HOOK_PAUSE_IDX}")"
  mode_label="random"
  if (( CASE_DRIVEN == 1 )); then
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
    echo "tc_edges_zero_ema_zero_close_down_status=$(tc_status "${TC_ZERO_EMA_DOWN_PASS}" "${TC_ZERO_EMA_DOWN_FAIL}")"
    echo "tc_edges_zero_ema_zero_close_down_obs=${TC_ZERO_EMA_DOWN_OBS}"
    echo "tc_edges_zero_ema_zero_close_down_pass=${TC_ZERO_EMA_DOWN_PASS}"
    echo "tc_edges_zero_ema_zero_close_down_fail=${TC_ZERO_EMA_DOWN_FAIL}"
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
    echo "fee_level_initial_idx=${HOOK_INITIAL_IDX}"
    echo "fee_level_initial_tier_bips=${initial_tier}"
    echo "fee_level_pause_idx=${HOOK_PAUSE_IDX}"
    echo "fee_level_pause_tier_bips=${pause_tier}"
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
  local current_tier floor_tier cap_tier initial_tier pause_tier
  local current_pct floor_pct cap_pct initial_pct pause_pct
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
  initial_tier="$(fee_tier_for_idx "${HOOK_INITIAL_IDX}")"
  pause_tier="$(fee_tier_for_idx "${HOOK_PAUSE_IDX}")"
  current_pct="$(fee_bips_to_percent "${current_tier}")"
  floor_pct="$(fee_bips_to_percent "${floor_tier}")"
  cap_pct="$(fee_bips_to_percent "${cap_tier}")"
  initial_pct="$(fee_bips_to_percent "${initial_tier}")"
  pause_pct="$(fee_bips_to_percent "${pause_tier}")"
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
  if (( CASE_DRIVEN == 1 )); then
    mode_label="cases"
  fi
  if [[ -t 1 && "${NO_LIVE}" -eq 0 ]]; then
    printf '\033[2J\033[H'
  fi
  echo "===== Dynamic Fee Traffic Simulator ====="
  echo "Mode: ${mode_label} | Chain: ${CHAIN} | Status: ${RND_REASON} | Runtime: $(fmt_duration "${elapsed}")"
  echo
  echo "Hook:"
  echo "  Address: ${HOOK_ADDRESS}"
  echo "  Deploy: floor=${floor_pct} (${floor_tier}, i${HOOK_FLOOR_IDX}) | initial=${initial_pct} (${initial_tier}, i${HOOK_INITIAL_IDX}) | pause=${pause_pct} (${pause_tier}, i${HOOK_PAUSE_IDX}) | cap=${cap_pct} (${cap_tier}, i${HOOK_CAP_IDX})"
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
  echo "Execution: tx=${attempts_fmt} | ok=${success_fmt} fail=${failed_fmt} | rpcErr=${rpc_errors_fmt} | skipped(noBalance)=${skip_balance_fmt} | successRate=${success_pct}%"
  echo "Directions: zeroForOne=${zfo_fmt} | oneForZero=${ozf_fmt}"
  echo
  render_hook_cases_table
  echo "  Note: INV-* are on-chain invariants; RT/FZ/ED are script-model checks vs on-chain state."
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
      RND_REASON="completed"
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
  local amount_pick amount_pick_rest planned_side bounds_pick wait_pick wait_reason
  local attempt_no side_roll
  local side zero_for_one tx_hash tx_out tx_reason
  local econ_metrics econ_vol_usd6 econ_vol0 econ_vol1 econ_fee0 econ_fee1 econ_fee_usd6
  local bal0_raw bal1_raw
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
  evaluate_hook_invariants "${RND_CURRENT_FEE}" "${RND_CURRENT_IDX}"
  random_refresh_runtime_metrics
  RND_START_TS="$(date +%s)"
  RND_START_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  RND_LAST_UPDATE_ISO="${RND_START_ISO}"
  RND_LAST_TX_REASON="-"

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

  trap random_request_stop INT TERM
  trap random_finalize EXIT

  random_write_stats_snapshot
  random_render_dashboard

  while (( RND_STOP_REQUESTED == 0 )); do
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
    RND_CURRENT_FEE="${fee_before}"
    RND_CURRENT_PV="${pv_before}"
    RND_CURRENT_EMA="${ema_before}"
    RND_CURRENT_IDX="${idx_before}"
    RND_CURRENT_DIR="${dir_before}"
    evaluate_hook_invariants "${fee_before}" "${idx_before}"
    random_refresh_runtime_metrics

    bounds_pick=""
    if [[ -n "${RANDOM_MIN_AMOUNT}" ]]; then
      min_amount="${RANDOM_MIN_AMOUNT}"
    elif (( CASE_DRIVEN == 1 )); then
      if bounds_pick="$(pick_case_amount_bounds 2>/dev/null)"; then
        min_amount="${bounds_pick%%|*}"
      else
        min_amount=100000
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
    elif (( CASE_DRIVEN == 1 )); then
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
    if (( min_amount <= 0 )); then min_amount=100; fi
    if [[ -z "${RANDOM_MIN_AMOUNT}" ]] && (( max_amount >= RANDOM_SOFT_MIN_AMOUNT && min_amount < RANDOM_SOFT_MIN_AMOUNT )); then
      min_amount="${RANDOM_SOFT_MIN_AMOUNT}"
    fi
    if [[ -z "${RANDOM_MAX_AMOUNT}" ]] && (( max_amount > RANDOM_SOFT_MAX_AMOUNT )); then
      max_amount="${RANDOM_SOFT_MAX_AMOUNT}"
    fi
    if (( max_amount < min_amount )); then max_amount="${min_amount}"; fi
    amount_pick="$(pick_amount_with_case_bias "${min_amount}" "${max_amount}" "${state_before}")"
    amount="${amount_pick%%|*}"
    amount_pick_rest="${amount_pick#*|}"
    tx_reason="${amount_pick_rest%%|*}"
    planned_side="${amount_pick_rest#*|}"
    if [[ "${planned_side}" == "${amount_pick_rest}" ]]; then
      planned_side=""
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
      elif (( RND_ARB_ENABLED == 0 && RND_SIDE_STREAK >= ARB_GUARD_STREAK_LIMIT )) && [[ "${RND_LAST_SIDE_SEEN}" != "-" ]]; then
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

    if bal0_raw="$(read_token_balance "${CURRENCY0}" 2>/dev/null)" && bal1_raw="$(read_token_balance "${CURRENCY1}" 2>/dev/null)"; then
      # If one input side is nearly depleted, force a reseed swap from the opposite side.
      if [[ "${side}" == "zeroForOne" && "${bal0_raw}" =~ ^[0-9]+$ && "${bal0_raw}" -lt 1000000 ]]; then
        if (( attempt_no < RND_BLOCK_OZF_UNTIL )); then
          RND_BLOCK_OZF_UNTIL=0
          RND_BALANCE_UNBLOCK_FORCED=$((RND_BALANCE_UNBLOCK_FORCED + 1))
        fi
        side="oneForZero"
        zero_for_one=false
        tx_reason="${tx_reason}+balance-reseed-usdc"
      elif [[ "${side}" == "oneForZero" && "${bal1_raw}" =~ ^[0-9]+$ && "${bal1_raw}" -lt 1000000000000000 ]]; then
        if (( attempt_no < RND_BLOCK_ZFO_UNTIL )); then
          RND_BLOCK_ZFO_UNTIL=0
          RND_BALANCE_UNBLOCK_FORCED=$((RND_BALANCE_UNBLOCK_FORCED + 1))
        fi
        side="zeroForOne"
        zero_for_one=true
        tx_reason="${tx_reason}+balance-reseed-weth"
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
        RND_CURRENT_FEE="${fee_after}"
        RND_CURRENT_PV="${pv_after}"
        RND_CURRENT_EMA="${ema_after}"
        RND_CURRENT_IDX="${idx_after}"
        RND_CURRENT_DIR="${dir_after}"
        evaluate_hook_invariants "${fee_after}" "${idx_after}"
        evaluate_hook_transition_cases "${state_before}" "${state_after}"
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
        RND_LAST_ERROR="post-send read_state failed: $(sanitize_inline "${state_after}")"
        fee_after="${fee_before}"
        idx_after="${idx_before}"
        dir_after="${dir_before}"
      fi
      if (( fee_after > fee_before )); then
        RND_FEE_UP=$((RND_FEE_UP + 1))
      elif (( fee_after < fee_before )); then
        RND_FEE_DOWN=$((RND_FEE_DOWN + 1))
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
      wait_pick="$(pick_wait_with_case_bias "${state_before}")"
      wait_seconds="${wait_pick%%|*}"
      wait_reason="${wait_pick#*|}"
    fi
    RND_LAST_WAIT_STRATEGY="${wait_reason}"
    random_refresh_runtime_metrics
    random_write_stats_snapshot
    random_render_dashboard
    random_sleep_with_dashboard "${wait_seconds}"
  done
}

if [[ "${MODE}" == "random" ]]; then
  run_random_mode
  exit 0
fi

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
TX_U1="$(run_swap_step "U1_HIGH" "${AMT_U1}" "true")"
S_AFTER_U1="$(read_state)"
append_step_line "U1_HIGH" "${AMT_U1}" "${TX_U1}" "${S_BEFORE}" "${S_AFTER_U1}"

wait_for_next_period "U2" "${S_AFTER_U1}"
S_BEFORE="$(read_state)"
AMT_U2="$(pick_low_amount "${S_BEFORE}")"
TX_U2="$(run_swap_step "U2_LOW" "${AMT_U2}" "true")"
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
TX_D1="$(run_swap_step "D1_LOW_LOCK" "${AMT_D1}" "true")"
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
TX_D2="$(run_swap_step "D2_LOW_DOWN" "${AMT_D2}" "true")"
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
echo "Pool: ${POOL_ID:-n/a}"
echo "Swap helper: ${SWAP_TEST_ADDRESS}"
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
