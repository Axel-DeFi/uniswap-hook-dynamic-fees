#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <pool-config-name-in-config-dir> [--write]"
  echo "Examples:"
  echo "  $0 pool.local.conf"
  echo "  $0 pool.local --write"
  exit 1
}

CONFIG_NAME="${1:-}"
[[ -z "$CONFIG_NAME" ]] && usage

WRITE_MODE="${2:-}"
if [[ "$WRITE_MODE" != "" && "$WRITE_MODE" != "--write" ]]; then
  usage
fi

if [[ "$CONFIG_NAME" != *.conf ]]; then
  CONFIG_NAME="${CONFIG_NAME}.conf"
fi

CONFIG_PATH="config/${CONFIG_NAME}"
if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: missing ./${CONFIG_PATH}"
  exit 1
fi

if ! command -v cast >/dev/null 2>&1; then
  echo "ERROR: 'cast' not found. Install Foundry (foundryup) first."
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$CONFIG_PATH"
set +a

# Must come from config (no hidden defaults)
RPC_URL="${RPC_URL:-}"
if [[ -z "$RPC_URL" ]]; then
  echo "ERROR: RPC_URL is empty in ./${CONFIG_PATH}"
  exit 1
fi

TOKEN0="${TOKEN0:-}"
TOKEN1="${TOKEN1:-}"
if [[ -z "$TOKEN0" || -z "$TOKEN1" ]]; then
  echo "ERROR: TOKEN0 and TOKEN1 must be set in ./${CONFIG_PATH}"
  exit 1
fi

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Canonical ordering (same as CreatePool.s.sol)
_t0="$(lower "$TOKEN0")"
_t1="$(lower "$TOKEN1")"
if [[ "$_t0" > "$_t1" ]]; then
  echo "Note: swapping TOKEN0/TOKEN1 to match canonical ordering (address sort)."
  tmp="$TOKEN0"; TOKEN0="$TOKEN1"; TOKEN1="$tmp"
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

  while true; do
    read -r -p "Could not fetch decimals() for ${addr}. Enter decimals manually: " out
    if [[ "$out" =~ ^[0-9]+$ ]] && (( out >= 0 )) && (( out <= 36 )); then
      echo "$out"
      return
    fi
    echo "Invalid decimals. Try again."
  done
}

DEC0="$(read_decimals "$TOKEN0")"
DEC1="$(read_decimals "$TOKEN1")"

echo
echo "=== Inputs from ./${CONFIG_PATH} ==="
echo "RPC_URL : $RPC_URL"
echo "TOKEN0  : $TOKEN0 (decimals=$DEC0)"
echo "TOKEN1  : $TOKEN1 (decimals=$DEC1)"
echo

# If this is not an interactive terminal, don't try to prompt.
if [[ ! -t 0 ]]; then
  echo "ERROR: interactive input required (no TTY)."
  exit 1
fi

read -r -p "Enter price value (e.g. 2200.5): " PRICE_STR
if [[ -z "$PRICE_STR" ]]; then
  echo "ERROR: price is empty"
  exit 1
fi

read -r -p "Is this price TOKEN0 per 1 TOKEN1? [Y/n]: " QUOTE
QUOTE="${QUOTE:-Y}"

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

echo
echo "=== Result ==="
echo "INIT_SQRT_PRICE_X96=$SQRT_PRICE_X96"
echo
echo "Sanity (implied):"
echo "  TOKEN0 per 1 TOKEN1 ~= $IMPLIED_0_PER_1"
echo "  TOKEN1 per 1 TOKEN0 ~= $IMPLIED_1_PER_0"
echo

if [[ "$WRITE_MODE" == "--write" ]]; then
  python3 - <<PY
import re
from pathlib import Path

path = Path("$CONFIG_PATH")
text = path.read_text()

if "INIT_SQRT_PRICE_X96=" not in text:
    # append if missing
    text += "\nINIT_SQRT_PRICE_X96=$SQRT_PRICE_X96\n"
else:
    text = re.sub(r"^INIT_SQRT_PRICE_X96=.*$", f"INIT_SQRT_PRICE_X96=$SQRT_PRICE_X96", text, flags=re.M)

path.write_text(text)
print(f"Wrote INIT_SQRT_PRICE_X96 to ./{path}")
PY
fi
