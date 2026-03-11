#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OPS_LOCAL_DIR="${ROOT_DIR}/ops/local"
DEFAULTS_ENV="${OPS_LOCAL_DIR}/config/defaults.env"
DEPLOY_ENV_DEFAULT="${OPS_LOCAL_DIR}/config/deploy.env"
STATE_PATH_DEFAULT="${OPS_LOCAL_DIR}/out/state/local.addresses.json"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }
}

run_forge_cmd() {
  "$@"
}

ensure_dirs() {
  mkdir -p "${OPS_LOCAL_DIR}/out/reports" "${OPS_LOCAL_DIR}/out/state" "${OPS_LOCAL_DIR}/out/logs"
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
  local state_path="${OPS_LOCAL_STATE_PATH:-$STATE_PATH_DEFAULT}"
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

load_local_config() {
  local scenario="$1"
  load_env_file "$DEFAULTS_ENV"
  local scenario_env="${OPS_LOCAL_DIR}/config/scenarios/${scenario}.env"
  [[ -f "$scenario_env" ]] && load_env_file "$scenario_env"
  [[ -f "${ROOT_DIR}/.env" ]] && load_env_file "${ROOT_DIR}/.env"
  local deploy_env="${OPS_DEPLOY_ENV:-$DEPLOY_ENV_DEFAULT}"
  [[ -f "$deploy_env" ]] && load_env_file "$deploy_env"

  export OPS_RUNTIME="local"
  export OPS_DEPLOY_ENV="${OPS_DEPLOY_ENV:-$deploy_env}"
  export OPS_LOCAL_STATE_PATH="${OPS_LOCAL_STATE_PATH:-$STATE_PATH_DEFAULT}"
  ensure_dirs
  load_state_env
}

forge_local() {
  local script_path="$1"
  local broadcast_mode="$2"

  require_cmd forge
  require_cmd cast
  require_cmd anvil

  export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"
  export no_proxy="${no_proxy:-$NO_PROXY}"
  # Foundry can panic on macOS when reading system proxy settings; pin env to deterministic values.
  export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:9}"
  export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:9}"
  export ALL_PROXY="${ALL_PROXY:-http://127.0.0.1:9}"
  export http_proxy="${http_proxy:-$HTTP_PROXY}"
  export https_proxy="${https_proxy:-$HTTPS_PROXY}"
  export all_proxy="${all_proxy:-$ALL_PROXY}"
  export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-ops}"

  if [[ "${OPS_FORCE_SIMULATION:-0}" == "1" ]]; then
    export OPS_BROADCAST=0
    run_forge_cmd forge script "$script_path"
    return 0
  fi

  local rpc_url="${RPC_URL:-http://127.0.0.1:8545}"
  local broadcast_args=()
  if [[ "$broadcast_mode" == "broadcast" ]]; then
    if [[ -z "${PRIVATE_KEY:-}" ]]; then
      echo "ERROR: PRIVATE_KEY is required for broadcast phase: ${script_path}" >&2
      return 1
    fi
    broadcast_args=(--broadcast)
    export OPS_BROADCAST=1
  else
    export OPS_BROADCAST=0
  fi

  if ((${#broadcast_args[@]})); then
    run_forge_cmd forge script "$script_path" --rpc-url "$rpc_url" "${broadcast_args[@]}"
  else
    run_forge_cmd forge script "$script_path" --rpc-url "$rpc_url"
  fi
}
