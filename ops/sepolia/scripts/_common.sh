#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OPS_SEPOLIA_DIR="${ROOT_DIR}/ops/sepolia"
DEFAULTS_ENV="${OPS_SEPOLIA_DIR}/config/defaults.env"
STATE_PATH_DEFAULT="${OPS_SEPOLIA_DIR}/out/state/sepolia.addresses.json"
DRIVER_STATE_PATH_DEFAULT="${OPS_SEPOLIA_DIR}/out/state/sepolia.drivers.json"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }
}

run_forge_cmd() {
  "$@"
}

ensure_dirs() {
  mkdir -p "${OPS_SEPOLIA_DIR}/out/reports" "${OPS_SEPOLIA_DIR}/out/state" "${OPS_SEPOLIA_DIR}/out/logs"
}

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || { echo "ERROR: config file not found: $file" >&2; exit 1; }
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}

load_state_env() {
  local state_path="${OPS_SEPOLIA_STATE_PATH:-$STATE_PATH_DEFAULT}"
  [[ -f "$state_path" ]] || return 0
  require_cmd jq

  local pm hook vol stab
  pm="$(jq -r '.poolManager // empty' "$state_path")"
  hook="$(jq -r '.hookAddress // empty' "$state_path")"
  vol="$(jq -r '.volatileToken // empty' "$state_path")"
  stab="$(jq -r '.stableToken // empty' "$state_path")"

  [[ -n "${pm}" ]] && export POOL_MANAGER="$pm"
  [[ -n "${hook}" && "${hook}" != "0x0000000000000000000000000000000000000000" ]] && export HOOK_ADDRESS="$hook"
  [[ -n "${vol}" ]] && export VOLATILE="$vol"
  [[ -n "${stab}" ]] && export STABLE="$stab"
}

load_driver_state_env() {
  local state_path="${OPS_SEPOLIA_DRIVERS_STATE_PATH:-$DRIVER_STATE_PATH_DEFAULT}"
  [[ -f "$state_path" ]] || return 0
  require_cmd jq

  local swap_driver liquidity_driver
  swap_driver="$(jq -r '.swapDriver // empty' "$state_path")"
  liquidity_driver="$(jq -r '.liquidityDriver // empty' "$state_path")"

  if [[ -z "${SWAP_DRIVER:-}" && -n "${swap_driver}" && "${swap_driver}" != "0x0000000000000000000000000000000000000000" ]]; then
    export SWAP_DRIVER="$swap_driver"
  fi
  if [[ -z "${LIQUIDITY_DRIVER:-}" && -n "${liquidity_driver}" && "${liquidity_driver}" != "0x0000000000000000000000000000000000000000" ]]; then
    export LIQUIDITY_DRIVER="$liquidity_driver"
  fi
}

load_sepolia_config() {
  local scenario="$1"
  load_env_file "$DEFAULTS_ENV"
  local scenario_env="${OPS_SEPOLIA_DIR}/config/scenarios/${scenario}.env"
  [[ -f "$scenario_env" ]] && load_env_file "$scenario_env"
  [[ -f "${ROOT_DIR}/.env" ]] && load_env_file "${ROOT_DIR}/.env"

  # defaults.env may derive PRIVATE_KEY from DEFAULT_PRIVATE_KEY before .env is loaded.
  if [[ -z "${PRIVATE_KEY:-}" && -n "${DEFAULT_PRIVATE_KEY:-}" ]]; then
    export PRIVATE_KEY="$DEFAULT_PRIVATE_KEY"
  fi

  export OPS_RUNTIME="sepolia"
  export OPS_SEPOLIA_STATE_PATH="${OPS_SEPOLIA_STATE_PATH:-$STATE_PATH_DEFAULT}"
  export OPS_SEPOLIA_DRIVERS_STATE_PATH="${OPS_SEPOLIA_DRIVERS_STATE_PATH:-$DRIVER_STATE_PATH_DEFAULT}"
  ensure_dirs
  load_state_env
  load_driver_state_env
}

forge_sepolia() {
  local script_path="$1"
  local broadcast_mode="$2"

  require_cmd forge

  export NO_PROXY="*"
  export no_proxy="*"
  # Foundry can panic on macOS when reading system proxy settings; pin env to deterministic values.
  export HTTP_PROXY="http://127.0.0.1:9"
  export HTTPS_PROXY="http://127.0.0.1:9"
  export ALL_PROXY="http://127.0.0.1:9"
  export http_proxy="$HTTP_PROXY"
  export https_proxy="$HTTPS_PROXY"
  export all_proxy="$ALL_PROXY"
  export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-ops}"

  if [[ "${OPS_FORCE_SIMULATION:-0}" == "1" ]]; then
    export OPS_BROADCAST=0
    run_forge_cmd forge script "$script_path"
    return 0
  fi

  local rpc_url="${RPC_URL:?RPC_URL is required}"
  local broadcast_args=()
  if [[ "$broadcast_mode" == "broadcast" ]]; then
    if [[ -z "${PRIVATE_KEY:-}" || "${PRIVATE_KEY}" == "1" ]]; then
      echo "ERROR: PRIVATE_KEY is required for broadcast phase: ${script_path}" >&2
      return 1
    fi
    broadcast_args=(--broadcast)
    export OPS_BROADCAST=1
  else
    if [[ -z "${PRIVATE_KEY:-}" ]]; then
      # Read-only flows still need a deployer identity for env decoding paths.
      export PRIVATE_KEY=1
    fi
    export OPS_BROADCAST=0
  fi

  if ((${#broadcast_args[@]})); then
    run_forge_cmd forge script "$script_path" --rpc-url "$rpc_url" "${broadcast_args[@]}"
  else
    run_forge_cmd forge script "$script_path" --rpc-url "$rpc_url"
  fi
}

ensure_sepolia_drivers() {
  if [[ "${OPS_FORCE_SIMULATION:-0}" == "1" ]]; then
    return 0
  fi
  if [[ -n "${SWAP_DRIVER:-}" && -n "${LIQUIDITY_DRIVER:-}" ]]; then
    return 0
  fi

  forge_sepolia "ops/sepolia/foundry/EnsureDriversSepolia.s.sol:EnsureDriversSepolia" "broadcast"
  load_driver_state_env

  if [[ -z "${SWAP_DRIVER:-}" || -z "${LIQUIDITY_DRIVER:-}" ]]; then
    echo "ERROR: SWAP_DRIVER/LIQUIDITY_DRIVER missing after ensure" >&2
    return 1
  fi
}

require_sepolia_preflight() {
  if [[ "${OPS_FORCE_SIMULATION:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "${OPS_REQUIRE_PREFLIGHT:-1}" != "1" ]]; then
    echo "[ops] preflight gate disabled (OPS_REQUIRE_PREFLIGHT=${OPS_REQUIRE_PREFLIGHT})"
    return 0
  fi

  forge_sepolia "ops/sepolia/foundry/PreflightSepolia.s.sol:PreflightSepolia" "readonly"
}
