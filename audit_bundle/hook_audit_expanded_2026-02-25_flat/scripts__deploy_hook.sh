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
#   INITIAL_FEE_IDX, FLOOR_IDX, CAP_IDX
#   PERIOD_SECONDS, EMA_PERIODS, DEADBAND_BPS, LULL_RESET_SECONDS
#   PAUSE_FEE_IDX
#
# Guardian behavior:
#   - If GUARDIAN is empty after sourcing config + .env, it defaults to the deployer address.
#   - If REQUIRE_GUARDIAN_CONTRACT=1, deployment fails when GUARDIAN is an EOA.

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
required=(POOL_MANAGER VOLATILE STABLE STABLE_DECIMALS TICK_SPACING INITIAL_FEE_IDX FLOOR_IDX CAP_IDX PERIOD_SECONDS EMA_PERIODS DEADBAND_BPS LULL_RESET_SECONDS PAUSE_FEE_IDX)
for k in "${required[@]}"; do
  if [[ -z "${!k:-}" ]]; then
    echo "ERROR: missing $k in $HOOK_CONF" >&2
    exit 1
  fi
done

# Default guardian to deployer if empty
if [[ -z "${GUARDIAN:-}" ]]; then
  GUARDIAN="$(cast wallet address --private-key "${PRIVATE_KEY}" | awk '{print $1}')"
  export GUARDIAN
  echo "==> GUARDIAN not set; defaulting to deployer: ${GUARDIAN}"
fi

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
