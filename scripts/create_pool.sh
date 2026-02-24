#!/usr/bin/env bash
set -euo pipefail

# Create+initialize a dynamic-fee pool using VOLATILE/STABLE + INIT_PRICE_USD.
#
# Usage:
#   ./scripts/create_pool.sh --chain <local|sepolia|...> [--rpc-url <url>] [--private-key <hex>] [--broadcast]
#
# Reads config from:
#   - local  -> ./config/hook.local.conf
#   - other  -> ./config/hook.<chain>.conf
#
# Requires in config:
#   POOL_MANAGER, VOLATILE, STABLE, STABLE_DECIMALS, TICK_SPACING, INIT_PRICE_USD
#
# HOOK_ADDRESS:
#   - can be set in config
#   - or loaded from ./scripts/out/deploy.<chain>.json (local -> deploy.local.json)

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

CHAIN="local"
RPC_URL_CLI=""
PRIVATE_KEY_CLI=""
BROADCAST=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/create_pool.sh --chain <name> [--rpc-url <url>] [--private-key <hex>] [--broadcast]

Examples:
  ./scripts/create_pool.sh --chain local --rpc-url http://127.0.0.1:8545 --private-key <pk> --broadcast
  ./scripts/create_pool.sh --chain sepolia --rpc-url https://ethereum-sepolia-rpc.publicnode.com --private-key <pk> --broadcast
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --rpc-url) RPC_URL_CLI="${2:-}"; shift 2 ;;
    --private-key) PRIVATE_KEY_CLI="${2:-}"; shift 2 ;;
    --broadcast) BROADCAST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
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

required=(POOL_MANAGER VOLATILE STABLE STABLE_DECIMALS TICK_SPACING INIT_PRICE_USD)
for k in "${required[@]}"; do
  if [[ -z "${!k:-}" ]]; then
    echo "ERROR: missing $k in $CFG" >&2
    exit 1
  fi
done

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

# Compute INIT_SQRT_PRICE_X96 from INIT_PRICE_USD (STABLE per 1 VOLATILE)
INIT_SQRT_PRICE_X96="$(./scripts/calc_init_sqrt_price.sh --config "$CFG" --rpc-url "$RPC_URL" --from-usd --sqrt-only)"
if [[ -z "$INIT_SQRT_PRICE_X96" ]]; then
  echo "ERROR: failed to compute INIT_SQRT_PRICE_X96" >&2
  exit 1
fi

export RPC_URL PRIVATE_KEY HOOK_ADDRESS INIT_SQRT_PRICE_X96

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
