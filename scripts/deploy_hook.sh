#!/usr/bin/env bash
set -euo pipefail

# Deploy hook (CREATE2-mined address with required v4 hook flags).
#
# Usage:
#   ./scripts/deploy_hook.sh --chain <chain> [--rpc-url <url>] [--private-key <hex>] [--broadcast] [--verify]
#
# If run with no args, prints this help.
#
# Config:
#   - local   -> ./config/hook.local.conf
#   - sepolia -> ./config/hook.sepolia.conf
#   - other   -> ./config/hook.<chain>.conf
#
# Required config keys:
#   POOL_MANAGER, VOLATILE, STABLE, STABLE_DECIMALS, TICK_SPACING
#   FLOOR_TIER
#   FEE_TIERS (comma-separated fee levels in percent, for example 0.009,0.04,0.09)
#   PERIOD_SECONDS, EMA_PERIODS, DEADBAND_BPS, LULL_RESET_SECONDS
#   HOOK_FEE_PERCENT
#   CASH_TIER, EXTREME_TIER
#   MIN_CLOSEVOL_TO_CASH_USD6, UP_R_TO_CASH_BPS, CASH_HOLD_PERIODS
#   MIN_CLOSEVOL_TO_EXTREME_USD6, UP_R_TO_EXTREME_BPS, UP_EXTREME_CONFIRM_PERIODS, EXTREME_HOLD_PERIODS
#   DOWN_R_FROM_EXTREME_BPS, DOWN_EXTREME_CONFIRM_PERIODS, DOWN_R_FROM_CASH_BPS, DOWN_CASH_CONFIRM_PERIODS
#   EMERGENCY_FLOOR_CLOSEVOL_USD6, EMERGENCY_CONFIRM_PERIODS
# Optional:
#   OWNER             (defaults to deployer address)
#   HOOK_FEE_ADDRESS (required when HOOK_FEE_PERCENT > 0)
#
# Owner behavior:
#   - OWNER defines privileged admin account.
#   - HOOK_FEE_ADDRESS defines payout recipient for hook fees.

usage() {
  cat <<'EOF'
Usage:
  ./scripts/deploy_hook.sh --chain <chain> [--rpc-url <url>] [--private-key <hex>] [--broadcast] [--verify]

Examples:
  ./scripts/deploy_hook.sh --chain local --rpc-url http://127.0.0.1:8545 --private-key <pk> --broadcast
  ./scripts/deploy_hook.sh --chain sepolia --rpc-url https://ethereum-sepolia-rpc.publicnode.com --private-key <pk> --broadcast

Notes:
  - Output JSON is written to ./scripts/out/deploy.<chain>.json
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
sort_pool_tokens() {
  local a b al bl
  a="${1:?}"
  b="${2:?}"
  al="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')"
  bl="$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')"
  if [[ "$al" < "$bl" ]]; then
    printf '%s %s\n' "$a" "$b"
  else
    printf '%s %s\n' "$b" "$a"
  fi
}

CHAIN=""
RPC_URL_CLI=""
PRIVATE_KEY_CLI=""
BROADCAST=0
VERIFY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --rpc-url) RPC_URL_CLI="${2:-}"; shift 2 ;;
    --private-key) PRIVATE_KEY_CLI="${2:-}"; shift 2 ;;
    --broadcast) BROADCAST=1; shift ;;
    --verify) VERIFY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

CHAIN="$(lower "${CHAIN:-}")"
if [[ -z "$CHAIN" ]]; then
  echo "ERROR: --chain is required" >&2
  usage
  exit 1
fi

# Auto-load .env (repo root) if present, so configs can reference DEFAULT_PRIVATE_KEY, etc.
if [[ -f "./.env" ]]; then
  # shellcheck disable=SC1091
  source "./.env"
fi

HOOK_CONF="./config/hook.${CHAIN}.conf"
if [[ "$CHAIN" == "local" ]]; then
  HOOK_CONF="./config/hook.local.conf"
elif [[ "$CHAIN" == "sepolia" ]]; then
  HOOK_CONF="./config/hook.sepolia.conf"
fi

if [[ ! -f "$HOOK_CONF" ]]; then
  echo "ERROR: config not found: $HOOK_CONF" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$HOOK_CONF"
set +a

RPC_URL="${RPC_URL_CLI:-${RPC_URL:-}}"
PRIVATE_KEY="${PRIVATE_KEY_CLI:-${PRIVATE_KEY:-}}"

if [[ -z "${RPC_URL:-}" ]]; then
  echo "ERROR: RPC_URL missing (config or --rpc-url)" >&2
  exit 1
fi

if [[ "$BROADCAST" -ne 1 ]]; then
  echo "==> deploy_hook: skipping (no --broadcast)" >&2
  exit 0
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "ERROR: PRIVATE_KEY missing (config, .env DEFAULT_PRIVATE_KEY, or --private-key)" >&2
  exit 1
fi

# Validate required variables
required=(
  POOL_MANAGER VOLATILE STABLE STABLE_DECIMALS TICK_SPACING
  FLOOR_TIER FEE_TIERS
  PERIOD_SECONDS EMA_PERIODS DEADBAND_BPS LULL_RESET_SECONDS
  HOOK_FEE_PERCENT
  CASH_TIER EXTREME_TIER
  MIN_CLOSEVOL_TO_CASH_USD6 UP_R_TO_CASH_BPS CASH_HOLD_PERIODS
  MIN_CLOSEVOL_TO_EXTREME_USD6 UP_R_TO_EXTREME_BPS UP_EXTREME_CONFIRM_PERIODS EXTREME_HOLD_PERIODS
  DOWN_R_FROM_EXTREME_BPS DOWN_EXTREME_CONFIRM_PERIODS DOWN_R_FROM_CASH_BPS DOWN_CASH_CONFIRM_PERIODS
  EMERGENCY_FLOOR_CLOSEVOL_USD6 EMERGENCY_CONFIRM_PERIODS
)
for k in "${required[@]}"; do
  if [[ -z "${!k:-}" ]]; then
    echo "ERROR: missing $k in $HOOK_CONF" >&2
    exit 1
  fi
done

percent_to_pips() {
  local pct="$1"
  awk -v pct="${pct}" '
    BEGIN {
      if (pct !~ /^[0-9]+([.][0-9]+)?$/) exit 1;
      v = pct * 10000;
      p = int(v + 0.5);
      if (p < 1 || p > 1000000) exit 1;
      print p;
    }' 2>/dev/null
}

require_uint() {
  local name="$1"
  local value="${!name:-}"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ${name} must be an unsigned integer, got '${value}'." >&2
    exit 1
  fi
}

# Parse fee tiers from percent CSV into hundredths-of-a-bip values expected by the hook.
# Example: 0.009% -> 90.
IFS=',' read -r -a FEE_TIER_PCT_ITEMS <<< "${FEE_TIERS}"
if (( ${#FEE_TIER_PCT_ITEMS[@]} == 0 )); then
  echo "ERROR: FEE_TIERS must contain at least one value (for example 0.009,0.04,0.09)." >&2
  exit 1
fi
if (( ${#FEE_TIER_PCT_ITEMS[@]} > 255 )); then
  echo "ERROR: FEE_TIERS has ${#FEE_TIER_PCT_ITEMS[@]} values; max supported is 255." >&2
  exit 1
fi

FEE_TIER_COUNT="${#FEE_TIER_PCT_ITEMS[@]}"
export FEE_TIER_COUNT

declare -a FEE_TIER_PIPS=()
prev_tier_pips=-1
for i in "${!FEE_TIER_PCT_ITEMS[@]}"; do
  tier_pct="$(printf '%s' "${FEE_TIER_PCT_ITEMS[$i]}" | tr -d '[:space:]')"
  tier_pips="$(percent_to_pips "${tier_pct}" || true)"
  if [[ -z "${tier_pips}" ]]; then
    echo "ERROR: FEE_TIERS item '${FEE_TIER_PCT_ITEMS[$i]}' is invalid. Use decimal percent values like 0.09." >&2
    exit 1
  fi
  if (( prev_tier_pips >= 0 && tier_pips <= prev_tier_pips )); then
    echo "ERROR: FEE_TIERS must be strictly increasing after conversion to pips." >&2
    exit 1
  fi
  prev_tier_pips="${tier_pips}"
  FEE_TIER_PIPS[$i]="${tier_pips}"

  tier_var="FEE_TIER_${i}"
  printf -v "${tier_var}" '%s' "${tier_pips}"
  export "${tier_var}"
done

floor_tier_pct="$(printf '%s' "${FLOOR_TIER}" | tr -d '[:space:]')"
cap_tier_pct="$(printf '%s' "${EXTREME_TIER}" | tr -d '[:space:]')"
floor_tier_pips="$(percent_to_pips "${floor_tier_pct}" || true)"
cap_tier_pips="$(percent_to_pips "${cap_tier_pct}" || true)"
if [[ -z "${floor_tier_pips}" ]]; then
  echo "ERROR: FLOOR_TIER='${FLOOR_TIER}' is invalid. Use decimal percent format like 0.04." >&2
  exit 1
fi
if [[ -z "${cap_tier_pips}" ]]; then
  echo "ERROR: EXTREME_TIER='${EXTREME_TIER}' is invalid. Use decimal percent format like 0.45." >&2
  exit 1
fi

FLOOR_IDX=""
EXTREME_IDX=""
for i in "${!FEE_TIER_PIPS[@]}"; do
  if [[ "${FEE_TIER_PIPS[$i]}" == "${floor_tier_pips}" ]]; then
    FLOOR_IDX="${i}"
  fi
  if [[ "${FEE_TIER_PIPS[$i]}" == "${cap_tier_pips}" ]]; then
    EXTREME_IDX="${i}"
  fi
done

if [[ -z "${FLOOR_IDX}" ]]; then
  echo "ERROR: FLOOR_TIER=${FLOOR_TIER}% is not present in FEE_TIERS='${FEE_TIERS}'." >&2
  exit 1
fi
if [[ -z "${EXTREME_IDX}" ]]; then
  echo "ERROR: EXTREME_TIER=${EXTREME_TIER}% is not present in FEE_TIERS='${FEE_TIERS}'." >&2
  exit 1
fi
if (( FLOOR_IDX > EXTREME_IDX )); then
  echo "ERROR: FLOOR_TIER index (${FLOOR_IDX}) must be <= EXTREME_TIER index (${EXTREME_IDX})." >&2
  exit 1
fi

export FLOOR_IDX EXTREME_IDX

CASH_TIER_PIPS="$(percent_to_pips "$(printf '%s' "${CASH_TIER}" | tr -d '[:space:]')" || true)"
EXTREME_TIER_PIPS="$(percent_to_pips "$(printf '%s' "${EXTREME_TIER}" | tr -d '[:space:]')" || true)"
if [[ -z "${CASH_TIER_PIPS}" ]]; then
  echo "ERROR: CASH_TIER='${CASH_TIER}' is invalid. Use decimal percent format like 0.25." >&2
  exit 1
fi
if [[ -z "${EXTREME_TIER_PIPS}" ]]; then
  echo "ERROR: EXTREME_TIER='${EXTREME_TIER}' is invalid. Use decimal percent format like 0.90." >&2
  exit 1
fi

CASH_IDX=""
EXTREME_IDX=""
for i in "${!FEE_TIER_PIPS[@]}"; do
  if [[ "${FEE_TIER_PIPS[$i]}" == "${CASH_TIER_PIPS}" ]]; then
    CASH_IDX="${i}"
  fi
  if [[ "${FEE_TIER_PIPS[$i]}" == "${EXTREME_TIER_PIPS}" ]]; then
    EXTREME_IDX="${i}"
  fi
done

if [[ -z "${CASH_IDX}" ]]; then
  echo "ERROR: CASH_TIER=${CASH_TIER}% is not present in FEE_TIERS='${FEE_TIERS}'." >&2
  exit 1
fi
if [[ -z "${EXTREME_IDX}" ]]; then
  echo "ERROR: EXTREME_TIER=${EXTREME_TIER}% is not present in FEE_TIERS='${FEE_TIERS}'." >&2
  exit 1
fi
if (( FLOOR_IDX >= CASH_IDX || CASH_IDX >= EXTREME_IDX )); then
  echo "ERROR: tier bounds must satisfy FLOOR < CASH < EXTREME (by index in FEE_TIERS)." >&2
  exit 1
fi
for n in \
  MIN_CLOSEVOL_TO_CASH_USD6 \
  UP_R_TO_CASH_BPS \
  CASH_HOLD_PERIODS \
  MIN_CLOSEVOL_TO_EXTREME_USD6 \
  UP_R_TO_EXTREME_BPS \
  UP_EXTREME_CONFIRM_PERIODS \
  EXTREME_HOLD_PERIODS \
  DOWN_R_FROM_EXTREME_BPS \
  DOWN_EXTREME_CONFIRM_PERIODS \
  DOWN_R_FROM_CASH_BPS \
  DOWN_CASH_CONFIRM_PERIODS \
  EMERGENCY_FLOOR_CLOSEVOL_USD6 \
  EMERGENCY_CONFIRM_PERIODS; do
  require_uint "$n"
done

# Human-friendly percent input in config (10 means 10%).
if ! [[ "${HOOK_FEE_PERCENT}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: HOOK_FEE_PERCENT must be an integer in [0..10]" >&2
  exit 1
fi
if (( HOOK_FEE_PERCENT > 10 )); then
  echo "ERROR: HOOK_FEE_PERCENT=${HOOK_FEE_PERCENT} out of range [0..10]" >&2
  exit 1
fi
export HOOK_FEE_PERCENT

DEPLOYER_ADDR="$(cast wallet address --private-key "${PRIVATE_KEY}" | awk '{print $1}')"
if [[ -z "${OWNER:-}" ]]; then
  OWNER="${DEPLOYER_ADDR}"
  echo "==> OWNER not set; defaulting to deployer: ${OWNER}"
fi
export OWNER

if [[ -z "${HOOK_FEE_ADDRESS:-}" ]]; then
  if (( HOOK_FEE_PERCENT > 0 )); then
    echo "ERROR: HOOK_FEE_ADDRESS is required when HOOK_FEE_PERCENT > 0" >&2
    exit 1
  fi
  HOOK_FEE_ADDRESS="0x0000000000000000000000000000000000000000"
  echo "==> HOOK_FEE_ADDRESS not set and HOOK_FEE_PERCENT=0; using zero recipient"
fi
export HOOK_FEE_ADDRESS

# Optional safety: verify STABLE_DECIMALS matches on-chain decimals()
if [[ -z "${SKIP_DECIMALS_CHECK:-}" ]]; then
  echo "==> Checking stable decimals for ${STABLE} ..."
  ONCHAIN_DECIMALS="$(cast call "${STABLE}" "decimals()(uint8)" --rpc-url "${RPC_URL}" 2>/dev/null || true)"
  if [[ -z "${ONCHAIN_DECIMALS}" ]]; then
    echo "ERROR: failed to read decimals() for STABLE=${STABLE}. If this token does not implement decimals(), set SKIP_DECIMALS_CHECK=1." >&2
    exit 1
  fi
  if [[ "${ONCHAIN_DECIMALS}" != "${STABLE_DECIMALS}" ]]; then
    echo "ERROR: STABLE_DECIMALS=${STABLE_DECIMALS} does not match on-chain decimals()=${ONCHAIN_DECIMALS} for STABLE=${STABLE}" >&2
    exit 1
  fi
fi

OUT_PATH="./scripts/out/deploy.${CHAIN}.json"
mkdir -p ./scripts/out
export DEPLOY_JSON_PATH="${OUT_PATH}"

# Pre-encode constructor args in bash to avoid IR stack issues in script-level abi.encode.
read -r POOL_CURRENCY0 POOL_CURRENCY1 <<< "$(sort_pool_tokens "${VOLATILE}" "${STABLE}")"
FEE_TIERS_ARG="[$(IFS=,; echo "${FEE_TIER_PIPS[*]}")]"
CONSTRUCTOR_ARGS_HEX="$(cast abi-encode \
  "constructor(address,address,address,int24,address,uint8,uint8,uint24[],uint32,uint8,uint16,uint32,address,address,uint16,uint24,uint64,uint16,uint8,uint24,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8)" \
  "${POOL_MANAGER}" \
  "${POOL_CURRENCY0}" \
  "${POOL_CURRENCY1}" \
  "${TICK_SPACING}" \
  "${STABLE}" \
  "${STABLE_DECIMALS}" \
  "${FLOOR_IDX}" \
  "${FEE_TIERS_ARG}" \
  "${PERIOD_SECONDS}" \
  "${EMA_PERIODS}" \
  "${DEADBAND_BPS}" \
  "${LULL_RESET_SECONDS}" \
  "${OWNER}" \
  "${HOOK_FEE_ADDRESS}" \
  "${HOOK_FEE_PERCENT}" \
  "${CASH_TIER_PIPS}" \
  "${MIN_CLOSEVOL_TO_CASH_USD6}" \
  "${UP_R_TO_CASH_BPS}" \
  "${CASH_HOLD_PERIODS}" \
  "${EXTREME_TIER_PIPS}" \
  "${MIN_CLOSEVOL_TO_EXTREME_USD6}" \
  "${UP_R_TO_EXTREME_BPS}" \
  "${UP_EXTREME_CONFIRM_PERIODS}" \
  "${EXTREME_HOLD_PERIODS}" \
  "${DOWN_R_FROM_EXTREME_BPS}" \
  "${DOWN_EXTREME_CONFIRM_PERIODS}" \
  "${DOWN_R_FROM_CASH_BPS}" \
  "${DOWN_CASH_CONFIRM_PERIODS}" \
  "${EMERGENCY_FLOOR_CLOSEVOL_USD6}" \
  "${EMERGENCY_CONFIRM_PERIODS}")"
if [[ -z "${CONSTRUCTOR_ARGS_HEX}" || "${CONSTRUCTOR_ARGS_HEX}" == "0x" ]]; then
  echo "ERROR: failed to encode constructor args" >&2
  exit 1
fi
export CONSTRUCTOR_ARGS_HEX

COMMON_ARGS=(--rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}")
if [[ "$VERIFY" -eq 1 ]]; then
  COMMON_ARGS+=(--verify)
fi
COMMON_ARGS+=(--broadcast)

echo "==> Deploying hook (scripts/foundry/DeployHook.s.sol) using ${HOOK_CONF}"
forge script scripts/foundry/DeployHook.s.sol "${COMMON_ARGS[@]}"

HOOK_ADDRESS="$(python3 - <<'PY' "${OUT_PATH}"
import json, sys
path = sys.argv[1]
data = json.load(open(path))

def find_addr(x):
    if isinstance(x, str) and x.startswith("0x") and len(x) == 42:
        return x
    if isinstance(x, dict):
        for k, v in x.items():
            if k.lower() in ("hook", "hook_address", "hookaddress") and isinstance(v, str) and v.startswith("0x") and len(v) == 42:
                return v
        for v in x.values():
            found = find_addr(v)
            if found:
                return found
    if isinstance(x, list):
        for v in x:
            found = find_addr(v)
            if found:
                return found
    return None

addr = find_addr(data)
if not addr:
    raise SystemExit("Could not find hook address in deploy JSON")
print(addr)
PY
)"

echo "==> Hook deployed at ${HOOK_ADDRESS}"

if [[ "$(lower "${OWNER}")" != "$(lower "${DEPLOYER_ADDR}")" ]]; then
  echo "WARN: OWNER=${OWNER} differs from signer ${DEPLOYER_ADDR}; skipping post-deploy on-chain setter calls."
  echo "      Run pause/setter/unpause from the OWNER account to finish configuration."
  echo "==> Wrote ${OUT_PATH}"
  exit 0
fi

CONTROLLER_PARAMS_TUPLE="(${MIN_CLOSEVOL_TO_CASH_USD6},${UP_R_TO_CASH_BPS},${CASH_HOLD_PERIODS},${MIN_CLOSEVOL_TO_EXTREME_USD6},${UP_R_TO_EXTREME_BPS},${UP_EXTREME_CONFIRM_PERIODS},${EXTREME_HOLD_PERIODS},${DOWN_R_FROM_EXTREME_BPS},${DOWN_EXTREME_CONFIRM_PERIODS},${DOWN_R_FROM_CASH_BPS},${DOWN_CASH_CONFIRM_PERIODS},${EMERGENCY_FLOOR_CLOSEVOL_USD6},${EMERGENCY_CONFIRM_PERIODS})"

echo "==> On-chain config: pause -> tiers+roles -> timing params -> controller params -> hook fee recipient -> hook fee schedule -> unpause"
cast send "${HOOK_ADDRESS}" "pause()" --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" >/dev/null
cast send "${HOOK_ADDRESS}" "setFeeTiersAndRoles(uint24[],uint8,uint8,uint8)" \
  "${FEE_TIERS_ARG}" "${FLOOR_IDX}" "${CASH_IDX}" "${EXTREME_IDX}" \
  --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" >/dev/null
cast send "${HOOK_ADDRESS}" "setTimingParams(uint32,uint8,uint32,uint16)" \
  "${PERIOD_SECONDS}" "${EMA_PERIODS}" "${LULL_RESET_SECONDS}" "${DEADBAND_BPS}" \
  --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" >/dev/null
cast send "${HOOK_ADDRESS}" "setControllerParams((uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8))" \
  "${CONTROLLER_PARAMS_TUPLE}" --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" >/dev/null
cast send "${HOOK_ADDRESS}" "setHookFeeRecipient(address)" \
  "${HOOK_FEE_ADDRESS}" --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" >/dev/null
cast send "${HOOK_ADDRESS}" "scheduleHookFeePercentChange(uint16)" \
  "${HOOK_FEE_PERCENT}" --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" >/dev/null
cast send "${HOOK_ADDRESS}" "unpause()" --rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}" >/dev/null

echo "==> Wrote ${OUT_PATH}"
