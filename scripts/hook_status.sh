#!/usr/bin/env bash
set -euo pipefail

# Print on-chain health/status for a deployed VolumeDynamicFeeHook + bound v4 pool.
#
# Usage examples:
#   ./scripts/hook_status.sh --chain optimism
#   ./scripts/hook_status.sh --chain optimism --watch-seconds 15
#   ./scripts/hook_status.sh --chain optimism --hook-address 0x... --state-view-address 0x...

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

usage() {
  cat <<'EOF'
Usage:
  ./scripts/hook_status.sh --chain <chain> [--rpc-url <url>] [--hook-address <addr>] [--state-view-address <addr>] [--watch-seconds <int>]

Options:
  --chain <chain>               Chain config name (e.g. optimism, sepolia, arbitrum, local).
  --rpc-url <url>               Override RPC URL from config.
  --hook-address <addr>         Override hook address. If empty, reads deploy artifact.
  --state-view-address <addr>   Optional StateView address. If empty, tries broadcast artifacts.
  --watch-seconds <int>         Repeat status every N seconds (0 = one shot, default 0).
  -h, --help                    Show help.
EOF
}

first_token() { printf '%s\n' "${1:-}" | sed -n '1p' | awk '{print $1}'; }

rpc_eth_call_result() {
  local to="$1"
  local data="$2"
  local payload resp attempt
  payload="$(printf '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"%s","data":"%s"},"latest"]}' "${to}" "${data}")"
  for attempt in 1 2 3; do
    resp="$(curl -sS --connect-timeout 3 --max-time 8 -H 'content-type: application/json' --data "${payload}" "${RPC_URL}" 2>/dev/null || true)"
    if [[ -z "${resp}" ]]; then
      sleep 1
      continue
    fi
    if python3 - "${resp}" <<'PY'
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    print("")
    raise SystemExit(1)
if isinstance(data, dict) and isinstance(data.get("result"), str):
    print(data["result"])
    raise SystemExit(0)
print("")
raise SystemExit(1)
PY
    then
      return 0
    fi
    sleep 1
  done
  return 1
}

rpc_get_code() {
  local addr="$1"
  local payload resp attempt
  payload="$(printf '{"jsonrpc":"2.0","id":1,"method":"eth_getCode","params":["%s","latest"]}' "${addr}")"
  for attempt in 1 2 3; do
    resp="$(curl -sS --connect-timeout 3 --max-time 8 -H 'content-type: application/json' --data "${payload}" "${RPC_URL}" 2>/dev/null || true)"
    if [[ -z "${resp}" ]]; then
      sleep 1
      continue
    fi
    if python3 - "${resp}" <<'PY'
import json
import sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    print("")
    raise SystemExit(1)
if isinstance(data, dict) and isinstance(data.get("result"), str):
    print(data["result"])
    raise SystemExit(0)
print("")
raise SystemExit(1)
PY
    then
      return 0
    fi
    sleep 1
  done
  return 1
}

try_cast_call() {
  local to="$1"
  local sig="$2"
  shift 2

  local input_sig calldata raw decoded
  input_sig="$(printf '%s' "${sig}" | sed -E 's/\)\(.*$/)/')"
  if [[ -z "${input_sig}" ]]; then
    return 1
  fi
  if ! calldata="$(cast calldata "${input_sig}" "$@" 2>/dev/null)"; then
    return 1
  fi
  if [[ -z "${calldata}" ]]; then
    return 1
  fi
  if ! raw="$(rpc_eth_call_result "${to}" "${calldata}")"; then
    return 1
  fi
  if [[ -z "${raw}" || "${raw}" == "0x" ]]; then
    return 1
  fi
  if ! decoded="$(cast decode-abi "${sig}" "${raw}" 2>/dev/null)"; then
    return 1
  fi
  printf '%s\n' "${decoded}"
}

try_get_code() {
  local addr="$1"
  rpc_get_code "${addr}"
}

find_hook_in_json() {
  local path="$1"
  python3 - "${path}" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

def find_addr(x):
    if isinstance(x, str) and x.startswith("0x") and len(x) == 42:
        return x
    if isinstance(x, dict):
        for k, v in x.items():
            if k.lower() in ("hook", "hook_address", "hookaddress"):
                if isinstance(v, str) and v.startswith("0x") and len(v) == 42:
                    return v
        for v in x.values():
            r = find_addr(v)
            if r:
                return r
    if isinstance(x, list):
        for v in x:
            r = find_addr(v)
            if r:
                return r
    return ""

print(find_addr(data))
PY
}

find_state_view_in_json() {
  local path="$1"
  python3 - "${path}" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

addr = ""
returns = data.get("returns") or {}
state = returns.get("state")
if isinstance(state, dict):
    value = state.get("value")
    if isinstance(value, str) and value.startswith("0x") and len(value) == 42:
        addr = value

if not addr:
    txs = data.get("transactions") or []
    if txs and isinstance(txs[0], dict):
        cand = txs[0].get("contractAddress")
        if isinstance(cand, str) and cand.startswith("0x") and len(cand) == 42:
            addr = cand

print(addr)
PY
}

chain_id_for_name() {
  case "$(lower "${1:-}")" in
    local) echo "31337" ;;
    sepolia) echo "11155111" ;;
    ethereum|mainnet) echo "1" ;;
    optimism) echo "10" ;;
    arbitrum) echo "42161" ;;
    base) echo "8453" ;;
    polygon) echo "137" ;;
    *) echo "" ;;
  esac
}

human_price_from_sqrt_x96() {
  local sqrt_x96="$1"
  local dec0="$2"
  local dec1="$3"
  local stable_is_token1="$4"
  python3 - "${sqrt_x96}" "${dec0}" "${dec1}" "${stable_is_token1}" <<'PY'
from decimal import Decimal, getcontext
import sys
getcontext().prec = 80
sqrt_x96 = Decimal(sys.argv[1])
dec0 = int(sys.argv[2])
dec1 = int(sys.argv[3])
stable_is_token1 = (sys.argv[4] == "1")

# token1 per token0
ratio_t1_per_t0 = (sqrt_x96 * sqrt_x96) / (Decimal(2) ** 192)
ratio_t1_per_t0 *= Decimal(10) ** (dec0 - dec1)

if stable_is_token1:
    print(ratio_t1_per_t0)
else:
    if ratio_t1_per_t0 == 0:
        print("0")
    else:
        print(Decimal(1) / ratio_t1_per_t0)
PY
}

CHAIN=""
RPC_URL_CLI=""
HOOK_ADDRESS_CLI=""
STATE_VIEW_ADDRESS_CLI=""
WATCH_SECONDS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --rpc-url) RPC_URL_CLI="${2:-}"; shift 2 ;;
    --hook-address) HOOK_ADDRESS_CLI="${2:-}"; shift 2 ;;
    --state-view-address) STATE_VIEW_ADDRESS_CLI="${2:-}"; shift 2 ;;
    --watch-seconds) WATCH_SECONDS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

CHAIN="$(lower "${CHAIN:-}")"
if [[ -z "${CHAIN}" ]]; then
  echo "ERROR: --chain is required" >&2
  usage
  exit 1
fi
if ! [[ "${WATCH_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --watch-seconds must be a non-negative integer" >&2
  exit 1
fi

if [[ -f "./.env" ]]; then
  # shellcheck disable=SC1091
  source "./.env"
fi

CFG="./config/hook.${CHAIN}.conf"
if [[ "${CHAIN}" == "local" ]]; then
  CFG="./config/hook.local.conf"
fi
if [[ ! -f "${CFG}" ]]; then
  echo "ERROR: config not found: ${CFG}" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "${CFG}"
set +a

RPC_URL="${RPC_URL_CLI:-${RPC_URL:-}}"
if [[ -z "${RPC_URL:-}" ]]; then
  echo "ERROR: RPC_URL missing (config or --rpc-url)" >&2
  exit 1
fi

HOOK_ADDRESS="${HOOK_ADDRESS_CLI:-${HOOK_ADDRESS:-}}"
if [[ -z "${HOOK_ADDRESS}" ]]; then
  DEPLOY_JSON="./scripts/out/deploy.${CHAIN}.json"
  if [[ "${CHAIN}" == "local" ]]; then
    DEPLOY_JSON="./scripts/out/deploy.local.json"
  fi
  if [[ -f "${DEPLOY_JSON}" ]]; then
    HOOK_ADDRESS="$(find_hook_in_json "${DEPLOY_JSON}")"
  fi
fi
if [[ -z "${HOOK_ADDRESS}" ]]; then
  echo "ERROR: HOOK_ADDRESS not provided and could not be read from deploy artifact" >&2
  exit 1
fi

required=(POOL_MANAGER VOLATILE STABLE TICK_SPACING STABLE_DECIMALS)
for k in "${required[@]}"; do
  if [[ -z "${!k:-}" ]]; then
    echo "ERROR: missing ${k} in ${CFG}" >&2
    exit 1
  fi
done

CURRENCY0="${VOLATILE}"
CURRENCY1="${STABLE}"
if [[ "$(lower "${CURRENCY0}")" > "$(lower "${CURRENCY1}")" ]]; then
  T="${CURRENCY0}"
  CURRENCY0="${CURRENCY1}"
  CURRENCY1="${T}"
fi

DYNAMIC_FEE_FLAG=8388608
POOL_KEY="(${CURRENCY0},${CURRENCY1},${DYNAMIC_FEE_FLAG},${TICK_SPACING},${HOOK_ADDRESS})"
set -f
POOL_KEY_ENC="$(cast abi-encode 'f((address,address,uint24,int24,address))' "${POOL_KEY}")"
set +f
POOL_ID="$(cast keccak "${POOL_KEY_ENC}")"

CHAIN_ID="$(chain_id_for_name "${CHAIN}")"
if [[ -z "${CHAIN_ID}" ]]; then
  echo "WARN: unknown chain '${CHAIN}', could not infer chain id for StateView artifact lookup." >&2
fi

STATE_VIEW_ADDRESS="${STATE_VIEW_ADDRESS_CLI:-}"
if [[ -z "${STATE_VIEW_ADDRESS}" && -n "${CHAIN_ID}" ]]; then
  sv_paths=(
    "./scripts/out/broadcast/DeployStateView.s.sol/${CHAIN_ID}/run-latest.json"
    "./lib/v4-periphery/broadcast/DeployStateView.s.sol/${CHAIN_ID}/run-latest.json"
  )
  for p in "${sv_paths[@]}"; do
    if [[ -f "${p}" ]]; then
      STATE_VIEW_ADDRESS="$(find_state_view_in_json "${p}")"
      if [[ -n "${STATE_VIEW_ADDRESS}" ]]; then
        break
      fi
    fi
  done
fi

if [[ -n "${STATE_VIEW_ADDRESS}" ]]; then
  sv_code="$(try_get_code "${STATE_VIEW_ADDRESS}" || true)"
  if [[ -z "${sv_code}" || "${sv_code}" == "0x" ]]; then
    STATE_VIEW_ADDRESS=""
  fi
fi

render_once() {
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local pool_currency0 pool_currency1 stable_currency pool_tick_spacing
  local initial_idx floor_idx cap_idx pause_idx
  local period_seconds ema_periods deadband_bps lull_reset_seconds guardian

  pool_currency0="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "poolCurrency0()(address)" || true)")"
  pool_currency1="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "poolCurrency1()(address)" || true)")"
  stable_currency="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "stableCurrency()(address)" || true)")"
  pool_tick_spacing="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "poolTickSpacing()(int24)" || true)")"

  initial_idx="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "initialFeeIdx()(uint8)" || true)")"
  floor_idx="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "floorIdx()(uint8)" || true)")"
  cap_idx="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "capIdx()(uint8)" || true)")"
  pause_idx="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "pauseFeeIdx()(uint8)" || true)")"
  period_seconds="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "periodSeconds()(uint32)" || true)")"
  ema_periods="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "emaPeriods()(uint8)" || true)")"
  deadband_bps="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "deadbandBps()(uint16)" || true)")"
  lull_reset_seconds="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "lullResetSeconds()(uint32)" || true)")"
  guardian="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "guardian()(address)" || true)")"

  local paused current_fee
  paused="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "isPaused()(bool)" || true)")"
  if cf="$(try_cast_call "${HOOK_ADDRESS}" "currentFeeBips()(uint24)" 2>/dev/null)"; then
    current_fee="$(first_token "${cf}")"
  else
    current_fee="NOT_INITIALIZED"
  fi

  local unpack_raw pv ema_vol period_start fee_idx last_dir
  unpack_raw="$(try_cast_call "${HOOK_ADDRESS}" "unpackedState()(uint64,uint96,uint64,uint8,uint8)" || true)"
  pv="$(printf '%s\n' "${unpack_raw}" | sed -n '1p' | awk '{print $1}')"
  ema_vol="$(printf '%s\n' "${unpack_raw}" | sed -n '2p' | awk '{print $1}')"
  period_start="$(printf '%s\n' "${unpack_raw}" | sed -n '3p' | awk '{print $1}')"
  fee_idx="$(printf '%s\n' "${unpack_raw}" | sed -n '4p' | awk '{print $1}')"
  last_dir="$(printf '%s\n' "${unpack_raw}" | sed -n '5p' | awk '{print $1}')"

  local tiers=()
  local i tier_val
  for i in 0 1 2 3 4 5 6; do
    tier_val="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "feeTiers(uint256)(uint24)" "${i}" || true)")"
    tiers+=("${i}:${tier_val:-?}")
  done

  local slot0_raw sqrt_price tick protocol_fee lp_fee liquidity price token0_decimals token1_decimals stable_is_token1
  sqrt_price=""
  tick=""
  protocol_fee=""
  lp_fee=""
  liquidity=""
  price=""
  token0_decimals=18
  token1_decimals=18
  stable_is_token1=0
  if [[ -n "${pool_currency0}" && -n "${pool_currency1}" && -n "${stable_currency}" ]]; then
    if [[ "$(lower "${stable_currency}")" == "$(lower "${pool_currency0}")" ]]; then
      token0_decimals="${STABLE_DECIMALS}"
      token1_decimals=18
      stable_is_token1=0
    elif [[ "$(lower "${stable_currency}")" == "$(lower "${pool_currency1}")" ]]; then
      token0_decimals=18
      token1_decimals="${STABLE_DECIMALS}"
      stable_is_token1=1
    fi
  fi
  if [[ -n "${STATE_VIEW_ADDRESS}" ]]; then
    if slot0_raw="$(try_cast_call "${STATE_VIEW_ADDRESS}" "getSlot0(bytes32)(uint160,int24,uint24,uint24)" "${POOL_ID}" 2>/dev/null)"; then
      sqrt_price="$(printf '%s\n' "${slot0_raw}" | sed -n '1p' | awk '{print $1}')"
      tick="$(printf '%s\n' "${slot0_raw}" | sed -n '2p' | awk '{print $1}')"
      protocol_fee="$(printf '%s\n' "${slot0_raw}" | sed -n '3p' | awk '{print $1}')"
      lp_fee="$(printf '%s\n' "${slot0_raw}" | sed -n '4p' | awk '{print $1}')"
      if [[ "${sqrt_price}" =~ ^[0-9]+$ ]]; then
        price="$(human_price_from_sqrt_x96 "${sqrt_price}" "${token0_decimals}" "${token1_decimals}" "${stable_is_token1}")"
      fi
    fi
    liquidity="$(first_token "$(try_cast_call "${STATE_VIEW_ADDRESS}" "getLiquidity(bytes32)(uint128)" "${POOL_ID}" || true)")"
  fi

  local fee_sync="n/a"
  if [[ "${current_fee}" =~ ^[0-9]+$ && "${lp_fee}" =~ ^[0-9]+$ ]]; then
    if [[ "${current_fee}" == "${lp_fee}" ]]; then
      fee_sync="OK"
    else
      fee_sync="MISMATCH"
    fi
  fi

  local fee_bounds="n/a"
  if [[ "${fee_idx}" =~ ^[0-9]+$ && "${floor_idx}" =~ ^[0-9]+$ && "${cap_idx}" =~ ^[0-9]+$ ]]; then
    if (( fee_idx >= floor_idx && fee_idx <= cap_idx )); then
      fee_bounds="OK"
    else
      fee_bounds="OUT_OF_RANGE"
    fi
  fi

  local init_status="NO"
  if [[ "${period_start}" =~ ^[0-9]+$ ]] && (( period_start > 0 )); then
    init_status="YES"
  fi

  local liq_status="n/a"
  if [[ "${liquidity}" =~ ^[0-9]+$ ]]; then
    if (( liquidity > 0 )); then
      liq_status="OK"
    else
      liq_status="ZERO"
    fi
  fi

  echo "timestamp_utc=${ts}"
  echo "chain=${CHAIN} chain_id=${CHAIN_ID}"
  echo "rpc_url=${RPC_URL}"
  echo "hook_address=${HOOK_ADDRESS}"
  echo "pool_manager=${POOL_MANAGER}"
  echo "pool_id=${POOL_ID}"
  echo "pool_key=${POOL_KEY}"
  echo "state_view_address=${STATE_VIEW_ADDRESS:-not-set}"
  echo "hook_pool: currency0=${pool_currency0} currency1=${pool_currency1} stable=${stable_currency} tick_spacing=${pool_tick_spacing}"
  echo "hook_params: initial_idx=${initial_idx} floor_idx=${floor_idx} cap_idx=${cap_idx} pause_idx=${pause_idx} period_seconds=${period_seconds} ema_periods=${ema_periods} deadband_bps=${deadband_bps} lull_reset_seconds=${lull_reset_seconds} guardian=${guardian}"
  echo "fee_tiers_bips=$(IFS=,; echo "${tiers[*]}")"
  echo "hook_state: paused=${paused} current_fee_bips=${current_fee} period_volume_usd6=${pv} ema_volume_usd6=${ema_vol} period_start=${period_start} fee_idx=${fee_idx} last_dir=${last_dir}"
  if [[ -n "${STATE_VIEW_ADDRESS}" ]]; then
    echo "pool_state: sqrt_price_x96=${sqrt_price:-?} tick=${tick:-?} protocol_fee=${protocol_fee:-?} lp_fee=${lp_fee:-?} liquidity=${liquidity:-?} price_stable_per_volatile=${price:-?}"
  fi
  echo "checks: initialized=${init_status} fee_sync=${fee_sync} fee_idx_bounds=${fee_bounds} liquidity=${liq_status}"
}

if (( WATCH_SECONDS > 0 )); then
  while true; do
    render_once
    echo "-----"
    sleep "${WATCH_SECONDS}"
  done
else
  render_once
fi
