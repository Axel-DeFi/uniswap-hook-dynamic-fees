#!/usr/bin/env bash
set -euo pipefail

# Sepolia-only liquidity manager:
# 1) drains liquidity/fees from an old pool+hook,
# 2) redeploys hook and creates a new pool,
# 3) rebalances wallet balances (if needed),
# 4) adds free liquidity into the new pool,
# while keeping reserves for gas and test swaps.

CONFIG_PATH="./config/hook.sepolia.conf"
OLD_HOOK_OVERRIDE=""
OLD_POOL_ID_OVERRIDE=""
RESERVE_ETH="0"
RESERVE_STABLE="0"
SEARCH_BACK_BLOCKS=500000
SWAP_IMBALANCE_BPS=2000
SWAP_MAX_FRACTION_BPS=1000
KEEP_BALANCE_BPS=1000
TARGET_RANGE_MIN_USD="1000"
TARGET_RANGE_MAX_USD="5000"
DRY_RUN=0
NO_REBALANCE=0
DEPOSIT_ONLY=0

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

calc_center_price_usd() {
  python3 - "$1" "$2" <<'PY'
from decimal import Decimal, getcontext
import sys
getcontext().prec = 50
lo = Decimal(sys.argv[1])
hi = Decimal(sys.argv[2])
print((lo * hi).sqrt())
PY
}

calc_wallet_plan_json() {
  local eth_raw="$1"
  local stable_raw="$2"
  python3 - "$eth_raw" "$stable_raw" "$RESERVE_ETH" "$RESERVE_STABLE" "$KEEP_BALANCE_BPS" "${STABLE_DECIMALS:-6}" <<'PY'
import json
import sys
from decimal import Decimal, getcontext

getcontext().prec = 50

eth_raw = int(sys.argv[1])
stable_raw = int(sys.argv[2])
reserve_eth_human = Decimal(sys.argv[3])
reserve_stable_human = Decimal(sys.argv[4])
keep_bps = int(sys.argv[5])
stable_decimals = int(sys.argv[6])

reserve_eth_abs = int(reserve_eth_human * (Decimal(10) ** 18))
reserve_stable_abs = int(reserve_stable_human * (Decimal(10) ** stable_decimals))

reserve_eth_pct = (eth_raw * keep_bps) // 10000
reserve_stable_pct = (stable_raw * keep_bps) // 10000

reserve_eth = max(reserve_eth_abs, reserve_eth_pct)
reserve_stable = max(reserve_stable_abs, reserve_stable_pct)

if reserve_eth > eth_raw:
    reserve_eth = eth_raw
if reserve_stable > stable_raw:
    reserve_stable = stable_raw

spend_eth = max(0, eth_raw - reserve_eth)
spend_stable = max(0, stable_raw - reserve_stable)

print(json.dumps({
    "reserveEthWei": reserve_eth,
    "reserveStableRaw": reserve_stable,
    "spendEthWei": spend_eth,
    "spendStableRaw": spend_stable,
}, separators=(',', ':')))
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
  --config <path>             Config file (default: ./config/hook.sepolia.conf)
  --old-hook <address>        Old hook address (default: HOOK_ADDRESS from config)
  --old-pool-id <bytes32>     Old pool id (default: computed from old hook)
  --reserve-eth <eth>         ETH reserve floor on wallet (default: 0)
  --reserve-stable <amount>   Stable reserve floor on wallet, human units (default: 0)
  --search-back-blocks <n>    How far to scan back for old pool events (default: 500000)
  --no-rebalance              Skip pre-deposit rebalance swap
  --deposit-only              Add liquidity only to current pool from config (no drain/redeploy)
  --dry-run                   Print actions without sending transactions
  -h, --help                  Show help

Notes:
  - Sepolia only.
  - Liquidity range is fixed to 1000..5000 (STABLE per 1 VOLATILE).
  - New pool initialization price is set near range center (geometric midpoint).
  - Keeps at least 10% of both assets on wallet (and optional reserve floors from flags).
  - Bootstrap safety: for a brand-new pool, rebalance swap is skipped.
  - Requires PRIVATE_KEY and RPC_URL via config/.env.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"; shift 2 ;;
    --old-hook)
      OLD_HOOK_OVERRIDE="${2:-}"; shift 2 ;;
    --old-pool-id)
      OLD_POOL_ID_OVERRIDE="${2:-}"; shift 2 ;;
    --reserve-eth)
      RESERVE_ETH="${2:-}"; shift 2 ;;
    --reserve-stable)
      RESERVE_STABLE="${2:-}"; shift 2 ;;
    --search-back-blocks)
      SEARCH_BACK_BLOCKS="${2:-}"; shift 2 ;;
    --no-rebalance)
      NO_REBALANCE=1; shift ;;
    --deposit-only)
      DEPOSIT_ONLY=1; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown argument: $1" ;;
  esac
done

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
TARGET_INIT_PRICE_USD="$(calc_center_price_usd "$TARGET_RANGE_MIN_USD" "$TARGET_RANGE_MAX_USD")"

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
  local code creator
  code="$(cast code --rpc-url "$RPC_URL" "$hook" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "0x" ]] || { warn "No code at old hook ${hook}, skipping claim"; return; }

  creator="$(cast call --rpc-url "$RPC_URL" "$hook" "creator()(address)" 2>/dev/null || true)"
  if [[ -z "$creator" ]]; then
    warn "Old hook ${hook} does not expose creator(), skip claim"
    return
  fi
  if [[ "$(lower "$creator")" != "$(lower "$DEPLOYER")" ]]; then
    warn "Old hook creator ${creator} != deployer ${DEPLOYER}; skip claim"
    return
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] claimAllCreatorFees on ${hook}"
    return
  fi

  log "Claiming creator fees from old hook ${hook}"
  cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" "$hook" "claimAllCreatorFees(address)" "$DEPLOYER" >/dev/null
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
  local helper code path addr

  if [[ -s /tmp/manage_liquidity.positions.tsv ]]; then
    helper="$(awk -F'\t' '{print $1}' /tmp/manage_liquidity.positions.tsv | head -n1)"
    if [[ -n "$helper" ]]; then
      code="$(cast code --rpc-url "$RPC_URL" "$helper" 2>/dev/null || true)"
      if [[ -n "$code" && "$code" != "0x" ]]; then
        local m
        m="$(cast call --rpc-url "$RPC_URL" "$helper" "manager()(address)" 2>/dev/null || true)"
        if [[ -n "$m" && "$(lower "$m")" == "$(lower "$POOL_MANAGER")" ]]; then
          echo "$helper"
          return
        fi
      fi
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "0x0000000000000000000000000000000000000000"
    return
  fi

  log "Deploying PoolModifyLiquidityTest helper"
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

  log "Deploying PoolSwapTest helper"
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
  python3 - "$RPC_URL" "$STATE_VIEW_ADDRESS" "$pool_id" "$TICK_SPACING" "$spend_eth" "$spend_stable" "$SWAP_IMBALANCE_BPS" "$SWAP_MAX_FRACTION_BPS" "$TARGET_RANGE_MIN_USD" "$TARGET_RANGE_MAX_USD" "${VOLATILE_DECIMALS:-18}" "${STABLE_DECIMALS:-6}" <<'PY'
import json
import math
import sys
import subprocess
from decimal import Decimal, getcontext

rpc, state_view, pool_id, tick_spacing, spend_eth, spend_stable, imb_bps, max_frac_bps, range_min_usd, range_max_usd, dec0, dec1 = sys.argv[1:]

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

run_swap_if_needed() {
  local pool_key="$1"
  local new_pool_id="$2"
  local swap_helper="$3"

  [[ "$NO_REBALANCE" -eq 0 ]] || { log "Rebalance disabled"; return; }
  [[ -n "$swap_helper" ]] || { warn "Swap helper unavailable, skip rebalance"; return; }
  local pool_liquidity
  pool_liquidity="$(to_uint "$(cast call --rpc-url "$RPC_URL" "$STATE_VIEW_ADDRESS" "getLiquidity(bytes32)(uint128)" "$new_pool_id" 2>/dev/null || echo 0)")"
  if [[ ! "$pool_liquidity" =~ ^[1-9][0-9]*$ ]]; then
    log "Skip rebalance: pool liquidity is zero"
    return
  fi

  local swap_sig test_settings attempt eth_bal stable_bal wallet_plan reserve_eth_wei reserve_stable_raw spend_eth spend_stable plan side amount params
  swap_sig="swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)(bytes32)"
  test_settings="(false,false)"

  for attempt in 1 2 3; do
    eth_bal="$(cast balance --rpc-url "$RPC_URL" "$DEPLOYER")"
    stable_bal="$(to_uint "$(cast call --rpc-url "$RPC_URL" "$STABLE" "balanceOf(address)(uint256)" "$DEPLOYER")")"
    wallet_plan="$(calc_wallet_plan_json "$eth_bal" "$stable_bal")"
    reserve_eth_wei="$(jq -r '.reserveEthWei' <<<"$wallet_plan")"
    reserve_stable_raw="$(jq -r '.reserveStableRaw' <<<"$wallet_plan")"
    spend_eth="$(jq -r '.spendEthWei' <<<"$wallet_plan")"
    spend_stable="$(jq -r '.spendStableRaw' <<<"$wallet_plan")"

    if [[ ! "$spend_eth" =~ ^[0-9]+$ || ! "$spend_stable" =~ ^[0-9]+$ ]]; then
      log "Skip rebalance: invalid spendable balances ETH=${spend_eth}, stable=${spend_stable}"
      return
    fi
    if [[ "$spend_eth" == "0" && "$spend_stable" == "0" ]]; then
      log "Skip rebalance: spendable ETH=${spend_eth}, stable=${spend_stable} (reserve ETH=${reserve_eth_wei}, stable=${reserve_stable_raw})"
      return
    fi

    plan="$(calc_plan_json "$new_pool_id" "$spend_eth" "$spend_stable")"
    side="$(jq -r '.swapSide' <<<"$plan")"
    amount="$(jq -r '.swapAmountRaw' <<<"$plan")"

    if [[ "$side" == "none" || ! "$amount" =~ ^[1-9][0-9]*$ ]]; then
      log "No rebalance swap required (attempt=${attempt})"
      return
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "[dry-run] rebalance attempt=${attempt} side=${side} amount_raw=${amount} reserve_eth=${reserve_eth_wei} reserve_stable=${reserve_stable_raw}"
      return
    fi

    if [[ "$side" == "eth_to_stable" ]]; then
      params="(true,-${amount},${SQRT_PRICE_LIMIT_X96_ZFO})"
      log "Rebalance swap ETH->stable (attempt=${attempt}) amount_raw=${amount}"
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
      log "Rebalance swap stable->ETH (attempt=${attempt}) amount_raw=${amount}"
      cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" "$swap_helper" \
        "$swap_sig" "$pool_key" "$params" "$test_settings" 0x >/dev/null
    fi
  done
}

add_liquidity_to_new_pool() {
  local helper="$1"
  local pool_key="$2"
  local new_pool_id="$3"

  local eth_bal stable_bal wallet_plan reserve_eth_wei reserve_stable_raw spend_eth spend_stable plan tl tu liq params allowance

  eth_bal="$(cast balance --rpc-url "$RPC_URL" "$DEPLOYER")"
  stable_bal="$(to_uint "$(cast call --rpc-url "$RPC_URL" "$STABLE" "balanceOf(address)(uint256)" "$DEPLOYER")")"
  wallet_plan="$(calc_wallet_plan_json "$eth_bal" "$stable_bal")"
  reserve_eth_wei="$(jq -r '.reserveEthWei' <<<"$wallet_plan")"
  reserve_stable_raw="$(jq -r '.reserveStableRaw' <<<"$wallet_plan")"
  spend_eth="$(jq -r '.spendEthWei' <<<"$wallet_plan")"
  spend_stable="$(jq -r '.spendStableRaw' <<<"$wallet_plan")"

  if [[ ! "$spend_eth" =~ ^[0-9]+$ || ! "$spend_stable" =~ ^[0-9]+$ ]]; then
    warn "Invalid spendable balances after reserves (ETH=${spend_eth}, stable=${spend_stable}), skip add"
    return
  fi
  if [[ "$spend_eth" == "0" && "$spend_stable" == "0" ]]; then
    warn "No spendable balances after reserves (ETH=${spend_eth}, stable=${spend_stable}), skip add"
    return
  fi

  plan="$(calc_plan_json "$new_pool_id" "$spend_eth" "$spend_stable")"
  tl="$(jq -r '.tickLower' <<<"$plan")"
  tu="$(jq -r '.tickUpper' <<<"$plan")"
  liq="$(jq -r '.liquidity' <<<"$plan")"

  if [[ ! "$liq" =~ ^[1-9][0-9]*$ ]]; then
    warn "Computed liquidity is zero, skip add"
    return
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

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] add liquidity helper=${helper} liq=${liq} ticks=${tl}:${tu} value=${spend_eth} reserve_eth=${reserve_eth_wei} reserve_stable=${reserve_stable_raw}"
  else
    log "Adding liquidity to new pool helper=${helper} liq=${liq} ticks=${tl}:${tu} reserve_eth=${reserve_eth_wei} reserve_stable=${reserve_stable_raw}"
    cast send --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --value "$spend_eth" "$helper" \
      "modifyLiquidity((address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)" \
      "$pool_key" "$params" 0x >/dev/null
  fi
}

log "Sepolia liquidity manager started"
log "deployer=${DEPLOYER}"
log "target_range_usd=${TARGET_RANGE_MIN_USD}..${TARGET_RANGE_MAX_USD} init_center_usd=${TARGET_INIT_PRICE_USD}"
log "wallet_reserve_policy=max(abs_reserve,10%_kept_each_asset) keep_bps=${KEEP_BALANCE_BPS}"

OLD_HOOK="${OLD_HOOK_OVERRIDE:-${HOOK_ADDRESS:-}}"
[[ -n "$OLD_HOOK" ]] || die "Old hook address is required (set HOOK_ADDRESS in config or pass --old-hook)"
OLD_HOOK_LC="$(lower "$OLD_HOOK")"

OLD_POOL_ID="${OLD_POOL_ID_OVERRIDE:-}"
if [[ -z "$OLD_POOL_ID" ]]; then
  OLD_POOL_ID="$(compute_pool_id "$OLD_HOOK")"
fi

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
  log "deposit_only=true; skip drain/redeploy"
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

    log "Creating new pool at center price INIT_PRICE_USD=${TARGET_INIT_PRICE_USD} for range ${TARGET_RANGE_MIN_USD}..${TARGET_RANGE_MAX_USD}"
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

POOL_LIQ_BEFORE="$(to_uint "$(cast call --rpc-url "$RPC_URL" "$STATE_VIEW_ADDRESS" "getLiquidity(bytes32)(uint128)" "$NEW_POOL_ID" 2>/dev/null || echo 0)")"
if [[ "$POOL_LIQ_BEFORE" =~ ^0+$ || -z "$POOL_LIQ_BEFORE" ]]; then
  # Safety: swapping against a just-bootstrapped narrow-range pool can push price
  # straight outside the range and leave active liquidity at zero.
  log "Pool has zero liquidity: bootstrap add only (rebalance skipped for safety)"
  add_liquidity_to_new_pool "$MODIFY_HELPER" "$NEW_POOL_KEY" "$NEW_POOL_ID"
else
  run_swap_if_needed "$NEW_POOL_KEY" "$NEW_POOL_ID" "$SWAP_HELPER"
  add_liquidity_to_new_pool "$MODIFY_HELPER" "$NEW_POOL_KEY" "$NEW_POOL_ID"
fi

log "Done"
log "Summary: old_pool=${OLD_POOL_ID}, new_pool=${NEW_POOL_ID}, old_hook=${OLD_HOOK}, new_hook=${NEW_HOOK}"
