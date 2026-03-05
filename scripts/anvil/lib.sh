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
  cast rpc --rpc-url "${RPC_URL}" "$@"
}

mine() {
  rpc_call evm_mine >/dev/null
}

warp_seconds() {
  local delta="${1:?delta seconds is required}"
  rpc_call evm_increaseTime "${delta}" >/dev/null
  mine
}

warp_to() {
  local ts="${1:?timestamp is required}"
  if rpc_call anvil_setNextBlockTimestamp "${ts}" >/dev/null 2>&1; then
    :
  else
    rpc_call evm_setNextBlockTimestamp "${ts}" >/dev/null
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
  local hex_value
  hex_value="$(to_hex_uint "${wei}")"
  rpc_call anvil_setBalance "${addr}" "${hex_value}" >/dev/null
}

block_timestamp() {
  local block_json ts_hex
  block_json="$(rpc_call eth_getBlockByNumber latest false)"
  ts_hex="$(jq -r '.timestamp' <<<"${block_json}")"
  cast to-dec "${ts_hex}"
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
  if [[ "${ema_vol}" != "0" ]]; then
    rbps="$(python3 - <<'PY' "${period_vol}" "${ema_vol}"
import sys
pv = int(sys.argv[1])
ev = int(sys.argv[2])
print((pv * 10000) // ev if ev > 0 else 0)
PY
)"
  fi

  printf 'fee_idx=%s hold_remaining=%s up_extreme_streak=%s down_streak=%s emergency_streak=%s period_start=%s period_vol=%s ema_vol=%s r_bps=%s current_fee_bips=%s paused=%s floor_idx=%s cash_idx=%s extreme_idx=%s cap_idx=%s period_seconds=%s ema_periods=%s lull_reset_seconds=%s deadband_bps=%s min_closevol_cash=%s up_r_cash=%s cash_hold=%s min_closevol_extreme=%s up_r_extreme=%s up_extreme_confirm=%s extreme_hold=%s down_r_extreme=%s down_extreme_confirm=%s down_r_cash=%s down_cash_confirm=%s emergency_floor=%s emergency_confirm=%s creator_fee_bps=%s\n' \
    "${fee_idx}" "${hold_remaining}" "${up_streak}" "${down_streak}" "${emergency_streak}" \
    "${period_start}" "${period_vol}" "${ema_vol}" "${rbps}" "${current_fee}" "${paused}" \
    "${floor_idx}" "${cash_idx}" "${extreme_idx}" "${cap_idx}" "${period_seconds}" "${ema_periods}" \
    "${lull_reset}" "${deadband}" "${min_cash}" "${up_cash}" "${hold_cash}" "${min_ext}" "${up_ext}" \
    "${up_ext_conf}" "${hold_ext}" "${down_ext}" "${down_ext_conf}" "${down_cash}" "${down_cash_conf}" \
    "${em_floor}" "${em_conf}" "${creator_bps}"
}
