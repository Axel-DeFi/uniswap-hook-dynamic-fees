#!/usr/bin/env bash
set -euo pipefail

# Create+initialize a dynamic-fee pool using VOLATILE/STABLE + INIT_PRICE_USD.
#
# If INIT_PRICE_USD is empty in the config, this script will interactively ask for it
# (only when --broadcast is provided and stdin is a TTY).
#
# Usage:
#   ./scripts/create_pool.sh --chain <local|sepolia|...> [--rpc-url <url>] [--private-key <hex>] [--broadcast]
#
# Reads config from:
#   - local  -> ./config/hook.local.conf
#   - other  -> ./config/hook.<chain>.conf
#
# Requires in config:
#   POOL_MANAGER, VOLATILE, STABLE, STABLE_DECIMALS, TICK_SPACING
#   For --chain optimism, explicit regime fee keys must also be present (FLOOR_TIER/CASH_TIER/EXTREME_TIER and thresholds/holds).
#
# INIT_PRICE_USD:
#   - interpreted as STABLE per 1 VOLATILE token
#   - can be set in config OR provided interactively when missing
#
# HOOK_ADDRESS:
#   - can be set in config
#   - or loaded from ./scripts/out/deploy.<chain>.json (local -> deploy.local.json)

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

CHAIN="local"
RPC_URL_CLI=""
PRIVATE_KEY_CLI=""
INIT_PRICE_USD_ENV="${INIT_PRICE_USD:-}"
BROADCAST=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/create_pool.sh --chain <name> [--rpc-url <url>] [--private-key <hex>] [--broadcast]

Examples:
  ./scripts/create_pool.sh --chain local --rpc-url http://127.0.0.1:8545 --private-key <pk> --broadcast
  ./scripts/create_pool.sh --chain sepolia --rpc-url https://ethereum-sepolia-rpc.publicnode.com --private-key <pk> --broadcast

Notes:
  - If INIT_PRICE_USD is empty in the config, the script will prompt you for it (only with --broadcast).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --rpc-url) RPC_URL_CLI="${2:-}"; shift 2 ;;
    --private-key) PRIVATE_KEY_CLI="${2:-}"; shift 2 ;;
    --broadcast) BROADCAST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

CHAIN="$(lower "$CHAIN")"

CFG="./config/hook.${CHAIN}.conf"
if [[ "$CHAIN" == "local" ]]; then
  CFG="./config/hook.local.conf"
fi

if [[ ! -f "$CFG" ]]; then
  echo "ERROR: config not found: $CFG" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$CFG"
set +a

# Respect pre-exported INIT_PRICE_USD override (e.g. INIT_PRICE_USD=2500 ./scripts/create_pool.sh ...).
if [[ -n "${INIT_PRICE_USD_ENV:-}" ]]; then
  INIT_PRICE_USD="${INIT_PRICE_USD_ENV}"
fi

RPC_URL="${RPC_URL_CLI:-${RPC_URL:-}}"
PRIVATE_KEY="${PRIVATE_KEY_CLI:-${PRIVATE_KEY:-}}"

if [[ "$BROADCAST" -ne 1 ]]; then
  echo "==> create_pool: skipping (no --broadcast)" >&2
  exit 0
fi

if [[ -z "${RPC_URL:-}" ]]; then
  echo "ERROR: RPC_URL missing (config or --rpc-url)" >&2
  exit 1
fi
if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "ERROR: PRIVATE_KEY missing (config or --private-key)" >&2
  exit 1
fi

required=(POOL_MANAGER VOLATILE STABLE STABLE_DECIMALS TICK_SPACING)
for k in "${required[@]}"; do
  if [[ -z "${!k:-}" ]]; then
    echo "ERROR: missing $k in $CFG" >&2
    exit 1
  fi
done

required_v2=(
  FLOOR_TIER CASH_TIER EXTREME_TIER
  PERIOD_SECONDS EMA_PERIODS LULL_RESET_SECONDS DEADBAND_BPS
  HOOK_FEE_PERCENT
  MIN_CLOSEVOL_TO_CASH_USD6 UP_R_TO_CASH_BPS CASH_HOLD_PERIODS
  MIN_CLOSEVOL_TO_EXTREME_USD6 UP_R_TO_EXTREME_BPS UP_EXTREME_CONFIRM_PERIODS EXTREME_HOLD_PERIODS
  DOWN_R_FROM_EXTREME_BPS DOWN_EXTREME_CONFIRM_PERIODS DOWN_R_FROM_CASH_BPS DOWN_CASH_CONFIRM_PERIODS
  EMERGENCY_FLOOR_CLOSEVOL_USD6 EMERGENCY_CONFIRM_PERIODS
)
for k in "${required_v2[@]}"; do
  if [[ -z "${!k:-}" ]]; then
    echo "ERROR: missing v2 key $k in $CFG (required for canonical hook validation)." >&2
    exit 1
  fi
done

# Ask for INIT_PRICE_USD if missing.
if [[ -z "${INIT_PRICE_USD:-}" ]]; then
  if [[ -t 0 ]]; then
    echo "==> INIT_PRICE_USD is empty in $CFG"
    echo "    Enter a human price as STABLE per 1 VOLATILE."
    echo "    Example for WETH/USDC: 3000"
    tries=0
    while true; do
      tries=$((tries+1))
      read -r -p "INIT_PRICE_USD = " input
      input="$(echo "${input}" | tr -d '[:space:]')"
      # Basic numeric validation (integer or decimal, > 0)
      if [[ "$input" =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ "$input" != "0" ]] && [[ "$input" != "0.0" ]]; then
        INIT_PRICE_USD="$input"
        export INIT_PRICE_USD
        break
      fi
      echo "Invalid price. Please enter a positive number (e.g. 3000 or 0.1234)."
      if [[ "$tries" -ge 5 ]]; then
        echo "ERROR: too many invalid attempts." >&2
        exit 1
      fi
    done
  else
    echo "ERROR: INIT_PRICE_USD is empty in $CFG and stdin is not interactive." >&2
    echo "       Set INIT_PRICE_USD in the config or run interactively." >&2
    exit 1
  fi
fi

HOOK_ADDRESS="${HOOK_ADDRESS:-}"
if [[ -z "$HOOK_ADDRESS" ]]; then
  deploy_json="./scripts/out/deploy.${CHAIN}.json"
  if [[ "$CHAIN" == "local" ]]; then
    deploy_json="./scripts/out/deploy.local.json"
  fi

  if [[ ! -f "$deploy_json" ]]; then
    echo "ERROR: HOOK_ADDRESS not set and deploy artifact not found: $deploy_json" >&2
    exit 1
  fi

  HOOK_ADDRESS="$(python3 - <<'PY' "$deploy_json"
import json, sys
path=sys.argv[1]
data=json.load(open(path))
def find_addr(x):
    if isinstance(x,str) and x.startswith("0x") and len(x)==42:
        return x
    if isinstance(x,dict):
        for k,v in x.items():
            if k.lower() in ("hook","hook_address","hookaddress") and isinstance(v,str) and v.startswith("0x") and len(v)==42:
                return v
        for v in x.values():
            r=find_addr(v)
            if r: return r
    if isinstance(x,list):
        for v in x:
            r=find_addr(v)
            if r: return r
    return None
addr=find_addr(data)
if not addr:
    raise SystemExit("Could not find hook address in JSON")
print(addr)
PY
)"
  echo "==> Loaded HOOK_ADDRESS=$HOOK_ADDRESS from $deploy_json"
fi

if [[ -z "${OWNER:-}" ]]; then
  OWNER="$(cast call "${HOOK_ADDRESS}" "owner()(address)" --rpc-url "${RPC_URL}" 2>/dev/null || true)"
  if [[ -z "${OWNER}" || ! "${OWNER}" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: OWNER missing and failed to read owner() from HOOK_ADDRESS=${HOOK_ADDRESS}" >&2
    exit 1
  fi
  echo "==> OWNER not set; using on-chain hook owner: ${OWNER}"
fi
export OWNER

FLOOR_FEE_PIPS="$(percent_to_pips "$(printf '%s' "${FLOOR_TIER}" | tr -d '[:space:]')" || true)"
CASH_FEE_PIPS="$(percent_to_pips "$(printf '%s' "${CASH_TIER}" | tr -d '[:space:]')" || true)"
EXTREME_FEE_PIPS="$(percent_to_pips "$(printf '%s' "${EXTREME_TIER}" | tr -d '[:space:]')" || true)"
if [[ -z "${FLOOR_FEE_PIPS}" || -z "${CASH_FEE_PIPS}" || -z "${EXTREME_FEE_PIPS}" ]]; then
  echo "ERROR: invalid FLOOR_TIER/CASH_TIER/EXTREME_TIER values in ${CFG}" >&2
  exit 1
fi
if (( FLOOR_FEE_PIPS >= CASH_FEE_PIPS || CASH_FEE_PIPS >= EXTREME_FEE_PIPS )); then
  echo "ERROR: fee bounds must satisfy FLOOR_TIER < CASH_TIER < EXTREME_TIER." >&2
  exit 1
fi

read -r POOL_CURRENCY0 POOL_CURRENCY1 <<< "$(sort_pool_tokens "${VOLATILE}" "${STABLE}")"
CONSTRUCTOR_ARGS_HEX="$(cast abi-encode \
  "constructor(address,address,address,int24,address,uint8,uint24,uint24,uint24,uint32,uint8,uint16,uint32,address,uint16,uint64,uint16,uint8,uint64,uint16,uint8,uint8,uint16,uint8,uint16,uint8,uint64,uint8)" \
  "${POOL_MANAGER}" \
  "${POOL_CURRENCY0}" \
  "${POOL_CURRENCY1}" \
  "${TICK_SPACING}" \
  "${STABLE}" \
  "${STABLE_DECIMALS}" \
  "${FLOOR_FEE_PIPS}" \
  "${CASH_FEE_PIPS}" \
  "${EXTREME_FEE_PIPS}" \
  "${PERIOD_SECONDS}" \
  "${EMA_PERIODS}" \
  "${DEADBAND_BPS}" \
  "${LULL_RESET_SECONDS}" \
  "${OWNER}" \
  "${HOOK_FEE_PERCENT}" \
  "${MIN_CLOSEVOL_TO_CASH_USD6}" \
  "${UP_R_TO_CASH_BPS}" \
  "${CASH_HOLD_PERIODS}" \
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
  echo "ERROR: failed to encode CONSTRUCTOR_ARGS_HEX" >&2
  exit 1
fi

INIT_SQRT_PRICE_X96="$(./scripts/calc_init_sqrt_price.sh --config "$CFG" --rpc-url "$RPC_URL" --from-usd --sqrt-only)"
if [[ -z "$INIT_SQRT_PRICE_X96" ]]; then
  echo "ERROR: failed to compute INIT_SQRT_PRICE_X96" >&2
  exit 1
fi

export RPC_URL PRIVATE_KEY HOOK_ADDRESS INIT_SQRT_PRICE_X96 CONSTRUCTOR_ARGS_HEX

echo "==> Create+init pool (dynamic fee)"
echo "==> Config: $CFG"
echo "==> POOL_MANAGER=$POOL_MANAGER"
echo "==> VOLATILE=$VOLATILE"
echo "==> STABLE=$STABLE"
echo "==> TICK_SPACING=$TICK_SPACING"
echo "==> INIT_PRICE_USD=$INIT_PRICE_USD"
echo "==> INIT_SQRT_PRICE_X96=$INIT_SQRT_PRICE_X96"

forge script scripts/foundry/CreatePool.s.sol:CreatePool \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast

if [[ -n "${FLOOR_TIER:-}" ]]; then
  floor_tier_pips="$(percent_to_pips "$(printf '%s' "${FLOOR_TIER}" | tr -d '[:space:]')" || true)"
  if [[ -n "${floor_tier_pips}" ]]; then
    current_fee="$(cast call "${HOOK_ADDRESS}" "currentFeeBips()(uint24)" --rpc-url "${RPC_URL}" 2>/dev/null || true)"
    if [[ -z "${current_fee}" ]]; then
      echo "WARN: unable to read currentFeeBips() after initialize (HOOK_ADDRESS=${HOOK_ADDRESS})" >&2
    elif [[ "${current_fee}" != "${floor_tier_pips}" ]]; then
      echo "ERROR: initial fee mismatch: currentFeeBips=${current_fee}, expected floor=${floor_tier_pips}" >&2
      exit 1
    else
      echo "==> Verified initial fee is floor regime fee (${current_fee})"
    fi
  fi
fi
