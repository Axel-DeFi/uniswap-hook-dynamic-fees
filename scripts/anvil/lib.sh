#!/usr/bin/env bash
set -euo pipefail

: "${RPC_URL:=http://127.0.0.1:8545}"
: "${VERBOSE:=0}"

log() {
  printf '%s\n' "$*"
}

debug() {
  if [[ "${VERBOSE}" == "1" ]]; then
    printf '[debug] %s\n' "$*" >&2
  fi
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
}

json_get() {
  local expr="$1"
  jq -er "${expr}"
}

to_hex_uint() {
  cast to-hex "$1"
}

rpc_call() {
  local method="${1:?rpc method is required}"
  local params_json="${2:-[]}"
  local payload response rc

  payload="$(jq -cn --arg m "${method}" --argjson p "${params_json}" '{jsonrpc:"2.0",id:1,method:$m,params:$p}')" || return 1

  set +e
  response="$(curl -fsS -H "Content-Type: application/json" --data "${payload}" "${RPC_URL}" 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    debug "rpc_call transport error method=${method}: ${response}"
    return 1
  fi

  if jq -e '.error != null' >/dev/null 2>&1 <<<"${response}"; then
    debug "rpc_call rpc error method=${method}: ${response}"
    return 1
  fi

  jq -r 'if (.result|type) == "string" then .result else (.result|tojson) end' <<<"${response}"
}

evm_snapshot() {
  local snap_id
  snap_id="$(rpc_call "evm_snapshot" "[]" 2>/dev/null || true)"
  if [[ -z "${snap_id}" || "${snap_id}" == "null" ]]; then
    return 1
  fi
  printf '%s\n' "${snap_id}"
}

evm_revert() {
  local snapshot_id="${1:?snapshot id is required}"
  local params out
  params="$(jq -cn --arg s "${snapshot_id}" '[$s]')" || return 1
  out="$(rpc_call "evm_revert" "${params}" 2>/dev/null || true)"
  if [[ "${out}" == "true" ]]; then
    printf 'true\n'
    return 0
  fi
  printf 'false\n'
  return 1
}

mine() {
  rpc_call "evm_mine" "[]" >/dev/null
}

warp_seconds() {
  local delta="${1:?delta seconds is required}"
  rpc_call "evm_increaseTime" "[${delta}]" >/dev/null
  mine
}

warp_to() {
  local ts="${1:?timestamp is required}"
  if rpc_call "anvil_setNextBlockTimestamp" "[${ts}]" >/dev/null 2>&1; then
    :
  else
    rpc_call "evm_setNextBlockTimestamp" "[${ts}]" >/dev/null
  fi
  mine
}

assert_eq() {
  local name="${1:?name is required}"
  local got="${2:-}"
  local expected="${3:-}"
  if [[ "${got}" != "${expected}" ]]; then
    printf 'ASSERT_EQ failed [%s]: got=%s expected=%s\n' "${name}" "${got}" "${expected}" >&2
    return 1
  fi
}

assert_true() {
  local name="${1:?name is required}"
  local cmd="${2:?command is required}"
  if ! eval "${cmd}" >/dev/null 2>&1; then
    printf 'ASSERT_TRUE failed [%s]: %s\n' "${name}" "${cmd}" >&2
    return 1
  fi
}

normalize_expected_revert() {
  local expect="$1"
  local lowered
  if [[ -z "${expect}" ]]; then
    printf ''
    return 0
  fi
  if [[ "${expect}" =~ ^0x[0-9a-fA-F]{8}$ ]]; then
    lowered="$(printf '%s' "${expect}" | tr '[:upper:]' '[:lower:]')"
    printf '%s' "${lowered}"
    return 0
  fi
  if [[ "${expect}" == *"("*")"* ]]; then
    cast sig "${expect}" | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  printf '%s' "${expect}"
}

extract_first_hex() {
  local text="$1"
  grep -Eo '0x[0-9a-fA-F]{8,}' <<<"${text}" | head -n 1 | tr '[:upper:]' '[:lower:]'
}

is_transient_rpc_output() {
  local out="$1"
  grep -Eqi "connection (closed|reset)|broken pipe|SendRequest|error sending request|transport error|Connection reset by peer|timed out" <<<"${out}"
}

expect_revert() {
  local name="${1:?name is required}"
  local cmd="${2:?command is required}"
  local expected="${3:-}"
  local normalized out rc first_hex attempt

  normalized="$(normalize_expected_revert "${expected}")"

  for attempt in 1 2 3; do
    set +e
    out="$(eval "${cmd}" 2>&1)"
    rc=$?
    set -e

    debug "expect_revert output [${name}]: ${out}"

    if [[ "${rc}" -eq 0 ]]; then
      printf 'EXPECT_REVERT failed [%s]: command succeeded\n' "${name}" >&2
      return 1
    fi

    if [[ -z "${normalized}" ]]; then
      return 0
    fi

    if [[ "${normalized}" =~ ^0x[0-9a-f]{8}$ ]]; then
      first_hex="$(extract_first_hex "${out}")"
      if [[ -n "${first_hex}" && "${first_hex:0:10}" == "${normalized}" ]]; then
        return 0
      fi
      if grep -qi -- "${normalized}" <<<"${out}"; then
        return 0
      fi
      if (( attempt < 3 )) && is_transient_rpc_output "${out}"; then
        sleep 0.2
        continue
      fi
      printf 'EXPECT_REVERT failed [%s]: expected selector=%s output=%s\n' "${name}" "${normalized}" "${out}" >&2
      return 1
    fi

    if grep -qi -- "${normalized}" <<<"${out}"; then
      return 0
    fi
    if (( attempt < 3 )) && is_transient_rpc_output "${out}"; then
      sleep 0.2
      continue
    fi
    printf 'EXPECT_REVERT failed [%s]: expected text=%s output=%s\n' "${name}" "${normalized}" "${out}" >&2
    return 1
  done

  printf 'EXPECT_REVERT failed [%s]: transient rpc errors persisted\n' "${name}" >&2
  return 1
}

cast_call_single() {
  local to="${1:?to is required}"
  local sig="${2:?signature is required}"
  local out rc token attempt
  shift 2
  for attempt in 1 2 3; do
    set +e
    out="$(cast call --rpc-url "${RPC_URL}" "${to}" "${sig}" "$@" 2>&1)"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      token="$(awk '{print $1}' <<<"${out}")"
      if [[ -n "${token}" ]]; then
        printf '%s\n' "${token}"
        return 0
      fi
    fi
    sleep 0.2
  done
  return 1
}

cast_call_json() {
  local to="${1:?to is required}"
  local sig="${2:?signature is required}"
  local out rc attempt
  shift 2
  for attempt in 1 2 3; do
    set +e
    out="$(cast call --rpc-url "${RPC_URL}" --json "${to}" "${sig}" "$@" 2>&1)"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      if jq -e . >/dev/null 2>&1 <<<"${out}"; then
        printf '%s\n' "${out}"
        return 0
      fi
    fi
    sleep 0.2
  done
  return 1
}

cast_send_retry() {
  local out rc attempt
  for attempt in 1 2 3; do
    set +e
    out="$(cast send --rpc-url "${RPC_URL}" "$@" 2>&1)"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      printf '%s\n' "${out}"
      return 0
    fi
    sleep 0.3
  done
  return 1
}

extract_hook_from_deploy_json() {
  local path="${1:?path is required}"
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

extract_contract_from_broadcast() {
  local path="${1:?path is required}"
  python3 - "${path}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

for tx in data.get("transactions", []):
    addr = tx.get("contractAddress")
    if isinstance(addr, str) and addr.startswith("0x") and len(addr) == 42:
        print(addr)
        raise SystemExit(0)

for receipt in data.get("receipts", []):
    addr = receipt.get("contractAddress")
    if isinstance(addr, str) and addr.startswith("0x") and len(addr) == 42:
        print(addr)
        raise SystemExit(0)

print("")
PY
}

sort_tokens() {
  local a="${1:?token a is required}"
  local b="${2:?token b is required}"
  local al bl
  al="$(tr '[:upper:]' '[:lower:]' <<<"${a}")"
  bl="$(tr '[:upper:]' '[:lower:]' <<<"${b}")"
  if [[ "${al}" < "${bl}" ]]; then
    printf '%s %s\n' "${a}" "${b}"
  else
    printf '%s %s\n' "${b}" "${a}"
  fi
}

compute_pool_id() {
  local token_a="${1:?token a is required}"
  local token_b="${2:?token b is required}"
  local tick_spacing="${3:?tick spacing is required}"
  local hook="${4:?hook is required}"
  local token0 token1 key_enc
  read -r token0 token1 <<<"$(sort_tokens "${token_a}" "${token_b}")"
  key_enc="$(cast abi-encode "f((address,address,uint24,int24,address))" "(${token0},${token1},8388608,${tick_spacing},${hook})")"
  cast keccak "${key_enc}"
}

set_eth_balance() {
  local addr="${1:?address is required}"
  local wei="${2:?wei value is required}"
  local hex_value params
  hex_value="$(to_hex_uint "${wei}")"
  params="$(jq -cn --arg a "${addr}" --arg v "${hex_value}" '[$a,$v]')" || return 1
  rpc_call "anvil_setBalance" "${params}" >/dev/null
}

block_timestamp() {
  local block_json ts_hex
  block_json="$(rpc_call "eth_getBlockByNumber" '["latest", false]')"
  ts_hex="$(jq -r '.timestamp' <<<"${block_json}")"
  cast to-dec "${ts_hex}"
}

line_kv_get() {
  local line="$1"
  local key="$2"
  tr ' ' '\n' <<<"${line}" | sed -n "s/^${key}=//p" | head -n 1
}

get_fee_tier() {
  local hook="${1:-${HOOK_ADDRESS:-}}"
  local fee
  [[ -n "${hook}" ]] || return 1
  fee="$(cast_call_single "${hook}" "currentFeeBips()(uint24)" || true)"
  if [[ "${fee}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${fee}"
  else
    printf 'NOT_INITIALIZED\n'
  fi
}

get_state_debug() {
  local hook="${1:-${HOOK_ADDRESS:-}}"
  local state_json fee_idx hold_remaining up_streak down_streak emergency_streak period_start period_vol ema_vol paused rbps
  [[ -n "${hook}" ]] || return 1

  state_json="$(cast_call_json "${hook}" "getStateDebug()(uint8,uint8,uint8,uint8,uint8,uint64,uint64,uint96,bool)")" || return 1
  fee_idx="$(jq -r '.[0]' <<<"${state_json}")"
  hold_remaining="$(jq -r '.[1]' <<<"${state_json}")"
  up_streak="$(jq -r '.[2]' <<<"${state_json}")"
  down_streak="$(jq -r '.[3]' <<<"${state_json}")"
  emergency_streak="$(jq -r '.[4]' <<<"${state_json}")"
  period_start="$(jq -r '.[5]' <<<"${state_json}")"
  period_vol="$(jq -r '.[6]' <<<"${state_json}")"
  ema_vol="$(jq -r '.[7]' <<<"${state_json}")"
  paused="$(jq -r '.[8]' <<<"${state_json}")"

  rbps="0"
  if [[ "${ema_vol}" =~ ^[0-9]+$ && "${period_vol}" =~ ^[0-9]+$ && "${ema_vol}" != "0" ]]; then
    rbps="$(( (period_vol * 10000) / ema_vol ))"
  fi

  printf 'feeIdx=%s rBps=%s closeVol=%s holdRemaining=%s emaVol=%s periodStart=%s paused=%s upStreak=%s downStreak=%s emergencyStreak=%s\n' \
    "${fee_idx}" "${rbps}" "${period_vol}" "${hold_remaining}" "${ema_vol}" "${period_start}" \
    "${paused}" "${up_streak}" "${down_streak}" "${emergency_streak}"
}

checkpoint() {
  local label="${1:?checkpoint label is required}"
  local expected_fee="${2:-}"
  local hook="${HOOK_ADDRESS:-}"
  local fee state rbps close_vol hold_remaining fee_idx ema_vol paused line

  [[ -n "${hook}" ]] || return 1

  fee="$(get_fee_tier "${hook}" || true)"
  state="$(get_state_debug "${hook}" || true)"
  rbps="$(line_kv_get "${state}" "rBps")"
  close_vol="$(line_kv_get "${state}" "closeVol")"
  hold_remaining="$(line_kv_get "${state}" "holdRemaining")"
  fee_idx="$(line_kv_get "${state}" "feeIdx")"
  ema_vol="$(line_kv_get "${state}" "emaVol")"
  paused="$(line_kv_get "${state}" "paused")"

  [[ -n "${rbps}" ]] || rbps="n/a"
  [[ -n "${close_vol}" ]] || close_vol="n/a"
  [[ -n "${hold_remaining}" ]] || hold_remaining="n/a"
  [[ -n "${fee_idx}" ]] || fee_idx="n/a"
  [[ -n "${ema_vol}" ]] || ema_vol="n/a"
  [[ -n "${paused}" ]] || paused="n/a"

  if [[ -n "${expected_fee}" ]]; then
    line="checkpoint=${label} feeTier=${fee} expectedFee=${expected_fee} feeIdx=${fee_idx} rBps=${rbps} closeVol=${close_vol} emaVol=${ema_vol} holdRemaining=${hold_remaining} paused=${paused}"
  else
    line="checkpoint=${label} feeTier=${fee} expectedFee=- feeIdx=${fee_idx} rBps=${rbps} closeVol=${close_vol} emaVol=${ema_vol} holdRemaining=${hold_remaining} paused=${paused}"
  fi

  if [[ "${VERBOSE}" == "1" ]]; then
    printf '%s\n' "${line}" >&2
  fi

  if [[ -n "${expected_fee}" ]]; then
    assert_eq "checkpoint ${label} fee" "${fee}" "${expected_fee}" || {
      printf '%s\n' "${line}"
      return 1
    }
  fi

  printf '%s\n' "${line}"
}

call_hook_getters() {
  local hook="${1:?hook address is required}"

  local floor_idx cash_idx extreme_idx cap_idx paused current_fee
  local period_seconds ema_periods lull_reset deadband
  local min_cash up_cash hold_cash min_ext up_ext up_ext_conf hold_ext
  local down_ext down_ext_conf down_cash down_cash_conf em_floor em_conf
  local creator_bps
  local state_json fee_idx hold_remaining up_streak down_streak emergency_streak period_start period_vol ema_vol
  local rbps

  floor_idx="$(cast_call_single "${hook}" "floorIdx()(uint8)")"
  cash_idx="$(cast_call_single "${hook}" "cashIdx()(uint8)")"
  extreme_idx="$(cast_call_single "${hook}" "extremeIdx()(uint8)")"
  cap_idx="$(cast_call_single "${hook}" "capIdx()(uint8)")"
  paused="$(cast_call_single "${hook}" "isPaused()(bool)")"
  current_fee="$(cast call --rpc-url "${RPC_URL}" "${hook}" "currentFeeBips()(uint24)" 2>/dev/null | awk '{print $1}' || true)"
  if [[ -z "${current_fee}" ]]; then
    current_fee="NOT_INITIALIZED"
  fi

  period_seconds="$(cast_call_single "${hook}" "periodSeconds()(uint32)")"
  ema_periods="$(cast_call_single "${hook}" "emaPeriods()(uint8)")"
  lull_reset="$(cast_call_single "${hook}" "lullResetSeconds()(uint32)")"
  deadband="$(cast_call_single "${hook}" "deadbandBps()(uint16)")"

  min_cash="$(cast_call_single "${hook}" "minCloseVolToCashUsd6()(uint64)")"
  up_cash="$(cast_call_single "${hook}" "upRToCashBps()(uint16)")"
  hold_cash="$(cast_call_single "${hook}" "cashHoldPeriods()(uint8)")"
  min_ext="$(cast_call_single "${hook}" "minCloseVolToExtremeUsd6()(uint64)")"
  up_ext="$(cast_call_single "${hook}" "upRToExtremeBps()(uint16)")"
  up_ext_conf="$(cast_call_single "${hook}" "upExtremeConfirmPeriods()(uint8)")"
  hold_ext="$(cast_call_single "${hook}" "extremeHoldPeriods()(uint8)")"
  down_ext="$(cast_call_single "${hook}" "downRFromExtremeBps()(uint16)")"
  down_ext_conf="$(cast_call_single "${hook}" "downExtremeConfirmPeriods()(uint8)")"
  down_cash="$(cast_call_single "${hook}" "downRFromCashBps()(uint16)")"
  down_cash_conf="$(cast_call_single "${hook}" "downCashConfirmPeriods()(uint8)")"
  em_floor="$(cast_call_single "${hook}" "emergencyFloorCloseVolUsd6()(uint64)")"
  em_conf="$(cast_call_single "${hook}" "emergencyConfirmPeriods()(uint8)")"
  creator_bps="$(cast_call_single "${hook}" "creatorFeeBps()(uint16)")"

  state_json="$(cast_call_json "${hook}" "getStateDebug()(uint8,uint8,uint8,uint8,uint8,uint64,uint64,uint96,bool)")"
  fee_idx="$(jq -r '.[0]' <<<"${state_json}")"
  hold_remaining="$(jq -r '.[1]' <<<"${state_json}")"
  up_streak="$(jq -r '.[2]' <<<"${state_json}")"
  down_streak="$(jq -r '.[3]' <<<"${state_json}")"
  emergency_streak="$(jq -r '.[4]' <<<"${state_json}")"
  period_start="$(jq -r '.[5]' <<<"${state_json}")"
  period_vol="$(jq -r '.[6]' <<<"${state_json}")"
  ema_vol="$(jq -r '.[7]' <<<"${state_json}")"

  rbps="0"
  if [[ "${ema_vol}" =~ ^[0-9]+$ && "${period_vol}" =~ ^[0-9]+$ && "${ema_vol}" != "0" ]]; then
    rbps="$(( (period_vol * 10000) / ema_vol ))"
  fi

  printf 'fee_idx=%s hold_remaining=%s up_extreme_streak=%s down_streak=%s emergency_streak=%s period_start=%s period_vol=%s ema_vol=%s r_bps=%s current_fee_bips=%s paused=%s floor_idx=%s cash_idx=%s extreme_idx=%s cap_idx=%s period_seconds=%s ema_periods=%s lull_reset_seconds=%s deadband_bps=%s min_closevol_cash=%s up_r_cash=%s cash_hold=%s min_closevol_extreme=%s up_r_extreme=%s up_extreme_confirm=%s extreme_hold=%s down_r_extreme=%s down_extreme_confirm=%s down_r_cash=%s down_cash_confirm=%s emergency_floor=%s emergency_confirm=%s creator_fee_bps=%s\n' \
    "${fee_idx}" "${hold_remaining}" "${up_streak}" "${down_streak}" "${emergency_streak}" \
    "${period_start}" "${period_vol}" "${ema_vol}" "${rbps}" "${current_fee}" "${paused}" \
    "${floor_idx}" "${cash_idx}" "${extreme_idx}" "${cap_idx}" "${period_seconds}" "${ema_periods}" \
    "${lull_reset}" "${deadband}" "${min_cash}" "${up_cash}" "${hold_cash}" "${min_ext}" "${up_ext}" \
    "${up_ext_conf}" "${hold_ext}" "${down_ext}" "${down_ext_conf}" "${down_cash}" "${down_cash_conf}" \
    "${em_floor}" "${em_conf}" "${creator_bps}"
}

abi_function_entries() {
  forge inspect --json VolumeDynamicFeeHook abi \
    | jq -r '.[] | select(.type=="function") | "\(.name)(\(.inputs|map(.type)|join(",")))|\(.stateMutability)"'
}

abi_function_signatures() {
  abi_function_entries | cut -d'|' -f1
}

source_custom_errors() {
  local src_path="${1:-src/VolumeDynamicFeeHook.sol}"
  python3 - "${src_path}" <<'PY'
import re
import sys

path = sys.argv[1]
pattern = re.compile(r'^\s*error\s+([A-Za-z0-9_]+)\(([^)]*)\)\s*;', re.M)

with open(path, "r", encoding="utf-8") as f:
    src = f.read()

for m in pattern.finditer(src):
    name = m.group(1)
    params = m.group(2).strip()
    if not params:
        print(f"{name}()")
        continue
    types = []
    for raw in params.split(","):
        item = raw.strip()
        if not item:
            continue
        token = item.split()[0]
        types.append(token)
    print(f"{name}({','.join(types)})")
PY
}

source_reason_constants() {
  local src_path="${1:-src/VolumeDynamicFeeHook.sol}"
  python3 - "${src_path}" <<'PY'
import re
import sys

path = sys.argv[1]
pattern = re.compile(r'^\s*uint8\s+public\s+constant\s+(REASON_[A-Z0-9_]+)\s*=\s*([0-9]+)\s*;', re.M)

with open(path, "r", encoding="utf-8") as f:
    src = f.read()

for name, value in pattern.findall(src):
    print(f"{name}={value}")
PY
}

tx_hash_from_send_output() {
  local out="${1:-}"
  local tx cand

  tx="$(awk '/transactionHash/ {print $2}' <<<"${out}" | tail -n 1 | tr '[:upper:]' '[:lower:]')"
  if [[ "${tx}" =~ ^0x[0-9a-f]{64}$ ]]; then
    printf '%s\n' "${tx}"
    return 0
  fi

  tx=""
  while IFS= read -r cand; do
    [[ -n "${cand}" ]] || continue
    cand="$(printf '%s' "${cand}" | tr '[:upper:]' '[:lower:]')"
    if cast receipt --rpc-url "${RPC_URL}" "${cand}" >/dev/null 2>&1; then
      printf '%s\n' "${cand}"
      return 0
    fi
    if [[ -z "${tx}" ]]; then
      tx="${cand}"
    fi
  done < <(grep -Eo '0x[0-9a-fA-F]{64}' <<<"${out}")

  printf '%s\n' "${tx}"
}

cast_send_txhash() {
  local out tx
  out="$(cast_send_retry "$@")" || return 1
  tx="$(tx_hash_from_send_output "${out}")"
  if [[ -z "${tx}" ]]; then
    debug "cast_send_txhash could not parse tx hash from output: ${out}"
    return 1
  fi
  printf '%s\n' "${tx}"
}

period_closed_topic0() {
  cast keccak "PeriodClosed(uint24,uint8,uint24,uint8,uint64,uint96,uint64,uint8)"
}

period_closed_events_from_tx() {
  local tx_hash="${1:?tx hash is required}"
  local topic0="${2:-}"
  local receipt_json

  if [[ -z "${topic0}" ]]; then
    topic0="$(period_closed_topic0)"
  fi

  receipt_json="$(cast receipt --rpc-url "${RPC_URL}" --json "${tx_hash}")" || return 1
  python3 - "${topic0}" "${receipt_json}" <<'PY'
import json
import sys

topic0 = sys.argv[1].lower()
receipt = json.loads(sys.argv[2])

for idx, log in enumerate(receipt.get("logs", [])):
    topics = [str(t).lower() for t in log.get("topics", [])]
    if not topics or topics[0] != topic0:
        continue

    data = str(log.get("data", "0x"))
    if not data.startswith("0x"):
        continue
    payload = data[2:]
    if len(payload) < 64 * 8:
        continue

    words = [int(payload[i * 64:(i + 1) * 64], 16) for i in range(8)]
    print(
        "logIndex={idx} fromFee={from_fee} fromFeeIdx={from_idx} toFee={to_fee} toFeeIdx={to_idx} "
        "closeVol={close_vol} emaVol={ema_vol} lpFees={lp_fees} reason={reason}".format(
            idx=idx,
            from_fee=words[0],
            from_idx=words[1],
            to_fee=words[2],
            to_idx=words[3],
            close_vol=words[4],
            ema_vol=words[5],
            lp_fees=words[6],
            reason=words[7],
        )
    )
PY
}

last_period_closed_reason_from_tx() {
  local tx_hash="${1:?tx hash is required}"
  local events last_line reason
  events="$(period_closed_events_from_tx "${tx_hash}" || true)"
  last_line="$(tail -n 1 <<<"${events}")"
  reason="$(line_kv_get "${last_line}" "reason")"
  if [[ "${reason}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${reason}"
    return 0
  fi
  return 1
}
