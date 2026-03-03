#!/usr/bin/env bash
set -euo pipefail

# Deploy hook (CREATE2-mined address with required v4 hook flags).
#
# Usage:
#   ./scripts/deploy_hook.sh --chain <chain> [--rpc-url <url>] [--private-key <hex>] [--broadcast] [--verify]
#
# If run with no args, prints this help.
#
# Config:
#   - local   -> ./config/hook.local.conf
#   - sepolia -> ./config/hook.sepolia.conf
#   - other   -> ./config/hook.<chain>.conf
#
# Required config keys:
#   POOL_MANAGER, VOLATILE, STABLE, STABLE_DECIMALS, TICK_SPACING
#   FLOOR_TIER, CAP_TIER
#   FEE_TIERS (comma-separated fee levels in percent, for example 0.009,0.04,0.09)
#   PERIOD_SECONDS, EMA_PERIODS, DEADBAND_BPS, LULL_RESET_SECONDS
#   CREATOR_FEE_PERCENT
# Optional:
#   CREATOR_FEE_ADDRESS (defaults to GUARDIAN)
#
# Guardian behavior:
#   - If GUARDIAN is empty after sourcing config + .env, it defaults to the deployer address.
#   - If REQUIRE_GUARDIAN_CONTRACT=1, deployment fails when GUARDIAN is an EOA.
#
# Creator behavior:
#   - CREATOR_FEE_ADDRESS defines creator-fee receiver/controller.
#   - If CREATOR_FEE_ADDRESS is empty, it defaults to GUARDIAN.

usage() {
  cat <<'EOF'
Usage:
  ./scripts/deploy_hook.sh --chain <chain> [--rpc-url <url>] [--private-key <hex>] [--broadcast] [--verify]

Examples:
  ./scripts/deploy_hook.sh --chain local --rpc-url http://127.0.0.1:8545 --private-key <pk> --broadcast
  ./scripts/deploy_hook.sh --chain sepolia --rpc-url https://ethereum-sepolia-rpc.publicnode.com --private-key <pk> --broadcast

Notes:
  - Output JSON is written to ./scripts/out/deploy.<chain>.json
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

CHAIN=""
RPC_URL_CLI=""
PRIVATE_KEY_CLI=""
BROADCAST=0
VERIFY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --rpc-url) RPC_URL_CLI="${2:-}"; shift 2 ;;
    --private-key) PRIVATE_KEY_CLI="${2:-}"; shift 2 ;;
    --broadcast) BROADCAST=1; shift ;;
    --verify) VERIFY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

CHAIN="$(lower "${CHAIN:-}")"
if [[ -z "$CHAIN" ]]; then
  echo "ERROR: --chain is required" >&2
  usage
  exit 1
fi

# Auto-load .env (repo root) if present, so configs can reference DEFAULT_PRIVATE_KEY, DEFAULT_GUARDIAN, etc.
if [[ -f "./.env" ]]; then
  # shellcheck disable=SC1091
  source "./.env"
fi

HOOK_CONF="./config/hook.${CHAIN}.conf"
if [[ "$CHAIN" == "local" ]]; then
  HOOK_CONF="./config/hook.local.conf"
elif [[ "$CHAIN" == "sepolia" ]]; then
  HOOK_CONF="./config/hook.sepolia.conf"
fi

if [[ ! -f "$HOOK_CONF" ]]; then
  echo "ERROR: config not found: $HOOK_CONF" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$HOOK_CONF"
set +a

RPC_URL="${RPC_URL_CLI:-${RPC_URL:-}}"
PRIVATE_KEY="${PRIVATE_KEY_CLI:-${PRIVATE_KEY:-}}"

if [[ -z "${RPC_URL:-}" ]]; then
  echo "ERROR: RPC_URL missing (config or --rpc-url)" >&2
  exit 1
fi

if [[ "$BROADCAST" -ne 1 ]]; then
  echo "==> deploy_hook: skipping (no --broadcast)" >&2
  exit 0
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "ERROR: PRIVATE_KEY missing (config, .env DEFAULT_PRIVATE_KEY, or --private-key)" >&2
  exit 1
fi

# Validate required variables
required=(POOL_MANAGER VOLATILE STABLE STABLE_DECIMALS TICK_SPACING FLOOR_TIER CAP_TIER FEE_TIERS PERIOD_SECONDS EMA_PERIODS DEADBAND_BPS LULL_RESET_SECONDS CREATOR_FEE_PERCENT)
for k in "${required[@]}"; do
  if [[ -z "${!k:-}" ]]; then
    echo "ERROR: missing $k in $HOOK_CONF" >&2
    exit 1
  fi
done

percent_to_pips() {
  local pct="$1"
  awk -v pct="${pct}" '
    BEGIN {
      if (pct !~ /^[0-9]+([.][0-9]+)?$/) exit 1;
      v = pct * 10000;
      p = int(v + 0.5);
      if (p < 1 || p > 1000000) exit 1;
      print p;
    }' 2>/dev/null
}

# Parse fee tiers from percent CSV into hundredths-of-a-bip values expected by the hook.
# Example: 0.009% -> 90.
IFS=',' read -r -a FEE_TIER_PCT_ITEMS <<< "${FEE_TIERS}"
if (( ${#FEE_TIER_PCT_ITEMS[@]} == 0 )); then
  echo "ERROR: FEE_TIERS must contain at least one value (for example 0.009,0.04,0.09)." >&2
  exit 1
fi
if (( ${#FEE_TIER_PCT_ITEMS[@]} > 255 )); then
  echo "ERROR: FEE_TIERS has ${#FEE_TIER_PCT_ITEMS[@]} values; max supported is 255." >&2
  exit 1
fi

FEE_TIER_COUNT="${#FEE_TIER_PCT_ITEMS[@]}"
export FEE_TIER_COUNT

declare -a FEE_TIER_PIPS=()
prev_tier_pips=-1
for i in "${!FEE_TIER_PCT_ITEMS[@]}"; do
  tier_pct="$(printf '%s' "${FEE_TIER_PCT_ITEMS[$i]}" | tr -d '[:space:]')"
  tier_pips="$(percent_to_pips "${tier_pct}" || true)"
  if [[ -z "${tier_pips}" ]]; then
    echo "ERROR: FEE_TIERS item '${FEE_TIER_PCT_ITEMS[$i]}' is invalid. Use decimal percent values like 0.09." >&2
    exit 1
  fi
  if (( prev_tier_pips >= 0 && tier_pips <= prev_tier_pips )); then
    echo "ERROR: FEE_TIERS must be strictly increasing after conversion to pips." >&2
    exit 1
  fi
  prev_tier_pips="${tier_pips}"
  FEE_TIER_PIPS[$i]="${tier_pips}"

  tier_var="FEE_TIER_${i}"
  printf -v "${tier_var}" '%s' "${tier_pips}"
  export "${tier_var}"
done

floor_tier_pct="$(printf '%s' "${FLOOR_TIER}" | tr -d '[:space:]')"
cap_tier_pct="$(printf '%s' "${CAP_TIER}" | tr -d '[:space:]')"
floor_tier_pips="$(percent_to_pips "${floor_tier_pct}" || true)"
cap_tier_pips="$(percent_to_pips "${cap_tier_pct}" || true)"
if [[ -z "${floor_tier_pips}" ]]; then
  echo "ERROR: FLOOR_TIER='${FLOOR_TIER}' is invalid. Use decimal percent format like 0.04." >&2
  exit 1
fi
if [[ -z "${cap_tier_pips}" ]]; then
  echo "ERROR: CAP_TIER='${CAP_TIER}' is invalid. Use decimal percent format like 0.45." >&2
  exit 1
fi

FLOOR_IDX=""
CAP_IDX=""
for i in "${!FEE_TIER_PIPS[@]}"; do
  if [[ "${FEE_TIER_PIPS[$i]}" == "${floor_tier_pips}" ]]; then
    FLOOR_IDX="${i}"
  fi
  if [[ "${FEE_TIER_PIPS[$i]}" == "${cap_tier_pips}" ]]; then
    CAP_IDX="${i}"
  fi
done

if [[ -z "${FLOOR_IDX}" ]]; then
  echo "ERROR: FLOOR_TIER=${FLOOR_TIER}% is not present in FEE_TIERS='${FEE_TIERS}'." >&2
  exit 1
fi
if [[ -z "${CAP_IDX}" ]]; then
  echo "ERROR: CAP_TIER=${CAP_TIER}% is not present in FEE_TIERS='${FEE_TIERS}'." >&2
  exit 1
fi
if (( FLOOR_IDX > CAP_IDX )); then
  echo "ERROR: FLOOR_TIER index (${FLOOR_IDX}) must be <= CAP_TIER index (${CAP_IDX})." >&2
  exit 1
fi

export FLOOR_IDX CAP_IDX

# Human-friendly percent input in config (10 means 10%).
if ! [[ "${CREATOR_FEE_PERCENT}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: CREATOR_FEE_PERCENT must be an integer in [0..100]" >&2
  exit 1
fi
if (( CREATOR_FEE_PERCENT > 100 )); then
  echo "ERROR: CREATOR_FEE_PERCENT=${CREATOR_FEE_PERCENT} out of range [0..100]" >&2
  exit 1
fi
CREATOR_FEE_BPS=$((CREATOR_FEE_PERCENT * 100))
export CREATOR_FEE_BPS

# Default guardian to deployer if empty
DEPLOYER_ADDR="$(cast wallet address --private-key "${PRIVATE_KEY}" | awk '{print $1}')"

if [[ -z "${GUARDIAN:-}" ]]; then
  GUARDIAN="${DEPLOYER_ADDR}"
  export GUARDIAN
  echo "==> GUARDIAN not set; defaulting to deployer: ${GUARDIAN}"
fi

# Use CREATOR_FEE_ADDRESS as canonical creator fee account.
# Keep CREATOR exported for the current Solidity constructor/input naming.
if [[ -z "${CREATOR_FEE_ADDRESS:-}" ]]; then
  if [[ -n "${CREATOR:-}" ]]; then
    CREATOR_FEE_ADDRESS="${CREATOR}"
    echo "==> CREATOR_FEE_ADDRESS not set; reusing CREATOR: ${CREATOR_FEE_ADDRESS}"
  else
    CREATOR_FEE_ADDRESS="${GUARDIAN}"
    echo "==> CREATOR_FEE_ADDRESS not set; defaulting to GUARDIAN: ${CREATOR_FEE_ADDRESS}"
  fi
fi
export CREATOR_FEE_ADDRESS

if [[ -n "${CREATOR:-}" && "${CREATOR}" != "${CREATOR_FEE_ADDRESS}" ]]; then
  echo "ERROR: CREATOR (${CREATOR}) and CREATOR_FEE_ADDRESS (${CREATOR_FEE_ADDRESS}) differ. Use one value." >&2
  exit 1
fi
CREATOR="${CREATOR_FEE_ADDRESS}"
export CREATOR

# Optional safety: enforce contract-based guardian (e.g. multisig) in strict mode.
GUARDIAN_CODE="$(cast code "${GUARDIAN}" --rpc-url "${RPC_URL}" 2>/dev/null || true)"
if [[ -z "${GUARDIAN_CODE}" ]]; then
  echo "ERROR: failed to fetch bytecode for GUARDIAN=${GUARDIAN}" >&2
  exit 1
fi
if [[ "${GUARDIAN_CODE}" == "0x" ]]; then
  if [[ "${REQUIRE_GUARDIAN_CONTRACT:-0}" == "1" ]]; then
    echo "ERROR: GUARDIAN=${GUARDIAN} is an EOA; REQUIRE_GUARDIAN_CONTRACT=1 expects a contract address (recommended multisig)." >&2
    exit 1
  fi
  echo "WARN: GUARDIAN=${GUARDIAN} appears to be an EOA. For production, use a multisig contract guardian."
fi

# Optional safety: verify STABLE_DECIMALS matches on-chain decimals()
if [[ -z "${SKIP_DECIMALS_CHECK:-}" ]]; then
  echo "==> Checking stable decimals for ${STABLE} ..."
  ONCHAIN_DECIMALS="$(cast call "${STABLE}" "decimals()(uint8)" --rpc-url "${RPC_URL}" 2>/dev/null || true)"
  if [[ -z "${ONCHAIN_DECIMALS}" ]]; then
    echo "ERROR: failed to read decimals() for STABLE=${STABLE}. If this token does not implement decimals(), set SKIP_DECIMALS_CHECK=1." >&2
    exit 1
  fi
  if [[ "${ONCHAIN_DECIMALS}" != "${STABLE_DECIMALS}" ]]; then
    echo "ERROR: STABLE_DECIMALS=${STABLE_DECIMALS} does not match on-chain decimals()=${ONCHAIN_DECIMALS} for STABLE=${STABLE}" >&2
    exit 1
  fi
fi

OUT_PATH="./scripts/out/deploy.${CHAIN}.json"
mkdir -p ./scripts/out
export DEPLOY_JSON_PATH="${OUT_PATH}"

COMMON_ARGS=(--rpc-url "${RPC_URL}" --private-key "${PRIVATE_KEY}")
if [[ "$VERIFY" -eq 1 ]]; then
  COMMON_ARGS+=(--verify)
fi
COMMON_ARGS+=(--broadcast)

echo "==> Deploying hook (scripts/foundry/DeployHook.s.sol) using ${HOOK_CONF}"
forge script scripts/foundry/DeployHook.s.sol "${COMMON_ARGS[@]}"

echo "==> Wrote ${OUT_PATH}"
