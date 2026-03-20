#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF2'
Usage:
  ./scripts/show_hook_config.sh --chain <chain>

Example:
  ./scripts/show_hook_config.sh --chain optimism
EOF2
}

CHAIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain)
      [[ $# -ge 2 ]] || { echo "Error: --chain requires a value" >&2; usage; exit 1; }
      CHAIN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

[[ -n "$CHAIN" ]] || { echo "Error: --chain is required" >&2; usage; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/ops/${CHAIN}/config/defaults.env"

[[ -f "$CONFIG_FILE" ]] || {
  echo "Error: config file not found: $CONFIG_FILE" >&2
  exit 1
}

set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

HOOK="${HOOK_ADDRESS:-}"
RPC_URL="${RPC_URL:-}"

[[ -n "$HOOK" ]] || {
  echo "Error: HOOK_ADDRESS is empty in $CONFIG_FILE" >&2
  exit 1
}

[[ -n "$RPC_URL" ]] || {
  echo "Error: RPC_URL is empty in $CONFIG_FILE" >&2
  exit 1
}

call_uint() {
  local sig="$1"
  cast call "$HOOK" "$sig" --rpc-url "$RPC_URL" 2>/dev/null | awk 'NF { print $1; exit }'
}

call_multiline_clean() {
  local sig="$1"
  cast call "$HOOK" "$sig" --rpc-url "$RPC_URL" 2>/dev/null \
    | sed -E 's/[[:space:]]+\[[^]]+\]//g' \
    | sed '/^[[:space:]]*$/d' || true
}

fmt_usd6() {
  awk -v v="$1" 'BEGIN { printf "%.6f USD", v / 1000000 }'
}

fmt_ema_scaled() {
  awk -v v="$1" 'BEGIN { printf "%.6f USD", v / 1000000000000 }'
}

fmt_fee_pips() {
  awk -v v="$1" 'BEGIN { printf "%.4f%%", v / 10000 }'
}

fmt_ratio_bps() {
  awk -v v="$1" 'BEGIN { printf "%.4fx", v / 10000 }'
}

fmt_seconds() {
  local v="$1"
  awk -v v="$v" 'BEGIN {
    d = int(v / 86400)
    h = int((v % 86400) / 3600)
    m = int((v % 3600) / 60)
    s = int(v % 60)

    out = ""
    if (d > 0) out = out d "d "
    if (h > 0) out = out h "h "
    if (m > 0) out = out m "m "
    if (s > 0 || out == "") out = out s "s"
    sub(/[[:space:]]+$/, "", out)
    printf "%s", out
  }'
}

fmt_regime() {
  case "$1" in
    0) echo "FLOOR" ;;
    1) echo "CASH" ;;
    2) echo "EXTREME" ;;
    *) echo "UNKNOWN" ;;
  esac
}

print_param() {
  local name="$1"
  local raw="$2"
  local human="${3:-}"

  printf "%-30s = %-20s" "$name" "$raw"
  if [[ -n "$human" ]]; then
    printf " (%s)" "$human"
  fi
  printf "\n"
}

read_uint() {
  local sig="$1"
  local out
  out="$(call_uint "$sig" || true)"
  if [[ -z "$out" ]]; then
    echo "ERROR"
  else
    echo "$out"
  fi
}

echo "CHAIN=$CHAIN"
echo "CONFIG_FILE=$CONFIG_FILE"
echo "HOOK_ADDRESS=$HOOK"
echo "RPC_URL=$RPC_URL"
echo

floorFee="$(read_uint "floorFee()(uint24)")"
cashFee="$(read_uint "cashFee()(uint24)")"
extremeFee="$(read_uint "extremeFee()(uint24)")"

minCloseVolToCashUsd6="$(read_uint "minCloseVolToCashUsd6()(uint64)")"
cashEnterTriggerBps="$(read_uint "cashEnterTriggerBps()(uint16)")"
cashHoldPeriods="$(read_uint "cashHoldPeriods()(uint8)")"

minCloseVolToExtremeUsd6="$(read_uint "minCloseVolToExtremeUsd6()(uint64)")"
extremeEnterTriggerBps="$(read_uint "extremeEnterTriggerBps()(uint16)")"
upExtremeConfirmPeriods="$(read_uint "upExtremeConfirmPeriods()(uint8)")"
extremeHoldPeriods="$(read_uint "extremeHoldPeriods()(uint8)")"

extremeExitTriggerBps="$(read_uint "extremeExitTriggerBps()(uint16)")"
downExtremeConfirmPeriods="$(read_uint "downExtremeConfirmPeriods()(uint8)")"

cashExitTriggerBps="$(read_uint "cashExitTriggerBps()(uint16)")"
downCashConfirmPeriods="$(read_uint "downCashConfirmPeriods()(uint8)")"

emergencyFloorCloseVolUsd6="$(read_uint "emergencyFloorCloseVolUsd6()(uint64)")"
emergencyConfirmPeriods="$(read_uint "emergencyConfirmPeriods()(uint8)")"

periodSeconds="$(read_uint "periodSeconds()(uint32)")"
emaPeriods="$(read_uint "emaPeriods()(uint8)")"
lullResetSeconds="$(read_uint "lullResetSeconds()(uint32)")"
minCountedSwapUsd6="$(read_uint "minCountedSwapUsd6()(uint64)")"

currentRegime="$(read_uint "currentRegime()(uint8)")"

STATE_DEBUG=()
while IFS= read -r line; do
  [[ -n "$line" ]] && STATE_DEBUG+=("$line")
done < <(call_multiline_clean "getStateDebug()(uint8,uint8,uint8,uint8,uint8,uint64,uint64,uint96,bool)")

state_feeIdx="${STATE_DEBUG[0]:-ERROR}"
state_holdRemaining="${STATE_DEBUG[1]:-ERROR}"
state_upExtremeStreak="${STATE_DEBUG[2]:-ERROR}"
state_downStreak="${STATE_DEBUG[3]:-ERROR}"
state_emergencyStreak="${STATE_DEBUG[4]:-ERROR}"
state_periodStart="${STATE_DEBUG[5]:-ERROR}"
state_periodVol="${STATE_DEBUG[6]:-ERROR}"
state_emaVolScaled="${STATE_DEBUG[7]:-ERROR}"
state_paused="${STATE_DEBUG[8]:-ERROR}"

echo "=== Fees ==="
print_param "floorFee"                    "$floorFee"                    "$(fmt_fee_pips "$floorFee")"
print_param "cashFee"                     "$cashFee"                     "$(fmt_fee_pips "$cashFee")"
print_param "extremeFee"                  "$extremeFee"                  "$(fmt_fee_pips "$extremeFee")"

echo
echo "=== Cash enter ==="
print_param "minCloseVolToCashUsd6"       "$minCloseVolToCashUsd6"       "$(fmt_usd6 "$minCloseVolToCashUsd6")"
print_param "cashEnterTriggerBps"         "$cashEnterTriggerBps"         "$(fmt_ratio_bps "$cashEnterTriggerBps")"
print_param "cashHoldPeriods"             "$cashHoldPeriods"

echo
echo "=== Extreme enter ==="
print_param "minCloseVolToExtremeUsd6"    "$minCloseVolToExtremeUsd6"    "$(fmt_usd6 "$minCloseVolToExtremeUsd6")"
print_param "extremeEnterTriggerBps"      "$extremeEnterTriggerBps"      "$(fmt_ratio_bps "$extremeEnterTriggerBps")"
print_param "upExtremeConfirmPeriods"     "$upExtremeConfirmPeriods"
print_param "extremeHoldPeriods"          "$extremeHoldPeriods"

echo
echo "=== Extreme exit ==="
print_param "extremeExitTriggerBps"       "$extremeExitTriggerBps"       "$(fmt_ratio_bps "$extremeExitTriggerBps")"
print_param "downExtremeConfirmPeriods"   "$downExtremeConfirmPeriods"

echo
echo "=== Cash exit ==="
print_param "cashExitTriggerBps"          "$cashExitTriggerBps"          "$(fmt_ratio_bps "$cashExitTriggerBps")"
print_param "downCashConfirmPeriods"      "$downCashConfirmPeriods"

echo
echo "=== Emergency / reset ==="
print_param "emergencyFloorCloseVolUsd6"  "$emergencyFloorCloseVolUsd6"  "$(fmt_usd6 "$emergencyFloorCloseVolUsd6")"
print_param "emergencyConfirmPeriods"     "$emergencyConfirmPeriods"
print_param "lullResetSeconds"            "$lullResetSeconds"            "$(fmt_seconds "$lullResetSeconds")"

echo
echo "=== Timing / smoothing ==="
print_param "periodSeconds"               "$periodSeconds"               "$(fmt_seconds "$periodSeconds")"
print_param "emaPeriods"                  "$emaPeriods"
print_param "minCountedSwapUsd6"          "$minCountedSwapUsd6"          "$(fmt_usd6 "$minCountedSwapUsd6")"

echo
echo "=== Live state ==="
print_param "currentRegime"               "$currentRegime"               "$(fmt_regime "$currentRegime")"
print_param "state.feeIdx"                "$state_feeIdx"                "$(fmt_regime "$state_feeIdx")"
print_param "state.holdRemaining"         "$state_holdRemaining"
print_param "state.upExtremeStreak"       "$state_upExtremeStreak"
print_param "state.downStreak"            "$state_downStreak"
print_param "state.emergencyStreak"       "$state_emergencyStreak"
print_param "state.periodStart"           "$state_periodStart"
print_param "state.periodVolUsd6"         "$state_periodVol"             "$(fmt_usd6 "$state_periodVol")"
print_param "state.emaVolScaled"          "$state_emaVolScaled"          "$(fmt_ema_scaled "$state_emaVolScaled")"
print_param "state.paused"                "$state_paused"
echo "getStateDebug_tuple=($state_feeIdx,$state_holdRemaining,$state_upExtremeStreak,$state_downStreak,$state_emergencyStreak,$state_periodStart,$state_periodVol,$state_emaVolScaled,$state_paused)"

echo
echo "=== setControllerParams JSON (current) ==="
cat <<EOF2
{
  "minCloseVolToCashUsd6": $minCloseVolToCashUsd6,
  "cashEnterTriggerBps": $cashEnterTriggerBps,
  "cashHoldPeriods": $cashHoldPeriods,
  "minCloseVolToExtremeUsd6": $minCloseVolToExtremeUsd6,
  "extremeEnterTriggerBps": $extremeEnterTriggerBps,
  "upExtremeConfirmPeriods": $upExtremeConfirmPeriods,
  "extremeHoldPeriods": $extremeHoldPeriods,
  "extremeExitTriggerBps": $extremeExitTriggerBps,
  "downExtremeConfirmPeriods": $downExtremeConfirmPeriods,
  "cashExitTriggerBps": $cashExitTriggerBps,
  "downCashConfirmPeriods": $downCashConfirmPeriods,
  "emergencyFloorCloseVolUsd6": $emergencyFloorCloseVolUsd6,
  "emergencyConfirmPeriods": $emergencyConfirmPeriods
}
EOF2

echo
echo "=== setControllerParams tuple (current) ==="
echo "($minCloseVolToCashUsd6,$cashEnterTriggerBps,$cashHoldPeriods,$minCloseVolToExtremeUsd6,$extremeEnterTriggerBps,$upExtremeConfirmPeriods,$extremeHoldPeriods,$extremeExitTriggerBps,$downExtremeConfirmPeriods,$cashExitTriggerBps,$downCashConfirmPeriods,$emergencyFloorCloseVolUsd6,$emergencyConfirmPeriods)"
