#!/usr/bin/env bash
set -euo pipefail

# Sepolia-only liquidity manager:
# 1) drains liquidity/fees from an old pool+hook,
# 2) redeploys hook and creates a new pool,
# 3) rebalances wallet balances (if needed),
# 4) adds free liquidity into the new pool,
# while keeping reserves for gas and test swaps.

CONFIG_PATH="./config/hook.sepolia.conf"
RESERVE_ETH="0"
RESERVE_STABLE="0"
SEARCH_BACK_BLOCKS=500000
SWAP_IMBALANCE_BPS=2000
SWAP_MAX_FRACTION_BPS=3500
REBALANCE_TARGET_STABLE_BPS=4700
REBALANCE_TOLERANCE_BPS=500
REBALANCE_STEP_DIVISOR=1
DEPLOY_SHARE_BPS=8000
BOOTSTRAP_SHARE_BPS=1000
TARGET_RANGE_MIN_USD="1000"
TARGET_RANGE_MAX_USD="5000"
TARGET_INIT_PRICE_USD="2500"
DRY_RUN=0
DEPOSIT_ONLY=0
CLAIM_ONLY=0

DYNAMIC_FEE_FLAG=8388608
MODIFY_TOPIC0="0xf208f4912782fd25c7f114ca3723a2d5dd6f3bcc3ac8db5af63baa85f711d5ec"
INIT_TOPIC0="0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438"
TRANSFER_TOPIC0="0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
SQRT_PRICE_LIMIT_X96_ZFO=4295128740
SQRT_PRICE_LIMIT_X96_OZF=1461446703485210103287273052203988822378723970341

log() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

to_uint() {
  local raw first
  raw="$(printf '%s' "${1:-}" | tr -d '\r' | tr '\n' ' ' | xargs)"
  first="${raw%% *}"
  if [[ "$first" =~ ^0x[0-9a-fA-F]+$ ]]; then
    cast --to-dec "$first" 2>/dev/null || echo 0
    return
  fi
  if [[ "$first" =~ ^[0-9]+$ ]]; then
    echo "$first"
    return
  fi
  echo 0
}

get_currency_decimals() {
  local currency="$1"
  local fallback="${2:-18}"
  local lc
  lc="$(lower "$currency")"
  if [[ "$lc" == "0x0000000000000000000000000000000000000000" ]]; then
    echo 18
    return
  fi
  local out
  out="$(cast call --rpc-url "$RPC_URL" "$currency" "decimals()(uint8)" 2>/dev/null || true)"
  out="$(to_uint "$out")"
  if [[ "$out" =~ ^[0-9]+$ ]] && (( out >= 0 && out <= 255 )); then
    echo "$out"
  else
    echo "$fallback"
  fi
}

format_amount_human() {
  local raw="${1:-0}"
  local decimals="${2:-18}"
  local places="${3:-6}"
  python3 - "$raw" "$decimals" "$places" <<'PY'
from decimal import Decimal, getcontext
import sys
getcontext().prec = 80
raw = int(sys.argv[1])
decimals = int(sys.argv[2])
places = int(sys.argv[3])
if decimals < 0:
    decimals = 0
if places < 0:
    places = 0
value = Decimal(raw) / (Decimal(10) ** decimals)
txt = f"{value:.{places}f}"
txt = txt.rstrip("0").rstrip(".")
if txt in ("", "-0"):
    txt = "0"
print(txt)
PY
}

format_eth_wei() {
  format_amount_human "${1:-0}" 18 6
}

format_stable_raw() {
  format_amount_human "${1:-0}" "${STABLE_DECIMALS:-6}" 4
}

format_bps_percent() {
  python3 - "${1:-0}" <<'PY'
import sys
bps = int(sys.argv[1])
print(f"{bps/100:.2f}")
PY
}

calc_wallet_budget_json() {
  local eth_raw="$1"
  local stable_raw="$2"
  local deploy_bps="${3:-${DEPLOY_SHARE_BPS}}"
  python3 - "$eth_raw" "$stable_raw" "$RESERVE_ETH" "$RESERVE_STABLE" "${STABLE_DECIMALS:-6}" "$deploy_bps" <<'PY'
import json
import sys
from decimal import Decimal, getcontext

getcontext().prec = 50

eth_raw = int(sys.argv[1])
stable_raw = int(sys.argv[2])
reserve_eth_human = Decimal(sys.argv[3])
reserve_stable_human = Decimal(sys.argv[4])
stable_decimals = int(sys.argv[5])
deploy_bps = int(sys.argv[6])

reserve_eth_abs = int(reserve_eth_human * (Decimal(10) ** 18))
reserve_stable_abs = int(reserve_stable_human * (Decimal(10) ** stable_decimals))

reserve_eth = reserve_eth_abs
reserve_stable = reserve_stable_abs

if reserve_eth > eth_raw:
    reserve_eth = eth_raw
if reserve_stable > stable_raw:
    reserve_stable = stable_raw

available_eth = max(0, eth_raw - reserve_eth)
available_stable = max(0, stable_raw - reserve_stable)
deploy_eth = (available_eth * max(0, deploy_bps)) // 10000
deploy_stable = (available_stable * max(0, deploy_bps)) // 10000

print(json.dumps({
    "reserveEthWei": reserve_eth,
    "reserveStableRaw": reserve_stable,
    "availableEthWei": available_eth,
    "availableStableRaw": available_stable,
    "deployEthWei": deploy_eth,
    "deployStableRaw": deploy_stable,
}, separators=(',', ':')))
PY
}

calc_bps_amount() {
  local value="$1"
  local bps="$2"
  python3 - "$value" "$bps" <<'PY'
import sys
v = int(sys.argv[1])
b = int(sys.argv[2])
if v < 0:
    v = 0
if b < 0:
    b = 0
print((v * b) // 10000)
PY
}

int_min() {
  python3 - "$1" "$2" <<'PY'
import sys
a = int(sys.argv[1])
b = int(sys.argv[2])
print(a if a <= b else b)
PY
}

int_lt() {
  python3 - "$1" "$2" <<'PY'
import sys
print("1" if int(sys.argv[1]) < int(sys.argv[2]) else "0")
PY
}

usage() {
  cat <<'USAGE'
Usage:
  ./test/scripts/redeploy_sepolia.sh [options]

Options:
  --claim                     Claim/drain from old hook+pool only (no redeploy, no deposit)
  --deposit                   Add liquidity only to current pool from config (no claim/redeploy)
  --dry-run                   Print actions without sending transactions
  -h, --help                  Show help

Notes:
  - Sepolia only.
  - Redeploy creates the pool with INIT_PRICE_USD=2500 by default.
  - Wallet rebalance target is 50/50 by value (STABLE vs VOLATILE).
  - Final LP deploy target is 80% of wallet balances (after reserve floors), range 1000..5000.
  - Liquidity range is fixed to 1000..5000 (STABLE per 1 VOLATILE).
  - If pool starts with zero liquidity, script adds a small bootstrap LP slice first to enable rebalance swaps.
  - Requires PRIVATE_KEY and RPC_URL via config/.env.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claim)
      CLAIM_ONLY=1; shift ;;
    --deposit)
      DEPOSIT_ONLY=1; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown argument: $1" ;;
  esac
done

if (( CLAIM_ONLY == 1 && DEPOSIT_ONLY == 1 )); then
  die "--claim and --deposit are mutually exclusive"
fi

[[ "${DEPLOY_SHARE_BPS}" =~ ^[0-9]+$ ]] || die "internal config error: DEPLOY_SHARE_BPS must be integer in [0..10000]"
[[ "${BOOTSTRAP_SHARE_BPS}" =~ ^[0-9]+$ ]] || die "internal config error: BOOTSTRAP_SHARE_BPS must be integer in [0..10000]"
if (( DEPLOY_SHARE_BPS < 0 || DEPLOY_SHARE_BPS > 10000 )); then
  die "internal config error: DEPLOY_SHARE_BPS must be in [0..10000]"
fi
if (( BOOTSTRAP_SHARE_BPS < 0 || BOOTSTRAP_SHARE_BPS > 10000 )); then
  die "internal config error: BOOTSTRAP_SHARE_BPS must be in [0..10000]"
fi
python3 - "$TARGET_INIT_PRICE_USD" <<'PY' >/dev/null 2>&1 || die "internal config error: TARGET_INIT_PRICE_USD must be a positive decimal"
from decimal import Decimal
import sys
v = Decimal(sys.argv[1])
if v <= 0:
    raise SystemExit(1)
PY

for cmd in cast jq python3 forge perl; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done

[[ -f "$CONFIG_PATH" ]] || die "Config not found: $CONFIG_PATH"

if [[ -f ./.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
fi

set -a
# shellcheck disable=SC1090
source "$CONFIG_PATH"
set +a

[[ -n "${RPC_URL:-}" ]] || die "RPC_URL is missing"
[[ -n "${PRIVATE_KEY:-}" ]] || die "PRIVATE_KEY is missing"
[[ -n "${POOL_MANAGER:-}" ]] || die "POOL_MANAGER is missing"
[[ -n "${STABLE:-}" ]] || die "STABLE is missing"
[[ -n "${TICK_SPACING:-}" ]] || die "TICK_SPACING is missing"
[[ -n "${STABLE_DECIMALS:-}" ]] || die "STABLE_DECIMALS is missing"

CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || true)"
if [[ -z "$CHAIN_ID" ]]; then
  CHAIN_ID="$(curl -fsS -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
    "$RPC_URL" | jq -r '.result // empty' | xargs printf '%d' 2>/dev/null || true)"
fi
[[ "$CHAIN_ID" == "11155111" ]] || die "This script is Sepolia-only. Current chain id: ${CHAIN_ID:-unknown}"

DEPLOYER="$(cast wallet address --private-key "$PRIVATE_KEY" | awk '{print $1}')"
DEPLOYER_LC="$(lower "$DEPLOYER")"
POSM="0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4"
POSM_LC="$(lower "$POSM")"
STATE_VIEW_ADDRESS="${STATE_VIEW_ADDRESS:-0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C}"
VOLATILE_DECIMALS="$(get_currency_decimals "${VOLATILE}" "18")"
STABLE_DECIMALS_ONCHAIN="$(get_currency_decimals "${STABLE}" "${STABLE_DECIMALS}")"
if [[ "${STABLE_DECIMALS_ONCHAIN}" != "${STABLE_DECIMALS}" ]]; then
  warn "STABLE_DECIMALS mismatch config=${STABLE_DECIMALS} onchain=${STABLE_DECIMALS_ONCHAIN}; using onchain value"
  STABLE_DECIMALS="${STABLE_DECIMALS_ONCHAIN}"
fi

sort_pool_tokens() {
  local a b al bl
  a="$1"
  b="$2"
  al="$(lower "$a")"
  bl="$(lower "$b")"
  if [[ "$al" < "$bl" ]]; then
    echo "$a $b"
  else
    echo "$b $a"
  fi
}

compute_pool_id() {
  local hook="$1"
  local c0 c1 enc
  read -r c0 c1 <<<"$(sort_pool_tokens "${VOLATILE}" "${STABLE}")"
  enc="$(cast abi-encode "f((address,address,uint24,int24,address))" "(${c0},${c1},${DYNAMIC_FEE_FLAG},${TICK_SPACING},${hook})")"
  cast keccak "$enc"
}

to_wei() {
  python3 - "$1" <<'PY'
from decimal import Decimal
import sys
v = Decimal(sys.argv[1])
print(int(v * (10 ** 18)))
PY
}

to_stable_raw() {
  python3 - "$1" "${STABLE_DECIMALS:-6}" <<'PY'
from decimal import Decimal
import sys
v = Decimal(sys.argv[1])
d = int(sys.argv[2])
print(int(v * (10 ** d)))
PY
}

update_hook_in_config() {
  local hook="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] update HOOK_ADDRESS in ${CONFIG_PATH} -> ${hook}"
    return
  fi
  perl -0pi -e "s/^HOOK_ADDRESS=.*/HOOK_ADDRESS=${hook//\//\\/}/m" "$CONFIG_PATH"
}

read_hook_from_deploy_artifact() {
  python3 - <<'PY'
import json
p = 'scripts/out/deploy.sepolia.json'
with open(p, 'r', encoding='utf-8') as f:
    d = json.load(f)
for k in ('hook','hook_address','hookAddress'):
    v = d.get(k) if isinstance(d, dict) else None
    if isinstance(v, str) and v.startswith('0x') and len(v) == 42:
        print(v)
        raise SystemExit(0)

def walk(x):
    if isinstance(x, str) and x.startswith('0x') and len(x) == 42:
        return x
    if isinstance(x, dict):
        for v in x.values():
            r = walk(v)
            if r:
                return r
    if isinstance(x, list):
        for v in x:
            r = walk(v)
            if r:
                return r
    return None

r = walk(d)
if not r:
    raise SystemExit('failed to parse hook address from deploy artifact')
print(r)
PY
}

rpc_json() {
  local payload="$1"
  curl -fsS -H 'content-type: application/json' --data "$payload" "$RPC_URL"
}

scan_old_pool_json() {
  local pool_id="$1"
  local max_back="$2"
  python3 - "$RPC_URL" "$POOL_MANAGER" "$pool_id" "$INIT_TOPIC0" "$MODIFY_TOPIC0" "$max_back" <<'PY'
import json
import sys
import urllib.request
from collections import defaultdict

rpc, pm, pool_id, init_topic0, modify_topic0, max_back = sys.argv[1:]
max_back = int(max_back)
chunk = 800


def rpc_call(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(
        rpc,
        data=body,
        headers={"content-type": "application/json", "user-agent": "curl/8.6.0"},
    )
    with urllib.request.urlopen(req, timeout=45) as r:
        out = json.loads(r.read().decode())
    if 'error' in out:
        raise RuntimeError(out['error'])
    return out['result']


def s256(hex_word: str) -> int:
    n = int(hex_word, 16)
    if n >= 1 << 255:
        n -= 1 << 256
    return n

latest = int(rpc_call('eth_blockNumber', []), 16)
start = max(0, latest - max_back)

init_block = None
b = start
while b <= latest:
    to_b = min(b + chunk - 1, latest)
    logs = rpc_call('eth_getLogs', [{
        'address': pm,
        'fromBlock': hex(b),
        'toBlock': hex(to_b),
        'topics': [init_topic0, pool_id],
    }])
    if logs:
        blocks = [int(x['blockNumber'], 16) for x in logs]
        init_block = min(blocks) if init_block is None else min(init_block, min(blocks))
    b = to_b + 1

if init_block is None:
    init_block = start

agg = defaultdict(int)
b = init_block
while b <= latest:
    to_b = min(b + chunk - 1, latest)
    logs = rpc_call('eth_getLogs', [{
        'address': pm,
        'fromBlock': hex(b),
        'toBlock': hex(to_b),
        'topics': [modify_topic0, pool_id],
    }])
    for lg in logs:
        topics = lg.get('topics', [])
        if len(topics) < 3:
            continue
        sender = '0x' + topics[2][-40:]
        data = lg.get('data', '0x')
        raw = data[2:]
        if len(raw) < 64 * 4:
            continue
        w = [raw[i:i+64] for i in range(0, 64 * 4, 64)]
        tick_lower = s256(w[0])
        tick_upper = s256(w[1])
        liq_delta = s256(w[2])
        salt = '0x' + w[3]
        agg[(sender.lower(), tick_lower, tick_upper, salt)] += liq_delta
    b = to_b + 1

positions = []
for (sender, tl, tu, salt), liq in agg.items():
    if liq > 0:
        positions.append({
            'sender': sender,
            'tickLower': tl,
            'tickUpper': tu,
            'salt': salt,
            'netLiquidity': liq,
        })

positions.sort(key=lambda x: x['netLiquidity'], reverse=True)
print(json.dumps({
    'latestBlock': latest,
    'initBlock': init_block,
    'positions': positions,
}, separators=(',', ':')))
PY
}

scan_owner_posm_tokens() {
  local from_block="$1"
  local to_block="$2"
  python3 - "$RPC_URL" "$POSM_LC" "$DEPLOYER_LC" "$TRANSFER_TOPIC0" "$from_block" "$to_block" <<'PY'
import json
import sys
import urllib.request

rpc, posm, owner, transfer_topic0, from_block, to_block = sys.argv[1:]
from_block = int(from_block)
to_block = int(to_block)
chunk = 800


def rpc_call(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(
        rpc,
        data=body,
        headers={"content-type": "application/json", "user-agent": "curl/8.6.0"},
    )
    with urllib.request.urlopen(req, timeout=45) as r:
        out = json.loads(r.read().decode())
    if 'error' in out:
        raise RuntimeError(out['error'])
    return out['result']

owned = set()

b = from_block
while b <= to_block:
    to_b = min(b + chunk - 1, to_block)
    logs = rpc_call('eth_getLogs', [{
        'address': posm,
        'fromBlock': hex(b),
        'toBlock': hex(to_b),
        'topics': [transfer_topic0],
    }])
    for lg in logs:
        topics = lg.get('topics', [])
        if len(topics) < 4:
            continue
        f = ('0x' + topics[1][-40:]).lower()
        t = ('0x' + topics[2][-40:]).lower()
        token_id = int(topics[3], 16)
        if t == owner:
            owned.add(token_id)
        if f == owner and t != owner:
            owned.discard(token_id)
    b = to_b + 1

print('\n'.join(str(x) for x in sorted(owned)))
PY
}

claim_hook_fees() {
  local hook="$1"
  local code owner
  code="$(cast code --rpc-url "$RPC_URL" "$hook" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "0x" ]] || { warn "No code at old hook ${hook}, skipping claim"; return; }

  owner="$(cast call --rpc-url "$RPC_URL" "$hook" "owner()(address)" 2>/dev/null || true)"
  if [[ -z "$owner" ]]; then
    warn "Old hook ${hook} does not expose owner(), skip claim"
    return
  fi
  if [[ "$(lower "$owner")" != "$(lower "$DEPLOYER")" ]]; then
    warn "Old hook owner ${owner} != deployer ${DEPLOYER}; skip claim"
    return
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] claimAllHookFees on ${hook}"
    return
  fi

  log "Claiming hook fees from old hook ${hook}"
  cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" "$hook" "claimAllHookFees()" >/dev/null
}

extract_contract_positions() {
  local old_hook="$1"
  local old_pool_id="$2"

  local scan_json init_block latest
  scan_json="$(scan_old_pool_json "$old_pool_id" "$SEARCH_BACK_BLOCKS")"
  init_block="$(jq -r '.initBlock' <<<"$scan_json")"
  latest="$(jq -r '.latestBlock' <<<"$scan_json")"

  log "Old pool init block: ${init_block}, latest block: ${latest}"
  jq -r '.positions[] | [.sender,.tickLower,.tickUpper,.salt,.netLiquidity] | @tsv' <<<"$scan_json" > /tmp/manage_liquidity.positions.tsv

  if [[ ! -s /tmp/manage_liquidity.positions.tsv ]]; then
    log "No contract-managed positions with net liquidity > 0 found in old pool"
    echo "$init_block" > /tmp/manage_liquidity.init_block
    return
  fi

  local key sender tick_lower tick_upper salt net_liq sender_code sender_manager params
  key="(${VOLATILE},${STABLE},${DYNAMIC_FEE_FLAG},${TICK_SPACING},${old_hook})"

  while IFS=$'\t' read -r sender tick_lower tick_upper salt net_liq; do
    sender="$(lower "$sender")"
    if [[ "$sender" == "$POSM_LC" ]]; then
      continue
    fi
    if [[ "$net_liq" == "0" ]]; then
      continue
    fi

    sender_code="$(cast code --rpc-url "$RPC_URL" "$sender" 2>/dev/null || true)"
    [[ -n "$sender_code" && "$sender_code" != "0x" ]] || { warn "Skip non-contract sender ${sender}"; continue; }

    sender_manager="$(cast call --rpc-url "$RPC_URL" "$sender" "manager()(address)" 2>/dev/null || true)"
    if [[ -z "$sender_manager" ]]; then
      warn "Sender ${sender} does not expose manager(); skip"
      continue
    fi
    if [[ "$(lower "$sender_manager")" != "$(lower "$POOL_MANAGER")" ]]; then
      warn "Sender ${sender} manager ${sender_manager} != ${POOL_MANAGER}; skip"
      continue
    fi

    params="(${tick_lower},${tick_upper},-${net_liq},${salt})"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] remove contract position sender=${sender} ticks=${tick_lower}:${tick_upper} liq=${net_liq}"
    else
      log "Removing contract position sender=${sender} ticks=${tick_lower}:${tick_upper} liq=${net_liq}"
      cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" "$sender" \
        "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)" \
        "$key" "$params" 0x >/dev/null
    fi
  done < /tmp/manage_liquidity.positions.tsv

  echo "$init_block" > /tmp/manage_liquidity.init_block
}

extract_posm_positions() {
  local old_hook="$1"
  local old_pool_id="$2"

  local init_block latest token_ids
  init_block="$(cat /tmp/manage_liquidity.init_block 2>/dev/null || echo 0)"
  latest="$(cast block-number --rpc-url "$RPC_URL")"

  token_ids="$(scan_owner_posm_tokens "$init_block" "$latest" || true)"
  if [[ -z "$token_ids" ]]; then
    log "No PosM token ids owned by deployer in scan window"
    return
  fi

  local token owner info hook currency0 currency1 liquidity actions p1 p2 p3 unlock deadline
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue

    owner="$(cast call --rpc-url "$RPC_URL" "$POSM" "ownerOf(uint256)(address)" "$token" 2>/dev/null || true)"
    [[ -n "$owner" ]] || continue
    [[ "$(lower "$owner")" == "$DEPLOYER_LC" ]] || continue

    info="$(cast call --json --rpc-url "$RPC_URL" "$POSM" "getPoolAndPositionInfo(uint256)((address,address,uint24,int24,address),uint256)" "$token" 2>/dev/null || true)"
    [[ -n "$info" ]] || continue

    hook="$(jq -r '.[0][4] // empty' <<<"$info")"
    currency0="$(jq -r '.[0][0] // empty' <<<"$info")"
    currency1="$(jq -r '.[0][1] // empty' <<<"$info")"

    [[ -n "$hook" ]] || continue
    [[ "$(lower "$hook")" == "$(lower "$old_hook")" ]] || continue

    liquidity="$(cast call --json --rpc-url "$RPC_URL" "$POSM" "getPositionLiquidity(uint256)(uint128)" "$token" | jq -r '.[0]')"

    actions="0x031212"
    p1="$(cast abi-encode "f(uint256,uint128,uint128,bytes)" "$token" 0 0 0x)"
    p2="$(cast abi-encode "f(address)" "$currency0")"
    p3="$(cast abi-encode "f(address)" "$currency1")"
    unlock="$(cast abi-encode "f(bytes,bytes[])" "$actions" "[$p1,$p2,$p3]")"
    deadline="$(( $(date +%s) + 1800 ))"

    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] burn PosM token=${token} liquidity=${liquidity} old_pool=${old_pool_id}"
    else
      log "Burning PosM token=${token} liquidity=${liquidity} from old hook"
      cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" "$POSM" \
        "modifyLiquidities(bytes,uint256)" "$unlock" "$deadline" >/dev/null
    fi
  done <<<"$token_ids"
}

ensure_modify_helper() {
  local path addr

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "0x0000000000000000000000000000000000000000"
    return
  fi

  echo "==> Deploying PoolModifyLiquidityTest helper" >&2
  forge script lib/v4-periphery/script/02_PoolModifyLiquidityTest.s.sol:DeployPoolModifyLiquidityTest \
    --sig "run(address)" "$POOL_MANAGER" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast >/dev/null

  path="./scripts/out/broadcast/02_PoolModifyLiquidityTest.s.sol/${CHAIN_ID}/run-latest.json"
  [[ -f "$path" ]] || path="./lib/v4-periphery/broadcast/02_PoolModifyLiquidityTest.s.sol/${CHAIN_ID}/run-latest.json"
  [[ -f "$path" ]] || die "Cannot locate modify helper broadcast artifact"

  addr="$(python3 - "$path" <<'PY'
import json, sys
p=sys.argv[1]
d=json.load(open(p))
for tx in d.get('transactions', []):
    a=tx.get('contractAddress')
    if isinstance(a,str) and a.startswith('0x') and len(a)==42:
        print(a); raise SystemExit(0)
for rc in d.get('receipts', []):
    a=rc.get('contractAddress')
    if isinstance(a,str) and a.startswith('0x') and len(a)==42:
        print(a); raise SystemExit(0)
raise SystemExit('no contractAddress found')
PY
)"
  echo "$addr"
}

ensure_swap_helper() {
  local addr code path

  for path in \
    "./scripts/out/broadcast/03_PoolSwapTest.s.sol/${CHAIN_ID}/run-latest.json" \
    "./lib/v4-periphery/broadcast/03_PoolSwapTest.s.sol/${CHAIN_ID}/run-latest.json"
  do
    if [[ -f "$path" ]]; then
      addr="$(python3 - "$path" <<'PY'
import json, sys
p=sys.argv[1]
d=json.load(open(p))
for tx in d.get('transactions', []):
    a=tx.get('contractAddress')
    if isinstance(a,str) and a.startswith('0x') and len(a)==42:
        print(a); raise SystemExit(0)
for rc in d.get('receipts', []):
    a=rc.get('contractAddress')
    if isinstance(a,str) and a.startswith('0x') and len(a)==42:
        print(a); raise SystemExit(0)
raise SystemExit(1)
PY
 2>/dev/null || true)"
      if [[ -n "$addr" ]]; then
        code="$(cast code --rpc-url "$RPC_URL" "$addr" 2>/dev/null || true)"
        if [[ -n "$code" && "$code" != "0x" ]]; then
          echo "$addr"
          return
        fi
      fi
    fi
  done

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    return
  fi

  echo "==> Deploying PoolSwapTest helper" >&2
  forge script lib/v4-periphery/script/03_PoolSwapTest.s.sol:DeployPoolSwapTest \
    --sig "run(address)" "$POOL_MANAGER" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast >/dev/null

  path="./scripts/out/broadcast/03_PoolSwapTest.s.sol/${CHAIN_ID}/run-latest.json"
  [[ -f "$path" ]] || path="./lib/v4-periphery/broadcast/03_PoolSwapTest.s.sol/${CHAIN_ID}/run-latest.json"
  [[ -f "$path" ]] || { echo ""; return; }

  addr="$(python3 - "$path" <<'PY'
import json, sys
p=sys.argv[1]
d=json.load(open(p))
for tx in d.get('transactions', []):
    a=tx.get('contractAddress')
    if isinstance(a,str) and a.startswith('0x') and len(a)==42:
        print(a); raise SystemExit(0)
for rc in d.get('receipts', []):
    a=rc.get('contractAddress')
    if isinstance(a,str) and a.startswith('0x') and len(a)==42:
        print(a); raise SystemExit(0)
print('')
PY
)"
  echo "$addr"
}

calc_plan_json() {
  local pool_id="$1"
  local spend_eth="$2"
  local spend_stable="$3"
  local range_mode="${4:-target-range}"
  python3 - "$RPC_URL" "$STATE_VIEW_ADDRESS" "$pool_id" "$TICK_SPACING" "$spend_eth" "$spend_stable" "$SWAP_IMBALANCE_BPS" "$SWAP_MAX_FRACTION_BPS" "$TARGET_RANGE_MIN_USD" "$TARGET_RANGE_MAX_USD" "${VOLATILE_DECIMALS:-18}" "${STABLE_DECIMALS:-6}" "$range_mode" <<'PY'
import json
import math
import sys
import subprocess
from decimal import Decimal, getcontext

rpc, state_view, pool_id, tick_spacing, spend_eth, spend_stable, imb_bps, max_frac_bps, range_min_usd, range_max_usd, dec0, dec1, range_mode = sys.argv[1:]

tick_spacing = int(tick_spacing)
spend_eth = int(spend_eth)
spend_stable = int(spend_stable)
imb_bps = int(imb_bps)
max_frac_bps = int(max_frac_bps)
range_min_usd = Decimal(range_min_usd)
range_max_usd = Decimal(range_max_usd)
dec0 = int(dec0)
dec1 = int(dec1)

getcontext().prec = 100
Q96 = Decimal(2) ** 96
MIN_TICK = -887272
MAX_TICK = 887272

if range_mode != "full-range":
    if range_min_usd <= 0 or range_max_usd <= 0 or range_min_usd >= range_max_usd:
        raise SystemExit('invalid target range')

def price_to_tick(human_price: Decimal) -> int:
    # human_price is token1 (stable) per token0 (volatile) in human units.
    raw_price = human_price * (Decimal(10) ** (dec1 - dec0))
    if raw_price <= 0:
        raise SystemExit('invalid raw price')
    return math.floor(math.log(float(raw_price), 1.0001))

def floor_to_spacing(tick: int) -> int:
    return math.floor(tick / tick_spacing) * tick_spacing

def ceil_to_spacing(tick: int) -> int:
    return math.ceil(tick / tick_spacing) * tick_spacing

min_usable = int(MIN_TICK / tick_spacing) * tick_spacing
max_usable = int(MAX_TICK / tick_spacing) * tick_spacing

if range_mode == "full-range":
    tick_lower = min_usable
    tick_upper = max_usable
else:
    tick_lower = max(min_usable, floor_to_spacing(price_to_tick(range_min_usd)))
    tick_upper = min(max_usable, ceil_to_spacing(price_to_tick(range_max_usd)))

if tick_lower >= tick_upper:
    tick_upper = tick_lower + tick_spacing
if tick_upper > max_usable:
    tick_upper = max_usable
if tick_lower >= tick_upper:
    tick_lower = tick_upper - tick_spacing
if tick_lower < min_usable:
    tick_lower = min_usable
if tick_lower >= tick_upper:
    raise SystemExit('failed to derive usable tick range')

# getSlot0(bytes32)(uint160,int24,uint24,uint24)
slot0 = subprocess.check_output(
    [
        "cast",
        "call",
        "--rpc-url",
        rpc,
        state_view,
        "getSlot0(bytes32)(uint160,int24,uint24,uint24)",
        pool_id,
    ],
    text=True,
).strip()
parts = [x.strip() for x in slot0.replace("(", "").replace(")", "").split(",")]
sqrt_p = Decimal(parts[0].split()[0])

def sqrt_at_tick(tick: int) -> Decimal:
    # conservative decimal approximation; we later apply safety haircut on liquidity
    v = (Decimal('1.0001') ** (Decimal(tick) / Decimal(2))) * Q96
    return v

sa = sqrt_at_tick(tick_lower)
sb = sqrt_at_tick(tick_upper)
sp = sqrt_p
amt0 = Decimal(spend_eth)
amt1 = Decimal(spend_stable)

if sp <= sa:
    liq = amt0 * sa * sb / (Q96 * (sb - sa))
    ratio_raw = Decimal(0)
elif sp >= sb:
    liq = amt1 * Q96 / (sb - sa)
    ratio_raw = Decimal(10**18)
else:
    liq0 = amt0 * sp * sb / (Q96 * (sb - sp))
    liq1 = amt1 * Q96 / (sp - sa)
    liq = liq0 if liq0 < liq1 else liq1
    # amount1_raw per amount0_raw for in-range
    num = (sp - sa) * sp * sb
    den = Q96 * Q96 * (sb - sp)
    ratio_raw = num / den

liq_i = int(liq * Decimal('0.995'))
if liq_i < 0:
    liq_i = 0

swap_side = "none"
swap_amount = 0

if ratio_raw > 0 and (spend_eth > 0 or spend_stable > 0):
    desired_stable = Decimal(spend_eth) * ratio_raw
    high = desired_stable * Decimal(1 + imb_bps / 10000)
    low = desired_stable * Decimal(1 - imb_bps / 10000)

    if Decimal(spend_stable) > high:
        excess = Decimal(spend_stable) - desired_stable
        swap = int(excess / 2)
        cap = int(Decimal(spend_stable) * Decimal(max_frac_bps) / Decimal(10000))
        swap_amount = min(max(swap, 0), max(cap, 0))
        if swap_amount > 0:
            swap_side = "stable_to_eth"
    elif Decimal(spend_stable) < low:
        desired_eth = Decimal(spend_stable) / ratio_raw
        excess_eth = Decimal(spend_eth) - desired_eth
        swap = int(excess_eth / 2)
        cap = int(Decimal(spend_eth) * Decimal(max_frac_bps) / Decimal(10000))
        swap_amount = min(max(swap, 0), max(cap, 0))
        if swap_amount > 0:
            swap_side = "eth_to_stable"

print(json.dumps({
    "tickLower": tick_lower,
    "tickUpper": tick_upper,
    "liquidity": liq_i,
    "swapSide": swap_side,
    "swapAmountRaw": swap_amount,
}, separators=(',', ':')))
PY
}

read_pool_price_stable_per_volatile() {
  local pool_id="$1"
  local out sqrt_price
  out="$(cast call --rpc-url "$RPC_URL" "$STATE_VIEW_ADDRESS" "getSlot0(bytes32)(uint160,int24,uint24,uint24)" "$pool_id" 2>/dev/null || true)"
  sqrt_price="$(printf '%s\n' "$out" | sed -n '1p' | awk '{print $1}')"
  [[ "$sqrt_price" =~ ^[0-9]+$ ]] || return 1
  python3 - "$sqrt_price" "${VOLATILE_DECIMALS:-18}" "${STABLE_DECIMALS:-6}" <<'PY'
from decimal import Decimal, getcontext
import sys
getcontext().prec = 80
sqrt_price = Decimal(sys.argv[1])
dec0 = int(sys.argv[2])
dec1 = int(sys.argv[3])
q96 = Decimal(2) ** 96
if sqrt_price <= 0:
    raise SystemExit(1)
price = (sqrt_price / q96) ** 2 * (Decimal(10) ** (dec0 - dec1))
print(price)
PY
}

calc_rebalance_order_50_50_json() {
  local eth_raw="$1"
  local stable_raw="$2"
  local price="$3"
  python3 - "$eth_raw" "$stable_raw" "$price" "${VOLATILE_DECIMALS:-18}" "${STABLE_DECIMALS:-6}" "$REBALANCE_TARGET_STABLE_BPS" "$REBALANCE_TOLERANCE_BPS" "$SWAP_MAX_FRACTION_BPS" "$REBALANCE_STEP_DIVISOR" <<'PY'
import json
import sys
from decimal import Decimal, getcontext

getcontext().prec = 80

eth_raw = int(sys.argv[1])
stable_raw = int(sys.argv[2])
price = Decimal(sys.argv[3])  # stable per volatile, human units
dec0 = int(sys.argv[4])
dec1 = int(sys.argv[5])
target_bps = int(sys.argv[6])
tol_bps = int(sys.argv[7])
cap_bps = int(sys.argv[8])
step_divisor = int(sys.argv[9])

if eth_raw < 0: eth_raw = 0
if stable_raw < 0: stable_raw = 0
if price <= 0:
    print(json.dumps({"side": "none", "amountRaw": 0, "stableShareBps": 0}))
    raise SystemExit

eth_human = Decimal(eth_raw) / (Decimal(10) ** dec0)
stable_human = Decimal(stable_raw) / (Decimal(10) ** dec1)
eth_value_stable_human = eth_human * price
total_stable_human = stable_human + eth_value_stable_human

if total_stable_human <= 0:
    print(json.dumps({"side": "none", "amountRaw": 0, "stableShareBps": 0}))
    raise SystemExit
if step_divisor <= 0:
    step_divisor = 1

stable_share_bps = int((stable_human / total_stable_human) * Decimal(10000))
target_stable_human = total_stable_human * Decimal(target_bps) / Decimal(10000)
high_share_bps = min(10000, target_bps + tol_bps)
low_share_bps = max(0, target_bps - tol_bps)

side = "none"
amount = 0

if stable_share_bps > high_share_bps:
    excess_human = stable_human - target_stable_human
    want_raw = int((excess_human * (Decimal(10) ** dec1)) / step_divisor)
    cap_raw = (stable_raw * cap_bps) // 10000
    amount = max(0, min(want_raw, cap_raw))
    if amount > 0:
        side = "stable_to_eth"
elif stable_share_bps < low_share_bps:
    need_human = target_stable_human - stable_human
    need_eth_human = need_human / price
    want_raw = int((need_eth_human * (Decimal(10) ** dec0)) / step_divisor)
    cap_raw = (eth_raw * cap_bps) // 10000
    amount = max(0, min(want_raw, cap_raw))
    if amount > 0:
        side = "eth_to_stable"

print(json.dumps({
    "side": side,
    "amountRaw": amount,
    "stableShareBps": stable_share_bps
}, separators=(',', ':')))
PY
}

rebalance_wallet_to_50_50() {
  local pool_key="$1"
  local new_pool_id="$2"
  local swap_helper="$3"

  [[ -n "$swap_helper" ]] || { warn "Swap helper unavailable, skip 50/50 rebalance"; return 0; }

  local pool_liquidity
  pool_liquidity="$(to_uint "$(cast call --rpc-url "$RPC_URL" "$STATE_VIEW_ADDRESS" "getLiquidity(bytes32)(uint128)" "$new_pool_id" 2>/dev/null || echo 0)")"
  if [[ ! "$pool_liquidity" =~ ^[1-9][0-9]*$ ]]; then
    warn "Pool liquidity is zero, cannot rebalance to 50/50 yet"
    return 1
  fi

  local swap_sig test_settings eth_bal stable_bal price order side amount params stable_share
  local share_pct amount_h
  swap_sig="swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)(bytes32)"
  test_settings="(false,false)"

  eth_bal="$(cast balance --rpc-url "$RPC_URL" "$DEPLOYER")"
  stable_bal="$(to_uint "$(cast call --rpc-url "$RPC_URL" "$STABLE" "balanceOf(address)(uint256)" "$DEPLOYER")")"
  price="$(read_pool_price_stable_per_volatile "$new_pool_id" 2>/dev/null || true)"
  if [[ -z "$price" ]]; then
    warn "Failed to read pool price, skip rebalance"
    return 1
  fi

  order="$(calc_rebalance_order_50_50_json "$eth_bal" "$stable_bal" "$price")"
  side="$(jq -r '.side' <<<"$order")"
  amount="$(jq -r '.amountRaw' <<<"$order")"
  stable_share="$(jq -r '.stableShareBps' <<<"$order")"
  share_pct="$(format_bps_percent "$stable_share")"

  if [[ "$side" == "none" || ! "$amount" =~ ^[1-9][0-9]*$ ]]; then
    log "Wallet rebalance skipped: already inside band (stableShare=${share_pct}%)"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    amount_h="$(format_eth_wei "$amount")"
    if [[ "$side" == "stable_to_eth" ]]; then
      amount_h="$(format_stable_raw "$amount")"
    fi
    log "[dry-run] rebalance side=${side} amount=${amount_h} stableShare=${share_pct}%"
    return 0
  fi

  if [[ "$side" == "eth_to_stable" ]]; then
    params="(true,-${amount},${SQRT_PRICE_LIMIT_X96_ZFO})"
    amount_h="$(format_eth_wei "$amount")"
    log "Rebalance swap ETH->stable amount=${amount_h} ETH stableShare=${share_pct}%"
    cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --value "$amount" "$swap_helper" \
      "$swap_sig" "$pool_key" "$params" "$test_settings" 0x >/dev/null
  else
    local swap_allowance
    swap_allowance="$(to_uint "$(cast call --rpc-url "$RPC_URL" "$STABLE" "allowance(address,address)(uint256)" "$DEPLOYER" "$swap_helper")")"
    if [[ "$(int_lt "$swap_allowance" "$amount")" == "1" ]]; then
      log "Approving stable token for swap helper ${swap_helper}"
      cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" "$STABLE" \
        "approve(address,uint256)" "$swap_helper" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff >/dev/null
    fi
    params="(false,-${amount},${SQRT_PRICE_LIMIT_X96_OZF})"
    amount_h="$(format_stable_raw "$amount")"
    log "Rebalance swap stable->ETH amount=${amount_h} stable stableShare=${share_pct}%"
    cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" "$swap_helper" \
      "$swap_sig" "$pool_key" "$params" "$test_settings" 0x >/dev/null
  fi
  return 0
}

add_liquidity_to_new_pool() {
  local helper="$1"
  local pool_key="$2"
  local new_pool_id="$3"
  local spend_eth="$4"
  local spend_stable="$5"
  local range_mode="${6:-target-range}"
  local label="${7:-main}"
  local eth_h stable_h

  if [[ ! "$spend_eth" =~ ^[0-9]+$ || ! "$spend_stable" =~ ^[0-9]+$ ]]; then
    warn "Invalid budget for add (${label}): ETH=${spend_eth}, stable=${spend_stable}"
    return 1
  fi
  if [[ "$spend_eth" == "0" && "$spend_stable" == "0" ]]; then
    warn "No budget for add (${label}), skip"
    return 0
  fi

  local plan tl tu liq params allowance
  plan="$(calc_plan_json "$new_pool_id" "$spend_eth" "$spend_stable" "$range_mode")"
  tl="$(jq -r '.tickLower' <<<"$plan")"
  tu="$(jq -r '.tickUpper' <<<"$plan")"
  liq="$(jq -r '.liquidity' <<<"$plan")"

  if [[ ! "$liq" =~ ^[1-9][0-9]*$ ]]; then
    warn "Computed liquidity is zero for ${label} add, skip"
    return 1
  fi

  if [[ "$spend_stable" != "0" ]]; then
    allowance="$(to_uint "$(cast call --rpc-url "$RPC_URL" "$STABLE" "allowance(address,address)(uint256)" "$DEPLOYER" "$helper")")"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] ensure allowance for helper ${helper}"
    elif [[ "$(int_lt "$allowance" "$spend_stable")" == "1" ]]; then
      log "Approving stable token for helper ${helper}"
      cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" "$STABLE" \
        "approve(address,uint256)" "$helper" 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff >/dev/null
    fi
  fi

  params="(${tl},${tu},${liq},0x0000000000000000000000000000000000000000000000000000000000000000)"
  eth_h="$(format_eth_wei "$spend_eth")"
  stable_h="$(format_stable_raw "$spend_stable")"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] add(${label}) mode=${range_mode} helper=${helper} liq=${liq} ticks=${tl}:${tu} ethBudget=${eth_h} ETH stableBudget=${stable_h} stable"
  else
    log "Adding liquidity (${label}) mode=${range_mode} helper=${helper} liq=${liq} ticks=${tl}:${tu} ethBudget=${eth_h} ETH stableBudget=${stable_h} stable"
    cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --value "$spend_eth" "$helper" \
      "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)" \
      "$pool_key" "$params" 0x >/dev/null
  fi
  return 0
}

log "Sepolia liquidity manager started"
log "deployer=${DEPLOYER}"
log "target_range_usd=${TARGET_RANGE_MIN_USD}..${TARGET_RANGE_MAX_USD} init_price_usd=${TARGET_INIT_PRICE_USD}"
log "plan: rebalance_target_stable=$(format_bps_percent "$REBALANCE_TARGET_STABLE_BPS")% (+ETH bias), tolerance=+/-$(format_bps_percent "$REBALANCE_TOLERANCE_BPS")% deploy_share=$(format_bps_percent "$DEPLOY_SHARE_BPS")% bootstrap_share=$(format_bps_percent "$BOOTSTRAP_SHARE_BPS")%"
log "wallet_reserve_policy=absolute_floors reserve_eth=${RESERVE_ETH} reserve_stable=${RESERVE_STABLE}"

OLD_HOOK="${HOOK_ADDRESS:-}"
[[ -n "$OLD_HOOK" ]] || die "Old hook address is required (set HOOK_ADDRESS in config)"

OLD_POOL_ID="$(compute_pool_id "$OLD_HOOK")"

log "old_hook=${OLD_HOOK}"
log "old_pool_id=${OLD_POOL_ID}"

if [[ "$DEPOSIT_ONLY" -eq 1 ]]; then
  # Reuse current hook/pool from config and only deposit wallet balances.
  NEW_HOOK="$OLD_HOOK"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    NEW_POOL_ID="0x0000000000000000000000000000000000000000000000000000000000000000"
  else
    NEW_POOL_ID="$(compute_pool_id "$NEW_HOOK")"
  fi
  log "deposit=true; skip claim/redeploy"
elif [[ "$CLAIM_ONLY" -eq 1 ]]; then
  # Claim/drain old pool + old hook and stop.
  claim_hook_fees "$OLD_HOOK"
  extract_contract_positions "$OLD_HOOK" "$OLD_POOL_ID"
  extract_posm_positions "$OLD_HOOK" "$OLD_POOL_ID"
  claim_hook_fees "$OLD_HOOK"

  NEW_HOOK="$OLD_HOOK"
  NEW_POOL_ID="$OLD_POOL_ID"
  log "claim=true; drained old pool/hook; skip redeploy/deposit"
  log "new_hook=${NEW_HOOK}"
  log "new_pool_id=${NEW_POOL_ID}"
  log "Done"
  log "Summary: old_pool=${OLD_POOL_ID}, new_pool=${NEW_POOL_ID}, old_hook=${OLD_HOOK}, new_hook=${NEW_HOOK}"
  exit 0
else
  # 1) Drain old hook + old pool
  claim_hook_fees "$OLD_HOOK"
  extract_contract_positions "$OLD_HOOK" "$OLD_POOL_ID"
  extract_posm_positions "$OLD_HOOK" "$OLD_POOL_ID"
  claim_hook_fees "$OLD_HOOK"

  # 2) Redeploy new hook + new pool
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] deploy_hook + create_pool"
    NEW_HOOK="0x0000000000000000000000000000000000000000"
  else
    log "Clearing HOOK_ADDRESS in config before deploy"
    update_hook_in_config ""

    log "Deploying new hook"
    ./scripts/deploy_hook.sh --chain sepolia --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast >/dev/null

    NEW_HOOK="$(read_hook_from_deploy_artifact)"
    [[ -n "$NEW_HOOK" ]] || die "Failed to read new hook address"

    log "Updating config HOOK_ADDRESS=${NEW_HOOK}"
    update_hook_in_config "$NEW_HOOK"

    log "Creating new pool with INIT_PRICE_USD=${TARGET_INIT_PRICE_USD} for range ${TARGET_RANGE_MIN_USD}..${TARGET_RANGE_MAX_USD}"
    INIT_PRICE_USD="$TARGET_INIT_PRICE_USD" \
      ./scripts/create_pool.sh --chain sepolia --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast >/dev/null
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    NEW_POOL_ID="0x0000000000000000000000000000000000000000000000000000000000000000"
  else
    NEW_POOL_ID="$(compute_pool_id "$NEW_HOOK")"
  fi
fi

log "new_hook=${NEW_HOOK}"
log "new_pool_id=${NEW_POOL_ID}"

# 3) Move free wallet liquidity to the new pool (with optional rebalance)
MODIFY_HELPER="$(ensure_modify_helper)"
if [[ "$DRY_RUN" -eq 1 ]]; then
  SWAP_HELPER=""
else
  SWAP_HELPER="$(ensure_swap_helper)"
fi

NEW_POOL_KEY="(${VOLATILE},${STABLE},${DYNAMIC_FEE_FLAG},${TICK_SPACING},${NEW_HOOK})"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[dry-run] skip rebalance/add-to-new-pool phase"
  log "Done"
  log "Summary: old_pool=${OLD_POOL_ID}, new_pool=${NEW_POOL_ID}, old_hook=${OLD_HOOK}, new_hook=${NEW_HOOK}"
  exit 0
fi

# 3) Check wallet balances and compute deploy budget
ETH_BAL_BEFORE="$(cast balance --rpc-url "$RPC_URL" "$DEPLOYER")"
STABLE_BAL_BEFORE="$(to_uint "$(cast call --rpc-url "$RPC_URL" "$STABLE" "balanceOf(address)(uint256)" "$DEPLOYER")")"
BUDGET_BEFORE="$(calc_wallet_budget_json "$ETH_BAL_BEFORE" "$STABLE_BAL_BEFORE" "$DEPLOY_SHARE_BPS")"
RESERVE_ETH_WEI="$(jq -r '.reserveEthWei' <<<"$BUDGET_BEFORE")"
RESERVE_STABLE_RAW="$(jq -r '.reserveStableRaw' <<<"$BUDGET_BEFORE")"
AVAILABLE_ETH_WEI="$(jq -r '.availableEthWei' <<<"$BUDGET_BEFORE")"
AVAILABLE_STABLE_RAW="$(jq -r '.availableStableRaw' <<<"$BUDGET_BEFORE")"
DEPLOY_ETH_TOTAL="$(jq -r '.deployEthWei' <<<"$BUDGET_BEFORE")"
DEPLOY_STABLE_TOTAL="$(jq -r '.deployStableRaw' <<<"$BUDGET_BEFORE")"

log "wallet_before: eth=$(format_eth_wei "$ETH_BAL_BEFORE") ETH stable=$(format_stable_raw "$STABLE_BAL_BEFORE") stable"
log "wallet_budget: reserve_eth=$(format_eth_wei "$RESERVE_ETH_WEI") ETH reserve_stable=$(format_stable_raw "$RESERVE_STABLE_RAW") stable available_eth=$(format_eth_wei "$AVAILABLE_ETH_WEI") ETH available_stable=$(format_stable_raw "$AVAILABLE_STABLE_RAW") stable"
log "deploy_budget_total: eth=$(format_eth_wei "$DEPLOY_ETH_TOTAL") ETH stable=$(format_stable_raw "$DEPLOY_STABLE_TOTAL") stable (share=$(format_bps_percent "$DEPLOY_SHARE_BPS")%)"

BOOTSTRAP_ETH_WEI=0
BOOTSTRAP_STABLE_RAW=0

POOL_LIQ_BEFORE="$(to_uint "$(cast call --rpc-url "$RPC_URL" "$STATE_VIEW_ADDRESS" "getLiquidity(bytes32)(uint128)" "$NEW_POOL_ID" 2>/dev/null || echo 0)")"
if [[ "$POOL_LIQ_BEFORE" =~ ^0+$ || -z "$POOL_LIQ_BEFORE" ]]; then
  BOOTSTRAP_ETH_WEI="$(calc_bps_amount "$DEPLOY_ETH_TOTAL" "$BOOTSTRAP_SHARE_BPS")"
  BOOTSTRAP_STABLE_RAW="$(calc_bps_amount "$DEPLOY_STABLE_TOTAL" "$BOOTSTRAP_SHARE_BPS")"
  if [[ "$BOOTSTRAP_ETH_WEI" =~ ^[0-9]+$ && "$BOOTSTRAP_STABLE_RAW" =~ ^[0-9]+$ ]] \
     && (( BOOTSTRAP_ETH_WEI > 0 || BOOTSTRAP_STABLE_RAW > 0 )); then
    log "Pool has zero liquidity: bootstrap add first (eth=$(format_eth_wei "$BOOTSTRAP_ETH_WEI") ETH, stable=$(format_stable_raw "$BOOTSTRAP_STABLE_RAW") stable)"
    add_liquidity_to_new_pool "$MODIFY_HELPER" "$NEW_POOL_KEY" "$NEW_POOL_ID" "$BOOTSTRAP_ETH_WEI" "$BOOTSTRAP_STABLE_RAW" "full-range" "bootstrap" || true
  else
    log "Pool has zero liquidity and bootstrap budget is zero"
  fi
fi

# 4) Rebalance wallet to 50/50
rebalance_wallet_to_50_50 "$NEW_POOL_KEY" "$NEW_POOL_ID" "$SWAP_HELPER" || true

# 5) Add remaining part of the 80% deploy budget to range 1000..5000
TARGET_MAIN_ETH="$(python3 - "$DEPLOY_ETH_TOTAL" "$BOOTSTRAP_ETH_WEI" <<'PY'
import sys
total = int(sys.argv[1]); boot = int(sys.argv[2])
print(total - boot if total > boot else 0)
PY
)"
TARGET_MAIN_STABLE="$(python3 - "$DEPLOY_STABLE_TOTAL" "$BOOTSTRAP_STABLE_RAW" <<'PY'
import sys
total = int(sys.argv[1]); boot = int(sys.argv[2])
print(total - boot if total > boot else 0)
PY
)"

ETH_BAL_AFTER_REBAL="$(cast balance --rpc-url "$RPC_URL" "$DEPLOYER")"
STABLE_BAL_AFTER_REBAL="$(to_uint "$(cast call --rpc-url "$RPC_URL" "$STABLE" "balanceOf(address)(uint256)" "$DEPLOYER")")"
BUDGET_AFTER_REBAL="$(calc_wallet_budget_json "$ETH_BAL_AFTER_REBAL" "$STABLE_BAL_AFTER_REBAL" 10000)"
AVAILABLE_ETH_AFTER_REBAL="$(jq -r '.availableEthWei' <<<"$BUDGET_AFTER_REBAL")"
AVAILABLE_STABLE_AFTER_REBAL="$(jq -r '.availableStableRaw' <<<"$BUDGET_AFTER_REBAL")"

MAIN_ETH_WEI="$(int_min "$TARGET_MAIN_ETH" "$AVAILABLE_ETH_AFTER_REBAL")"
MAIN_STABLE_RAW="$(int_min "$TARGET_MAIN_STABLE" "$AVAILABLE_STABLE_AFTER_REBAL")"

log "wallet_after_rebalance: eth=$(format_eth_wei "$ETH_BAL_AFTER_REBAL") ETH stable=$(format_stable_raw "$STABLE_BAL_AFTER_REBAL") stable"
log "deploy_budget_main: eth=$(format_eth_wei "$MAIN_ETH_WEI") ETH stable=$(format_stable_raw "$MAIN_STABLE_RAW") stable"

add_liquidity_to_new_pool "$MODIFY_HELPER" "$NEW_POOL_KEY" "$NEW_POOL_ID" "$MAIN_ETH_WEI" "$MAIN_STABLE_RAW" "target-range" "main"

log "Done"
log "Summary: old_pool=${OLD_POOL_ID}, new_pool=${NEW_POOL_ID}, old_hook=${OLD_HOOK}, new_hook=${NEW_HOOK}"
