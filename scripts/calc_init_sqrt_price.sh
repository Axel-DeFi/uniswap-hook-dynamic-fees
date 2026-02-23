#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <config-name-in-config-dir|path> [--from-usd] [--sqrt-only]"
  echo
  echo "Examples:"
  echo "  $0 hook.local.conf"
  echo "  $0 hook.optimism.conf --from-usd"
  echo "  $0 hook.optimism --from-usd --sqrt-only"
  echo
  echo "Notes:"
  echo "  - --from-usd uses INIT_PRICE_USD + STABLE from the config, interpreting INIT_PRICE_USD as STABLE per 1 VOLATILE token."
  echo "  - The utility automatically sorts TOKEN0/TOKEN1 by address (same as CreatePool.s.sol)."
  exit 1
}

CONFIG_NAME="${1:-}"
[[ -z "$CONFIG_NAME" ]] && usage

FROM_USD=0
SQRT_ONLY=0

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-usd) FROM_USD=1; shift ;;
    --sqrt-only) SQRT_ONLY=1; shift ;;
    *) usage ;;
  esac
done

if [[ "$CONFIG_NAME" != *.conf && "$CONFIG_NAME" != */*.conf ]]; then
  CONFIG_NAME="${CONFIG_NAME}.conf"
fi

if [[ "$CONFIG_NAME" == */* ]]; then
  CONFIG_PATH="$CONFIG_NAME"
else
  CONFIG_PATH="config/${CONFIG_NAME}"
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: missing ./${CONFIG_PATH}" >&2
  exit 1
fi

if ! command -v cast >/dev/null 2>&1; then
  echo "ERROR: 'cast' not found. Install Foundry (foundryup) first." >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$CONFIG_PATH"
set +a

RPC_URL="${RPC_URL:-}"
if [[ -z "$RPC_URL" ]]; then
  echo "ERROR: RPC_URL is empty in ./${CONFIG_PATH}" >&2
  exit 1
fi

TOKEN0="${TOKEN0:-}"
TOKEN1="${TOKEN1:-}"
if [[ -z "$TOKEN0" || -z "$TOKEN1" ]]; then
  echo "ERROR: TOKEN0 and TOKEN1 must be set in ./${CONFIG_PATH}" >&2
  exit 1
fi

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Canonical ordering (same as CreatePool.s.sol)
_t0="$(lower "$TOKEN0")"
_t1="$(lower "$TOKEN1")"
if [[ "$_t0" > "$_t1" ]]; then
  tmp="$TOKEN0"; TOKEN0="$TOKEN1"; TOKEN1="$tmp"
  _t0="$(lower "$TOKEN0")"; _t1="$(lower "$TOKEN1")"
fi

read_decimals() {
  local addr="$1"

  # Native ETH represented as address(0)
  if [[ "$(lower "$addr")" == "0x0000000000000000000000000000000000000000" ]]; then
    echo "18"
    return
  fi

  local out
  out="$(cast call "$addr" "decimals()(uint8)" --rpc-url "$RPC_URL" 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -n "$out" ]]; then
    echo "$out"
    return
  fi

  echo "ERROR: could not fetch decimals() for ${addr}." >&2
  exit 1
}

DEC0="$(read_decimals "$TOKEN0")"
DEC1="$(read_decimals "$TOKEN1")"

PRICE_STR=""
QUOTE="Y"  # Y => TOKEN0 per 1 TOKEN1

if [[ "$FROM_USD" -eq 1 ]]; then
  STABLE="${STABLE:-}"
  INIT_PRICE_USD="${INIT_PRICE_USD:-}"
  if [[ -z "$STABLE" || -z "$INIT_PRICE_USD" ]]; then
    echo "ERROR: --from-usd requires STABLE and INIT_PRICE_USD in ./${CONFIG_PATH}" >&2
    exit 1
  fi

  stable_lc="$(lower "$STABLE")"
  if [[ "$stable_lc" != "$(lower "$TOKEN0")" && "$stable_lc" != "$(lower "$TOKEN1")" ]]; then
    echo "ERROR: STABLE must equal TOKEN0 or TOKEN1 (after canonical sorting)." >&2
    echo "  TOKEN0=${TOKEN0}" >&2
    echo "  TOKEN1=${TOKEN1}" >&2
    echo "  STABLE=${STABLE}" >&2
    exit 1
  fi

  PRICE_STR="$INIT_PRICE_USD"

  # INIT_PRICE_USD is STABLE per 1 VOLATILE.
  # If STABLE==TOKEN0, then it's TOKEN0 per 1 TOKEN1 (QUOTE=Y).
  # If STABLE==TOKEN1, then it's TOKEN1 per 1 TOKEN0, so set QUOTE=n.
  if [[ "$stable_lc" == "$(lower "$TOKEN1")" ]]; then
    QUOTE="n"
  else
    QUOTE="Y"
  fi
else
  # Interactive input
  if [[ ! -t 0 ]]; then
    echo "ERROR: interactive input required (no TTY). Use --from-usd." >&2
    exit 1
  fi

  echo
  echo "=== Inputs from ./${CONFIG_PATH} ==="
  echo "RPC_URL : $RPC_URL"
  echo "TOKEN0  : $TOKEN0 (decimals=$DEC0)"
  echo "TOKEN1  : $TOKEN1 (decimals=$DEC1)"
  echo

  read -r -p "Enter price value (e.g. 2200.5): " PRICE_STR
  if [[ -z "$PRICE_STR" ]]; then
    echo "ERROR: price is empty" >&2
    exit 1
  fi

  read -r -p "Is this price TOKEN0 per 1 TOKEN1? [Y/n]: " QUOTE
  QUOTE="${QUOTE:-Y}"
fi

RESULT="$(python3 - <<PY
from fractions import Fraction
from math import isqrt
from decimal import Decimal, getcontext

getcontext().prec = 80

price_str = "$PRICE_STR"
quote = "$QUOTE"
dec0 = int("$DEC0")
dec1 = int("$DEC1")

p = Fraction(price_str)
if p <= 0:
    raise SystemExit("Price must be > 0")

# If user provided TOKEN1 per TOKEN0, invert to get TOKEN0 per TOKEN1
if quote.lower().startswith('n'):
    p = Fraction(1, 1) / p

# token1/token0 (raw) = (10^dec1) / (p * 10^dec0)
den = p * (10 ** dec0)              # Fraction
num = (10 ** dec1) * (1 << 192)     # int

price_x192 = (num * den.denominator) // den.numerator
sqrt_price_x96 = isqrt(price_x192)

# Implied prices back for sanity
ratio_raw = Fraction(sqrt_price_x96 * sqrt_price_x96, 1 << 192)
token1_per_token0_human = ratio_raw * Fraction(10 ** dec0, 10 ** dec1)
token0_per_token1_human = Fraction(1, 1) / token1_per_token0_human

def to_dec(fr: Fraction) -> Decimal:
    return Decimal(fr.numerator) / Decimal(fr.denominator)

print(sqrt_price_x96)
print(to_dec(token0_per_token1_human))
print(to_dec(token1_per_token0_human))
PY
)"

SQRT_PRICE_X96="$(echo "$RESULT" | sed -n '1p')"
IMPLIED_0_PER_1="$(echo "$RESULT" | sed -n '2p')"
IMPLIED_1_PER_0="$(echo "$RESULT" | sed -n '3p')"

if [[ "$SQRT_ONLY" -eq 1 ]]; then
  echo "$SQRT_PRICE_X96"
  exit 0
fi

echo
echo "=== Result ==="
echo "INIT_SQRT_PRICE_X96=$SQRT_PRICE_X96"
echo
echo "Sanity (implied, after canonical token sorting):"
echo "  TOKEN0 per 1 TOKEN1 ~= $IMPLIED_0_PER_1"
echo "  TOKEN1 per 1 TOKEN0 ~= $IMPLIED_1_PER_0"
echo
