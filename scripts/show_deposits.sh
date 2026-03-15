#!/usr/bin/env bash
set -euo pipefail

# Auxiliary helper:
# Aggregate current net LP liquidity by wallet in USD for a Uniswap v4 pool.
#
# Examples:
#   ./scripts/show_deposits.sh --chain optimism
#   ./scripts/show_deposits.sh --chain optimism --pool-id 0x... --from-block 0x8d8245c
#   ./scripts/show_deposits.sh --chain optimism --csv /tmp/lp_liquidity_usd.csv

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

usage() {
  cat <<'EOF'
Usage:
  ./scripts/show_deposits.sh --chain <chain> [options]

Options:
  --chain <name>               Supported ops network: local, sepolia, optimism.
  --rpc-url <url>              Override RPC URL from ops defaults.
  --pool-manager <addr>        Override PoolManager address.
  --pool-id <bytes32>          PoolId. If omitted, tries to read from hook_status.sh.
  --from-block <hex|int>       Start block (default: latest - 2,000,000 blocks).
  --to-block <hex|latest>      End block (default: latest).
  --stable <addr>              Stable token address for transfer parsing.
  --stable-decimals <int>      Stable token decimals (default: from config, else 6).
  --eth-usd <number>           ETH/USD for USD aggregation (default: auto from hook_status).
  --csv <path>                 Optional CSV path for wallet aggregate.
  --cache-path <path>          Optional tx-from cache path (default: tmp/private_lp_txfrom_<chain>.json).
  -h, --help                   Show help.
EOF
}

ops_defaults_env_path() {
  case "$1" in
    local|sepolia|optimism) printf './ops/%s/config/defaults.env\n' "$1" ;;
    *)
      echo "ERROR: unsupported --chain '$1' (expected local, sepolia, or optimism)" >&2
      return 1
      ;;
  esac
}

ops_state_path() {
  printf './ops/%s/out/state/%s.addresses.json\n' "$1" "$1"
}

require_cmd() {
  local c="$1"
  command -v "${c}" >/dev/null 2>&1 || { echo "ERROR: required command not found: ${c}" >&2; exit 1; }
}

to_dec_block() {
  local v="${1:-}"
  local vv
  vv="$(lower "${v}")"
  if [[ "${vv}" == 0x* ]]; then
    echo $((16#${vv#0x}))
  else
    echo $((vv))
  fi
}

to_hex_block() {
  printf '0x%x' "$1"
}

rpc_post() {
  local payload="$1"
  local attempt resp last_err
  last_err=""
  for attempt in 1 2 3 4 5; do
    resp="$(printf '%s' "${payload}" | curl -sS --connect-timeout 4 --max-time 20 -H 'content-type: application/json' --data @- "${RPC_URL}" 2>&1 || true)"
    if [[ -n "${resp}" ]] && printf '%s' "${resp}" | jq -e . >/dev/null 2>&1; then
      printf '%s\n' "${resp}"
      return 0
    fi
    if [[ -n "${resp}" ]]; then
      last_err="${resp}"
    fi
    sleep 1
  done
  if [[ -n "${last_err}" ]]; then
    printf '%s\n' "${last_err}" >&2
  fi
  return 1
}

CHAIN=""
RPC_URL_CLI=""
POOL_MANAGER_CLI=""
POOL_ID_CLI=""
FROM_BLOCK=""
TO_BLOCK="latest"
STABLE_CLI=""
STABLE_DECIMALS_CLI=""
ETH_USD_CLI=""
CSV_PATH=""
CACHE_PATH_CLI=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --rpc-url) RPC_URL_CLI="${2:-}"; shift 2 ;;
    --pool-manager) POOL_MANAGER_CLI="${2:-}"; shift 2 ;;
    --pool-id) POOL_ID_CLI="${2:-}"; shift 2 ;;
    --from-block) FROM_BLOCK="${2:-}"; shift 2 ;;
    --to-block) TO_BLOCK="${2:-}"; shift 2 ;;
    --stable) STABLE_CLI="${2:-}"; shift 2 ;;
    --stable-decimals) STABLE_DECIMALS_CLI="${2:-}"; shift 2 ;;
    --eth-usd) ETH_USD_CLI="${2:-}"; shift 2 ;;
    --csv) CSV_PATH="${2:-}"; shift 2 ;;
    --cache-path) CACHE_PATH_CLI="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

CHAIN="$(lower "${CHAIN:-}")"
if [[ -z "${CHAIN}" ]]; then
  echo "ERROR: --chain is required" >&2
  usage
  exit 1
fi

require_cmd curl
require_cmd jq
require_cmd python3

HOOK_CONF="$(ops_defaults_env_path "${CHAIN}")"
if [[ ! -f "${HOOK_CONF}" ]]; then
  echo "ERROR: config not found: ${HOOK_CONF}" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "${HOOK_CONF}"
DEPLOY_HOOK_CONF="$(dirname "${HOOK_CONF}")/deploy.env"
if [[ -f "${DEPLOY_HOOK_CONF}" ]]; then
  # shellcheck disable=SC1090
  source "${DEPLOY_HOOK_CONF}"
fi
if [[ -f "./.env" ]]; then
  # shellcheck disable=SC1091
  source "./.env"
fi
set +a

STATE_JSON="$(ops_state_path "${CHAIN}")"
if [[ -f "${STATE_JSON}" ]]; then
  state_pool_manager="$(jq -r '.poolManager // empty' "${STATE_JSON}")"
  state_stable="$(jq -r '.stableToken // empty' "${STATE_JSON}")"
  if [[ -z "${POOL_MANAGER:-}" && -n "${state_pool_manager}" ]]; then
    POOL_MANAGER="${state_pool_manager}"
  fi
  if [[ -z "${STABLE:-}" && -n "${state_stable}" ]]; then
    STABLE="${state_stable}"
  fi
fi

RPC_URL="${RPC_URL_CLI:-${RPC_URL:-}}"
POOL_MANAGER="${POOL_MANAGER_CLI:-${POOL_MANAGER:-${DEPLOY_POOL_MANAGER:-}}}"
STABLE_ADDR="$(lower "${STABLE_CLI:-${STABLE:-${DEPLOY_STABLE:-}}}")"
STABLE_DECIMALS="${STABLE_DECIMALS_CLI:-${STABLE_DECIMALS:-${DEPLOY_STABLE_DECIMALS:-6}}}"
VOLATILE_DECIMALS="${VOLATILE_DECIMALS:-18}"
ETH_USD="${ETH_USD_CLI:-}"
POOL_ID="${POOL_ID_CLI:-}"
CACHE_PATH="${CACHE_PATH_CLI:-tmp/show_deposits_txfrom_${CHAIN}.json}"

if [[ -z "${RPC_URL}" ]]; then
  echo "ERROR: RPC_URL missing (config or --rpc-url)" >&2
  exit 1
fi
if [[ -z "${POOL_MANAGER}" ]]; then
  echo "ERROR: POOL_MANAGER missing (config or --pool-manager)" >&2
  exit 1
fi

HOOK_STATUS_OUTPUT=""
if [[ -x "./scripts/hook_status.sh" ]] && ([[ -z "${POOL_ID}" ]] || [[ -z "${ETH_USD}" ]]); then
  HOOK_STATUS_OUTPUT="$(./scripts/hook_status.sh --chain "${CHAIN}" --rpc-url "${RPC_URL}" 2>/dev/null || true)"
fi

if [[ -z "${POOL_ID}" ]]; then
  POOL_ID="$(printf '%s\n' "${HOOK_STATUS_OUTPUT}" | sed -n 's/^pool_id=//p' | head -n 1)"
fi
if [[ -z "${POOL_ID}" ]]; then
  echo "ERROR: failed to resolve pool_id. Pass --pool-id explicitly." >&2
  exit 1
fi

if [[ -z "${ETH_USD}" ]]; then
  ETH_USD="$(printf '%s\n' "${HOOK_STATUS_OUTPUT}" | sed -n 's/.*price_stable_per_volatile=\([^ ]*\).*/\1/p' | head -n 1)"
fi
if [[ -z "${ETH_USD}" ]] && [[ -n "${INIT_PRICE_USD:-}" ]]; then
  ETH_USD="${INIT_PRICE_USD}"
fi
if ! [[ "${ETH_USD}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  ETH_USD="0"
fi
if [[ -z "${ETH_USD}" ]]; then
  ETH_USD="0"
fi

# keccak256("ModifyLiquidity(bytes32,address,int24,int24,int256,bytes32)")
MODIFY_TOPIC0="0xf208f4912782fd25c7f114ca3723a2d5dd6f3bcc3ac8db5af63baa85f711d5ec"
# keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
SWAP_TOPIC0="0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

modify_logs_json="${tmpdir}/modify_logs.json"
modify_logs_ndjson="${tmpdir}/modify_logs.ndjson"
latest_swap_log_json="${tmpdir}/latest_swap_log.json"
if [[ "$(lower "${TO_BLOCK}")" == "latest" ]]; then
  payload_latest='{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}'
  if ! latest_resp="$(rpc_post "${payload_latest}")"; then
    echo "ERROR: RPC request failed after retries (eth_blockNumber)" >&2
    exit 1
  fi
  to_block_dec="$(to_dec_block "$(printf '%s' "${latest_resp}" | jq -r '.result')")"
else
  to_block_dec="$(to_dec_block "${TO_BLOCK}")"
fi

if [[ -z "${FROM_BLOCK}" ]]; then
  lookback_blocks=2000000
  from_block_dec=$((to_block_dec - lookback_blocks))
  if (( from_block_dec < 0 )); then
    from_block_dec=0
  fi
else
  from_block_dec="$(to_dec_block "${FROM_BLOCK}")"
fi

if (( from_block_dec > to_block_dec )); then
  echo "ERROR: from-block is greater than to-block" >&2
  exit 1
fi

# 1) Fetch ModifyLiquidity logs in chunks (RPC limit: 50k blocks).
: > "${modify_logs_ndjson}"
chunk_span=49999
start="${from_block_dec}"
while (( start <= to_block_dec )); do
  end=$((start + chunk_span))
  if (( end > to_block_dec )); then
    end="${to_block_dec}"
  fi

  payload_logs="$(jq -nc \
    --arg a "${POOL_MANAGER}" \
    --arg fb "$(to_hex_block "${start}")" \
    --arg tb "$(to_hex_block "${end}")" \
    --arg t0 "${MODIFY_TOPIC0}" \
    --arg pid "${POOL_ID}" \
    '{jsonrpc:"2.0",id:1,method:"eth_getLogs",params:[{address:$a,fromBlock:$fb,toBlock:$tb,topics:[$t0,$pid]}]}'
  )"

  if ! logs_resp="$(rpc_post "${payload_logs}")"; then
    echo "ERROR: RPC request failed after retries (eth_getLogs ModifyLiquidity)" >&2
    exit 1
  fi
  if [[ "$(printf '%s' "${logs_resp}" | jq -r 'has("error")')" == "true" ]]; then
    echo "ERROR: eth_getLogs ModifyLiquidity failed:" >&2
    printf '%s\n' "${logs_resp}" | jq -r '.error' >&2
    exit 1
  fi
  printf '%s\n' "${logs_resp}" | jq -c '.result[]?' >> "${modify_logs_ndjson}"

  start=$((end + 1))
done
jq -s '.' "${modify_logs_ndjson}" > "${modify_logs_json}"

event_count="$(jq 'length' "${modify_logs_json}")"
if [[ "${event_count}" == "0" ]]; then
  echo "Wallet\tCurrent Liquidity (USD)\tShare"
  echo "Total\t$0.00\t100.00%"
  exit 0
fi

# 2) Find latest Swap log by scanning chunks backwards.
printf 'null' > "${latest_swap_log_json}"
end="${to_block_dec}"
found_swap=0
while (( end >= from_block_dec )); do
  start=$((end - chunk_span))
  if (( start < from_block_dec )); then
    start="${from_block_dec}"
  fi

  payload_swap="$(jq -nc \
    --arg a "${POOL_MANAGER}" \
    --arg fb "$(to_hex_block "${start}")" \
    --arg tb "$(to_hex_block "${end}")" \
    --arg t0 "${SWAP_TOPIC0}" \
    --arg pid "${POOL_ID}" \
    '{jsonrpc:"2.0",id:1,method:"eth_getLogs",params:[{address:$a,fromBlock:$fb,toBlock:$tb,topics:[$t0,$pid]}]}'
  )"

  if ! swap_resp="$(rpc_post "${payload_swap}")"; then
    echo "ERROR: RPC request failed after retries (eth_getLogs Swap)" >&2
    exit 1
  fi
  if [[ "$(printf '%s' "${swap_resp}" | jq -r 'has("error")')" == "true" ]]; then
    echo "ERROR: eth_getLogs Swap failed:" >&2
    printf '%s\n' "${swap_resp}" | jq -r '.error' >&2
    exit 1
  fi

  swap_count="$(printf '%s\n' "${swap_resp}" | jq '.result | length')"
  if (( swap_count > 0 )); then
    printf '%s\n' "${swap_resp}" | jq -c '.result[-1]' > "${latest_swap_log_json}"
    found_swap=1
    break
  fi

  if (( start == from_block_dec )); then
    break
  fi
  end=$((start - 1))
done

if (( found_swap == 0 )); then
  echo "ERROR: no Swap logs found in selected block range; cannot value active liquidity." >&2
  echo "Hint: pass an earlier --from-block" >&2
  exit 1
fi

# 3) Compute current net USD liquidity per wallet.
python3 - "${modify_logs_json}" "${latest_swap_log_json}" "${STABLE_DECIMALS}" "${VOLATILE_DECIMALS}" "${ETH_USD}" "${CSV_PATH}" "${RPC_URL}" "${CACHE_PATH}" <<'PY'
import csv
import json
import sys
import subprocess
import time
from collections import defaultdict
from decimal import Decimal, getcontext

getcontext().prec = 80

(
    modify_logs_path,
    latest_swap_log_path,
    stable_decimals_s,
    volatile_decimals_s,
    eth_usd_override_s,
    csv_path,
    rpc_url,
    cache_path,
) = sys.argv[1:]

stable_decimals = int(stable_decimals_s)
volatile_decimals = int(volatile_decimals_s)
eth_usd_override = Decimal(eth_usd_override_s)
Q96 = Decimal(2) ** 96

with open(modify_logs_path, "r", encoding="utf-8") as f:
    modify_logs = json.load(f)

with open(latest_swap_log_path, "r", encoding="utf-8") as f:
    swap_log = json.load(f)

def rpc_batch_tx_from(tx_hashes, rpc_url_value, batch_size=100, retries=6):
    out = {}
    if not tx_hashes:
        return out

    def chunks(arr, n):
        for i in range(0, len(arr), n):
            yield arr[i : i + n]

    for chunk in chunks(tx_hashes, batch_size):
        payload = []
        for i, txh in enumerate(chunk):
            payload.append(
                {
                    "jsonrpc": "2.0",
                    "id": i + 1,
                    "method": "eth_getTransactionByHash",
                    "params": [txh],
                }
            )

        payload_str = json.dumps(payload)
        last_err = ""
        ok = False
        for _ in range(retries):
            cmd = [
                "zsh",
                "-lc",
                "curl -sS --connect-timeout 4 --max-time 30 -H 'content-type: application/json' --data @- '"
                + rpc_url_value
                + "'",
            ]
            proc = subprocess.run(cmd, input=payload_str, text=True, capture_output=True)
            if proc.returncode != 0:
                last_err = proc.stderr.strip() or f"curl exit {proc.returncode}"
                time.sleep(1)
                continue
            try:
                resp = json.loads(proc.stdout)
            except Exception as e:
                last_err = f"json decode error: {e}"
                time.sleep(1)
                continue

            if isinstance(resp, dict) and resp.get("error"):
                last_err = str(resp["error"])
                time.sleep(1)
                continue
            if not isinstance(resp, list):
                last_err = "unexpected non-list batch response"
                time.sleep(1)
                continue

            for item in resp:
                res = item.get("result") if isinstance(item, dict) else None
                if not isinstance(res, dict):
                    continue
                h = res.get("hash")
                frm = res.get("from")
                if isinstance(h, str) and isinstance(frm, str):
                    out[h] = frm.lower()
            ok = True
            break

        if not ok:
            raise RuntimeError(f"batch eth_getTransactionByHash failed: {last_err}")

    return out

tx_hashes = sorted({lg.get("transactionHash") for lg in modify_logs if isinstance(lg.get("transactionHash"), str)})

# Persistent local cache: txHash -> tx.from.
cache = {}
try:
    with open(cache_path, "r", encoding="utf-8") as f:
        obj = json.load(f)
        if isinstance(obj, dict):
            cache = {str(k): str(v).lower() for k, v in obj.items()}
except FileNotFoundError:
    cache = {}
except Exception:
    cache = {}

missing = [h for h in tx_hashes if h not in cache]
if missing:
    fetched = rpc_batch_tx_from(missing, rpc_url_value=rpc_url)
    cache.update(fetched)
    try:
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump(cache, f, indent=2, sort_keys=True)
    except Exception:
        pass

tx_from = cache

def signed256(hex_word: str) -> int:
    x = int(hex_word, 16)
    if x >= 2**255:
        x -= 2**256
    return x

def sqrt_ratio_at_tick(tick: int) -> Decimal:
    cached = sqrt_cache.get(tick)
    if cached is not None:
        return cached
    val = (Decimal("1.0001") ** (Decimal(tick) / Decimal(2))) * (Decimal(2) ** 96)
    sqrt_cache[tick] = val
    return val

# Swap data layout:
# amount0(int128), amount1(int128), sqrtPriceX96(uint160), liquidity(uint128), tick(int24), fee(uint24)
swap_data = swap_log["data"][2:]
swap_words = [swap_data[i : i + 64] for i in range(0, len(swap_data), 64)]
sqrt_price_x96 = Decimal(int(swap_words[2], 16))

pool_price_stable_per_volatile = (sqrt_price_x96 / Q96) ** 2 * (Decimal(10) ** (volatile_decimals - stable_decimals))
valuation_price = eth_usd_override if eth_usd_override > 0 else pool_price_stable_per_volatile

# Net liquidity per (wallet, tickLower, tickUpper)
buckets = defaultdict(Decimal)
sqrt_cache = {}
for lg in modify_logs:
    data = lg["data"][2:]
    words = [data[i : i + 64] for i in range(0, len(data), 64)]
    if len(words) < 4:
        continue
    tx_hash = lg["transactionHash"]
    wallet = tx_from.get(tx_hash)
    if not wallet:
        continue

    tick_lower = signed256(words[0])
    tick_upper = signed256(words[1])
    liquidity_delta = Decimal(signed256(words[2]))
    buckets[(wallet, tick_lower, tick_upper)] += liquidity_delta

wallet_usd = defaultdict(Decimal)
for (wallet, tick_lower, tick_upper), liquidity in buckets.items():
    if liquidity <= 0:
        continue

    sa = sqrt_ratio_at_tick(tick_lower)
    sb = sqrt_ratio_at_tick(tick_upper)
    sp = sqrt_price_x96

    if sp <= sa:
        amount0_raw = liquidity * (sb - sa) * Q96 / (sa * sb)
        amount1_raw = Decimal(0)
    elif sp < sb:
        amount0_raw = liquidity * (sb - sp) * Q96 / (sp * sb)
        amount1_raw = liquidity * (sp - sa) / Q96
    else:
        amount0_raw = Decimal(0)
        amount1_raw = liquidity * (sb - sa) / Q96

    amount0 = amount0_raw / (Decimal(10) ** volatile_decimals)
    amount1 = amount1_raw / (Decimal(10) ** stable_decimals)
    usd_value = amount1 + amount0 * valuation_price
    wallet_usd[wallet] += usd_value

ranked = sorted(wallet_usd.items(), key=lambda kv: kv[1], reverse=True)
total_usd = sum(v for _, v in ranked)

headers = ("#", "Wallet", "Current Liquidity (USD)", "Share")
rows = []
for idx, (wallet, usd_value) in enumerate(ranked, start=1):
    share = (usd_value / total_usd * Decimal(100)) if total_usd > 0 else Decimal(0)
    usd_fmt = "$" + format(usd_value.quantize(Decimal("0.01")), ",.2f")
    share_fmt = f"{share.quantize(Decimal('0.01'))}%"
    rows.append((str(idx), wallet, usd_fmt, share_fmt))

wallet_count = len(ranked)
total_fmt = "$" + format(total_usd.quantize(Decimal("0.01")), ",.2f")
total_row = ("", "Total", total_fmt, "100.00%")

col_w = [
    max(len(headers[0]), *(len(r[0]) for r in rows)),
    max(len(headers[1]), *(len(r[1]) for r in rows)),
    max(len(headers[2]), *(len(r[2]) for r in rows)),
    max(len(headers[3]), *(len(r[3]) for r in rows)),
]

sep = "+-" + "-+-".join("-" * w for w in col_w) + "-+"
print(sep)
print(
    "| "
    + headers[0].ljust(col_w[0])
    + " | "
    + headers[1].ljust(col_w[1])
    + " | "
    + headers[2].ljust(col_w[2])
    + " | "
    + headers[3].ljust(col_w[3])
    + " |"
)
print(sep)
for idx, wallet, usd_fmt, share_fmt in rows:
    print(
        "| "
        + idx.rjust(col_w[0])
        + " | "
        + wallet.ljust(col_w[1])
        + " | "
        + usd_fmt.rjust(col_w[2])
        + " | "
        + share_fmt.rjust(col_w[3])
        + " |"
    )
print(sep)
idx, wallet, usd_fmt, share_fmt = total_row
print(
    "| "
    + idx.rjust(col_w[0])
    + " | "
    + wallet.ljust(col_w[1])
    + " | "
    + usd_fmt.rjust(col_w[2])
    + " | "
    + share_fmt.rjust(col_w[3])
    + " |"
)
print(sep)
print(f"Wallets: {wallet_count}")

if csv_path:
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["wallet", "current_liquidity_usd", "share_pct"])
        for wallet, usd_value in ranked:
            share = (usd_value / total_usd * Decimal(100)) if total_usd > 0 else Decimal(0)
            w.writerow([wallet, str(usd_value.quantize(Decimal("0.01"))), str(share.quantize(Decimal("0.01")))])
        w.writerow(["Total", str(total_usd.quantize(Decimal("0.01"))), "100.00"])
PY
