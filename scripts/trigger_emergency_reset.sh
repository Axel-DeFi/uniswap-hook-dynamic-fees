#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

CHAIN="optimism"
RPC_URL="${RPC_URL:-}"
AMOUNT_IN_ETH="0.000001"
MIN_AMOUNT_OUT="${MIN_AMOUNT_OUT:-0}"
DEADLINE_SECONDS="${DEADLINE_SECONDS:-900}"

usage() {
  echo "Usage: $0 [--chain optimism] [--amount 0.000001]" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

clean_uint() {
  printf '%s' "$1" | awk '{print $1}' | tr -cd '0-9'
}

native_price_id() {
  case "$1" in
    optimism|arbitrum|base|ethereum|mainnet) echo "ethereum" ;;
    bsc|bnb) echo "binancecoin" ;;
    avalanche) echo "avalanche-2" ;;
    polygon) echo "matic-network" ;;
    sonic) echo "sonic-3" ;;
    *) echo "" ;;
  esac
}

native_symbol() {
  case "$1" in
    optimism|arbitrum|base|ethereum|mainnet) echo "ETH" ;;
    bsc|bnb) echo "BNB" ;;
    avalanche) echo "AVAX" ;;
    polygon) echo "POL" ;;
    sonic) echo "S" ;;
    *) echo "NATIVE" ;;
  esac
}

json_rpc() {
  local method="$1"
  local params="$2"

  curl -fsS \
    -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
    "$RPC_URL"
}

call_uint() {
  local to="$1"
  local sig="$2"
  shift 2
  clean_uint "$(cast call "$to" "$sig" "$@" --rpc-url "$RPC_URL" 2>/dev/null || true)"
}

call_string() {
  local to="$1"
  local sig="$2"
  shift 2
  cast call "$to" "$sig" "$@" --rpc-url "$RPC_URL" 2>/dev/null | tr -d '"\n'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain)
      [[ $# -ge 2 ]] || usage
      CHAIN="$2"
      shift 2
      ;;
    --amount)
      [[ $# -ge 2 ]] || usage
      AMOUNT_IN_ETH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

require_cmd cast
require_cmd curl
require_cmd python3
require_cmd awk

ROOT_ENV="$REPO_DIR/.env"
if [[ -f "$ROOT_ENV" ]]; then
  set -a
  . "$ROOT_ENV"
  set +a
fi

CONFIG_DIR="$REPO_DIR/ops/$CHAIN/config"
DEFAULTS_ENV="$CONFIG_DIR/defaults.env"
DEPLOY_ENV="$CONFIG_DIR/deploy.env"

[[ -f "$DEFAULTS_ENV" ]] || { echo "Missing config: $DEFAULTS_ENV" >&2; exit 1; }
[[ -f "$DEPLOY_ENV" ]] || { echo "Missing config: $DEPLOY_ENV" >&2; exit 1; }

set -a
. "$DEFAULTS_ENV"
. "$DEPLOY_ENV"
set +a

PRIVATE_KEY="${PRIVATE_KEY:-${DEFAULT_PRIVATE_KEY:-}}"
: "${PRIVATE_KEY:?PRIVATE_KEY is not set and DEFAULT_PRIVATE_KEY was not found in .env}"

RPC_URL="${RPC_URL:?RPC_URL is missing in config}"
HOOK_ADDRESS="${HOOK_ADDRESS:?HOOK_ADDRESS is missing in config}"
STABLE_TOKEN="${DEPLOY_STABLE:?DEPLOY_STABLE is missing in config}"
VOLATILE_TOKEN="${DEPLOY_VOLATILE:?DEPLOY_VOLATILE is missing in config}"
TICK_SPACING="${DEPLOY_TICK_SPACING:?DEPLOY_TICK_SPACING is missing in config}"

ZERO_ADDRESS="0x0000000000000000000000000000000000000000"
if [[ "$(lower "$VOLATILE_TOKEN")" != "$(lower "$ZERO_ADDRESS")" ]]; then
  echo "This script supports native -> stable pools only." >&2
  exit 1
fi

UNIVERSAL_ROUTER="${UNIVERSAL_ROUTER:-${UNIVERSAL_ROUTER_ADDRESS:-}}"
if [[ -z "$UNIVERSAL_ROUTER" ]]; then
  case "$CHAIN" in
    optimism)
      UNIVERSAL_ROUTER="0x851116d9223fabed8e56c0e6b8ad0c31d98b3507"
      ;;
    *)
      echo "UNIVERSAL_ROUTER is not set for chain '$CHAIN'." >&2
      exit 1
      ;;
  esac
fi

DYNAMIC_FEE_FLAG="8388608"
AMOUNT_IN_WEI="$(cast to-wei "$AMOUNT_IN_ETH" ether | tr -d '\n')"
DEADLINE="$(( $(date +%s) + DEADLINE_SECONDS ))"
SENDER="$(cast wallet address --private-key "$PRIVATE_KEY" | tr -d '\n')"

STABLE_SYMBOL="$(call_string "$STABLE_TOKEN" "symbol()(string)")"
STABLE_DECIMALS="$(call_uint "$STABLE_TOKEN" "decimals()(uint8)")"
STABLE_SYMBOL="${STABLE_SYMBOL:-TOKEN}"
STABLE_DECIMALS="${STABLE_DECIMALS:-18}"
NATIVE_SYMBOL="$(native_symbol "$CHAIN")"

SWAP_PARAMS="$(cast abi-encode \
  "f(((address,address,uint24,int24,address),bool,uint128,uint128,bytes))" \
  "(($ZERO_ADDRESS,$STABLE_TOKEN,$DYNAMIC_FEE_FLAG,$TICK_SPACING,$HOOK_ADDRESS),true,$AMOUNT_IN_WEI,$MIN_AMOUNT_OUT,0x)")"

SETTLE_ALL_PARAMS="$(cast abi-encode \
  "f(address,uint256)" \
  "$ZERO_ADDRESS" "$AMOUNT_IN_WEI")"

TAKE_ALL_PARAMS="$(cast abi-encode \
  "f(address,uint256)" \
  "$STABLE_TOKEN" "$MIN_AMOUNT_OUT")"

V4_SWAP_INPUT="$(cast abi-encode \
  "f(bytes,bytes[])" \
  0x060c0f \
  "[$SWAP_PARAMS,$SETTLE_ALL_PARAMS,$TAKE_ALL_PARAMS]")"

set +e
SEND_OUT="$(cast send "$UNIVERSAL_ROUTER" \
  "execute(bytes,bytes[],uint256)" \
  0x10 \
  "[$V4_SWAP_INPUT]" \
  "$DEADLINE" \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --value "$AMOUNT_IN_WEI" 2>&1)"
SEND_RC=$?
set -e

TX_HASH="$(printf '%s\n' "$SEND_OUT" | grep -Eo '0x[a-fA-F0-9]{64}' | tail -n1 || true)"

RED=$'\033[31m'
GREEN=$'\033[32m'
RESET=$'\033[0m'

if [[ -z "$TX_HASH" ]]; then
  echo "Operation: Swap ${AMOUNT_IN_ETH} ${NATIVE_SYMBOL} for 0.00000000 ${STABLE_SYMBOL}"
  echo -e "Status: ${RED}FAILED${RESET}"
  echo "GasUsed: n/a (n/a)"
  echo "TransactionHash: n/a"
  exit "${SEND_RC:-1}"
fi

RECEIPT_JSON=""
for _ in $(seq 1 60); do
  RECEIPT_JSON="$(json_rpc "eth_getTransactionReceipt" "[\"$TX_HASH\"]" || true)"
  HAS_RESULT="$(printf '%s' "$RECEIPT_JSON" | python3 -c 'import json,sys
try:
    obj=json.load(sys.stdin)
    print("1" if obj.get("result") else "0")
except Exception:
    print("0")')"
  [[ "$HAS_RESULT" == "1" ]] && break
  sleep 2
done

if [[ -z "$RECEIPT_JSON" ]]; then
  echo "Operation: Swap ${AMOUNT_IN_ETH} ${NATIVE_SYMBOL} for 0.00000000 ${STABLE_SYMBOL}"
  echo -e "Status: ${RED}FAILED${RESET}"
  echo "GasUsed: n/a (n/a)"
  echo "TransactionHash: $TX_HASH"
  exit 1
fi

NATIVE_PRICE_ID="$(native_price_id "$CHAIN")"
NATIVE_USD=""

if [[ -n "$NATIVE_PRICE_ID" ]]; then
  PRICE_JSON="$(curl -fsS "https://api.coingecko.com/api/v3/simple/price?ids=${NATIVE_PRICE_ID}&vs_currencies=usd" || true)"
  if [[ -n "$PRICE_JSON" ]]; then
    NATIVE_USD="$(printf '%s' "$PRICE_JSON" | python3 -c "import json,sys
try:
    obj=json.load(sys.stdin)
    price=obj.get('$NATIVE_PRICE_ID', {}).get('usd')
    print('' if price is None else price)
except Exception:
    print('')")"
  fi
fi

PARSED="$(RECEIPT_JSON="$RECEIPT_JSON" \
STABLE_TOKEN="$STABLE_TOKEN" \
STABLE_DECIMALS="$STABLE_DECIMALS" \
SENDER="$SENDER" \
NATIVE_USD="$NATIVE_USD" \
python3 - <<'PY'
import json
import os
from decimal import Decimal, ROUND_DOWN

TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55aeb"

def fmt_trim(value: Decimal, places: int) -> str:
    q = value.quantize(Decimal("1." + "0" * places), rounding=ROUND_DOWN)
    s = format(q, "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s if s else "0"

def fmt_fixed(value: Decimal, places: int) -> str:
    q = value.quantize(Decimal("1." + "0" * places), rounding=ROUND_DOWN)
    return format(q, "f")

receipt = json.loads(os.environ["RECEIPT_JSON"])["result"]
status = int(receipt.get("status", "0x0"), 16)
gas_used = int(receipt.get("gasUsed", "0x0"), 16)
effective_gas_price = int(receipt.get("effectiveGasPrice", "0x0"), 16)

stable_token = os.environ["STABLE_TOKEN"].lower()
stable_decimals = int(os.environ["STABLE_DECIMALS"])
sender = os.environ["SENDER"].lower().replace("0x", "")
native_usd_raw = os.environ.get("NATIVE_USD", "").strip()

out_raw = 0
for log in receipt.get("logs", []):
    if log.get("address", "").lower() != stable_token:
        continue
    topics = [t.lower() for t in log.get("topics", [])]
    if len(topics) < 3:
        continue
    if topics[0] != TRANSFER_TOPIC:
        continue
    if not topics[2].endswith(sender):
        continue
    data_hex = log.get("data", "0x0")
    out_raw += int(data_hex, 16)

output_amount = Decimal(out_raw) / (Decimal(10) ** stable_decimals)

fee_wei = gas_used * effective_gas_price
gas_gwei = Decimal(fee_wei) / Decimal(10**9)

if native_usd_raw:
    gas_usd = (Decimal(fee_wei) / Decimal(10**18)) * Decimal(native_usd_raw)
    gas_usd_str = f"${fmt_fixed(gas_usd, 8)}"
else:
    gas_usd_str = "n/a"

print("SUCCESS" if status == 1 else "FAILED")
print(fmt_fixed(output_amount, 8))
print(fmt_trim(gas_gwei, 6))
print(gas_usd_str)
PY
)"

TX_STATUS_TEXT="$(printf '%s\n' "$PARSED" | sed -n '1p')"
OUTPUT_AMOUNT="$(printf '%s\n' "$PARSED" | sed -n '2p')"
GAS_GWEI="$(printf '%s\n' "$PARSED" | sed -n '3p')"
GAS_USD="$(printf '%s\n' "$PARSED" | sed -n '4p')"

if [[ "$TX_STATUS_TEXT" == "SUCCESS" ]]; then
  STATUS_LINE="${GREEN}SUCCESS${RESET}"
else
  STATUS_LINE="${RED}FAILED${RESET}"
fi

echo "Operation: Swap ${AMOUNT_IN_ETH} ${NATIVE_SYMBOL} for ${OUTPUT_AMOUNT} ${STABLE_SYMBOL}"
echo -e "Status: ${STATUS_LINE}"
echo "GasUsed: ${GAS_GWEI} gwei (${GAS_USD})"
echo "TransactionHash: ${TX_HASH}"