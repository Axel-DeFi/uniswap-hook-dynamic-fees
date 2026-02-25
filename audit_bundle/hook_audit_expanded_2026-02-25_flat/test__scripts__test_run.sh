#!/bin/sh
set -eu

# Unified test runner (portable: works with macOS default /bin/sh).
#
# Single-mode runner:
#   - Runs the FULL (heavy) test suite every time.
#   - No fast/full switch to avoid branching logic.
#
# Usage:
#   ./test/scripts/test_run.sh <local|sepolia|prod> [chain] [--dry-run] [--anvil-port <port>]
#
# Env overrides (optional):
#   FOUNDRY_FUZZ_RUNS         default: 20000
#   FOUNDRY_INVARIANT_RUNS    default: 1024
#   FOUNDRY_INVARIANT_DEPTH   default: 512

print_help() {
  cat <<'EOF'
Usage:
  ./test/scripts/test_run.sh <local|sepolia|prod> [chain] [--dry-run] [--anvil-port <port>]

Contours:
  local    Runs on Anvil fork of Ethereum Sepolia (uses config/hook.local.conf)
  sepolia  Runs against live Ethereum Sepolia (uses config/hook.sepolia.conf)
  prod     Runs against live target chain (uses config/hook.<chain>.conf, default chain = ethereum)

Options:
  --dry-run         Skip --broadcast for deployment scripts
  --anvil-port N    Use port N for anvil (local contour only). Default: 8545

Env overrides:
  FOUNDRY_FUZZ_RUNS         default: 20000
  FOUNDRY_INVARIANT_RUNS    default: 1024
  FOUNDRY_INVARIANT_DEPTH   default: 512

Examples:
  ./test/scripts/test_run.sh local
  ./test/scripts/test_run.sh local --dry-run
  ./test/scripts/test_run.sh sepolia --dry-run
  ./test/scripts/test_run.sh prod ethereum --dry-run
EOF
}

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
die() { echo "Error: $*" >&2; exit 1; }

[ $# -ge 1 ] || { print_help; exit 0; }

CONTOUR="$(lower "$1")"
shift 1

CHAIN="ethereum"
CHAIN_SET=0
DRY_RUN_FLAG=0
ANVIL_PORT="8545"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|dry) DRY_RUN_FLAG=1; shift ;;
    --anvil-port) [ $# -ge 2 ] || die "Missing value for --anvil-port"; ANVIL_PORT="$2"; shift 2 ;;
    --chain) [ $# -ge 2 ] || die "Missing value for --chain"; CHAIN="$2"; CHAIN_SET=1; shift 2 ;;
    --help|-h) print_help; exit 0 ;;
    *)
      if [ "$CHAIN_SET" -eq 0 ]; then
        CHAIN="$1"; CHAIN_SET=1; shift
      else
        die "Unknown argument: $1"
      fi
      ;;
  esac
done

CHAIN="$(lower "$CHAIN")"

case "$CONTOUR" in local|sepolia|prod) : ;; *) die "Invalid contour: $CONTOUR" ;; esac

CFG=""
case "$CONTOUR" in
  local)   CFG="./config/hook.local.conf" ;;
  sepolia) CFG="./config/hook.sepolia.conf" ;;
  prod)    CFG="./config/hook.${CHAIN}.conf" ;;
esac
[ -f "$CFG" ] || die "Config not found: $CFG"

# Auto-load .env from repo root if present.
if [ -f "./.env" ]; then
  # shellcheck disable=SC1091
  . "./.env"
fi

# Source config (dotenv-style)
set -a
# shellcheck disable=SC1090
. "$CFG"
set +a

: "${FOUNDRY_FUZZ_RUNS:=20000}"
: "${FOUNDRY_INVARIANT_RUNS:=1024}"
: "${FOUNDRY_INVARIANT_DEPTH:=512}"
export FOUNDRY_FUZZ_RUNS FOUNDRY_INVARIANT_RUNS FOUNDRY_INVARIANT_DEPTH

VERBOSITY="-vv"

echo "==> Contour:  $CONTOUR"
echo "==> Chain:    $CHAIN"
echo "==> Config:   $CFG"
echo "==> Fuzz runs: ${FOUNDRY_FUZZ_RUNS}"
echo "==> Invariant runs: ${FOUNDRY_INVARIANT_RUNS}"
echo "==> Invariant depth: ${FOUNDRY_INVARIANT_DEPTH}"
echo "==> Verbosity: ${VERBOSITY}"

forge fmt --check
# NOTE: We do NOT pass --invariant-runs/--invariant-depth flags; some forge versions reject them.
forge test --gas-report --fuzz-runs "${FOUNDRY_FUZZ_RUNS}" ${VERBOSITY}

broadcast_flag="--broadcast"
if [ "$DRY_RUN_FLAG" -eq 1 ]; then
  broadcast_flag=""
  echo "==> DRY-RUN: skipping --broadcast for deployment scripts"
fi

run_deploy_scripts() {
  chain_name="$1"
  rpc="$2"
  pk="$3"

  echo "==> Deploy hook"
  ./scripts/deploy_hook.sh --chain "$chain_name" --rpc-url "$rpc" --private-key "$pk" $broadcast_flag

  echo "==> Create+init pool"
  ./scripts/create_pool.sh --chain "$chain_name" --rpc-url "$rpc" --private-key "$pk" $broadcast_flag
}

if [ "$CONTOUR" = "local" ]; then
  fork_url="${FORK_URL:-}"
  if [ -z "$fork_url" ] && [ -f "./config/hook.sepolia.conf" ]; then
    # best-effort fallback to sepolia RPC_URL for forking
    # shellcheck disable=SC1090
    . "./config/hook.sepolia.conf" || true
    fork_url="${RPC_URL:-}"
  fi
  [ -n "$fork_url" ] || die "FORK_URL is missing in config/hook.local.conf (or hook.sepolia.conf RPC_URL fallback)."

  rpc="http://127.0.0.1:${ANVIL_PORT}"

  # Use configured PRIVATE_KEY if present, else Anvil default key #0.
  anvil_pk_default="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  pk="${PRIVATE_KEY:-$anvil_pk_default}"

  echo "==> Starting Anvil fork on $rpc (forking Sepolia)"
  anvil --fork-url "$fork_url" --port "$ANVIL_PORT" --chain-id 31337 --silent &
  anvil_pid=$!
  trap 'kill "$anvil_pid" 2>/dev/null || true' EXIT INT TERM

  run_deploy_scripts "local" "$rpc" "$pk"
elif [ "$CONTOUR" = "sepolia" ]; then
  [ -n "${RPC_URL:-}" ] || die "Missing RPC_URL in $CFG"
  [ -n "${PRIVATE_KEY:-}" ] || die "Missing PRIVATE_KEY in $CFG (can be set via DEFAULT_PRIVATE_KEY)"
  run_deploy_scripts "sepolia" "$RPC_URL" "$PRIVATE_KEY"
else
  [ -n "${RPC_URL:-}" ] || die "Missing RPC_URL in $CFG"
  [ -n "${PRIVATE_KEY:-}" ] || die "Missing PRIVATE_KEY in $CFG (can be set via DEFAULT_PRIVATE_KEY)"
  run_deploy_scripts "$CHAIN" "$RPC_URL" "$PRIVATE_KEY"
fi

echo "==> Done: C1..E6 executed in contour=$CONTOUR"
