#!/usr/bin/env bash
set -euo pipefail

DAYS=1
RPC_URL=""
NETWORK="optimism"
GECKO_BASE="https://api.geckoterminal.com/api/v2"
POOL_MANAGER="0x9a13f98cb987694c9f086b1f5eb990eea8264ec3"

usage() {
  cat <<USAGE
Usage:
  ./scripts/pool_stats_op.sh [--days N] [--rpc URL]

Options:
  --days N     Lookback window in days (default: 1)
  --rpc URL    Force RPC URL (otherwise auto-pick a public one)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="${2:-}"; shift 2 ;;
    --rpc)  RPC_URL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [[ "$DAYS" -lt 1 ]]; then
  echo "--days must be an integer >= 1"
  exit 1
fi

POOLS_JSON='[
  {"id":"0x2cf70f1927e5ecc3d025deb35cd33bf3ebf0d783992dd06764e3fa3d742eb694","label":"V4 ETH/USDC (yours, dynamic)","proto":"v4","fee_bps_fixed":null,"usdc_leg":1,"dec0":18,"dec1":6},
  {"id":"0xdb67e87b43804197a3a62c6d5066587d649782ce2dcada9586d6a35d57f02f2e","label":"V4 ETH/USDC 0.30%","proto":"v4","fee_bps_fixed":30,"usdc_leg":1,"dec0":18,"dec1":6},
  {"id":"0xc1738d90e2e26c35784a0d3e3d8a9f795074bca4","label":"V3 USDC/WETH 0.30%","proto":"v3","fee_bps_fixed":30,"usdc_leg":0,"dec0":6,"dec1":18},
  {"id":"0x1fb3cf6e48f1e7b10213e7b6d87d4c073c7fdb7b","label":"V3 USDC/WETH 0.05%","proto":"v3","fee_bps_fixed":5,"usdc_leg":0,"dec0":6,"dec1":18}
]'

python3 - <<'PY' "$RPC_URL" "$NETWORK" "$GECKO_BASE" "$POOL_MANAGER" "$DAYS" "$POOLS_JSON"
import json, sys, time, math, shutil, subprocess
from urllib.request import Request, urlopen

RPC_URL, NETWORK, GECKO_BASE, POOL_MANAGER, DAYS, POOLS_JSON = sys.argv[1:]
DAYS = int(DAYS)
pools = json.loads(POOLS_JSON)

UA = "curl/8.0 (pool-stats-op)"

def http_json(url: str, payload=None, timeout=60):
    data = None if payload is None else json.dumps(payload).encode()
    req = Request(url, data=data, headers={"Content-Type":"application/json", "User-Agent": UA})
    with urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

def rpc_call(url, method, params=None, _id=1):
    if params is None: params=[]
    res = http_json(url, {"jsonrpc":"2.0","id":_id,"method":method,"params":params}, timeout=60)
    if "error" in res:
        raise RuntimeError(res["error"])
    return res["result"]

def pick_rpc(user_rpc: str):
    if user_rpc:
        cid = int(rpc_call(user_rpc, "eth_chainId"), 16)
        if cid != 10:
            raise RuntimeError(f"RPC chainId={cid}, expected 10 (Optimism)")
        return user_rpc

    candidates = [
        "https://optimism-rpc.publicnode.com",
        "https://rpc.ankr.com/optimism",
        "https://mainnet.optimism.io",
    ]
    for url in candidates:
        try:
            cid = int(rpc_call(url, "eth_chainId"), 16)
            if cid == 10:
                return url
        except Exception:
            continue
    raise RuntimeError("Could not reach any public Optimism RPC. Pass --rpc with your provider URL.")

RPC = pick_rpc(RPC_URL)

TOPIC0_V3_SWAP = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"
TOPIC0_V4_SWAP = None
if shutil.which("cast"):
    try:
        out = subprocess.check_output(["cast","keccak","Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"], text=True).strip()
        if out.startswith("0x") and len(out) == 66:
            TOPIC0_V4_SWAP = out
    except Exception:
        TOPIC0_V4_SWAP = None

def rpc(method, params=None, _id=1):
    return rpc_call(RPC, method, params=params, _id=_id)

def hex_to_int_signed(word_hex: str) -> int:
    v = int(word_hex, 16)
    if v >= 2**255:
        v -= 2**256
    return v

def percentile(vals, p):
    if not vals:
        return None
    vals = sorted(vals)
    k = (len(vals) - 1) * (p / 100.0)
    f = math.floor(k); c = math.ceil(k)
    if f == c:
        return vals[int(k)]
    return vals[f] + (vals[c] - vals[f]) * (k - f)

def fnum(x):
    if x is None: return "NA"
    if abs(x) >= 1e9: return f"{x/1e9:.2f}B"
    if abs(x) >= 1e6: return f"{x/1e6:.2f}M"
    if abs(x) >= 1e3: return f"{x/1e3:.2f}K"
    return f"{x:.2f}"

def pct(x):
    return "NA" if x is None else f"{x:.2f}%"

def safe_float(x):
    try: return float(x)
    except: return None

latest_block = int(rpc("eth_blockNumber"), 16)

def get_block_ts(block_no: int) -> int:
    b = rpc("eth_getBlockByNumber", [hex(block_no), False])
    return int(b["timestamp"], 16)

now_ts = int(time.time())
start_ts = now_ts - DAYS * 86400

lo, hi = 0, latest_block
while lo < hi:
    mid = (lo + hi) // 2
    ts = get_block_ts(mid)
    if ts < start_ts:
        lo = mid + 1
    else:
        hi = mid
from_block = lo
to_block = latest_block

ids = ",".join([p["id"] for p in pools])
tvl_by_id = {}
try:
    gecko_url = f"{GECKO_BASE}/networks/{NETWORK}/pools/multi/{ids}"
    gecko = http_json(gecko_url, None, timeout=60)
except Exception:
    gecko = {"data":[]}

for item in gecko.get("data", []):
    a = item.get("attributes", {}) or {}
    pid = (a.get("address") or "").lower()
    if pid:
        tvl_by_id[pid] = safe_float(a.get("reserve_in_usd"))

def get_logs(address: str, topics, fb: int, tb: int):
    logs = []
    step = 20000
    cur = fb
    while cur <= tb:
        end = min(tb, cur + step - 1)
        params = [{
            "fromBlock": hex(cur),
            "toBlock": hex(end),
            "address": address,
            "topics": topics
        }]
        try:
            res = rpc("eth_getLogs", params, _id=7)
            logs.extend(res)
            cur = end + 1
        except Exception:
            step = max(500, step // 2)
            if step == 500 and cur == end:
                raise
    return logs

def price_token1_per_token0_from_sqrtP(sqrtP, dec0, dec1):
    price_raw = (sqrtP * sqrtP) / float(2**192)
    return price_raw * (10 ** (dec0 - dec1))

def is_v4_swap_log(log):
    if TOPIC0_V4_SWAP:
        return len(log.get("topics", [])) >= 3 and (log["topics"][0].lower() == TOPIC0_V4_SWAP.lower())
    tpcs = log.get("topics", [])
    data = log.get("data","")
    if not (isinstance(data,str) and data.startswith("0x")):
        return False
    hexdata = data[2:]
    return (len(tpcs) == 3) and (len(hexdata) == 64*6)

def analyze_pool(p):
    pid = p["id"]
    proto = p["proto"]
    usdc_leg = int(p["usdc_leg"])
    dec0 = int(p["dec0"]); dec1 = int(p["dec1"])
    fee_fixed = p["fee_bps_fixed"]

    if proto == "v4":
        addr = POOL_MANAGER
        topics = [TOPIC0_V4_SWAP, pid] if TOPIC0_V4_SWAP else [None, pid]
    else:
        addr = pid
        topics = [TOPIC0_V3_SWAP]

    logs = get_logs(addr, topics, from_block, to_block)

    swap_sizes_usd = []
    fee_bps_list = []
    total_volume_usd = 0.0
    total_fees_usd = 0.0

    for lg in logs:
        tpcs = lg.get("topics", [])
        data = lg.get("data","")
        if not (isinstance(data,str) and data.startswith("0x")):
            continue
        hexdata = data[2:]

        if proto == "v4":
            if not is_v4_swap_log(lg):
                continue
            if len(hexdata) < 64*6:
                continue
            amount0 = hex_to_int_signed(hexdata[0:64])
            amount1 = hex_to_int_signed(hexdata[64:128])
            sqrtP  = int(hexdata[128:192], 16)
            fee_raw = int(hexdata[-64:], 16)
            fee_bps = (fee_raw / 100.0)
        else:
            if len(hexdata) < 64*5:
                continue
            amount0 = hex_to_int_signed(hexdata[0:64])
            amount1 = hex_to_int_signed(hexdata[64:128])
            sqrtP  = int(hexdata[128:192], 16)
            fee_bps = float(fee_fixed) if fee_fixed is not None else None

        usdc_raw = amount0 if usdc_leg == 0 else amount1
        size_usd = abs(usdc_raw) / 1e6
        if size_usd == 0:
            continue

        fee_usd = None
        if fee_bps is not None:
            fee_rate = fee_bps / 10000.0
            if amount0 > 0:
                fee_token0 = (amount0 / (10 ** dec0)) * fee_rate
                if usdc_leg == 0:
                    fee_usd = fee_token0
                else:
                    price1per0 = price_token1_per_token0_from_sqrtP(sqrtP, dec0, dec1)
                    fee_usd = fee_token0 * price1per0
            elif amount1 > 0:
                fee_token1 = (amount1 / (10 ** dec1)) * fee_rate
                if usdc_leg == 1:
                    fee_usd = fee_token1
                else:
                    price1per0 = price_token1_per_token0_from_sqrtP(sqrtP, dec0, dec1)
                    usdc_per_weth = 1.0 / price1per0 if price1per0 else None
                    if usdc_per_weth is not None:
                        fee_usd = fee_token1 * usdc_per_weth

        if fee_usd is None and fee_bps is not None:
            fee_usd = size_usd * (fee_bps / 10000.0)

        swap_sizes_usd.append(size_usd)
        total_volume_usd += size_usd
        total_fees_usd += (fee_usd or 0.0)
        fee_bps_list.append(fee_bps if fee_bps is not None else 0.0)

    n = len(swap_sizes_usd)
    if n == 0:
        return dict(swaps=0, volume_usd=0.0, fees_usd=0.0,
                    avg_swap=None, p50_swap=None, p90_swap=None,
                    fee_bps_avg_w=None, fee_bps_p50=None, fee_bps_p90=None)

    avg_swap = total_volume_usd / n
    p50_swap = percentile(swap_sizes_usd, 50)
    p90_swap = percentile(swap_sizes_usd, 90)

    wsum = sum(s * b for s, b in zip(swap_sizes_usd, fee_bps_list))
    ssum = sum(swap_sizes_usd)
    fee_bps_avg_w = (wsum / ssum) if ssum else None
    fee_bps_p50 = percentile(fee_bps_list, 50)
    fee_bps_p90 = percentile(fee_bps_list, 90)

    return dict(
        swaps=n,
        volume_usd=total_volume_usd,
        fees_usd=total_fees_usd,
        avg_swap=avg_swap,
        p50_swap=p50_swap,
        p90_swap=p90_swap,
        fee_bps_avg_w=fee_bps_avg_w,
        fee_bps_p50=fee_bps_p50,
        fee_bps_p90=fee_bps_p90,
    )

results = []
for p in pools:
    r = analyze_pool(p)
    pid = p["id"].lower()
    tvl = tvl_by_id.get(pid)
    r["tvl_usd"] = tvl
    r["label"] = p["label"]
    r["id_short"] = p["id"][:10] + "…" + p["id"][-6:]
    if tvl and tvl > 0:
        r["apr_ann"] = (r["fees_usd"] / tvl) * (365.0 / DAYS) * 100.0
        r["vol_tvl"] = (r["volume_usd"] / tvl) * 100.0
    else:
        r["apr_ann"] = None
        r["vol_tvl"] = None
    results.append(r)

headers = [
    f"Pool (last {DAYS}d)",
    "TVL$ (spot)",
    "Swaps",
    "Volume$",
    "Fees$",
    "APR ann.",
    "AvgSwap$",
    "p50$",
    "p90$",
    "Fee bps (w-avg)",
    "Fee p50",
    "Fee p90",
    "ID"
]

rows = []
for r in results:
    rows.append([
        r["label"],
        fnum(r["tvl_usd"]) if r["tvl_usd"] is not None else "NA",
        str(r["swaps"]),
        fnum(r["volume_usd"]),
        fnum(r["fees_usd"]),
        pct(r["apr_ann"]),
        fnum(r["avg_swap"]) if r["avg_swap"] is not None else "NA",
        fnum(r["p50_swap"]) if r["p50_swap"] is not None else "NA",
        fnum(r["p90_swap"]) if r["p90_swap"] is not None else "NA",
        f"{r['fee_bps_avg_w']:.2f}" if r["fee_bps_avg_w"] is not None else "NA",
        f"{r['fee_bps_p50']:.2f}" if r["fee_bps_p50"] is not None else "NA",
        f"{r['fee_bps_p90']:.2f}" if r["fee_bps_p90"] is not None else "NA",
        r["id_short"],
    ])

colw = [min(max(len(str(x)) for x in col), 44) for col in zip(headers, *rows)]

def fmt_row(row):
    out=[]
    for i, x in enumerate(row):
        s = str(x)
        if len(s) > colw[i]:
            s = s[:colw[i]-1] + "…"
        out.append(s.ljust(colw[i]))
    return " | ".join(out)

print(f"RPC: {RPC}")
print(f"v4 topic0: {TOPIC0_V4_SWAP or 'NA (fallback heuristic)'}")
print(fmt_row(headers))
print("-+-".join("-"*w for w in colw))
for row in rows:
    print(fmt_row(row))

print("\nNotes:")
print(" - p50 = median; p90 = 90th percentile.")
print(" - TVL$ is spot TVL from GeckoTerminal; Volume/Fees are computed from Swap logs over the lookback window.")
PY
