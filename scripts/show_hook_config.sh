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

fmt_mode() {
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

floorToCashMinCloseVolume="$(read_uint "floorToCashMinCloseVolume()(uint64)")"
floorToCashMinFlowBps="$(read_uint "floorToCashMinFlowBps()(uint16)")"
cashHoldPeriods="$(read_uint "cashHoldPeriods()(uint8)")"

cashToExtremeMinCloseVolume="$(read_uint "cashToExtremeMinCloseVolume()(uint64)")"
cashToExtremeMinFlowBps="$(read_uint "cashToExtremeMinFlowBps()(uint16)")"
cashToExtremeConfirmPeriods="$(read_uint "cashToExtremeConfirmPeriods()(uint8)")"
extremeHoldPeriods="$(read_uint "extremeHoldPeriods()(uint8)")"

extremeToCashMaxFlowBps="$(read_uint "extremeToCashMaxFlowBps()(uint16)")"
extremeToCashConfirmPeriods="$(read_uint "extremeToCashConfirmPeriods()(uint8)")"

cashToFloorMaxFlowBps="$(read_uint "cashToFloorMaxFlowBps()(uint16)")"
cashToFloorConfirmPeriods="$(read_uint "cashToFloorConfirmPeriods()(uint8)")"

emergencyToFloorMaxCloseVolume="$(read_uint "emergencyToFloorMaxCloseVolume()(uint64)")"
emergencyToFloorConfirmPeriods="$(read_uint "emergencyToFloorConfirmPeriods()(uint8)")"

periodSeconds="$(read_uint "periodSeconds()(uint32)")"
emaPeriods="$(read_uint "emaPeriods()(uint8)")"
lullResetSeconds="$(read_uint "lullResetSeconds()(uint32)")"
minCountedSwapVolume="$(read_uint "minCountedSwapVolume()(uint64)")"

currentMode="$(read_uint "currentMode()(uint8)")"

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
print_param "floorToCashMinCloseVolume"   "$floorToCashMinCloseVolume"   "$(fmt_usd6 "$floorToCashMinCloseVolume")"
print_param "floorToCashMinFlowBps"       "$floorToCashMinFlowBps"       "$(fmt_ratio_bps "$floorToCashMinFlowBps")"
print_param "cashHoldPeriods"             "$cashHoldPeriods"

echo
echo "=== Extreme enter ==="
print_param "cashToExtremeMinCloseVolume" "$cashToExtremeMinCloseVolume" "$(fmt_usd6 "$cashToExtremeMinCloseVolume")"
print_param "cashToExtremeMinFlowBps"     "$cashToExtremeMinFlowBps"     "$(fmt_ratio_bps "$cashToExtremeMinFlowBps")"
print_param "cashToExtremeConfirmPeriods" "$cashToExtremeConfirmPeriods"
print_param "extremeHoldPeriods"          "$extremeHoldPeriods"

echo
echo "=== Extreme exit ==="
print_param "extremeToCashMaxFlowBps"     "$extremeToCashMaxFlowBps"     "$(fmt_ratio_bps "$extremeToCashMaxFlowBps")"
print_param "extremeToCashConfirmPeriods" "$extremeToCashConfirmPeriods"

echo
echo "=== Cash exit ==="
print_param "cashToFloorMaxFlowBps"       "$cashToFloorMaxFlowBps"       "$(fmt_ratio_bps "$cashToFloorMaxFlowBps")"
print_param "cashToFloorConfirmPeriods"   "$cashToFloorConfirmPeriods"

echo
echo "=== Emergency / reset ==="
print_param "emergencyToFloorMaxCloseVolume" "$emergencyToFloorMaxCloseVolume" "$(fmt_usd6 "$emergencyToFloorMaxCloseVolume")"
print_param "emergencyToFloorConfirmPeriods" "$emergencyToFloorConfirmPeriods"
print_param "lullResetSeconds"            "$lullResetSeconds"            "$(fmt_seconds "$lullResetSeconds")"

echo
echo "=== Timing / smoothing ==="
print_param "periodSeconds"               "$periodSeconds"               "$(fmt_seconds "$periodSeconds")"
print_param "emaPeriods"                  "$emaPeriods"
print_param "minCountedSwapVolume"        "$minCountedSwapVolume"        "$(fmt_usd6 "$minCountedSwapVolume")"

echo
echo "=== Live state ==="
print_param "currentMode"               "$currentMode"               "$(fmt_mode "$currentMode")"
print_param "state.feeIdx"                "$state_feeIdx"                "$(fmt_mode "$state_feeIdx")"
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
  "floorToCashMinCloseVolume": $floorToCashMinCloseVolume,
  "floorToCashMinFlowBps": $floorToCashMinFlowBps,
  "cashHoldPeriods": $cashHoldPeriods,
  "cashToExtremeMinCloseVolume": $cashToExtremeMinCloseVolume,
  "cashToExtremeMinFlowBps": $cashToExtremeMinFlowBps,
  "cashToExtremeConfirmPeriods": $cashToExtremeConfirmPeriods,
  "extremeHoldPeriods": $extremeHoldPeriods,
  "extremeToCashMaxFlowBps": $extremeToCashMaxFlowBps,
  "extremeToCashConfirmPeriods": $extremeToCashConfirmPeriods,
  "cashToFloorMaxFlowBps": $cashToFloorMaxFlowBps,
  "cashToFloorConfirmPeriods": $cashToFloorConfirmPeriods,
  "emergencyToFloorMaxCloseVolume": $emergencyToFloorMaxCloseVolume,
  "emergencyToFloorConfirmPeriods": $emergencyToFloorConfirmPeriods
}
EOF2

echo
echo "=== setControllerParams tuple (current) ==="
echo "($floorToCashMinCloseVolume,$floorToCashMinFlowBps,$cashHoldPeriods,$cashToExtremeMinCloseVolume,$cashToExtremeMinFlowBps,$cashToExtremeConfirmPeriods,$extremeHoldPeriods,$extremeToCashMaxFlowBps,$extremeToCashConfirmPeriods,$cashToFloorMaxFlowBps,$cashToFloorConfirmPeriods,$emergencyToFloorMaxCloseVolume,$emergencyToFloorConfirmPeriods)"
