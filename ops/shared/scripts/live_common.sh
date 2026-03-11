#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

if [[ -z "${OPS_NETWORK:-}" ]]; then
  echo "ERROR: OPS_NETWORK must be set before sourcing ops/shared/scripts/live_common.sh" >&2
  exit 1
fi

OPS_NETWORK_DIR="${ROOT_DIR}/ops/${OPS_NETWORK}"
DEFAULTS_ENV="${OPS_NETWORK_DIR}/config/defaults.env"
DEPLOY_ENV_DEFAULT="${OPS_NETWORK_DIR}/config/deploy.env"
STATE_PATH_DEFAULT="${OPS_NETWORK_DIR}/out/state/${OPS_NETWORK}.addresses.json"
DRIVER_STATE_PATH_DEFAULT="${OPS_NETWORK_DIR}/out/state/${OPS_NETWORK}.drivers.json"
PREFLIGHT_REPORT_DEFAULT="${OPS_NETWORK_DIR}/out/reports/preflight.${OPS_NETWORK}.json"
INSPECT_REPORT_DEFAULT="${OPS_NETWORK_DIR}/out/state/inspect.${OPS_NETWORK}.json"
FULL_REPORT_DEFAULT="${OPS_NETWORK_DIR}/out/reports/full.${OPS_NETWORK}.json"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }
}

run_forge_cmd() {
  "$@"
}

ensure_dirs() {
  mkdir -p "${OPS_NETWORK_DIR}/out/reports" "${OPS_NETWORK_DIR}/out/state" "${OPS_NETWORK_DIR}/out/logs"
}

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || { echo "ERROR: config file not found: $file" >&2; exit 1; }
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}

assert_frozen_deploy_env() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  if grep -Eq '^[[:space:]]*DEPLOY_[A-Z0-9_]+=.*[$]' "$file"; then
    echo "ERROR: deploy snapshot must use literal DEPLOY_* values only: $file" >&2
    return 1
  fi
}

load_state_env() {
  local state_path="${OPS_STATE_PATH:-$STATE_PATH_DEFAULT}"
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
  local state_path="${OPS_DRIVERS_STATE_PATH:-$DRIVER_STATE_PATH_DEFAULT}"
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

load_live_config() {
  local scenario="$1"
  load_env_file "$DEFAULTS_ENV"
  local scenario_env="${OPS_NETWORK_DIR}/config/scenarios/${scenario}.env"
  [[ -f "$scenario_env" ]] && load_env_file "$scenario_env"
  [[ -f "${ROOT_DIR}/.env" ]] && load_env_file "${ROOT_DIR}/.env"
  local deploy_env="${OPS_DEPLOY_ENV:-$DEPLOY_ENV_DEFAULT}"
  [[ -f "$deploy_env" ]] && assert_frozen_deploy_env "$deploy_env" && load_env_file "$deploy_env"

  local network_prefix network_pk_var network_owner_var
  network_prefix="$(printf '%s' "${OPS_NETWORK}" | tr '[:lower:]' '[:upper:]')"
  network_pk_var="${network_prefix}_PRIVATE_KEY"
  network_owner_var="${network_prefix}_OWNER"

  if [[ -z "${PRIVATE_KEY:-}" ]]; then
    if [[ -n "${!network_pk_var:-}" ]]; then
      export PRIVATE_KEY="${!network_pk_var}"
    elif [[ -n "${DEFAULT_PRIVATE_KEY:-}" ]]; then
      export PRIVATE_KEY="$DEFAULT_PRIVATE_KEY"
    fi
  fi

  if [[ -z "${OWNER:-}" ]]; then
    if [[ -n "${!network_owner_var:-}" ]]; then
      export OWNER="${!network_owner_var}"
    elif [[ -n "${DEFAULT_OWNER:-}" ]]; then
      export OWNER="$DEFAULT_OWNER"
    fi
  fi

  export OPS_RUNTIME="live"
  export OPS_NETWORK_DIR
  export OPS_DEPLOY_ENV="${OPS_DEPLOY_ENV:-$deploy_env}"
  export OPS_STATE_PATH="${OPS_STATE_PATH:-$STATE_PATH_DEFAULT}"
  export OPS_DRIVERS_STATE_PATH="${OPS_DRIVERS_STATE_PATH:-$DRIVER_STATE_PATH_DEFAULT}"
  export OPS_PREFLIGHT_REPORT="${OPS_PREFLIGHT_REPORT:-$PREFLIGHT_REPORT_DEFAULT}"
  export OPS_INSPECT_REPORT="${OPS_INSPECT_REPORT:-$INSPECT_REPORT_DEFAULT}"
  export OPS_FULL_REPORT="${OPS_FULL_REPORT:-$FULL_REPORT_DEFAULT}"
  ensure_dirs
  load_state_env
  load_driver_state_env
}

forge_live() {
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

ensure_live_drivers() {
  if [[ "${OPS_FORCE_SIMULATION:-0}" == "1" ]]; then
    return 0
  fi

  forge_live "ops/shared/foundry/EnsureDriversLive.s.sol:EnsureDriversLive" "broadcast"
  unset SWAP_DRIVER LIQUIDITY_DRIVER
  load_driver_state_env

  if [[ -z "${SWAP_DRIVER:-}" || -z "${LIQUIDITY_DRIVER:-}" ]]; then
    echo "ERROR: SWAP_DRIVER/LIQUIDITY_DRIVER missing after ensure" >&2
    return 1
  fi
}

require_live_preflight() {
  if [[ "${OPS_FORCE_SIMULATION:-0}" == "1" ]]; then
    return 0
  fi
  if [[ "${OPS_REQUIRE_PREFLIGHT:-1}" != "1" ]]; then
    echo "[ops] preflight gate disabled (OPS_REQUIRE_PREFLIGHT=${OPS_REQUIRE_PREFLIGHT})"
    return 0
  fi

  forge_live "ops/shared/foundry/PreflightLive.s.sol:PreflightLive" "readonly"
}
