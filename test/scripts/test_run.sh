#!/bin/sh
set -eu

# Unified test runner (portable: works with macOS default /bin/sh).
#
# Runs the same suite (C1..E6) in different contours:
#   local   -> Anvil fork of Ethereum Sepolia
#   sepolia -> live Ethereum Sepolia
#   prod    -> live target chain (default: ethereum)
#
# Profiles (only two):
#   fast -> pre-deploy gate
#   full -> deep fuzz/invariants + optional gas snapshot check
#
# Usage:
#   ./test/scripts/test_run.sh <local|sepolia|prod> <fast|full> [chain] [--dry-run] [--anvil-port <port>]

print_help() {
  cat <<'EOF'
Usage:
  ./test/scripts/test_run.sh <local|sepolia|prod> <fast|full> [chain] [--dry-run] [--anvil-port <port>]

Contours:
  local    Runs on Anvil fork of Ethereum Sepolia (uses config/hook.local.conf)
  sepolia  Runs against live Ethereum Sepolia (uses config/hook.sepolia.conf)
  prod     Runs against live target chain (uses config/hook.<chain>.conf, default chain = ethereum)

Profiles:
  fast     Quick pre-deploy gate: fmt + tests + gas report + smoke deploy/init
  full     Deep run: increased fuzz/invariants + gas report + optional gas snapshot check (if .gas-snapshot exists)

Options:
  --dry-run         Skip --broadcast for deployment scripts
  --anvil-port N    Use port N for anvil (local contour only). Default: 8545

Examples:
  ./test/scripts/test_run.sh local fast
  ./test/scripts/test_run.sh local full --anvil-port 8546
  ./test/scripts/test_run.sh sepolia fast --dry-run
  ./test/scripts/test_run.sh prod full ethereum --dry-run
EOF
}

lower() {
  # Portable lowercase
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

die() {
  echo "Error: $*" >&2
  exit 1
}

# --- args ---
[ $# -ge 2 ] || { print_help; exit 0; }

CONTOUR="$(lower "$1")"
PROFILE="$(lower "$2")"
shift 2

CHAIN="ethereum"
CHAIN_SET=0
DRY_RUN_FLAG=0
ANVIL_PORT="8545"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|dry)
      DRY_RUN_FLAG=1
      shift
      ;;
    --anvil-port)
      [ $# -ge 2 ] || die "Missing value for --anvil-port"
      ANVIL_PORT="$2"
      shift 2
      ;;
    --chain)
      [ $# -ge 2 ] || die "Missing value for --chain"
      CHAIN="$2"
      CHAIN_SET=1
      shift 2
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    *)
      if [ "$CHAIN_SET" -eq 0 ]; then
        CHAIN="$1"
        CHAIN_SET=1
        shift
      else
        die "Unknown argument: $1"
      fi
      ;;
  esac
done

CHAIN="$(lower "$CHAIN")"

case "$CONTOUR" in
  local|sepolia|prod) : ;;
  *) die "Invalid contour: $CONTOUR" ;;
esac

case "$PROFILE" in
  fast|full) : ;;
  *) die "Invalid profile: $PROFILE" ;;
esac

# --- config selection ---
CFG=""
case "$CONTOUR" in
  local)   CFG="./config/hook.local.conf" ;;
  sepolia) CFG="./config/hook.sepolia.conf" ;;
  prod)    CFG="./config/hook.${CHAIN}.conf" ;;
esac

[ -f "$CFG" ] || die "Config not found: $CFG"


# Auto-load .env from repo root (if present), so configs can reference DEFAULT_PRIVATE_KEY, DEFAULT_GUARDIAN, etc.
if [ -f "./.env" ]; then
  # shellcheck disable=SC1091
  . "./.env"
fi

# --- validator location (supports move to ./test/scripts) ---
VALIDATOR="./test/scripts/check_config.sh"
if [ ! -x "$VALIDATOR" ]; then
  VALIDATOR="./scripts/check_config.sh"
fi
[ -x "$VALIDATOR" ] || die "Config validator not found (expected ./test/scripts/check_config.sh or ./scripts/check_config.sh)"

# Validate config keys exist
"$VALIDATOR" "$CFG"

# Source config (dotenv-style)
set -a
# shellcheck disable=SC1090
. "$CFG"
set +a

# Base required keys for all contours
required_base="POOL_MANAGER VOLATILE STABLE STABLE_DECIMALS TICK_SPACING INIT_PRICE_USD"
for k in $required_base; do
  # POSIX-safe indirect expansion via eval
  eval "v=\${$k:-}"
  [ -n "$v" ] || die "Missing/empty in $CFG: $k"
done

# Profile tuning (only two)
if [ "$PROFILE" = "full" ]; then
  : "${FOUNDRY_FUZZ_RUNS:=5000}"
  : "${FOUNDRY_INVARIANT_RUNS:=256}"
  : "${FOUNDRY_INVARIANT_DEPTH:=256}"
else
  : "${FOUNDRY_FUZZ_RUNS:=256}"
  : "${FOUNDRY_INVARIANT_RUNS:=64}"
  : "${FOUNDRY_INVARIANT_DEPTH:=64}"
fi
export FOUNDRY_FUZZ_RUNS FOUNDRY_INVARIANT_RUNS FOUNDRY_INVARIANT_DEPTH

echo "==> Contour:  $CONTOUR"
echo "==> Profile:  $PROFILE"
echo "==> Chain:    $CHAIN"
echo "==> Config:   $CFG"

# Gates: formatting + tests + gas visibility
forge fmt --check
forge test --gas-report

# Optional strict gas regression gate (only in full and only if baseline exists)
if [ "$PROFILE" = "full" ] && [ -f ".gas-snapshot" ]; then
  forge snapshot --check
fi

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
  # Local runs on Anvil fork of Sepolia.
  fork_url="${FORK_URL:-}"
  if [ -z "$fork_url" ] && [ -f "./config/hook.sepolia.conf" ]; then
    # best-effort fallback to sepolia RPC_URL for forking
    # shellcheck disable=SC1090
    . "./config/hook.sepolia.conf" || true
    fork_url="${RPC_URL:-}"
  fi
  [ -n "$fork_url" ] || die "FORK_URL is missing in config/hook.local.conf (or hook.sepolia.conf RPC_URL fallback)."

  rpc="http://127.0.0.1:${ANVIL_PORT}"

  # Foundry Anvil default key #0 (deterministic)
  anvil_pk_default="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  pk="${PRIVATE_KEY:-$anvil_pk_default}"

  echo "==> Starting Anvil fork on $rpc (forking Sepolia)"
  anvil --fork-url "$fork_url" --port "$ANVIL_PORT" --chain-id 31337 --silent &
  anvil_pid=$!

  # Ensure cleanup
  trap 'kill "$anvil_pid" 2>/dev/null || true' EXIT INT TERM

  run_deploy_scripts "local" "$rpc" "$pk"
else
  # Live contours
  [ -n "${RPC_URL:-}" ] || die "Missing RPC_URL in $CFG"
  [ -n "${PRIVATE_KEY:-}" ] || die "Missing PRIVATE_KEY in $CFG (can be set via DEFAULT_PRIVATE_KEY)"

  chain_name="$CHAIN"
  if [ "$CONTOUR" = "sepolia" ]; then
    chain_name="sepolia"
  fi

  run_deploy_scripts "$chain_name" "$RPC_URL" "$PRIVATE_KEY"
fi

echo "==> Done: C1..E6 executed in contour=$CONTOUR profile=$PROFILE"
