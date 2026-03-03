#!/usr/bin/env bash
set -euo pipefail

# Print on-chain health/status for a deployed VolumeDynamicFeeHook + bound v4 pool.
#
# Usage examples:
#   ./scripts/hook_status.sh --chain optimism
#   ./scripts/hook_status.sh --chain optimism --refresh 15
#   ./scripts/hook_status.sh --chain optimism --hook-address 0x... --state-view-address 0x...

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

usage() {
  cat <<'EOF'
Usage:
  ./scripts/hook_status.sh --chain <chain> [--rpc-url <url>] [--hook-address <addr>] [--state-view-address <addr>] [--refresh <int>]

Options:
  --chain <chain>               Chain config name (e.g. optimism, sepolia, arbitrum, local).
  --rpc-url <url>               Override RPC URL from config.
  --hook-address <addr>         Override hook address. If empty, reads deploy artifact.
  --state-view-address <addr>   Optional StateView address. If empty, tries broadcast artifacts.
  --refresh <int>               Repeat status every N seconds (0 = one shot, default 0).
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

rpc_block_number() {
  local payload resp attempt
  payload='{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}'
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
result = data.get("result")
if isinstance(result, str) and result.startswith("0x"):
    print(int(result, 16))
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

find_pool_create_block_in_json() {
  local path="$1"
  local pool_id="$2"
  python3 - "${path}" "${pool_id}" <<'PY'
import json
import sys

path = sys.argv[1]
pool_id = sys.argv[2].lower()

def to_int(v):
    if isinstance(v, str):
        if v.startswith("0x"):
            return int(v, 16)
        return int(v)
    if isinstance(v, int):
        return v
    return None

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

txs = data.get("transactions") or []
receipts = data.get("receipts") or []

by_hash = {}
for rc in receipts:
    if isinstance(rc, dict):
        h = str(rc.get("transactionHash") or "").lower()
        if h:
            by_hash[h] = rc

for idx, tx in enumerate(txs):
    if not isinstance(tx, dict):
        continue
    args = tx.get("arguments") or []
    args_join = " ".join(a.lower() for a in args if isinstance(a, str))
    if pool_id not in args_join:
        continue
    rc = None
    if idx < len(receipts) and isinstance(receipts[idx], dict):
        rc = receipts[idx]
    if rc is None:
        h = str(tx.get("hash") or "").lower()
        if h and h in by_hash:
            rc = by_hash[h]
    if rc:
        block = to_int(rc.get("blockNumber"))
        if block is not None:
            print(block)
            raise SystemExit(0)

# fallback for common single-tx create scripts
if len(receipts) == 1 and isinstance(receipts[0], dict):
    block = to_int(receipts[0].get("blockNumber"))
    if block is not None:
        print(block)
        raise SystemExit(0)

print("")
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

compute_pool_activity_lifetime_line() {
  local from_block="$1"
  local to_block="$2"
  local stable_is_token1="$3"
  local stable_decimals="$4"
  local cache_file="$5"
  local chunk_size="$6"
  python3 - "${RPC_URL}" "${POOL_MANAGER}" "${POOL_ID}" "${from_block}" "${to_block}" "${stable_is_token1}" "${stable_decimals}" "${cache_file}" "${chunk_size}" <<'PY'
import json
import os
import subprocess
import sys
import time

rpc_url = sys.argv[1]
pool_manager = sys.argv[2]
pool_id = sys.argv[3].lower()
from_block = int(sys.argv[4])
to_block = int(sys.argv[5])
stable_is_token1 = (sys.argv[6] == "1")
stable_decimals = int(sys.argv[7])
cache_file = sys.argv[8]
chunk_size = int(sys.argv[9])

WINDOWS = [
    ("24h", 24 * 3600),
    ("7d", 7 * 24 * 3600),
    ("30d", 30 * 24 * 3600),
    ("90d", 90 * 24 * 3600),
    ("180d", 180 * 24 * 3600),
    ("365d", 365 * 24 * 3600),
]
RETENTION_SECONDS = 380 * 24 * 3600

swap_topic = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
modify_topic = "0xf208f4912782fd25c7f114ca3723a2d5dd6f3bcc3ac8db5af63baa85f711d5ec"
pool_topic = "0x" + pool_id[2:].rjust(64, "0")

def default_state():
    return {
        "schema_version": 5,
        "pool_id": pool_id,
        "from_block": from_block,
        "last_scanned_block": from_block - 1,
        "latest_block_ts": 0,
        "last_swap_sqrt_x96": 0,
        "swap_count": 0,
        "volume_usd6": 0,
        "fees_usd6": 0,
        "fee_weighted_usd6_pips": 0,
        "tx_from_by_hash": {},
        "block_ts_by_number": {},
        "hourly_buckets": {},
        "fee_buckets": {},
        "range_buckets": {},
        "lp_provider_wallets": [],
        "lp_senders": [],
    }

def load_state():
    if not os.path.exists(cache_file):
        return default_state()
    try:
        with open(cache_file, "r", encoding="utf-8") as f:
            state = json.load(f)
        if not isinstance(state, dict):
            return default_state()
        if int(state.get("schema_version", 0)) not in (5, 6):
            return default_state()
        if str(state.get("pool_id", "")).lower() != pool_id:
            return default_state()
        if int(state.get("from_block", -1)) != from_block:
            return default_state()
        st = default_state()
        st.update(state)
        st["schema_version"] = 5
        if not isinstance(st.get("tx_from_by_hash"), dict):
            st["tx_from_by_hash"] = {}
        st["tx_from_by_hash"] = {str(k).lower(): str(v).lower() for k, v in st["tx_from_by_hash"].items()}
        if not isinstance(st.get("block_ts_by_number"), dict):
            st["block_ts_by_number"] = {}
        st["block_ts_by_number"] = {str(k): int(v) for k, v in st["block_ts_by_number"].items()}
        if not isinstance(st.get("hourly_buckets"), dict):
            st["hourly_buckets"] = {}
        cleaned_buckets = {}
        for k, v in st["hourly_buckets"].items():
            try:
                hk = str(int(k))
            except Exception:
                continue
            if not isinstance(v, dict):
                continue
            cleaned_buckets[hk] = {
                "swaps": int(v.get("swaps", 0)),
                "volume_usd6": int(v.get("volume_usd6", 0)),
                "fees_usd6": int(v.get("fees_usd6", 0)),
            }
        st["hourly_buckets"] = cleaned_buckets
        if not isinstance(st.get("fee_buckets"), dict):
            st["fee_buckets"] = {}
        cleaned_fee_buckets = {}
        for k, v in st["fee_buckets"].items():
            try:
                fk = str(int(k))
            except Exception:
                continue
            if not isinstance(v, dict):
                continue
            cleaned_fee_buckets[fk] = {
                "swaps": int(v.get("swaps", 0)),
                "volume_usd6": int(v.get("volume_usd6", 0)),
                "fees_usd6": int(v.get("fees_usd6", 0)),
            }
        st["fee_buckets"] = cleaned_fee_buckets
        if not isinstance(st.get("range_buckets"), dict):
            st["range_buckets"] = {}
        cleaned_range_buckets = {}
        for k, v in st["range_buckets"].items():
            parts = str(k).split(":", 1)
            if len(parts) != 2:
                continue
            try:
                lower_tick = int(parts[0])
                upper_tick = int(parts[1])
                liq = int(v)
            except Exception:
                continue
            cleaned_range_buckets[f"{lower_tick}:{upper_tick}"] = liq
        st["range_buckets"] = cleaned_range_buckets
        try:
            st["last_swap_sqrt_x96"] = int(st.get("last_swap_sqrt_x96", 0))
        except Exception:
            st["last_swap_sqrt_x96"] = 0
        if not isinstance(st.get("lp_provider_wallets"), list):
            st["lp_provider_wallets"] = []
        st["lp_provider_wallets"] = [str(x).lower() for x in st["lp_provider_wallets"]]
        if not isinstance(st.get("lp_senders"), list):
            st["lp_senders"] = []
        st["lp_senders"] = [str(x).lower() for x in st["lp_senders"]]
        if int(st.get("last_scanned_block", from_block - 1)) < from_block - 1:
            st["last_scanned_block"] = from_block - 1
        return st
    except Exception:
        return default_state()

def save_state(state):
    os.makedirs(os.path.dirname(cache_file), exist_ok=True)
    tmp_file = cache_file + ".tmp"
    with open(tmp_file, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=True, separators=(",", ":"))
    os.replace(tmp_file, cache_file)

def rpc_post(payload):
    cmd = [
        "curl", "-sS", "--connect-timeout", "3", "--max-time", "12",
        "-H", "content-type: application/json",
        "--data", payload,
        rpc_url,
    ]
    last_err = ""
    for _ in range(3):
        try:
            out = subprocess.check_output(cmd, stderr=subprocess.STDOUT).decode("utf-8")
            data = json.loads(out)
            if isinstance(data, dict) and data.get("error") is not None:
                raise RuntimeError(str(data["error"]))
            return data
        except Exception as exc:
            last_err = str(exc)
            time.sleep(0.7)
    raise RuntimeError(last_err or "rpc_failed")

def rpc_get_logs(topic0, from_block, to_block):
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_getLogs",
        "params": [{
            "address": pool_manager,
            "fromBlock": hex(from_block),
            "toBlock": hex(to_block),
            "topics": [topic0, pool_topic],
        }],
    }, separators=(",", ":"))
    data = rpc_post(payload)
    logs = data.get("result")
    if not isinstance(logs, list):
        raise RuntimeError("invalid_logs_format")
    return logs

def rpc_get_tx_from(tx_hash):
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_getTransactionByHash",
        "params": [tx_hash],
    }, separators=(",", ":"))
    data = rpc_post(payload)
    tx = data.get("result")
    if not isinstance(tx, dict):
        return ""
    frm = str(tx.get("from") or "").lower()
    if frm.startswith("0x") and len(frm) == 42:
        return frm
    return ""

def rpc_get_block_timestamp(block_number):
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_getBlockByNumber",
        "params": [hex(block_number), False],
    }, separators=(",", ":"))
    data = rpc_post(payload)
    block = data.get("result")
    if not isinstance(block, dict):
        return 0
    ts = block.get("timestamp")
    if isinstance(ts, str) and ts.startswith("0x"):
        return int(ts, 16)
    return 0

def s256(hex_word):
    x = int(hex_word, 16)
    if x >= (1 << 255):
        x -= (1 << 256)
    return x

def to_int_block(block_value):
    if isinstance(block_value, str):
        if block_value.startswith("0x"):
            return int(block_value, 16)
        return int(block_value)
    if isinstance(block_value, int):
        return block_value
    return -1

def window_stats(state):
    latest_ts = int(state.get("latest_block_ts", 0))
    if latest_ts <= 0:
        latest_ts = int(time.time())
    buckets = state.get("hourly_buckets") or {}
    out = {}
    for label, seconds in WINDOWS:
        cutoff = latest_ts - seconds
        swaps = 0
        volume = 0
        fees = 0
        for hk, b in buckets.items():
            try:
                h = int(hk)
            except Exception:
                continue
            if h * 3600 >= cutoff:
                swaps += int(b.get("swaps", 0))
                volume += int(b.get("volume_usd6", 0))
                fees += int(b.get("fees_usd6", 0))
        out[label] = {"swaps": swaps, "volume_usd6": volume, "fees_usd6": fees}
    return out

def observed_days(state):
    latest_ts = int(state.get("latest_block_ts", 0))
    if latest_ts <= 0:
        latest_ts = int(time.time())
    buckets = state.get("hourly_buckets") or {}
    min_hour = None
    for hk in buckets.keys():
        try:
            h = int(hk)
        except Exception:
            continue
        if min_hour is None or h < min_hour:
            min_hour = h
    if min_hour is None:
        return 0.0
    start_ts = min_hour * 3600
    span = latest_ts - start_ts
    if span < 3600:
        span = 3600
    return span / 86400.0

def format_lines(state, status, err):
    volume = int(state.get("volume_usd6", 0))
    fees = int(state.get("fees_usd6", 0))
    fee_weighted = int(state.get("fee_weighted_usd6_pips", 0))
    avg_fee = 0
    if volume > 0:
        avg_fee = (fee_weighted + volume // 2) // volume
    providers = set(str(x).lower() for x in state.get("lp_provider_wallets", []))
    if providers:
        lp_count = len(providers)
    else:
        lp_count = len(set(str(x).lower() for x in state.get("lp_senders", [])))
    lines = [
        "pool_activity: "
        f"mode=lifetime "
        f"from_block={from_block} "
        f"to_block={to_block} "
        f"scanned_through={int(state.get('last_scanned_block', -1))} "
        f"swaps={int(state.get('swap_count', 0))} "
        f"volume_usd6={volume} "
        f"fees_usd6={fees} "
        f"observed_days={observed_days(state):.4f} "
        f"avg_fee_pips={avg_fee} "
        f"lp_providers={lp_count} "
        f"status={status} "
        f"error={err} "
        f"cache_file={cache_file}"
    ]
    ws = window_stats(state)
    for label, _seconds in WINDOWS:
        s = ws[label]
        lines.append(
            "pool_activity_window: "
            f"label={label} "
            f"swaps={s['swaps']} "
            f"volume_usd6={s['volume_usd6']} "
            f"fees_usd6={s['fees_usd6']}"
        )
    fee_buckets = state.get("fee_buckets") or {}
    fee_keys = []
    for k in fee_buckets.keys():
        try:
            fee_keys.append(int(k))
        except Exception:
            continue
    fee_keys.sort()
    for fee_pips in fee_keys:
        b = fee_buckets.get(str(fee_pips), {})
        lines.append(
            "pool_activity_fee: "
            f"fee_pips={fee_pips} "
            f"swaps={int(b.get('swaps', 0))} "
            f"volume_usd6={int(b.get('volume_usd6', 0))} "
            f"fees_usd6={int(b.get('fees_usd6', 0))}"
        )
    return lines

state = load_state()
sender_set = set(str(x).lower() for x in state.get("lp_senders", []))
provider_set = set(str(x).lower() for x in state.get("lp_provider_wallets", []))
tx_from_by_hash = {str(k).lower(): str(v).lower() for k, v in state.get("tx_from_by_hash", {}).items()}
block_ts_by_number = {str(k): int(v) for k, v in state.get("block_ts_by_number", {}).items()}
hourly_buckets = state.get("hourly_buckets", {})
fee_buckets = state.get("fee_buckets", {})
range_buckets = {str(k): int(v) for k, v in (state.get("range_buckets", {}) or {}).items()}
last_swap_sqrt_x96 = int(state.get("last_swap_sqrt_x96", 0))
state["lp_senders"] = list(sender_set)
state["lp_provider_wallets"] = list(provider_set)
state["tx_from_by_hash"] = tx_from_by_hash
state["block_ts_by_number"] = block_ts_by_number
state["hourly_buckets"] = hourly_buckets
state["fee_buckets"] = fee_buckets
state["range_buckets"] = range_buckets
state["last_swap_sqrt_x96"] = last_swap_sqrt_x96

if int(state.get("last_scanned_block", -1)) >= to_block:
    for ln in format_lines(state, "OK", "-"):
        print(ln)
    raise SystemExit(0)

start_block = int(state.get("last_scanned_block", from_block - 1)) + 1
if start_block < from_block:
    start_block = from_block

try:
    latest_ts = rpc_get_block_timestamp(to_block)
    if latest_ts > 0:
        state["latest_block_ts"] = latest_ts
except Exception:
    pass

try:
    block = start_block
    while block <= to_block:
        end = min(block + chunk_size - 1, to_block)
        swap_logs = rpc_get_logs(swap_topic, block, end)
        modify_logs = rpc_get_logs(modify_topic, block, end)

        needed_blocks = set()
        for lg in swap_logs:
            bn = to_int_block(lg.get("blockNumber"))
            if bn >= 0 and str(bn) not in block_ts_by_number:
                needed_blocks.add(bn)
        for bn in sorted(needed_blocks):
            try:
                block_ts_by_number[str(bn)] = rpc_get_block_timestamp(bn)
            except Exception:
                block_ts_by_number[str(bn)] = 0

        for lg in swap_logs:
            data_hex = str(lg.get("data") or "")
            if not data_hex.startswith("0x"):
                continue
            payload = data_hex[2:]
            if len(payload) < 64 * 6:
                continue
            words = [payload[i:i + 64] for i in range(0, 64 * 6, 64)]
            amount0 = s256(words[0])
            amount1 = s256(words[1])
            last_swap_sqrt_x96 = int(words[2], 16)
            fee_pips = int(words[5], 16)
            stable_raw = amount1 if stable_is_token1 else amount0
            stable_abs = abs(stable_raw)
            usd6 = stable_abs * 1_000_000 // (10 ** stable_decimals)
            fees6 = (usd6 * fee_pips + 500_000) // 1_000_000
            state["swap_count"] = int(state.get("swap_count", 0)) + 1
            state["volume_usd6"] = int(state.get("volume_usd6", 0)) + usd6
            state["fees_usd6"] = int(state.get("fees_usd6", 0)) + fees6
            state["fee_weighted_usd6_pips"] = int(state.get("fee_weighted_usd6_pips", 0)) + (usd6 * fee_pips)
            fk = str(fee_pips)
            fb = fee_buckets.get(fk)
            if not isinstance(fb, dict):
                fb = {"swaps": 0, "volume_usd6": 0, "fees_usd6": 0}
            fb["swaps"] = int(fb.get("swaps", 0)) + 1
            fb["volume_usd6"] = int(fb.get("volume_usd6", 0)) + usd6
            fb["fees_usd6"] = int(fb.get("fees_usd6", 0)) + fees6
            fee_buckets[fk] = fb

            bn = to_int_block(lg.get("blockNumber"))
            ts = int(block_ts_by_number.get(str(bn), 0))
            if ts > 0:
                hk = str(ts // 3600)
                b = hourly_buckets.get(hk)
                if not isinstance(b, dict):
                    b = {"swaps": 0, "volume_usd6": 0, "fees_usd6": 0}
                b["swaps"] = int(b.get("swaps", 0)) + 1
                b["volume_usd6"] = int(b.get("volume_usd6", 0)) + usd6
                b["fees_usd6"] = int(b.get("fees_usd6", 0)) + fees6
                hourly_buckets[hk] = b

        for lg in modify_logs:
            topics = lg.get("topics") or []
            if len(topics) < 3:
                continue
            data_hex = str(lg.get("data") or "")
            if data_hex.startswith("0x"):
                payload = data_hex[2:]
                if len(payload) >= 64 * 3:
                    words = [payload[i:i + 64] for i in range(0, 64 * 3, 64)]
                    tick_lower = s256(words[0])
                    tick_upper = s256(words[1])
                    liquidity_delta = s256(words[2])
                    bucket_key = f"{tick_lower}:{tick_upper}"
                    next_liq = int(range_buckets.get(bucket_key, 0)) + int(liquidity_delta)
                    if next_liq == 0:
                        range_buckets.pop(bucket_key, None)
                    else:
                        range_buckets[bucket_key] = next_liq
            topic2 = str(topics[2]).lower()
            if topic2.startswith("0x") and len(topic2) == 66:
                sender_set.add("0x" + topic2[-40:])
            tx_hash = str(lg.get("transactionHash") or "").lower()
            if tx_hash.startswith("0x") and len(tx_hash) == 66:
                if tx_hash not in tx_from_by_hash:
                    try:
                        tx_from_by_hash[tx_hash] = rpc_get_tx_from(tx_hash)
                    except Exception:
                        tx_from_by_hash[tx_hash] = ""
                tx_from = tx_from_by_hash.get(tx_hash, "")
                if tx_from.startswith("0x") and len(tx_from) == 42:
                    provider_set.add(tx_from)

        latest_ts = int(state.get("latest_block_ts", 0))
        if latest_ts > 0:
            min_hour = (latest_ts - RETENTION_SECONDS) // 3600
            drop_keys = [k for k in hourly_buckets.keys() if int(k) < min_hour]
            for k in drop_keys:
                del hourly_buckets[k]

        state["lp_senders"] = sorted(sender_set)
        state["lp_provider_wallets"] = sorted(provider_set)
        state["tx_from_by_hash"] = tx_from_by_hash
        state["block_ts_by_number"] = block_ts_by_number
        state["hourly_buckets"] = hourly_buckets
        state["fee_buckets"] = fee_buckets
        state["range_buckets"] = range_buckets
        state["last_swap_sqrt_x96"] = last_swap_sqrt_x96
        state["last_scanned_block"] = end
        save_state(state)
        block = end + 1

    for ln in format_lines(state, "OK", "-"):
        print(ln)
except Exception as exc:
    err = str(exc).replace(" ", "_")
    try:
        save_state(state)
    except Exception:
        pass
    for ln in format_lines(state, "ERROR", err):
        print(ln)
PY
}

pool_activity_line_from_cache() {
  local cache_file="$1"
  local fallback_from_block="$2"
  local reason="$3"
  python3 - "${cache_file}" "${fallback_from_block}" "${reason}" <<'PY'
import json
import os
import sys

cache_file = sys.argv[1]
fallback_from_block = sys.argv[2]
reason = sys.argv[3]

WINDOWS = [
    ("24h", 24 * 3600),
    ("7d", 7 * 24 * 3600),
    ("30d", 30 * 24 * 3600),
    ("90d", 90 * 24 * 3600),
    ("180d", 180 * 24 * 3600),
    ("365d", 365 * 24 * 3600),
]

def print_unknown_windows():
    for label, _ in WINDOWS:
        print(f"pool_activity_window: label={label} swaps=? volume_usd6=? fees_usd6=?")

def print_fee_from_cache(state):
    fee_buckets = state.get("fee_buckets")
    if not isinstance(fee_buckets, dict):
        return
    fee_keys = []
    for k in fee_buckets.keys():
        try:
            fee_keys.append(int(k))
        except Exception:
            continue
    fee_keys.sort()
    for fee_pips in fee_keys:
        b = fee_buckets.get(str(fee_pips), {})
        if not isinstance(b, dict):
            continue
        print(
            "pool_activity_fee: "
            f"fee_pips={fee_pips} "
            f"swaps={int(b.get('swaps', 0))} "
            f"volume_usd6={int(b.get('volume_usd6', 0))} "
            f"fees_usd6={int(b.get('fees_usd6', 0))}"
        )

def print_windows_from_cache(state):
    hourly = state.get("hourly_buckets")
    if not isinstance(hourly, dict):
        print_unknown_windows()
        return
    latest_ts = int(state.get("latest_block_ts", 0))
    if latest_ts <= 0:
        print_unknown_windows()
        return
    for label, seconds in WINDOWS:
        cutoff = latest_ts - seconds
        swaps = 0
        volume = 0
        fees = 0
        for hk, b in hourly.items():
            try:
                hour = int(hk)
            except Exception:
                continue
            if hour * 3600 < cutoff:
                continue
            if not isinstance(b, dict):
                continue
            swaps += int(b.get("swaps", 0))
            volume += int(b.get("volume_usd6", 0))
            fees += int(b.get("fees_usd6", 0))
        print(f"pool_activity_window: label={label} swaps={swaps} volume_usd6={volume} fees_usd6={fees}")

def observed_days_from_cache(state):
    hourly = state.get("hourly_buckets")
    if not isinstance(hourly, dict) or not hourly:
        return 0.0
    latest_ts = int(state.get("latest_block_ts", 0))
    if latest_ts <= 0:
        return 0.0
    min_hour = None
    for hk in hourly.keys():
        try:
            h = int(hk)
        except Exception:
            continue
        if min_hour is None or h < min_hour:
            min_hour = h
    if min_hour is None:
        return 0.0
    start_ts = min_hour * 3600
    span = latest_ts - start_ts
    if span < 3600:
        span = 3600
    return span / 86400.0

if not os.path.exists(cache_file):
    print(
        "pool_activity: "
        f"mode=lifetime from_block={fallback_from_block} to_block=? scanned_through=? "
        "swaps=? volume_usd6=? fees_usd6=? observed_days=? avg_fee_pips=? lp_providers=? "
        f"status=ERROR error={reason} cache_file={cache_file}"
    )
    print_unknown_windows()
    # no fee split without cache
    raise SystemExit(0)

try:
    with open(cache_file, "r", encoding="utf-8") as f:
        state = json.load(f)
    volume = int(state.get("volume_usd6", 0))
    fees = int(state.get("fees_usd6", 0))
    fee_weighted = int(state.get("fee_weighted_usd6_pips", 0))
    avg_fee = 0
    if volume > 0:
        avg_fee = (fee_weighted + volume // 2) // volume
    provider_set = set(str(x).lower() for x in (state.get("lp_provider_wallets") or []))
    if provider_set:
        lp_count = len(provider_set)
    else:
        lp_set = set(str(x).lower() for x in (state.get("lp_senders") or []))
        lp_count = len(lp_set)
    print(
        "pool_activity: "
        f"mode=lifetime "
        f"from_block={state.get('from_block', fallback_from_block)} "
        f"to_block=? "
        f"scanned_through={state.get('last_scanned_block', '?')} "
        f"swaps={state.get('swap_count', '?')} "
        f"volume_usd6={volume} "
        f"fees_usd6={fees} "
        f"observed_days={observed_days_from_cache(state):.4f} "
        f"avg_fee_pips={avg_fee} "
        f"lp_providers={lp_count} "
        f"status=STALE "
        f"error={reason} "
        f"cache_file={cache_file}"
    )
    print_windows_from_cache(state)
    print_fee_from_cache(state)
except Exception:
    print(
        "pool_activity: "
        f"mode=lifetime from_block={fallback_from_block} to_block=? scanned_through=? "
        "swaps=? volume_usd6=? fees_usd6=? observed_days=? avg_fee_pips=? lp_providers=? "
        f"status=ERROR error={reason}_cache_read_failed cache_file={cache_file}"
    )
    print_unknown_windows()
PY
}

compute_pool_tvl_from_cache() {
  local cache_file="$1"
  local sqrt_price_x96="$2"
  local token0_decimals="$3"
  local token1_decimals="$4"
  local stable_is_token1="$5"
  python3 - "${cache_file}" "${sqrt_price_x96}" "${token0_decimals}" "${token1_decimals}" "${stable_is_token1}" <<'PY'
import json
import os
import sys
from decimal import Decimal, ROUND_HALF_UP, getcontext

getcontext().prec = 90

cache_file = sys.argv[1]
sqrt_price_x96_s = sys.argv[2]
token0_decimals_s = sys.argv[3]
token1_decimals_s = sys.argv[4]
stable_is_token1 = (sys.argv[5] == "1")

def as_int(v):
    try:
        return int(v)
    except Exception:
        return 0

if not os.path.exists(cache_file):
    print("?")
    raise SystemExit(0)

try:
    with open(cache_file, "r", encoding="utf-8") as f:
        state = json.load(f)
except Exception:
    print("?")
    raise SystemExit(0)

range_buckets = state.get("range_buckets")
if not isinstance(range_buckets, dict):
    print("?")
    raise SystemExit(0)
if not range_buckets:
    print("0")
    raise SystemExit(0)

sqrt_price_x96 = as_int(sqrt_price_x96_s)
if sqrt_price_x96 <= 0:
    sqrt_price_x96 = as_int(state.get("last_swap_sqrt_x96", 0))
if sqrt_price_x96 <= 0:
    print("?")
    raise SystemExit(0)

token0_decimals = as_int(token0_decimals_s)
token1_decimals = as_int(token1_decimals_s)
Q96 = Decimal(2) ** 96
sp = Decimal(sqrt_price_x96)
ratio = (sp / Q96) ** 2
if ratio <= 0:
    print("?")
    raise SystemExit(0)

if stable_is_token1:
    stable_per_volatile = ratio * (Decimal(10) ** (token0_decimals - token1_decimals))
else:
    stable_per_volatile = (Decimal(1) / ratio) * (Decimal(10) ** (token1_decimals - token0_decimals))

sqrt_cache = {}

def sqrt_ratio_at_tick(tick):
    v = sqrt_cache.get(tick)
    if v is not None:
        return v
    v = (Decimal("1.0001") ** (Decimal(tick) / Decimal(2))) * Q96
    sqrt_cache[tick] = v
    return v

total_usd = Decimal(0)
for key, liq_raw in range_buckets.items():
    parts = str(key).split(":", 1)
    if len(parts) != 2:
        continue
    try:
        tick_lower = int(parts[0])
        tick_upper = int(parts[1])
        liquidity = Decimal(int(liq_raw))
    except Exception:
        continue
    if liquidity <= 0:
        continue

    sa = sqrt_ratio_at_tick(tick_lower)
    sb = sqrt_ratio_at_tick(tick_upper)
    if sb <= sa:
        continue

    if sp <= sa:
        amount0_raw = liquidity * (sb - sa) * Q96 / (sa * sb)
        amount1_raw = Decimal(0)
    elif sp < sb:
        amount0_raw = liquidity * (sb - sp) * Q96 / (sp * sb)
        amount1_raw = liquidity * (sp - sa) / Q96
    else:
        amount0_raw = Decimal(0)
        amount1_raw = liquidity * (sb - sa) / Q96

    amount0 = amount0_raw / (Decimal(10) ** token0_decimals)
    amount1 = amount1_raw / (Decimal(10) ** token1_decimals)
    if stable_is_token1:
        stable_amount = amount1
        volatile_amount = amount0
    else:
        stable_amount = amount0
        volatile_amount = amount1

    total_usd += stable_amount + volatile_amount * stable_per_volatile

if total_usd < 0:
    total_usd = Decimal(0)

usd6 = int((total_usd * Decimal(1_000_000)).to_integral_value(rounding=ROUND_HALF_UP))
print(usd6)
PY
}

read_last_swap_sqrt_from_cache() {
  local cache_file="$1"
  python3 - "${cache_file}" <<'PY'
import json
import os
import sys

cache_file = sys.argv[1]
if not os.path.exists(cache_file):
    print("?")
    raise SystemExit(0)
try:
    with open(cache_file, "r", encoding="utf-8") as f:
        state = json.load(f)
    v = int(state.get("last_swap_sqrt_x96", 0))
    if v > 0:
        print(v)
    else:
        print("?")
except Exception:
    print("?")
PY
}

compute_last_hour_fee_change_lines() {
  local latest_block="$1"
  local period_seconds="${2:-0}"
  local current_fee_bips="${3:-?}"
  local ema_periods="${4:-12}"
  local current_ema_usd6="${5:-?}"
  local floor_idx="${6:-?}"
  local cap_idx="${7:-?}"
  local current_fee_idx="${8:-?}"
  local lookback_blocks="${HOOK_STATUS_LAST_HOUR_LOOKBACK_BLOCKS:-20000}"
  if ! [[ "${latest_block}" =~ ^[0-9]+$ ]]; then
    echo "last_hour_status: status=ERROR error=latest_block_unavailable from_block=? to_block=? changes=0 periods=0"
    return
  fi
  if ! [[ "${lookback_blocks}" =~ ^[0-9]+$ ]] || (( lookback_blocks <= 0 )); then
    lookback_blocks=20000
  fi
  if ! [[ "${period_seconds}" =~ ^[0-9]+$ ]] || (( period_seconds < 0 )); then
    period_seconds=0
  fi
  if ! [[ "${current_fee_bips}" =~ ^[0-9]+$ ]]; then
    current_fee_bips="?"
  fi
  if ! [[ "${ema_periods}" =~ ^[0-9]+$ ]] || (( ema_periods < 2 )); then
    ema_periods=12
  fi
  if ! [[ "${current_ema_usd6}" =~ ^[0-9]+$ ]]; then
    current_ema_usd6="?"
  fi
  if ! [[ "${floor_idx}" =~ ^[0-9]+$ ]]; then
    floor_idx="?"
  fi
  if ! [[ "${cap_idx}" =~ ^[0-9]+$ ]]; then
    cap_idx="?"
  fi
  if ! [[ "${current_fee_idx}" =~ ^[0-9]+$ ]]; then
    current_fee_idx="?"
  fi
  local from_block=0
  if (( latest_block > lookback_blocks )); then
    from_block=$((latest_block - lookback_blocks))
  fi
  python3 - "${RPC_URL}" "${HOOK_ADDRESS}" "${from_block}" "${latest_block}" "${period_seconds}" "${current_fee_bips}" "${ema_periods}" "${current_ema_usd6}" "${floor_idx}" "${cap_idx}" "${current_fee_idx}" <<'PY'
import json
import subprocess
import sys
import time
from datetime import datetime, timezone

rpc_url = sys.argv[1]
hook_address = sys.argv[2]
from_block = int(sys.argv[3])
to_block = int(sys.argv[4])
period_seconds = int(sys.argv[5])
current_fee_bips = sys.argv[6]
ema_periods = int(sys.argv[7])
current_ema_usd6_raw = sys.argv[8]
floor_idx_raw = sys.argv[9]
cap_idx_raw = sys.argv[10]
current_fee_idx_raw = sys.argv[11]
fee_updated_topic = "0x7a7cee7d3375d08c4510b71462006ecbba16bc2e5f4fecc9fc41c22e43714924"
lull_reset_topic = "0x011265122800c4d227d5dc12c8704d982a13007a939d4286dbfca182d8bf66ee"
paused_topic = "0xeae0ae451529dfc5ca6c740fc8de37805f6010327053db71dea1fe719c8e0585"
unpaused_topic = "0xa45f47fdea8a1efdd9029a5691c7f759c32b7c698632b563573e155625d16933"

def rpc_post(payload):
    cmd = [
        "curl", "-sS", "--connect-timeout", "3", "--max-time", "12",
        "-H", "content-type: application/json",
        "--data", payload,
        rpc_url,
    ]
    last_err = ""
    for _ in range(3):
        try:
            out = subprocess.check_output(cmd, stderr=subprocess.STDOUT).decode("utf-8")
            data = json.loads(out)
            if isinstance(data, dict) and data.get("error") is not None:
                raise RuntimeError(str(data["error"]))
            return data
        except Exception as exc:
            last_err = str(exc)
            time.sleep(0.5)
    raise RuntimeError(last_err or "rpc_failed")

def rpc_get_logs(topic0, fb, tb):
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_getLogs",
        "params": [{
            "address": hook_address,
            "fromBlock": hex(fb),
            "toBlock": hex(tb),
            "topics": [topic0],
        }],
    }, separators=(",", ":"))
    data = rpc_post(payload)
    logs = data.get("result")
    if not isinstance(logs, list):
        raise RuntimeError("invalid_logs")
    return logs

_block_ts_cache = {}

def rpc_get_block_ts(block_number):
    if block_number in _block_ts_cache:
        return _block_ts_cache[block_number]
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_getBlockByNumber",
        "params": [hex(block_number), False],
    }, separators=(",", ":"))
    data = rpc_post(payload)
    block = data.get("result")
    if not isinstance(block, dict):
        _block_ts_cache[block_number] = 0
        return 0
    ts = block.get("timestamp")
    if isinstance(ts, str) and ts.startswith("0x"):
        v = int(ts, 16)
        _block_ts_cache[block_number] = v
        return v
    _block_ts_cache[block_number] = 0
    return 0

def to_int(v):
    if isinstance(v, int):
        return v
    if isinstance(v, str):
        if v.startswith("0x"):
            return int(v, 16)
        return int(v)
    return 0

def ts_to_utc_time(ts):
    # HH:MM:SS in UTC for compact dashboard row
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%H:%M:%S")

def decode_words(data_hex, words=4):
    if not isinstance(data_hex, str) or not data_hex.startswith("0x"):
        return None
    payload = data_hex[2:]
    if len(payload) < 64 * words:
        return None
    out = []
    for i in range(words):
        out.append(int(payload[i * 64:(i + 1) * 64], 16))
    return out

def parse_int_or_none(v):
    try:
        return int(v)
    except Exception:
        return None

def normalize_tx_hash(tx_hash):
    tx = str(tx_hash or "").lower()
    if tx.startswith("0x") and len(tx) == 66:
        return tx
    return ""

def decay_ema(ema_value):
    if ema_value is None or ema_value < 0:
        return None
    if ema_value == 0:
        return 0
    return (ema_value * (ema_periods - 1)) // ema_periods

def backfill_ema(ema_value):
    if ema_value is None or ema_value < 0:
        return None
    if ema_value == 0:
        return 0
    # Approximate inverse of floor(prev*(n-1)/n): ceil(curr*n/(n-1))
    return (ema_value * ema_periods + (ema_periods - 2)) // (ema_periods - 1)

def reason_for_no_event(fee_idx):
    if fee_idx is not None and cap_idx is not None and fee_idx >= cap_idx:
        return "CAP"
    if fee_idx is not None and floor_idx is not None and fee_idx <= floor_idx:
        return "FLOOR"
    return "NO_SWAPS"

def reason_for_fee_row(row, control_reason):
    if control_reason:
        return control_reason
    if row["direction"] in ("UP", "DOWN") and row["to_fee_bips"] != row["from_fee_bips"]:
        return "-"
    if row["to_idx"] is not None and cap_idx is not None and row["to_idx"] >= cap_idx:
        return "CAP"
    if row["to_idx"] is not None and floor_idx is not None and row["to_idx"] <= floor_idx:
        return "FLOOR"
    return "DEADBAND"

try:
    floor_idx = parse_int_or_none(floor_idx_raw)
    cap_idx = parse_int_or_none(cap_idx_raw)
    current_fee_idx = parse_int_or_none(current_fee_idx_raw)
    current_fee_bips_int = parse_int_or_none(current_fee_bips)
    latest_ts = rpc_get_block_ts(to_block)
    if latest_ts <= 0:
        raise RuntimeError("latest_ts_unavailable")
    cutoff_ts = latest_ts - 3600

    fee_logs = rpc_get_logs(fee_updated_topic, from_block, to_block)
    control_logs = []
    for topic0, reason in (
        (lull_reset_topic, "LULL_RESET"),
        (paused_topic, "PAUSED"),
        (unpaused_topic, "UNPAUSED"),
    ):
        logs = rpc_get_logs(topic0, from_block, to_block)
        for lg in logs:
            block_number = to_int(lg.get("blockNumber"))
            log_index = to_int(lg.get("logIndex"))
            if block_number < 0:
                continue
            ts = rpc_get_block_ts(block_number)
            if ts <= 0:
                continue
            tx_hash = normalize_tx_hash(lg.get("transactionHash"))
            new_fee = None
            new_idx = None
            if reason in ("LULL_RESET", "PAUSED"):
                words = decode_words(lg.get("data"), 2)
                if words is not None:
                    new_fee = int(words[0])
                    new_idx = int(words[1])
            control_logs.append({
                "id": f"{block_number}:{log_index}:{reason}",
                "block_number": block_number,
                "log_index": log_index,
                "time": ts,
                "tx_hash": tx_hash,
                "reason": reason,
                "new_fee": new_fee,
                "new_idx": new_idx,
            })

    control_logs.sort(key=lambda e: (e["block_number"], e["log_index"]))
    controls_by_tx = {}
    for c in control_logs:
        if not c["tx_hash"]:
            continue
        controls_by_tx.setdefault(c["tx_hash"], []).append(c)
    for tx_hash in list(controls_by_tx.keys()):
        controls_by_tx[tx_hash].sort(key=lambda e: e["log_index"])

    events = []
    for lg in fee_logs:
        words = decode_words(lg.get("data"), 4)
        if words is None:
            continue
        block_number = to_int(lg.get("blockNumber"))
        log_index = to_int(lg.get("logIndex"))
        if block_number < 0:
            continue
        ts = rpc_get_block_ts(block_number)
        if ts <= 0:
            continue
        events.append({
            "block_number": block_number,
            "log_index": log_index,
            "time": ts,
            "tx_hash": normalize_tx_hash(lg.get("transactionHash")),
            "new_fee": int(words[0]),
            "new_idx": int(words[1]),
            "closed_volume_usd6": int(words[2]),
            "ema_usd6": int(words[3]),
        })
    events.sort(key=lambda e: (e["block_number"], e["log_index"]))

    prev_idx = None
    prev_fee = None
    fee_updates = []
    used_control_ids = set()
    changes = []
    for e in events:
        if prev_idx is None:
            from_idx = e["new_idx"]
            from_fee = e["new_fee"]
            direction = "NONE"
        else:
            from_idx = prev_idx
            from_fee = prev_fee
            if e["new_idx"] > prev_idx:
                direction = "UP"
            elif e["new_idx"] < prev_idx:
                direction = "DOWN"
            else:
                direction = "FLAT"
        if e["time"] >= cutoff_ts:
            control_reason = None
            tx_controls = controls_by_tx.get(e["tx_hash"], [])
            if tx_controls:
                control_reason = tx_controls[0]["reason"]
                used_control_ids.add(tx_controls[0]["id"])
            row = {
                "time": e["time"],
                "direction": direction,
                "from_idx": from_idx,
                "to_idx": e["new_idx"],
                "from_fee_bips": from_fee,
                "to_fee_bips": e["new_fee"],
                "ema_usd6": e["ema_usd6"],
                "volume_usd6": e["closed_volume_usd6"],
                "reason": reason_for_fee_row({
                    "direction": direction,
                    "to_idx": e["new_idx"],
                    "from_fee_bips": from_fee,
                    "to_fee_bips": e["new_fee"],
                }, control_reason),
            }
            fee_updates.append(row)
            if e["new_fee"] != from_fee:
                changes.append(row)
        prev_idx = e["new_idx"]
        prev_fee = e["new_fee"]

    period_rows = []

    def add_no_event_row(ts_value, fee_value, ema_value, fee_idx):
        ema_out = "?"
        if ema_value is not None and ema_value >= 0:
            ema_out = int(ema_value)
        period_rows.append({
            "time": ts_value,
            "direction": "FLAT",
            "from_idx": fee_idx,
            "to_idx": fee_idx,
            "from_fee_bips": fee_value,
            "to_fee_bips": fee_value,
            "ema_usd6": ema_out,
            "volume_usd6": 0,
            "reason": reason_for_no_event(fee_idx),
        })

    if fee_updates:
        prev_row = None
        for row in fee_updates:
            if prev_row is not None and period_seconds > 0:
                gap_seconds = row["time"] - prev_row["time"]
                missing_periods = (gap_seconds // period_seconds) - 1
                if missing_periods > 0:
                    ema_cursor = parse_int_or_none(prev_row.get("ema_usd6"))
                    for i in range(1, missing_periods + 1):
                        ts_value = prev_row["time"] + i * period_seconds
                        if ts_value < cutoff_ts or ts_value > latest_ts:
                            continue
                        ema_cursor = decay_ema(ema_cursor)
                        add_no_event_row(ts_value, prev_row["to_fee_bips"], ema_cursor, prev_row["to_idx"])
            period_rows.append(row)
            prev_row = row
        if period_seconds > 0:
            last_row = fee_updates[-1]
            tail_periods = (latest_ts - last_row["time"]) // period_seconds
            if tail_periods > 0:
                ema_cursor = parse_int_or_none(last_row.get("ema_usd6"))
                for i in range(1, tail_periods + 1):
                    ts_value = last_row["time"] + i * period_seconds
                    if ts_value < cutoff_ts or ts_value > latest_ts:
                        continue
                    ema_cursor = decay_ema(ema_cursor)
                    add_no_event_row(ts_value, last_row["to_fee_bips"], ema_cursor, last_row["to_idx"])
    elif period_seconds > 0:
        current_ema = parse_int_or_none(current_ema_usd6_raw)
        ema_cursor = current_ema
        boundary = latest_ts - (latest_ts % period_seconds)
        generated = 0
        base_fee_bips = current_fee_bips_int if current_fee_bips_int is not None else current_fee_bips
        while boundary >= cutoff_ts and generated < 360:
            add_no_event_row(boundary, base_fee_bips, ema_cursor, current_fee_idx)
            ema_cursor = backfill_ema(ema_cursor)
            boundary -= period_seconds
            generated += 1

    for c in control_logs:
        if c["time"] < cutoff_ts:
            continue
        if c["id"] in used_control_ids:
            continue
        fee_bips = c["new_fee"]
        fee_idx = c["new_idx"]
        if fee_bips is None:
            fee_bips = current_fee_bips_int if current_fee_bips_int is not None else current_fee_bips
        if fee_idx is None:
            fee_idx = current_fee_idx
        period_rows.append({
            "time": c["time"],
            "direction": "FLAT",
            "from_idx": fee_idx,
            "to_idx": fee_idx,
            "from_fee_bips": fee_bips,
            "to_fee_bips": fee_bips,
            "ema_usd6": 0,
            "volume_usd6": 0,
            "reason": c["reason"],
        })

    period_rows.sort(key=lambda r: r["time"])
    if len(period_rows) > 500:
        period_rows = period_rows[-500:]

    print(
        "last_hour_status: "
        f"status=OK from_block={from_block} to_block={to_block} "
        f"latest_ts={latest_ts} cutoff_ts={cutoff_ts} changes={len(changes)} periods={len(period_rows)}"
    )
    for p in reversed(period_rows):
        print(
            "last_hour_period: "
            f"time={ts_to_utc_time(p['time'])} "
            f"direction={p['direction']} "
            f"from_fee_bips={p['from_fee_bips']} "
            f"to_fee_bips={p['to_fee_bips']} "
            f"ema_usd6={p['ema_usd6']} "
            f"volume_usd6={p['volume_usd6']} "
            f"reason={p['reason']}"
        )
    for c in reversed(changes):
        print(
            "last_hour_change: "
            f"time={ts_to_utc_time(c['time'])} "
            f"direction={c['direction']} "
            f"from_fee_bips={c['from_fee_bips']} "
            f"to_fee_bips={c['to_fee_bips']} "
            f"ema_usd6={c['ema_usd6']} "
            f"volume_usd6={c['volume_usd6']}"
        )
except Exception as exc:
    err = str(exc).replace(" ", "_")
    print(
        "last_hour_status: "
        f"status=ERROR error={err} from_block={from_block} to_block={to_block} changes=0 periods=0"
    )
PY
}

CHAIN=""
RPC_URL_CLI=""
HOOK_ADDRESS_CLI=""
STATE_VIEW_ADDRESS_CLI=""
REFRESH_SECONDS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --rpc-url) RPC_URL_CLI="${2:-}"; shift 2 ;;
    --hook-address) HOOK_ADDRESS_CLI="${2:-}"; shift 2 ;;
    --state-view-address) STATE_VIEW_ADDRESS_CLI="${2:-}"; shift 2 ;;
    --refresh) REFRESH_SECONDS="${2:-}"; shift 2 ;;
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
if ! [[ "${REFRESH_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --refresh must be a non-negative integer" >&2
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

POOL_ACTIVITY_CHUNK_BLOCKS="${HOOK_STATUS_CHUNK_BLOCKS:-50000}"
if ! [[ "${POOL_ACTIVITY_CHUNK_BLOCKS}" =~ ^[0-9]+$ ]] || (( POOL_ACTIVITY_CHUNK_BLOCKS <= 0 )); then
  echo "ERROR: HOOK_STATUS_CHUNK_BLOCKS must be a positive integer" >&2
  exit 1
fi
POOL_ACTIVITY_START_BLOCK="${HOOK_STATUS_START_BLOCK:-}"
if [[ -n "${POOL_ACTIVITY_START_BLOCK}" ]] && ! [[ "${POOL_ACTIVITY_START_BLOCK}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: HOOK_STATUS_START_BLOCK must be a non-negative integer" >&2
  exit 1
fi

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

if [[ -z "${POOL_ACTIVITY_START_BLOCK}" && -n "${CHAIN_ID}" ]]; then
  cp_paths=(
    "./scripts/out/broadcast/CreatePool.s.sol/${CHAIN_ID}/run-latest.json"
    "./lib/v4-periphery/broadcast/CreatePool.s.sol/${CHAIN_ID}/run-latest.json"
  )
  for p in "${cp_paths[@]}"; do
    if [[ -f "${p}" ]]; then
      candidate_start="$(find_pool_create_block_in_json "${p}" "${POOL_ID}")"
      if [[ "${candidate_start}" =~ ^[0-9]+$ ]]; then
        POOL_ACTIVITY_START_BLOCK="${candidate_start}"
        break
      fi
    fi
  done
fi

if [[ -z "${POOL_ACTIVITY_START_BLOCK}" ]]; then
  POOL_ACTIVITY_START_BLOCK=0
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

render_raw_once() {
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local pool_currency0 pool_currency1 stable_currency pool_tick_spacing
  local initial_idx floor_idx cap_idx pause_idx fee_tier_count
  local period_seconds ema_periods deadband_bps lull_reset_seconds

  pool_currency0="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "poolCurrency0()(address)" || true)")"
  pool_currency1="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "poolCurrency1()(address)" || true)")"
  stable_currency="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "stableCurrency()(address)" || true)")"
  pool_tick_spacing="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "poolTickSpacing()(int24)" || true)")"
  if [[ -z "${pool_currency0}" ]]; then
    pool_currency0="${CURRENCY0}"
  fi
  if [[ -z "${pool_currency1}" ]]; then
    pool_currency1="${CURRENCY1}"
  fi
  if [[ -z "${stable_currency}" ]]; then
    stable_currency="${STABLE}"
  fi
  if [[ -z "${pool_tick_spacing}" ]]; then
    pool_tick_spacing="${TICK_SPACING}"
  fi

  floor_idx="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "floorIdx()(uint8)" || true)")"
  cap_idx="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "capIdx()(uint8)" || true)")"
  initial_idx="${floor_idx}"
  pause_idx="${floor_idx}"
  fee_tier_count="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "feeTierCount()(uint16)" || true)")"
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
  if ! [[ "${fee_tier_count}" =~ ^[0-9]+$ ]]; then
    fee_tier_count=$((cap_idx + 1))
  fi
  for ((i = 0; i < fee_tier_count; ++i)); do
    tier_val="$(first_token "$(try_cast_call "${HOOK_ADDRESS}" "feeTiers(uint256)(uint24)" "${i}" || true)")"
    tiers+=("${i}:${tier_val:-?}")
  done

  local slot0_raw sqrt_price tick protocol_fee lp_fee liquidity price token0_decimals token1_decimals stable_is_token1 pool_tvl_usd6 cache_last_sqrt
  local latest_block activity_line last_hour_lines activity_cache_dir activity_cache_file
  sqrt_price=""
  tick=""
  protocol_fee=""
  lp_fee=""
  liquidity=""
  price=""
  pool_tvl_usd6="?"
  token0_decimals=18
  token1_decimals=18
  stable_is_token1=0
  if [[ "$(lower "${STABLE}")" == "$(lower "${CURRENCY0}")" ]]; then
    token0_decimals="${STABLE_DECIMALS}"
    token1_decimals=18
    stable_is_token1=0
  elif [[ "$(lower "${STABLE}")" == "$(lower "${CURRENCY1}")" ]]; then
    token0_decimals=18
    token1_decimals="${STABLE_DECIMALS}"
    stable_is_token1=1
  elif [[ -n "${pool_currency0}" && -n "${pool_currency1}" && -n "${stable_currency}" ]]; then
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

  activity_cache_dir="./scripts/out/cache/hook_status"
  activity_cache_file="${activity_cache_dir}/activity.v5.${CHAIN}.${POOL_ID}.json"
  latest_block="$(rpc_block_number || true)"
  if [[ "${latest_block}" =~ ^[0-9]+$ ]]; then
    activity_line="$(compute_pool_activity_lifetime_line "${POOL_ACTIVITY_START_BLOCK}" "${latest_block}" "${stable_is_token1}" "${STABLE_DECIMALS}" "${activity_cache_file}" "${POOL_ACTIVITY_CHUNK_BLOCKS}")"
    last_hour_lines="$(compute_last_hour_fee_change_lines "${latest_block}" "${period_seconds}" "${current_fee}" "${ema_periods}" "${ema_vol}" "${floor_idx}" "${cap_idx}" "${fee_idx}")"
  else
    activity_line="$(pool_activity_line_from_cache "${activity_cache_file}" "${POOL_ACTIVITY_START_BLOCK}" "block_number_unavailable")"
    last_hour_lines="last_hour_status: status=ERROR error=block_number_unavailable from_block=? to_block=? changes=0 periods=0"
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
  pool_tvl_usd6="$(compute_pool_tvl_from_cache "${activity_cache_file}" "${sqrt_price}" "${token0_decimals}" "${token1_decimals}" "${stable_is_token1}" || true)"
  if [[ -z "${pool_tvl_usd6}" ]]; then
    pool_tvl_usd6="?"
  fi
  if [[ -z "${price}" || "${price}" == "?" ]]; then
    cache_last_sqrt="$(read_last_swap_sqrt_from_cache "${activity_cache_file}" || true)"
    if [[ "${cache_last_sqrt}" =~ ^[0-9]+$ && "${cache_last_sqrt}" != "0" ]]; then
      price="$(human_price_from_sqrt_x96 "${cache_last_sqrt}" "${token0_decimals}" "${token1_decimals}" "${stable_is_token1}")"
    fi
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
  echo "pool_tvl_usd6=${pool_tvl_usd6}"
  echo "pool_price_stable_per_volatile=${price:-?}"
  echo "${activity_line}"
  echo "${last_hour_lines}"
  echo "checks: initialized=${init_status} fee_sync=${fee_sync} fee_idx_bounds=${fee_bounds} liquidity=${liq_status}"
}

inline_value() {
  local raw="$1"
  local key="$2"
  printf '%s\n' "${raw}" | sed -n "s/.*${key}=\\([^ ]*\\).*/\\1/p" | head -n 1
}

fee_metric_for_bips() {
  local lines="$1"
  local fee_bips="$2"
  local key="$3"
  printf '%s\n' "${lines}" | sed -n "s/^fee_pips=${fee_bips} .*${key}=\\([^ ]*\\).*/\\1/p" | head -n 1
}

line_value() {
  local raw="$1"
  local key="$2"
  printf '%s\n' "${raw}" | sed -n "s/^${key}=//p" | head -n 1
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

bips_to_percent() {
  local bips="$1"
  if ! [[ "${bips}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  python3 - "${bips}" <<'PY'
from decimal import Decimal
import sys
bips = Decimal(sys.argv[1])
print(f"{(bips/Decimal(10000)).normalize()}%")
PY
}

bips_to_percent_2dp() {
  local bips="$1"
  if ! [[ "${bips}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  python3 - "${bips}" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys
bips = Decimal(sys.argv[1])
pct = (bips / Decimal(10000)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
print(f"{pct}%")
PY
}

deadband_bps_to_percent() {
  local bps="$1"
  if ! [[ "${bps}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  python3 - "${bps}" <<'PY'
from decimal import Decimal
import sys
b = Decimal(sys.argv[1])
v = b / Decimal(100)
s = format(v, "f")
if "." in s:
    s = s.rstrip("0").rstrip(".")
print(f"{s}%")
PY
}

usd6_to_dollar() {
  local usd6="$1"
  if ! [[ "${usd6}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  python3 - "${usd6}" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys
v = Decimal(sys.argv[1]) / Decimal(1_000_000)
q = v.quantize(Decimal("1"), rounding=ROUND_HALF_UP)
print(f"${q:,.0f}")
PY
}

usd6_to_dollar_2dp() {
  local usd6="$1"
  if ! [[ "${usd6}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  python3 - "${usd6}" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys
v = Decimal(sys.argv[1]) / Decimal(1_000_000)
q = v.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
print(f"${q:,.2f}")
PY
}

fee_rate_percent_for_period() {
  local fees_usd6="$1"
  local volume_usd6="$2"
  if ! [[ "${fees_usd6}" =~ ^[0-9]+$ && "${volume_usd6}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  python3 - "${fees_usd6}" "${volume_usd6}" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys

fees = Decimal(sys.argv[1])
volume = Decimal(sys.argv[2])
if volume <= 0:
    print("-")
    raise SystemExit(0)
rate = (fees / volume) * Decimal(100)
q = rate.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
print(f"{q}%")
PY
}

format_price_usd_2dp() {
  local price="$1"
  if [[ -z "${price}" || "${price}" == "?" ]]; then
    echo "-"
    return
  fi
  python3 - "${price}" <<'PY'
from decimal import Decimal, ROUND_HALF_UP, InvalidOperation
import sys
try:
    v = Decimal(sys.argv[1])
except (InvalidOperation, ValueError):
    print("-")
    raise SystemExit(0)
if v <= 0:
    print("-")
    raise SystemExit(0)
q = v.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
print(f"${q:,.2f}")
PY
}

fees_usd6_per_swap() {
  local fees_usd6="$1"
  local swaps="$2"
  if ! [[ "${fees_usd6}" =~ ^[0-9]+$ && "${swaps}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  if (( swaps == 0 )); then
    echo "-"
    return
  fi
  python3 - "${fees_usd6}" "${swaps}" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys
fees_usd6 = Decimal(sys.argv[1])
swaps = Decimal(sys.argv[2])
v = (fees_usd6 / Decimal(1_000_000)) / swaps
q = v.quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP)
print(f"${q:,.4f}")
PY
}

fees_usd6_per_swap_2dp() {
  local fees_usd6="$1"
  local swaps="$2"
  if ! [[ "${fees_usd6}" =~ ^[0-9]+$ && "${swaps}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  if (( swaps == 0 )); then
    echo "-"
    return
  fi
  python3 - "${fees_usd6}" "${swaps}" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys
fees_usd6 = Decimal(sys.argv[1])
swaps = Decimal(sys.argv[2])
v = (fees_usd6 / Decimal(1_000_000)) / swaps
q = v.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
print(f"${q:,.2f}")
PY
}

center_text() {
  local txt="$1"
  local width="$2"
  local len=${#txt}
  local left right
  if (( len >= width )); then
    printf '%s' "${txt:0:width}"
    return
  fi
  left=$(( (width - len) / 2 ))
  right=$(( width - len - left ))
  printf '%*s%s%*s' "${left}" "" "${txt}" "${right}" ""
}

ema_periods_window_label() {
  local period_seconds="$1"
  local ema_periods="$2"
  if ! [[ "${period_seconds}" =~ ^[0-9]+$ && "${ema_periods}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  python3 - "${period_seconds}" "${ema_periods}" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys
period = int(sys.argv[1])
ema = int(sys.argv[2])
seconds = period * ema
if seconds <= 0:
    print("-")
    raise SystemExit(0)
hours = Decimal(seconds) / Decimal(3600)
hours_rounded = hours.quantize(Decimal("0.1"), rounding=ROUND_HALF_UP)
if hours_rounded == hours_rounded.to_integral():
    h = f"{int(hours_rounded)}"
else:
    h = f"{hours_rounded.normalize()}"
print(f"~{h}h")
PY
}

seconds_to_hours_label() {
  local seconds="$1"
  if ! [[ "${seconds}" =~ ^[0-9]+$ ]]; then
    echo "-"
    return
  fi
  python3 - "${seconds}" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys
seconds = int(sys.argv[1])
if seconds <= 0:
    print("0h")
    raise SystemExit(0)
hours = (Decimal(seconds) / Decimal(3600)).quantize(Decimal("0.1"), rounding=ROUND_HALF_UP)
if hours == hours.to_integral():
    print(f"{int(hours)}h")
else:
    print(f"{hours.normalize()}h")
PY
}

tier_for_idx() {
  local tiers="$1"
  local idx="$2"
  local item key value
  IFS=',' read -r -a items <<<"${tiers}"
  for item in "${items[@]}"; do
    key="${item%%:*}"
    value="${item#*:}"
    if [[ "${key}" == "${idx}" ]]; then
      echo "${value}"
      return
    fi
  done
  echo "-"
}

dir_label() {
  case "$1" in
    1) echo "UP" ;;
    2) echo "DOWN" ;;
    0) echo "NONE" ;;
    *) echo "-" ;;
  esac
}

format_deploy_level() {
  local tiers="$1"
  local idx="$2"
  local bips pct
  bips="$(tier_for_idx "${tiers}" "${idx}")"
  if [[ "${bips}" =~ ^[0-9]+$ ]]; then
    pct="$(bips_to_percent "${bips}")"
    echo "${pct}"
  else
    echo "i${idx}"
  fi
}

render_dashboard_once() {
  local raw
  local activity_line
  local activity_fee_lines
  local last_hour_status_line last_hour_period_lines last_hour_change_lines
  local window_24h_line window_7d_line window_30d_line window_90d_line window_180d_line window_365d_line
  local ts chain chain_id hook_addr pool_manager pool_id state_view
  local tick_spacing initial_idx floor_idx cap_idx pause_idx period_seconds ema_periods deadband_bps lull_reset_seconds
  local fee_tiers paused current_fee pv ema_vol fee_idx last_dir
  local tick protocol_fee lp_fee liquidity price pool_tvl_usd6 has_slot0
  local activity_swaps activity_volume activity_fees activity_lp activity_status
  local a24_swaps a24_volume a24_fees a7_swaps a7_volume a7_fees a30_swaps a30_volume a30_fees
  local a90_swaps a90_volume a90_fees a180_swaps a180_volume a180_fees a365_swaps a365_volume a365_fees
  local fee_level_bips fee_level_pct
  local pv_usd ema_usd pool_tvl_usd tick_fmt liquidity_fmt activity_volume_usd activity_fees_usd
  local a24_volume_usd a24_fees_usd a7_volume_usd a7_fees_usd a30_volume_usd a30_fees_usd
  local a90_volume_usd a90_fees_usd a180_volume_usd a180_fees_usd a365_volume_usd a365_fees_usd
  local activity_fee_rate a24_fee_rate a7_fee_rate a30_fee_rate a90_fee_rate a180_fee_rate a365_fee_rate
  local activity_swaps_fmt a24_swaps_fmt a7_swaps_fmt a30_swaps_fmt a90_swaps_fmt a180_swaps_fmt a365_swaps_fmt
  local tier_items tier_item tier_i tier_bips tier_pct tier_swaps tier_volume tier_fees tier_swaps_fmt tier_volume_usd tier_fees_usd tier_fee_per_swap_usd
  local fee_line fee_printed_count fee_fallback_bips can_filter_levels
  local tier_fee_label
  local run_badge deploy_floor deploy_initial deploy_pause deploy_cap deploy_deadband_pct
  local params_period params_ema params_lull_reset params_tick_spacing params_ema_window params_ema_full
  local levels_summary level_idx level_bips level_pct
  local live_period_vol live_last_dir
  local lh_status lh_change_count lh_time lh_direction lh_from_bips lh_to_bips lh_from_pct lh_to_pct lh_change lh_ema lh_volume lh_reason
  local lh_ema_raw lh_volume_raw period_estimate
  local lh_time_cell lh_change_cell lh_ema_cell lh_volume_cell lh_reason_cell
  local lh_reason_dir lh_reason_display
  local activity_rows_target activity_stream_lines
  local price_usd

  raw="$(render_raw_once)"

  ts="$(line_value "${raw}" "timestamp_utc")"
  chain="$(inline_value "${raw}" "chain")"
  chain_id="$(inline_value "${raw}" "chain_id")"
  hook_addr="$(line_value "${raw}" "hook_address")"
  pool_manager="$(line_value "${raw}" "pool_manager")"
  pool_id="$(line_value "${raw}" "pool_id")"
  state_view="$(line_value "${raw}" "state_view_address")"

  tick_spacing="$(inline_value "${raw}" "tick_spacing")"
  initial_idx="$(inline_value "${raw}" "initial_idx")"
  floor_idx="$(inline_value "${raw}" "floor_idx")"
  cap_idx="$(inline_value "${raw}" "cap_idx")"
  pause_idx="$(inline_value "${raw}" "pause_idx")"
  period_seconds="$(inline_value "${raw}" "period_seconds")"
  ema_periods="$(inline_value "${raw}" "ema_periods")"
  deadband_bps="$(inline_value "${raw}" "deadband_bps")"
  lull_reset_seconds="$(inline_value "${raw}" "lull_reset_seconds")"

  fee_tiers="$(line_value "${raw}" "fee_tiers_bips")"
  paused="$(inline_value "${raw}" "paused")"
  current_fee="$(inline_value "${raw}" "current_fee_bips")"
  pv="$(inline_value "${raw}" "period_volume_usd6")"
  ema_vol="$(inline_value "${raw}" "ema_volume_usd6")"
  fee_idx="$(inline_value "${raw}" "fee_idx")"
  last_dir="$(inline_value "${raw}" "last_dir")"

  tick="$(inline_value "${raw}" "tick")"
  protocol_fee="$(inline_value "${raw}" "protocol_fee")"
  lp_fee="$(inline_value "${raw}" "lp_fee")"
  liquidity="$(inline_value "${raw}" "liquidity")"
  price="$(line_value "${raw}" "pool_price_stable_per_volatile")"
  if [[ -z "${price}" ]]; then
    price="$(inline_value "${raw}" "price_stable_per_volatile")"
  fi
  pool_tvl_usd6="$(line_value "${raw}" "pool_tvl_usd6")"

  activity_line="$(printf '%s\n' "${raw}" | sed -n 's/^pool_activity: //p' | head -n 1)"
  activity_swaps="$(inline_value "${activity_line}" "swaps")"
  activity_volume="$(inline_value "${activity_line}" "volume_usd6")"
  activity_fees="$(inline_value "${activity_line}" "fees_usd6")"
  activity_lp="$(inline_value "${activity_line}" "lp_providers")"
  activity_status="$(inline_value "${activity_line}" "status")"
  activity_fee_lines="$(printf '%s\n' "${raw}" | sed -n 's/^pool_activity_fee: //p')"
  last_hour_status_line="$(printf '%s\n' "${raw}" | sed -n 's/^last_hour_status: //p' | head -n 1)"
  last_hour_period_lines="$(printf '%s\n' "${raw}" | sed -n 's/^last_hour_period: //p')"
  last_hour_change_lines="$(printf '%s\n' "${raw}" | sed -n 's/^last_hour_change: //p')"
  window_24h_line="$(printf '%s\n' "${raw}" | sed -n 's/^pool_activity_window: label=24h //p' | head -n 1)"
  window_7d_line="$(printf '%s\n' "${raw}" | sed -n 's/^pool_activity_window: label=7d //p' | head -n 1)"
  window_30d_line="$(printf '%s\n' "${raw}" | sed -n 's/^pool_activity_window: label=30d //p' | head -n 1)"
  window_90d_line="$(printf '%s\n' "${raw}" | sed -n 's/^pool_activity_window: label=90d //p' | head -n 1)"
  window_180d_line="$(printf '%s\n' "${raw}" | sed -n 's/^pool_activity_window: label=180d //p' | head -n 1)"
  window_365d_line="$(printf '%s\n' "${raw}" | sed -n 's/^pool_activity_window: label=365d //p' | head -n 1)"
  a24_swaps="$(inline_value "${window_24h_line}" "swaps")"
  a24_volume="$(inline_value "${window_24h_line}" "volume_usd6")"
  a24_fees="$(inline_value "${window_24h_line}" "fees_usd6")"
  a7_swaps="$(inline_value "${window_7d_line}" "swaps")"
  a7_volume="$(inline_value "${window_7d_line}" "volume_usd6")"
  a7_fees="$(inline_value "${window_7d_line}" "fees_usd6")"
  a30_swaps="$(inline_value "${window_30d_line}" "swaps")"
  a30_volume="$(inline_value "${window_30d_line}" "volume_usd6")"
  a30_fees="$(inline_value "${window_30d_line}" "fees_usd6")"
  a90_swaps="$(inline_value "${window_90d_line}" "swaps")"
  a90_volume="$(inline_value "${window_90d_line}" "volume_usd6")"
  a90_fees="$(inline_value "${window_90d_line}" "fees_usd6")"
  a180_swaps="$(inline_value "${window_180d_line}" "swaps")"
  a180_volume="$(inline_value "${window_180d_line}" "volume_usd6")"
  a180_fees="$(inline_value "${window_180d_line}" "fees_usd6")"
  a365_swaps="$(inline_value "${window_365d_line}" "swaps")"
  a365_volume="$(inline_value "${window_365d_line}" "volume_usd6")"
  a365_fees="$(inline_value "${window_365d_line}" "fees_usd6")"

  fee_level_bips="$(tier_for_idx "${fee_tiers}" "${fee_idx}")"
  if ! [[ "${fee_level_bips}" =~ ^[0-9]+$ ]]; then
    fee_level_bips="${current_fee}"
  fi
  fee_level_pct="$(bips_to_percent "${fee_level_bips}")"
  pv_usd="$(usd6_to_dollar "${pv}")"
  ema_usd="$(usd6_to_dollar "${ema_vol}")"
  pool_tvl_usd="$(usd6_to_dollar "${pool_tvl_usd6}")"
  tick_fmt="$(format_int_commas "${tick}")"
  liquidity_fmt="$(format_int_commas "${liquidity}")"
  activity_volume_usd="$(usd6_to_dollar "${activity_volume}")"
  activity_fees_usd="$(usd6_to_dollar "${activity_fees}")"
  a24_volume_usd="$(usd6_to_dollar "${a24_volume}")"
  a24_fees_usd="$(usd6_to_dollar "${a24_fees}")"
  a7_volume_usd="$(usd6_to_dollar "${a7_volume}")"
  a7_fees_usd="$(usd6_to_dollar "${a7_fees}")"
  a30_volume_usd="$(usd6_to_dollar "${a30_volume}")"
  a30_fees_usd="$(usd6_to_dollar "${a30_fees}")"
  a90_volume_usd="$(usd6_to_dollar "${a90_volume}")"
  a90_fees_usd="$(usd6_to_dollar "${a90_fees}")"
  a180_volume_usd="$(usd6_to_dollar "${a180_volume}")"
  a180_fees_usd="$(usd6_to_dollar "${a180_fees}")"
  a365_volume_usd="$(usd6_to_dollar "${a365_volume}")"
  a365_fees_usd="$(usd6_to_dollar "${a365_fees}")"
  a24_fee_rate="$(fee_rate_percent_for_period "${a24_fees}" "${a24_volume}")"
  a7_fee_rate="$(fee_rate_percent_for_period "${a7_fees}" "${a7_volume}")"
  a30_fee_rate="$(fee_rate_percent_for_period "${a30_fees}" "${a30_volume}")"
  a90_fee_rate="$(fee_rate_percent_for_period "${a90_fees}" "${a90_volume}")"
  a180_fee_rate="$(fee_rate_percent_for_period "${a180_fees}" "${a180_volume}")"
  a365_fee_rate="$(fee_rate_percent_for_period "${a365_fees}" "${a365_volume}")"
  activity_fee_rate="$(fee_rate_percent_for_period "${activity_fees}" "${activity_volume}")"
  activity_swaps_fmt="$(format_int_commas "${activity_swaps}")"
  a24_swaps_fmt="$(format_int_commas "${a24_swaps}")"
  a7_swaps_fmt="$(format_int_commas "${a7_swaps}")"
  a30_swaps_fmt="$(format_int_commas "${a30_swaps}")"
  a90_swaps_fmt="$(format_int_commas "${a90_swaps}")"
  a180_swaps_fmt="$(format_int_commas "${a180_swaps}")"
  a365_swaps_fmt="$(format_int_commas "${a365_swaps}")"
  has_slot0=0
  if [[ "${tick}" =~ ^-?[0-9]+$ || "${lp_fee}" =~ ^[0-9]+$ || "${protocol_fee}" =~ ^[0-9]+$ || "${liquidity}" =~ ^[0-9]+$ ]]; then
    has_slot0=1
  fi
  params_period="-"
  if [[ "${period_seconds}" =~ ^[0-9]+$ ]]; then
    params_period="${period_seconds}s"
  fi
  params_ema="-"
  if [[ "${ema_periods}" =~ ^[0-9]+$ ]]; then
    params_ema="${ema_periods}"
  fi
  params_ema_window="$(ema_periods_window_label "${period_seconds}" "${ema_periods}")"
  params_ema_full="${params_ema}"
  if [[ "${params_ema_window}" != "-" ]]; then
    params_ema_full="${params_ema} (${params_ema_window})"
  fi
  params_lull_reset="-"
  if [[ "${lull_reset_seconds}" =~ ^[0-9]+$ ]]; then
    params_lull_reset="$(seconds_to_hours_label "${lull_reset_seconds}")"
  fi
  params_tick_spacing="-"
  if [[ "${tick_spacing}" =~ ^-?[0-9]+$ ]]; then
    params_tick_spacing="${tick_spacing}"
  fi
  if [[ "${paused}" == "true" ]]; then
    run_badge="(Paused)"
    if [[ -t 1 ]]; then
      run_badge=$'\033[33m(Paused)\033[0m'
    fi
  elif [[ "${paused}" == "false" ]]; then
    run_badge="(Running)"
    if [[ -t 1 ]]; then
      run_badge=$'\033[32m(Running)\033[0m'
    fi
  else
    run_badge=""
  fi
  deploy_floor="$(format_deploy_level "${fee_tiers}" "${floor_idx}")"
  deploy_initial="$(format_deploy_level "${fee_tiers}" "${initial_idx}")"
  deploy_pause="$(format_deploy_level "${fee_tiers}" "${pause_idx}")"
  deploy_cap="$(format_deploy_level "${fee_tiers}" "${cap_idx}")"
  deploy_deadband_pct="$(deadband_bps_to_percent "${deadband_bps}")"
  levels_summary="-"
  if [[ "${floor_idx}" =~ ^[0-9]+$ && "${cap_idx}" =~ ^[0-9]+$ ]] && (( cap_idx >= floor_idx )); then
    levels_summary=""
    for (( level_idx=floor_idx; level_idx<=cap_idx; level_idx++ )); do
      level_bips="$(tier_for_idx "${fee_tiers}" "${level_idx}")"
      if [[ "${level_bips}" =~ ^[0-9]+$ ]]; then
        level_pct="$(bips_to_percent "${level_bips}")"
      else
        level_pct="-"
      fi
      if [[ -n "${levels_summary}" ]]; then
        levels_summary="${levels_summary} | "
      fi
      levels_summary="${levels_summary}${level_pct}"
    done
    if [[ -z "${levels_summary}" ]]; then
      levels_summary="-"
    fi
  fi
  echo "===== Dynamic Fee Hook Status ====="
  echo "Updated (UTC): ${ts}"
  echo
  echo "Chain: ${chain} (${chain_id})"
  echo "  Manager: ${pool_manager}"
  echo "  Pool: ${pool_id}"
  if [[ -n "${run_badge}" ]]; then
    echo "  Hook: ${hook_addr} ${run_badge}"
  else
    echo "  Hook: ${hook_addr}"
  fi
  price_usd="$(format_price_usd_2dp "${price}")"
  echo "  Price: ${price_usd}"
  echo
  echo "Deploy:"
  echo "  Limits: initial=${deploy_initial} | floor=${deploy_floor} | cap=${deploy_cap} | pause=${deploy_pause}"
  echo "  Levels: ${levels_summary}"
  echo "  Params: period=${params_period} | emaPeriods=${params_ema_full} | deadband=${deploy_deadband_pct} | lullReset=${params_lull_reset} | tickSpacing=${params_tick_spacing}"
  echo
  live_period_vol="$(usd6_to_dollar "${pv}")"
  live_last_dir="$(dir_label "${last_dir}")"
  echo "Live:"
  echo "  +------------+------------------+------------------+--------------+----------------------+"
  printf "  | %s | %s | %s | %s | %s |\n" "$(center_text "Level" 10)" "$(center_text "TVL" 16)" "$(center_text "PeriodVol" 16)" "$(center_text "EMA" 12)" "$(center_text "Direction" 20)"
  echo "  +------------+------------------+------------------+--------------+----------------------+"
  printf "  | %s | %s | %s | %s | %s |\n" \
    "$(center_text "${fee_level_pct}" 10)" \
    "$(center_text "${pool_tvl_usd}" 16)" \
    "$(center_text "${live_period_vol}" 16)" \
    "$(center_text "${ema_usd}" 12)" \
    "$(center_text "${live_last_dir}" 20)"
  echo "  +------------+------------------+------------------+--------------+----------------------+"
  if [[ -n "${state_view}" && "${state_view}" != "not-set" ]]; then
    echo "  StateView: ${state_view}"
  fi
  if (( has_slot0 == 1 )); then
    echo "  Slot0: tick=${tick_fmt} | lpFee=${lp_fee} | protocolFee=${protocol_fee} | liquidity=${liquidity_fmt}"
  fi
  echo
  echo "Historical Data:"
  echo "  +------------+------------------+------------------+--------------+----------------------+"
  printf "  | %s | %s | %s | %s | %s |\n" \
    "$(center_text "Period" 10)" \
    "$(center_text "Swaps" 16)" \
    "$(center_text "Volume USD" 16)" \
    "$(center_text "Fees USD" 12)" \
    "$(center_text "Fee Rate" 20)"
  echo "  +------------+------------------+------------------+--------------+----------------------+"
  printf "  | %s | %16s | %16s | %12s | %20s |\n" "$(center_text "1d" 10)" "${a24_swaps_fmt}" "${a24_volume_usd}" "${a24_fees_usd}" "${a24_fee_rate}"
  printf "  | %s | %16s | %16s | %12s | %20s |\n" "$(center_text "7d" 10)" "${a7_swaps_fmt}" "${a7_volume_usd}" "${a7_fees_usd}" "${a7_fee_rate}"
  printf "  | %s | %16s | %16s | %12s | %20s |\n" "$(center_text "30d" 10)" "${a30_swaps_fmt}" "${a30_volume_usd}" "${a30_fees_usd}" "${a30_fee_rate}"
  printf "  | %s | %16s | %16s | %12s | %20s |\n" "$(center_text "90d" 10)" "${a90_swaps_fmt}" "${a90_volume_usd}" "${a90_fees_usd}" "${a90_fee_rate}"
  printf "  | %s | %16s | %16s | %12s | %20s |\n" "$(center_text "180d" 10)" "${a180_swaps_fmt}" "${a180_volume_usd}" "${a180_fees_usd}" "${a180_fee_rate}"
  printf "  | %s | %16s | %16s | %12s | %20s |\n" "$(center_text "365d" 10)" "${a365_swaps_fmt}" "${a365_volume_usd}" "${a365_fees_usd}" "${a365_fee_rate}"
  echo "  +------------+------------------+------------------+--------------+----------------------+"
  printf "  | %s | %16s | %16s | %12s | %20s |\n" "$(center_text "Lifetime" 10)" "${activity_swaps_fmt}" "${activity_volume_usd}" "${activity_fees_usd}" "${activity_fee_rate}"
  echo "  +------------+------------------+------------------+--------------+----------------------+"
  if [[ "${activity_status}" != "OK" ]]; then
    echo "  status: ${activity_status}"
  fi
  echo
  echo "Fee Levels:"
  echo "  +------------+------------------+------------------+--------------+----------------------+"
  printf "  | %s | %s | %s | %s | %s |\n" "$(center_text "Level" 10)" "$(center_text "Swaps" 16)" "$(center_text "Volume USD" 16)" "$(center_text "Fees USD" 12)" "$(center_text "Fees/Swap" 20)"
  echo "  +------------+------------------+------------------+--------------+----------------------+"
  fee_printed_count=0
  can_filter_levels=0
  if [[ "${floor_idx}" =~ ^[0-9]+$ && "${cap_idx}" =~ ^[0-9]+$ ]]; then
    can_filter_levels=1
  fi
  IFS=',' read -r -a tier_items <<<"${fee_tiers}"
  for tier_item in "${tier_items[@]}"; do
    tier_i="${tier_item%%:*}"
    tier_bips="${tier_item#*:}"
    if ! [[ "${tier_i}" =~ ^[0-9]+$ && "${tier_bips}" =~ ^[0-9]+$ ]]; then
      continue
    fi
    if (( can_filter_levels == 0 )); then
      continue
    fi
    if (( tier_i < floor_idx || tier_i > cap_idx )); then
      continue
    fi
    tier_pct="$(bips_to_percent_2dp "${tier_bips}")"
    tier_swaps="$(fee_metric_for_bips "${activity_fee_lines}" "${tier_bips}" "swaps")"
    tier_volume="$(fee_metric_for_bips "${activity_fee_lines}" "${tier_bips}" "volume_usd6")"
    tier_fees="$(fee_metric_for_bips "${activity_fee_lines}" "${tier_bips}" "fees_usd6")"
    if [[ -z "${tier_swaps}" ]]; then tier_swaps=0; fi
    if [[ -z "${tier_volume}" ]]; then tier_volume=0; fi
    if [[ -z "${tier_fees}" ]]; then tier_fees=0; fi
    tier_swaps_fmt="$(format_int_commas "${tier_swaps}")"
    tier_volume_usd="$(usd6_to_dollar_2dp "${tier_volume}")"
    tier_fees_usd="$(usd6_to_dollar_2dp "${tier_fees}")"
    tier_fee_per_swap_usd="$(fees_usd6_per_swap_2dp "${tier_fees}" "${tier_swaps}")"
    tier_fee_label="${tier_pct}"
    printf "  | %s | %16s | %16s | %12s | %20s |\n" "$(center_text "${tier_fee_label}" 10)" "${tier_swaps_fmt}" "${tier_volume_usd}" "${tier_fees_usd}" "${tier_fee_per_swap_usd}"
    fee_printed_count=$((fee_printed_count + 1))
  done
  if (( fee_printed_count == 0 )); then
    while IFS= read -r fee_line; do
      if [[ -z "${fee_line}" ]]; then
        continue
      fi
      fee_fallback_bips="$(inline_value "${fee_line}" "fee_pips")"
      if ! [[ "${fee_fallback_bips}" =~ ^[0-9]+$ ]]; then
        continue
      fi
      tier_i="$(printf '%s\n' "${fee_tiers}" | tr ',' '\n' | sed -n "s/^\\([0-9][0-9]*\\):${fee_fallback_bips}$/\\1/p" | head -n 1)"
      if (( can_filter_levels == 0 )); then
        continue
      fi
      if ! [[ "${tier_i}" =~ ^[0-9]+$ ]]; then
        continue
      fi
      if (( tier_i < floor_idx || tier_i > cap_idx )); then
        continue
      fi
      tier_pct="$(bips_to_percent_2dp "${fee_fallback_bips}")"
      tier_swaps="$(inline_value "${fee_line}" "swaps")"
      tier_volume="$(inline_value "${fee_line}" "volume_usd6")"
      tier_fees="$(inline_value "${fee_line}" "fees_usd6")"
      if [[ -z "${tier_swaps}" ]]; then tier_swaps=0; fi
      if [[ -z "${tier_volume}" ]]; then tier_volume=0; fi
      if [[ -z "${tier_fees}" ]]; then tier_fees=0; fi
      tier_swaps_fmt="$(format_int_commas "${tier_swaps}")"
      tier_volume_usd="$(usd6_to_dollar_2dp "${tier_volume}")"
      tier_fees_usd="$(usd6_to_dollar_2dp "${tier_fees}")"
      tier_fee_per_swap_usd="$(fees_usd6_per_swap_2dp "${tier_fees}" "${tier_swaps}")"
      tier_fee_label="${tier_pct}"
      printf "  | %s | %16s | %16s | %12s | %20s |\n" "$(center_text "${tier_fee_label}" 10)" "${tier_swaps_fmt}" "${tier_volume_usd}" "${tier_fees_usd}" "${tier_fee_per_swap_usd}"
      fee_printed_count=$((fee_printed_count + 1))
    done < <(printf '%s\n' "${activity_fee_lines}")
  fi
  if (( fee_printed_count == 0 )); then
    printf "  | %s | %16s | %16s | %12s | %20s |\n" "$(center_text "-" 10)" "-" "-" "-" "-"
    if (( can_filter_levels == 0 )); then
      echo "  (waiting hook params: floor/cap unavailable)"
    else
      echo "  (no configured levels found)"
    fi
  fi
  echo "  +------------+------------------+------------------+--------------+----------------------+"
  echo
  echo "Activity (Last Hour):"
  echo "  +------------+------------------+------------------+--------------+----------------------+"
  printf "  | %s | %s | %s | %s | %s |\n" \
    "$(center_text "Time (UTC)" 10)" \
    "$(center_text "Level Change" 16)" \
    "$(center_text "EMA" 16)" \
    "$(center_text "Volume" 12)" \
    "$(center_text "Reason" 20)"
  echo "  +------------+------------------+------------------+--------------+----------------------+"
  activity_rows_target=12
  if [[ "${period_seconds}" =~ ^[0-9]+$ ]] && (( period_seconds > 0 )); then
    period_estimate=$((3600 / period_seconds + 4))
    if (( period_estimate > activity_rows_target )); then
      activity_rows_target="${period_estimate}"
    fi
  fi
  if [[ "${ema_periods}" =~ ^[0-9]+$ ]] && (( ema_periods > 0 )); then
    if (( ema_periods > activity_rows_target )); then
      activity_rows_target="${ema_periods}"
    fi
  fi
  if (( activity_rows_target > 60 )); then
    activity_rows_target=60
  fi
  activity_stream_lines="${last_hour_period_lines}"
  if [[ -z "${activity_stream_lines// /}" ]]; then
    activity_stream_lines="${last_hour_change_lines}"
  fi
  lh_change_count=0
  while IFS= read -r fee_line; do
    if [[ -z "${fee_line}" ]]; then
      continue
    fi
    lh_time="$(inline_value "${fee_line}" "time")"
    lh_direction="$(inline_value "${fee_line}" "direction")"
    lh_from_bips="$(inline_value "${fee_line}" "from_fee_bips")"
    lh_to_bips="$(inline_value "${fee_line}" "to_fee_bips")"
    lh_from_pct="$(bips_to_percent_2dp "${lh_from_bips}")"
    lh_to_pct="$(bips_to_percent_2dp "${lh_to_bips}")"
    lh_change="${lh_from_pct} -> ${lh_to_pct}"
    lh_ema_raw="$(inline_value "${fee_line}" "ema_usd6")"
    lh_volume_raw="$(inline_value "${fee_line}" "volume_usd6")"
    if [[ "${lh_ema_raw}" =~ ^[0-9]+$ ]]; then
      lh_ema="$(usd6_to_dollar "${lh_ema_raw}")"
    else
      lh_ema="-"
    fi
    if [[ "${lh_volume_raw}" =~ ^[0-9]+$ ]]; then
      lh_volume="$(usd6_to_dollar "${lh_volume_raw}")"
    else
      lh_volume="-"
    fi
    lh_reason="$(inline_value "${fee_line}" "reason")"
    if [[ -z "${lh_reason}" ]]; then
      if [[ "${lh_direction}" == "FLAT" ]]; then
        lh_reason="NO_SWAPS"
      else
        lh_reason="-"
      fi
    fi
    lh_reason_dir="FLAT"
    if [[ "${lh_direction}" == "UP" ]]; then
      lh_reason_dir="FEE_UP"
    elif [[ "${lh_direction}" == "DOWN" ]]; then
      lh_reason_dir="FEE_DOWN"
    fi
    if [[ "${lh_reason_dir}" == "FLAT" ]]; then
      if [[ -z "${lh_reason}" || "${lh_reason}" == "-" ]]; then
        lh_reason="NO_SWAPS"
      fi
      lh_reason_display="${lh_reason_dir}:${lh_reason}"
    else
      lh_reason_display="${lh_reason_dir}"
      if [[ -n "${lh_reason}" && "${lh_reason}" != "-" ]]; then
        lh_reason_display="${lh_reason_dir}:${lh_reason}"
      fi
    fi
    lh_time_cell="$(center_text "${lh_time}" 10)"
    lh_change_cell="$(center_text "${lh_change}" 16)"
    lh_ema_cell="$(printf '%16s' "${lh_ema}")"
    lh_volume_cell="$(printf '%12s' "${lh_volume}")"
    lh_reason_cell="$(printf '%20s' "${lh_reason_display}")"
    printf "  | %s | %s | %s | %s | %s |\n" \
      "${lh_time_cell}" \
      "${lh_change_cell}" \
      "${lh_ema_cell}" \
      "${lh_volume_cell}" \
      "${lh_reason_cell}"
    lh_change_count=$((lh_change_count + 1))
    if (( lh_change_count >= activity_rows_target )); then
      break
    fi
  done < <(printf '%s\n' "${activity_stream_lines}")
  if (( lh_change_count == 0 )); then
    printf "  | %s | %s | %16s | %12s | %20s |\n" \
      "$(center_text "-" 10)" \
      "$(center_text "-" 16)" \
      "-" \
      "-" \
      "-"
  fi
  echo "  +------------+------------------+------------------+--------------+----------------------+"
  lh_status="$(inline_value "${last_hour_status_line}" "status")"
  if [[ -n "${lh_status}" && "${lh_status}" != "OK" ]]; then
    echo "  status: ${lh_status}"
  fi
  echo
}

if (( REFRESH_SECONDS > 0 )); then
  while true; do
    if [[ -t 1 ]]; then
      printf '\033[2J\033[H'
      render_dashboard_once
      for (( remaining=REFRESH_SECONDS; remaining>0; remaining-- )); do
        printf '\rNext refresh in %2ss (Ctrl+C to stop) ' "${remaining}"
        sleep 1
      done
      printf '\r\033[K'
    else
      render_raw_once
      echo "-----"
      sleep "${REFRESH_SECONDS}"
    fi
  done
else
  if [[ -t 1 ]]; then
    render_dashboard_once
  else
    render_raw_once
  fi
fi
