#!/usr/bin/env bash
set -euo pipefail

# Calculates sqrtPriceX96 for v4 pool initialization.
#
# INIT_PRICE_USD is interpreted as: STABLE per 1 VOLATILE token.
# currency0/currency1 are derived by sorting VOLATILE/STABLE by address (same as PoolKey ordering).
#
# Usage:
#   ./scripts/calc_init_sqrt_price.sh --config <path> --rpc-url <url> --from-usd [--sqrt-only]

CONFIG_PATH=""
RPC_URL=""
FROM_USD=0
SQRT_ONLY=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/calc_init_sqrt_price.sh --config <path> --rpc-url <url> --from-usd [--sqrt-only]
EOF
}

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    --rpc-url) RPC_URL="${2:-}"; shift 2 ;;
    --from-usd) FROM_USD=1; shift ;;
    --sqrt-only) SQRT_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$CONFIG_PATH" || -z "$RPC_URL" ]]; then usage; exit 1; fi
if [[ ! -f "$CONFIG_PATH" ]]; then echo "ERROR: config not found: $CONFIG_PATH" >&2; exit 1; fi

# shellcheck disable=SC1090
set -a
source "$CONFIG_PATH"
set +a

if [[ -z "${VOLATILE:-}" || -z "${STABLE:-}" ]]; then
  echo "ERROR: VOLATILE and STABLE must be set in $CONFIG_PATH" >&2
  exit 1
fi
if [[ "$FROM_USD" -ne 1 ]]; then
  echo "ERROR: only --from-usd mode is supported" >&2
  exit 1
fi
if [[ -z "${INIT_PRICE_USD:-}" ]]; then
  echo "ERROR: INIT_PRICE_USD must be set in $CONFIG_PATH" >&2
  exit 1
fi

v_lc="$(lower "$VOLATILE")"
s_lc="$(lower "$STABLE")"

CURRENCY0="$VOLATILE"
CURRENCY1="$STABLE"
if [[ "$v_lc" > "$s_lc" ]]; then
  CURRENCY0="$STABLE"
  CURRENCY1="$VOLATILE"
fi

DEC0="$(cast call "$CURRENCY0" "decimals()(uint8)" --rpc-url "$RPC_URL" | tr -d '\r')"
DEC1="$(cast call "$CURRENCY1" "decimals()(uint8)" --rpc-url "$RPC_URL" | tr -d '\r')"

# Invert if STABLE ended up as currency0 after sorting.
stable_lc="$(lower "$STABLE")"
c0_lc="$(lower "$CURRENCY0")"
invert=0
if [[ "$stable_lc" == "$c0_lc" ]]; then invert=1; fi

SQRT="$(python3 - <<'PY' "$INIT_PRICE_USD" "$DEC0" "$DEC1" "$invert"
import sys, math

price_str=sys.argv[1]
dec0=int(sys.argv[2]); dec1=int(sys.argv[3])
invert=int(sys.argv[4])

if "." in price_str:
    a,b = price_str.split(".",1)
    k=len(b)
    p_int=int(a+b)
else:
    k=0
    p_int=int(price_str)

if p_int<=0:
    raise SystemExit("price must be > 0")

if invert==0:
    # ratio_raw = (p_int/10^k) * 10^(dec1-dec0)
    if dec1>=dec0:
        num = p_int * (10**(dec1-dec0))
        den = 10**k
    else:
        num = p_int
        den = (10**k) * (10**(dec0-dec1))
else:
    # ratio_raw = (1/price) * 10^(dec1-dec0)
    if dec1>=dec0:
        num = (10**k) * (10**(dec1-dec0))
        den = p_int
    else:
        num = 10**k
        den = p_int * (10**(dec0-dec1))

value = (num << 192) // den
print(math.isqrt(value))
PY
)"

if [[ "$SQRT_ONLY" -eq 1 ]]; then
  echo "$SQRT"
else
  echo "$SQRT"
fi