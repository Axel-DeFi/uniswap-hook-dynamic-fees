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
        if int(state.get("schema_version", 0)) != 5:
            return default_state()
        if str(state.get("pool_id", "")).lower() != pool_id:
            return default_state()
        if int(state.get("from_block", -1)) != from_block:
            return default_state()
        st = default_state()
        st.update(state)
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
            h = int(hk)
            if h * 3600 >= cutoff:
                swaps += int(b.get("swaps", 0))
                volume += int(b.get("volume_usd6", 0))
                fees += int(b.get("fees_usd6", 0))
        out[label] = {"swaps": swaps, "volume_usd6": volume, "fees_usd6": fees}
    return out

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

if not os.path.exists(cache_file):
    print(
        "pool_activity: "
        f"mode=lifetime from_block={fallback_from_block} to_block=? scanned_through=? "
        "swaps=? volume_usd6=? fees_usd6=? avg_fee_pips=? lp_providers=? "
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
        "swaps=? volume_usd6=? fees_usd6=? avg_fee_pips=? lp_providers=? "
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
  local initial_idx floor_idx cap_idx pause_idx
  local period_seconds ema_periods deadband_bps lull_reset_seconds

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

  local slot0_raw sqrt_price tick protocol_fee lp_fee liquidity price token0_decimals token1_decimals stable_is_token1 pool_tvl_usd6
  local latest_block activity_line activity_cache_dir activity_cache_file
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

  activity_cache_dir="./scripts/out/cache/hook_status"
  activity_cache_file="${activity_cache_dir}/activity.v4.${CHAIN}.${POOL_ID}.json"
  latest_block="$(rpc_block_number || true)"
  if [[ "${latest_block}" =~ ^[0-9]+$ ]]; then
    activity_line="$(compute_pool_activity_lifetime_line "${POOL_ACTIVITY_START_BLOCK}" "${latest_block}" "${stable_is_token1}" "${STABLE_DECIMALS}" "${activity_cache_file}" "${POOL_ACTIVITY_CHUNK_BLOCKS}")"
  else
    activity_line="$(pool_activity_line_from_cache "${activity_cache_file}" "${POOL_ACTIVITY_START_BLOCK}" "block_number_unavailable")"
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
  echo "${activity_line}"
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
q = v.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
print(f"${q:,.2f}")
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
    echo "${pct} (${bips}, i${idx})"
  else
    echo "i${idx}"
  fi
}

render_dashboard_once() {
  local raw
  local activity_line
  local activity_fee_lines
  local window_24h_line window_7d_line window_30d_line window_90d_line window_180d_line window_365d_line
  local ts chain chain_id hook_addr pool_manager pool_id state_view
  local tick_spacing initial_idx floor_idx cap_idx pause_idx period_seconds
  local fee_tiers paused current_fee pv ema_vol fee_idx last_dir
  local tick protocol_fee lp_fee liquidity price pool_tvl_usd6 has_slot0
  local activity_swaps activity_volume activity_fees activity_lp activity_status
  local a24_swaps a24_volume a24_fees a7_swaps a7_volume a7_fees a30_swaps a30_volume a30_fees
  local a90_swaps a90_volume a90_fees a180_swaps a180_volume a180_fees a365_swaps a365_volume a365_fees
  local fee_level_bips fee_level_pct
  local pv_usd ema_usd pool_tvl_usd tick_fmt liquidity_fmt activity_volume_usd activity_fees_usd
  local a24_volume_usd a24_fees_usd a7_volume_usd a7_fees_usd a30_volume_usd a30_fees_usd
  local a90_volume_usd a90_fees_usd a180_volume_usd a180_fees_usd a365_volume_usd a365_fees_usd
  local activity_swaps_fmt a24_swaps_fmt a7_swaps_fmt a30_swaps_fmt a90_swaps_fmt a180_swaps_fmt a365_swaps_fmt
  local tier_items tier_item tier_i tier_bips tier_pct tier_swaps tier_volume tier_fees tier_swaps_fmt tier_volume_usd tier_fees_usd
  local fee_line fee_printed_count fee_fallback_bips can_filter_levels
  local tier_level_label tier_fee_label
  local period_label run_badge deploy_floor deploy_initial deploy_pause deploy_cap

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
  price="$(inline_value "${raw}" "price_stable_per_volatile")"
  pool_tvl_usd6="$(line_value "${raw}" "pool_tvl_usd6")"

  activity_line="$(printf '%s\n' "${raw}" | sed -n 's/^pool_activity: //p' | head -n 1)"
  activity_swaps="$(inline_value "${activity_line}" "swaps")"
  activity_volume="$(inline_value "${activity_line}" "volume_usd6")"
  activity_fees="$(inline_value "${activity_line}" "fees_usd6")"
  activity_lp="$(inline_value "${activity_line}" "lp_providers")"
  activity_status="$(inline_value "${activity_line}" "status")"
  activity_fee_lines="$(printf '%s\n' "${raw}" | sed -n 's/^pool_activity_fee: //p')"
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
  period_label="${period_seconds:-?}"
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
  echo "===== Dynamic Fee Hook Status ====="
  echo "Chain: ${chain} (${chain_id}) | Updated (UTC): ${ts}"
  echo
  echo "Pool + Hook:"
  echo "  Manager: ${pool_manager}"
  echo "  Pool: ${pool_id}"
  if [[ -n "${run_badge}" ]]; then
    echo "  Hook: ${hook_addr} ${run_badge}"
  else
    echo "  Hook: ${hook_addr}"
  fi
  echo "  Deploy: floor=${deploy_floor} | initial=${deploy_initial} | pause=${deploy_pause} | cap=${deploy_cap}"
  echo "  Live: fee=${fee_level_pct} (${fee_level_bips}, i${fee_idx}) | TVL=${pool_tvl_usd} | periodVol(${period_label}s)=${pv_usd} | ema=${ema_usd} | lastDir=$(dir_label "${last_dir}")"
  if [[ -n "${state_view}" && "${state_view}" != "not-set" ]]; then
    echo "  StateView: ${state_view}"
  fi
  if (( has_slot0 == 1 )); then
    echo "  Slot0: tick=${tick_fmt} | lpFee=${lp_fee} | protocolFee=${protocol_fee} | liquidity=${liquidity_fmt}"
  fi
  if [[ -n "${price}" && "${price}" != "?" ]]; then
    echo "  Price: stable/volatile=${price}"
  fi
  echo
  echo "Activity:"
  echo "  +-----------+--------------+-----------------+--------------+"
  printf "  | %-9s | %12s | %15s | %12s |\n" "Period" "Swaps" "Volume USD" "Fees USD"
  echo "  +-----------+--------------+-----------------+--------------+"
  printf "  | %-9s | %12s | %15s | %12s |\n" "24h" "${a24_swaps_fmt}" "${a24_volume_usd}" "${a24_fees_usd}"
  printf "  | %-9s | %12s | %15s | %12s |\n" "7d" "${a7_swaps_fmt}" "${a7_volume_usd}" "${a7_fees_usd}"
  printf "  | %-9s | %12s | %15s | %12s |\n" "30d" "${a30_swaps_fmt}" "${a30_volume_usd}" "${a30_fees_usd}"
  printf "  | %-9s | %12s | %15s | %12s |\n" "90d" "${a90_swaps_fmt}" "${a90_volume_usd}" "${a90_fees_usd}"
  printf "  | %-9s | %12s | %15s | %12s |\n" "180d" "${a180_swaps_fmt}" "${a180_volume_usd}" "${a180_fees_usd}"
  printf "  | %-9s | %12s | %15s | %12s |\n" "365d" "${a365_swaps_fmt}" "${a365_volume_usd}" "${a365_fees_usd}"
  echo "  +-----------+--------------+-----------------+--------------+"
  printf "  | %-9s | %12s | %15s | %12s |\n" "Lifetime" "${activity_swaps_fmt}" "${activity_volume_usd}" "${activity_fees_usd}"
  echo "  +-----------+--------------+-----------------+--------------+"
  if [[ "${activity_status}" != "OK" ]]; then
    echo "  status: ${activity_status}"
  fi
  echo
  echo "Fee Levels:"
  echo "  +-------+------------------+--------------+-----------------+--------------+"
  printf "  | %-5s | %-16s | %12s | %15s | %12s |\n" "Level" "Fee" "Swaps" "Volume USD" "Fees USD"
  echo "  +-------+------------------+--------------+-----------------+--------------+"
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
    tier_pct="$(bips_to_percent "${tier_bips}")"
    tier_swaps="$(fee_metric_for_bips "${activity_fee_lines}" "${tier_bips}" "swaps")"
    tier_volume="$(fee_metric_for_bips "${activity_fee_lines}" "${tier_bips}" "volume_usd6")"
    tier_fees="$(fee_metric_for_bips "${activity_fee_lines}" "${tier_bips}" "fees_usd6")"
    if [[ -z "${tier_swaps}" ]]; then tier_swaps=0; fi
    if [[ -z "${tier_volume}" ]]; then tier_volume=0; fi
    if [[ -z "${tier_fees}" ]]; then tier_fees=0; fi
    tier_swaps_fmt="$(format_int_commas "${tier_swaps}")"
    tier_volume_usd="$(usd6_to_dollar "${tier_volume}")"
    tier_fees_usd="$(usd6_to_dollar "${tier_fees}")"
    tier_level_label="i${tier_i}"
    tier_fee_label="${tier_pct} (${tier_bips})"
    printf "  | %-5s | %-16s | %12s | %15s | %12s |\n" "${tier_level_label}" "${tier_fee_label}" "${tier_swaps_fmt}" "${tier_volume_usd}" "${tier_fees_usd}"
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
      tier_pct="$(bips_to_percent "${fee_fallback_bips}")"
      tier_swaps="$(inline_value "${fee_line}" "swaps")"
      tier_volume="$(inline_value "${fee_line}" "volume_usd6")"
      tier_fees="$(inline_value "${fee_line}" "fees_usd6")"
      if [[ -z "${tier_swaps}" ]]; then tier_swaps=0; fi
      if [[ -z "${tier_volume}" ]]; then tier_volume=0; fi
      if [[ -z "${tier_fees}" ]]; then tier_fees=0; fi
      tier_swaps_fmt="$(format_int_commas "${tier_swaps}")"
      tier_volume_usd="$(usd6_to_dollar "${tier_volume}")"
      tier_fees_usd="$(usd6_to_dollar "${tier_fees}")"
      if [[ "${tier_i}" =~ ^[0-9]+$ ]]; then
        tier_level_label="i${tier_i}"
      else
        tier_level_label="-"
      fi
      tier_fee_label="${tier_pct} (${fee_fallback_bips})"
      printf "  | %-5s | %-16s | %12s | %15s | %12s |\n" "${tier_level_label}" "${tier_fee_label}" "${tier_swaps_fmt}" "${tier_volume_usd}" "${tier_fees_usd}"
      fee_printed_count=$((fee_printed_count + 1))
    done < <(printf '%s\n' "${activity_fee_lines}")
  fi
  if (( fee_printed_count == 0 )); then
    printf "  | %-5s | %-16s | %12s | %15s | %12s |\n" "-" "-" "-" "-" "-"
    if (( can_filter_levels == 0 )); then
      echo "  (waiting hook params: floor/cap unavailable)"
    else
      echo "  (no configured levels found)"
    fi
  fi
  echo "  +-------+------------------+--------------+-----------------+--------------+"
  echo
}

if (( WATCH_SECONDS > 0 )); then
  while true; do
    if [[ -t 1 ]]; then
      printf '\033[2J\033[H'
      render_dashboard_once
    else
      render_raw_once
      echo "-----"
    fi
    sleep "${WATCH_SECONDS}"
  done
else
  if [[ -t 1 ]]; then
    render_dashboard_once
  else
    render_raw_once
  fi
fi
