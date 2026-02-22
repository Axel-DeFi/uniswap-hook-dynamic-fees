#!/usr/bin/env bash
set -euo pipefail

# 24h user-activity simulation on an Anvil fork.
# The script drives swaps and fast-forwards time to validate hook invariants
# across a full day without waiting in real time.
#
# Usage:
#   ./scripts/tools/simulate_24h_fork.sh --chain ethereum
#   ./scripts/tools/simulate_24h_fork.sh --chain ethereum --swaps 288 --step-seconds 300

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

CHAIN="ethereum"
FORK_URL=""
ANVIL_PORT="8547"
SWAPS="288"
STEP_SECONDS="300"
WRAP_ETH="0.3"
SMALL_TOKEN0_IN="1000000"         # 1 token0 unit for 6-decimals USDC-like token
BIG_TOKEN0_IN="5000000"           # 5 token0 units for 6-decimals USDC-like token
BIG_EVERY="8"
SWAP_TEST_ADDRESS="${SWAP_TEST_ADDRESS:-}"
SEED_TOKEN0_AMOUNT="${SEED_TOKEN0_AMOUNT:-5000000000}" # 5,000 token0 with 6 decimals for USDC-like tokens
SEED_TOKEN0_BALANCE_SLOT="${SEED_TOKEN0_BALANCE_SLOT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --fork-url) FORK_URL="${2:-}"; shift 2 ;;
    --anvil-port) ANVIL_PORT="${2:-}"; shift 2 ;;
    --swaps) SWAPS="${2:-}"; shift 2 ;;
    --step-seconds) STEP_SECONDS="${2:-}"; shift 2 ;;
    --wrap-eth) WRAP_ETH="${2:-}"; shift 2 ;;
    --small-token0-in) SMALL_TOKEN0_IN="${2:-}"; shift 2 ;;
    --big-token0-in) BIG_TOKEN0_IN="${2:-}"; shift 2 ;;
    --big-every) BIG_EVERY="${2:-}"; shift 2 ;;
    --swap-test-address) SWAP_TEST_ADDRESS="${2:-}"; shift 2 ;;
    --seed-token0-amount) SEED_TOKEN0_AMOUNT="${2:-}"; shift 2 ;;
    --seed-token0-balance-slot) SEED_TOKEN0_BALANCE_SLOT="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

load_pool_config "${CHAIN}"
resolve_private_key
resolve_rpc

if [[ -z "${FORK_URL}" ]]; then
  FORK_URL="${RPC_URL}"
fi

if [[ -z "${HOOK_ADDRESS:-}" || -z "${TOKEN0:-}" || -z "${TOKEN1:-}" || -z "${TICK_SPACING:-}" ]]; then
  echo "ERROR: HOOK_ADDRESS, TOKEN0, TOKEN1, TICK_SPACING must be set in pool config." >&2
  exit 1
fi

if [[ -z "${SWAP_TEST_ADDRESS}" ]]; then
  SWAP_TEST_ADDRESS="$(default_swap_test_address "${CHAIN}")"
fi
if [[ -z "${SWAP_TEST_ADDRESS}" ]]; then
  echo "ERROR: swap helper unknown for chain=${CHAIN}; pass --swap-test-address." >&2
  exit 1
fi

FORK_RPC="http://127.0.0.1:${ANVIL_PORT}"
ANVIL_LOG="$(mktemp)"

cleanup() {
  if [[ -n "${ANVIL_PID:-}" ]]; then
    kill "${ANVIL_PID}" >/dev/null 2>&1 || true
  fi
  rm -f "${ANVIL_LOG}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Starting anvil fork on ${FORK_RPC}"
/bin/zsh -lc "anvil --fork-url '${FORK_URL}' --port '${ANVIL_PORT}'" >"${ANVIL_LOG}" 2>&1 &
ANVIL_PID=$!
sleep 1

if ! ps -p "${ANVIL_PID}" >/dev/null 2>&1; then
  echo "ERROR: failed to start anvil. Log:" >&2
  sed -n '1,120p' "${ANVIL_LOG}" >&2
  exit 1
fi

cast_rpc_fork() {
  NO_PROXY='*' no_proxy='*' HTTPS_PROXY='' HTTP_PROXY='' ALL_PROXY='' cast "$@"
}

send_fork() {
  cast_rpc_fork send --rpc-url "${FORK_RPC}" --private-key "${PRIVATE_KEY}" "$@"
}

call_fork() {
  cast_rpc_fork call --rpc-url "${FORK_RPC}" "$@"
}

DEPLOYER="$(cast_rpc_fork wallet address --private-key "${PRIVATE_KEY}" | awk '{print $1}')"
if [[ -z "${DEPLOYER}" ]]; then
  echo "ERROR: failed to derive deployer from PRIVATE_KEY." >&2
  exit 1
fi

TOKENS=($(canonical_token_order "${TOKEN0}" "${TOKEN1}"))
C0="${TOKENS[0]}"
C1="${TOKENS[1]}"

POOL_KEY="(${C0},${C1},8388608,${TICK_SPACING},${HOOK_ADDRESS})"
SWAP_SIG="swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)(bytes32)"

echo "==> Basic checks"
HOOK_CODE="$(cast_rpc_fork code "${HOOK_ADDRESS}" --rpc-url "${FORK_RPC}")"
if [[ "${#HOOK_CODE}" -le 3 ]]; then
  echo "ERROR: no code at HOOK_ADDRESS on fork." >&2
  exit 1
fi
SWAP_HELPER_CODE="$(cast_rpc_fork code "${SWAP_TEST_ADDRESS}" --rpc-url "${FORK_RPC}")"
if [[ "${#SWAP_HELPER_CODE}" -le 3 ]]; then
  echo "ERROR: no code at SWAP_TEST_ADDRESS on fork." >&2
  exit 1
fi

# Optional fork-only convenience: seed token0 balance when wallet has none.
TOKEN0_BALANCE="$(call_fork "${C0}" "balanceOf(address)(uint256)" "${DEPLOYER}" | awk '{print $1}')"
TOKEN0_LC="$(printf '%s' "${C0}" | tr '[:upper:]' '[:lower:]')"
if [[ "${TOKEN0_BALANCE}" == "0" && "${SEED_TOKEN0_AMOUNT}" != "0" ]]; then
  if [[ -z "${SEED_TOKEN0_BALANCE_SLOT}" && "${CHAIN}" == "ethereum" && "${TOKEN0_LC}" == "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238" ]]; then
    SEED_TOKEN0_BALANCE_SLOT="9"
  fi
  if [[ -n "${SEED_TOKEN0_BALANCE_SLOT}" ]]; then
    echo "==> Seeding token0 balance on fork via storage slot ${SEED_TOKEN0_BALANCE_SLOT}"
    BAL_INDEX="$(cast index address "${DEPLOYER}" "${SEED_TOKEN0_BALANCE_SLOT}")"
    BAL_HEX="$(printf "0x%064x" "${SEED_TOKEN0_AMOUNT}")"
    cast_rpc_fork rpc --rpc-url "${FORK_RPC}" anvil_setStorageAt "${C0}" "${BAL_INDEX}" "${BAL_HEX}" >/dev/null
    TOKEN0_BALANCE="$(call_fork "${C0}" "balanceOf(address)(uint256)" "${DEPLOYER}" | awk '{print $1}')"
    if [[ "${TOKEN0_BALANCE}" == "0" ]]; then
      echo "ERROR: failed to seed token0 balance on fork." >&2
      exit 1
    fi
  fi
fi

echo "==> Wrap ${WRAP_ETH} ETH to WETH"
send_fork --value "${WRAP_ETH}ether" "${C1}" "deposit()" >/dev/null

echo "==> Approve token0/token1 to swap helper"
MAX_UINT="0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
send_fork "${C0}" "approve(address,uint256)(bool)" "${SWAP_TEST_ADDRESS}" "${MAX_UINT}" >/dev/null
send_fork "${C1}" "approve(address,uint256)(bool)" "${SWAP_TEST_ADDRESS}" "${MAX_UINT}" >/dev/null

FLOOR_IDX="$(call_fork "${HOOK_ADDRESS}" "floorIdx()(uint8)" | awk '{print $1}')"
CAP_IDX="$(call_fork "${HOOK_ADDRESS}" "capIdx()(uint8)" | awk '{print $1}')"
INITIAL_IDX="$(call_fork "${HOOK_ADDRESS}" "initialFeeIdx()(uint8)" | awk '{print $1}')"
PERIOD_SECONDS="$(call_fork "${HOOK_ADDRESS}" "periodSeconds()(uint32)" | awk '{print $1}')"

if [[ -z "${PERIOD_SECONDS}" || "${PERIOD_SECONDS}" -le 0 ]]; then
  echo "ERROR: invalid periodSeconds from hook." >&2
  exit 1
fi

read_state() {
  local fee out pv ema ps idx dir paused pending
  fee="$(call_fork "${HOOK_ADDRESS}" "currentFeeBips()(uint24)" | awk '{print $1}')"
  out="$(call_fork "${HOOK_ADDRESS}" "unpackedState()(uint64,uint96,uint32,uint8,uint8)")"
  pv="$(printf '%s\n' "${out}" | sed -n '1p' | awk '{print $1}')"
  ema="$(printf '%s\n' "${out}" | sed -n '2p' | awk '{print $1}')"
  ps="$(printf '%s\n' "${out}" | sed -n '3p' | awk '{print $1}')"
  idx="$(printf '%s\n' "${out}" | sed -n '4p' | awk '{print $1}')"
  dir="$(printf '%s\n' "${out}" | sed -n '5p' | awk '{print $1}')"
  paused="$(call_fork "${HOOK_ADDRESS}" "isPaused()(bool)" | awk '{print $1}')"
  pending="$(call_fork "${HOOK_ADDRESS}" "isPauseApplyPending()(bool)" | awk '{print $1}')"
  echo "${fee}|${pv}|${ema}|${ps}|${idx}|${dir}|${paused}|${pending}"
}

advance_time() {
  local step="$1"
  local now next
  now="$(cast_rpc_fork block --rpc-url "${FORK_RPC}" latest --field timestamp | awk '{print $1}')"
  next=$((now + step))
  cast_rpc_fork rpc --rpc-url "${FORK_RPC}" evm_setNextBlockTimestamp "${next}" >/dev/null
  cast_rpc_fork rpc --rpc-url "${FORK_RPC}" evm_mine >/dev/null
}

validate_invariants() {
  local fee="$1" idx="$2" paused="$3" pending="$4"
  if (( idx < FLOOR_IDX || idx > CAP_IDX )); then
    echo "ERROR: feeIdx=${idx} out of bounds [${FLOOR_IDX}, ${CAP_IDX}]" >&2
    exit 1
  fi
  local expected_fee
  expected_fee="$(call_fork "${HOOK_ADDRESS}" "feeTiers(uint256)(uint24)" "${idx}" | awk '{print $1}')"
  if [[ "${fee}" != "${expected_fee}" ]]; then
    echo "ERROR: fee mismatch currentFee=${fee} expectedByIdx=${expected_fee} idx=${idx}" >&2
    exit 1
  fi
  if [[ "${paused}" != "false" ]]; then
    echo "ERROR: hook unexpectedly paused during activity simulation." >&2
    exit 1
  fi
  if [[ "${pending}" != "false" ]]; then
    echo "ERROR: pauseApplyPending unexpectedly true during activity simulation." >&2
    exit 1
  fi
}

echo "==> Running ${SWAPS} swaps with time travel step=${STEP_SECONDS}s (total=$((SWAPS * STEP_SECONDS))s)"

INITIAL_STATE="$(read_state)"
IFS='|' read -r START_FEE START_PV START_EMA START_PS START_IDX START_DIR START_PAUSED START_PENDING <<<"${INITIAL_STATE}"
validate_invariants "${START_FEE}" "${START_IDX}" "${START_PAUSED}" "${START_PENDING}"

UP=0
DOWN=0
FLAT=0
MIN_IDX="${START_IDX}"
MAX_IDX="${START_IDX}"
ERR=0

for ((i=1; i<=SWAPS; i++)); do
  BEFORE="$(read_state)"
  IFS='|' read -r B_FEE _ _ B_PS B_IDX _ B_PAUSED B_PENDING <<<"${BEFORE}"
  validate_invariants "${B_FEE}" "${B_IDX}" "${B_PAUSED}" "${B_PENDING}"

  AMOUNT="${SMALL_TOKEN0_IN}"
  if (( i % BIG_EVERY == 0 )); then
    AMOUNT="${BIG_TOKEN0_IN}"
  fi

  OUT="$(send_fork "${SWAP_TEST_ADDRESS}" "${SWAP_SIG}" "${POOL_KEY}" "(true,-${AMOUNT},4295128740)" "(false,false)" 0x 2>&1)" || {
    echo "ERROR: swap failed on step=${i}" >&2
    echo "${OUT}" >&2
    ERR=1
    break
  }

  advance_time "${STEP_SECONDS}"

  AFTER="$(read_state)"
  IFS='|' read -r A_FEE _ _ A_PS A_IDX _ A_PAUSED A_PENDING <<<"${AFTER}"
  validate_invariants "${A_FEE}" "${A_IDX}" "${A_PAUSED}" "${A_PENDING}"

  if (( A_IDX > B_IDX )); then
    UP=$((UP + 1))
  elif (( A_IDX < B_IDX )); then
    DOWN=$((DOWN + 1))
  else
    FLAT=$((FLAT + 1))
  fi

  if (( A_IDX < MIN_IDX )); then MIN_IDX="${A_IDX}"; fi
  if (( A_IDX > MAX_IDX )); then MAX_IDX="${A_IDX}"; fi
  if (( A_PS < B_PS )); then
    echo "ERROR: periodStart moved backwards at step=${i}" >&2
    ERR=1
    break
  fi
done

if (( ERR != 0 )); then
  exit 1
fi

FINAL_STATE="$(read_state)"
IFS='|' read -r FINAL_FEE FINAL_PV FINAL_EMA FINAL_PS FINAL_IDX FINAL_DIR FINAL_PAUSED FINAL_PENDING <<<"${FINAL_STATE}"
validate_invariants "${FINAL_FEE}" "${FINAL_IDX}" "${FINAL_PAUSED}" "${FINAL_PENDING}"

echo
echo "===== 24h Fork Activity Report ====="
echo "Chain: ${CHAIN}"
echo "Fork URL: ${FORK_URL}"
echo "Fork RPC: ${FORK_RPC}"
echo "Hook: ${HOOK_ADDRESS}"
echo "Swap helper: ${SWAP_TEST_ADDRESS}"
echo "Deployer: ${DEPLOYER}"
echo "Periods simulated: ${SWAPS}"
echo "Step seconds: ${STEP_SECONDS}"
echo "Virtual duration: $((SWAPS * STEP_SECONDS)) seconds"
echo "Pool periodSeconds (hook): ${PERIOD_SECONDS}"
echo
echo "Start: feeBips=${START_FEE} feeIdx=${START_IDX} periodVolUsd6=${START_PV} emaUsd6=${START_EMA} lastDir=${START_DIR}"
echo "End:   feeBips=${FINAL_FEE} feeIdx=${FINAL_IDX} periodVolUsd6=${FINAL_PV} emaUsd6=${FINAL_EMA} lastDir=${FINAL_DIR}"
echo
echo "Dynamics:"
echo "  feeIdx up moves:   ${UP}"
echo "  feeIdx down moves: ${DOWN}"
echo "  feeIdx flat steps: ${FLAT}"
echo "  feeIdx min/max:    ${MIN_IDX}/${MAX_IDX} (bounds ${FLOOR_IDX}/${CAP_IDX})"
echo
echo "Invariant checks:"
echo "  [OK] feeIdx always within [floorIdx, capIdx]"
echo "  [OK] currentFeeBips always matches feeTiers(feeIdx)"
echo "  [OK] paused=false and pauseApplyPending=false throughout simulation"
echo "  [OK] periodStart monotonic non-decreasing"
echo "===== Simulation successful ====="
