#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
  set +a
fi

cast_rpc() {
  NO_PROXY='*' no_proxy='*' HTTPS_PROXY='' HTTP_PROXY='' ALL_PROXY='' cast "$@"
}

load_pool_config() {
  local chain="$1"
  local conf="${ROOT_DIR}/config/pool.${chain}.conf"
  if [[ ! -f "${conf}" ]]; then
    conf="${ROOT_DIR}/config/pool.conf"
  fi
  if [[ ! -f "${conf}" ]]; then
    echo "ERROR: pool config not found for chain=${chain}" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "${conf}"
  set +a
}

resolve_private_key() {
  if [[ -n "${PRIVATE_KEY:-}" ]]; then
    return
  fi
  if [[ -n "${ETHEREUM_PRIVATE_KEY:-}" ]]; then
    PRIVATE_KEY="${ETHEREUM_PRIVATE_KEY}"
    return
  fi
  if [[ -n "${DEFAULT_PRIVATE_KEY:-}" ]]; then
    PRIVATE_KEY="${DEFAULT_PRIVATE_KEY}"
    return
  fi
  echo "ERROR: PRIVATE_KEY is not set." >&2
  exit 1
}

resolve_rpc() {
  if [[ -n "${RPC_URL:-}" ]]; then
    return
  fi
  echo "ERROR: RPC_URL is not set." >&2
  exit 1
}

canonical_token_order() {
  local a b
  a="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  b="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  if [[ "${a}" > "${b}" ]]; then
    printf '%s\n%s\n' "$2" "$1"
  else
    printf '%s\n%s\n' "$1" "$2"
  fi
}

default_modify_test_address() {
  local chain="$1"
  case "${chain}" in
    ethereum) echo "0x0C478023803a644c94c4CE1C1e7b9A087e411B0A" ;;
    *) echo "" ;;
  esac
}

default_swap_test_address() {
  local chain="$1"
  case "${chain}" in
    ethereum) echo "0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe" ;;
    arbitrum) echo "0xCc1668F9f046C9b4e742793C85ef5f7bAEb8A160" ;;
    *) echo "" ;;
  esac
}
