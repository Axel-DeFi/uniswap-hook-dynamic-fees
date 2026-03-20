#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF2'
Usage:
  ./scripts/collect_hook_diagnostics.sh --chain <chain>

Example:
  ./scripts/collect_hook_diagnostics.sh --chain optimism
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required command not found: $1" >&2
    exit 1
  }
}

require_cmd cast
require_cmd psql
require_cmd tar
require_cmd sed
require_cmd awk
require_cmd grep
require_cmd find
require_cmd mkdir
require_cmd cp
require_cmd date

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/ops/${CHAIN}/config"
DEFAULTS_ENV="${CONFIG_DIR}/defaults.env"
DEPLOY_ENV="${CONFIG_DIR}/deploy.env"
ROOT_ENV="${PROJECT_ROOT}/.env"
SHOW_CONFIG_SCRIPT="${SCRIPT_DIR}/show_hook_config.sh"

[[ -d "$CONFIG_DIR" ]] || {
  echo "Error: config dir not found: $CONFIG_DIR" >&2
  exit 1
}

[[ -f "$DEFAULTS_ENV" ]] || {
  echo "Error: defaults env not found: $DEFAULTS_ENV" >&2
  exit 1
}

read_env_value() {
  local file="$1"
  local key="$2"

  [[ -f "$file" ]] || return 0

  awk -F= -v key="$key" '
    $0 ~ "^[[:space:]]*" key "=" {
      sub(/^[[:space:]]*[^=]+=/, "", $0)
      sub(/^[[:space:]]*/, "", $0)
      sub(/[[:space:]]*$/, "", $0)
      if ($0 ~ /^".*"$/ || $0 ~ /^'\''.*'\''$/) {
        print substr($0, 2, length($0) - 2)
      } else {
        print $0
      }
      exit
    }
  ' "$file"
}

first_nonempty() {
  local v
  for v in "$@"; do
    if [[ -n "${v:-}" ]]; then
      echo "$v"
      return 0
    fi
  done
  echo ""
}

redact_db_url() {
  local url="$1"
  if [[ -z "$url" ]]; then
    echo ""
    return 0
  fi
  echo "$url" | sed -E 's#(postgres(ql)?://[^:/@]+:)[^@]+@#\1***@#'
}

sanitize_root_env() {
  local src="$1"
  local dst="$2"

  [[ -f "$src" ]] || return 0

  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*(DATABASE_URL|PGHOST|PGPORT|PGDATABASE|PGUSER|PGSERVICE|PGPASSFILE)=/ { print; next }
    /^[[:space:]]*(HOOK_ADDRESS|RPC_URL|POOL_ID|POOL_MANAGER|OWNER|HOOK_DEPLOY_TX|POOL_INIT_TX)=/ { print; next }
  ' "$src" \
    | sed -E 's#(DATABASE_URL=postgres(ql)?://[^:/@]+:)[^@]+@#\1***@#' \
    > "$dst"
}

copy_if_exists() {
  local src="$1"
  local dst="$2"
  [[ -f "$src" ]] && cp "$src" "$dst"
}

warn() {
  echo "$1" >> "$WORK_DIR/logs/WARNINGS.txt"
}

try_cast_scalar() {
  local sig="$1"
  cast call "$HOOK" "$sig" --rpc-url "$RPC_URL" 2>/dev/null | awk 'NF { print $1; exit }' || true
}

try_cast_multiline() {
  local sig="$1"
  cast call "$HOOK" "$sig" --rpc-url "$RPC_URL" 2>/dev/null \
    | sed -E 's/[[:space:]]+\[[^]]+\]//g' \
    | sed '/^[[:space:]]*$/d' || true
}

run_psql_command() {
  local sql="$1"
  psql "${PSQL_ARGS[@]}" -v ON_ERROR_STOP=1 -c "$sql"
}

run_psql_file() {
  local sql_file="$1"
  psql "${PSQL_ARGS[@]}" -v ON_ERROR_STOP=1 -f "$sql_file"
}

detect_table_schema() {
  local table="$1"
  psql "${PSQL_ARGS[@]}" -At -v ON_ERROR_STOP=1 -c "
    SELECT table_schema
    FROM information_schema.tables
    WHERE table_name = '${table}'
    ORDER BY CASE WHEN table_schema = 'public' THEN 0 ELSE 1 END, table_schema
    LIMIT 1
  " 2>/dev/null | head -n1
}

export_table_csv() {
  local table="$1"
  local schema="$2"

  if [[ -z "$schema" ]]; then
    warn "Table schema not found for ${table}."
    return 1
  fi

  if ! run_psql_command "\\copy (SELECT * FROM ${schema}.${table}) TO '${WORK_DIR}/db/${table}.csv' WITH CSV HEADER" > "$WORK_DIR/logs/${table}.log" 2>&1; then
    warn "Table export failed for ${schema}.${table}; see logs/${table}.log"
    return 1
  fi

  return 0
}

count_table_rows() {
  local schema="$1"
  local table="$2"
  psql "${PSQL_ARGS[@]}" -At -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM ${schema}.${table}" 2>/dev/null | head -n1 || true
}

run_pg_dump_schema() {
  if ! command -v pg_dump >/dev/null 2>&1; then
    warn "pg_dump not found; schema export skipped."
    return 0
  fi

  local args=("${PG_DUMP_ARGS[@]}")

  [[ -n "$SCHEMA_SWAP" ]] && args+=("--table=${SCHEMA_SWAP}.tbl_hook_pool_swap")
  [[ -n "$SCHEMA_TRANSITION" ]] && args+=("--table=${SCHEMA_TRANSITION}.tbl_hook_transition_trace")
  [[ -n "$SCHEMA_PERIOD" ]] && args+=("--table=${SCHEMA_PERIOD}.tbl_hook_period_close")
  [[ -n "$SCHEMA_FEE" ]] && args+=("--table=${SCHEMA_FEE}.tbl_hook_fee_change")

  pg_dump "${args[@]}" --schema-only
}

set -a
source "$DEFAULTS_ENV"
[[ -f "$DEPLOY_ENV" ]] && source "$DEPLOY_ENV"
set +a

HOOK="${HOOK_ADDRESS:-}"
RPC_URL="${RPC_URL:-}"

[[ -n "$HOOK" ]] || {
  echo "Error: HOOK_ADDRESS is empty in $DEFAULTS_ENV" >&2
  exit 1
}

[[ -n "$RPC_URL" ]] || {
  echo "Error: RPC_URL is empty in $DEFAULTS_ENV" >&2
  exit 1
}

[[ -n "${POOL_ADDRESS:-}" ]] || {
  echo "Error: POOL_ADDRESS is empty in $DEFAULTS_ENV" >&2
  exit 1
}

DATABASE_URL_VALUE="$(read_env_value "$ROOT_ENV" "DATABASE_URL")"
PGHOST_VALUE="$(read_env_value "$ROOT_ENV" "PGHOST")"
PGPORT_VALUE="$(read_env_value "$ROOT_ENV" "PGPORT")"
PGDATABASE_VALUE="$(read_env_value "$ROOT_ENV" "PGDATABASE")"
PGUSER_VALUE="$(read_env_value "$ROOT_ENV" "PGUSER")"
PGSERVICE_VALUE="$(read_env_value "$ROOT_ENV" "PGSERVICE")"
PGPASSFILE_VALUE="$(read_env_value "$ROOT_ENV" "PGPASSFILE")"

TS="$(date -u +%Y%m%d_%H%M%S)"
BUNDLE_NAME="hook_diagnostics_${CHAIN}_${TS}"
OUT_DIR="${PROJECT_ROOT}/out"
WORK_DIR="${OUT_DIR}/${BUNDLE_NAME}"
ARCHIVE_PATH="${OUT_DIR}/${BUNDLE_NAME}.tar.gz"

mkdir -p "$OUT_DIR"
rm -rf "$WORK_DIR"
mkdir -p \
  "$WORK_DIR/config" \
  "$WORK_DIR/db" \
  "$WORK_DIR/meta" \
  "$WORK_DIR/runtime" \
  "$WORK_DIR/logs"

copy_if_exists "$DEFAULTS_ENV" "$WORK_DIR/config/defaults.env"
copy_if_exists "$DEPLOY_ENV" "$WORK_DIR/config/deploy.env"

find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.env' ! -name 'defaults.env' ! -name 'deploy.env' -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do
      cp "$f" "$WORK_DIR/config/$(basename "$f")"
    done

[[ -f "$ROOT_ENV" ]] && sanitize_root_env "$ROOT_ENV" "$WORK_DIR/config/root.env.redacted"

{
  echo "# Public config snapshot"
  echo "CHAIN=${CHAIN}"
  echo "CONFIG_DIR=${CONFIG_DIR}"
  echo
  echo "# Exported variables after sourcing defaults.env + deploy.env"
  env | LC_ALL=C sort | grep -E '^(HOOK|POOL|POOL_ADDRESS|OWNER|RPC|DEPLOY|CHAIN|NETWORK|FEE|MIN|MAX|EMA|LULL|PERIOD|CASH|EXTREME|EMERGENCY|UP|DOWN|PAUSE|UNPAUSE|CONTROLLER|MANAGER|POOL_MANAGER|HOOK_ADDRESS|POOL_ID|HOOK_DEPLOY_TX|POOL_INIT_TX)=' || true
} > "$WORK_DIR/config/public_config_snapshot.txt"

if git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$PROJECT_ROOT" rev-parse HEAD > "$WORK_DIR/meta/git_commit.txt" 2>/dev/null || true
  git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD > "$WORK_DIR/meta/git_branch.txt" 2>/dev/null || true
  git -C "$PROJECT_ROOT" status --short > "$WORK_DIR/meta/git_status.txt" 2>/dev/null || true
  git -C "$PROJECT_ROOT" submodule status > "$WORK_DIR/meta/git_submodules.txt" 2>/dev/null || true
fi

CURRENT_BLOCK="$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null || true)"
CURRENT_BLOCK="${CURRENT_BLOCK:-}"

ONCHAIN_OWNER="$(try_cast_scalar 'owner()(address)')"
ONCHAIN_POOL_MANAGER="$(try_cast_scalar 'poolManager()(address)')"
[[ -z "$ONCHAIN_POOL_MANAGER" ]] && ONCHAIN_POOL_MANAGER="$(try_cast_scalar 'manager()(address)')"
ONCHAIN_CURRENT_REGIME="$(try_cast_scalar 'currentRegime()(uint8)')"
ONCHAIN_IS_PAUSED="$(try_cast_scalar 'isPaused()(bool)')"
ONCHAIN_POOL_ID="$(try_cast_scalar 'poolId()(bytes32)')"
[[ -z "$ONCHAIN_POOL_ID" ]] && ONCHAIN_POOL_ID="$(try_cast_scalar 'POOL_ID()(bytes32)')"

CONFIG_POOL_ID="${POOL_ADDRESS}"
CONFIG_POOL_MANAGER="$(first_nonempty "${POOL_MANAGER:-}" "${POOL_MANAGER_ADDRESS:-}" "${MANAGER:-}" "$ONCHAIN_POOL_MANAGER")"
CONFIG_OWNER="$(first_nonempty "${OWNER:-}" "${OWNER_ADDRESS:-}" "$ONCHAIN_OWNER")"
CONFIG_HOOK_DEPLOY_TX="$(first_nonempty "${HOOK_DEPLOY_TX:-}" "${DEPLOY_TX:-}" "${HOOK_DEPLOY_TX_HASH:-}")"
CONFIG_POOL_INIT_TX="$(first_nonempty "${POOL_INIT_TX:-}" "${INIT_TX:-}" "${POOL_INIT_TX_HASH:-}")"

{
  echo "generated_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "chain=${CHAIN}"
  echo "project_root=${PROJECT_ROOT}"
  echo "config_dir=${CONFIG_DIR}"
  echo "hook_address=${HOOK}"
  echo "rpc_url=${RPC_URL}"
  echo "database_url_redacted=$(redact_db_url "$DATABASE_URL_VALUE")"
  echo "pgdatabase=${PGDATABASE_VALUE:-uniswap_lp_analytics}"
  echo "pghost=${PGHOST_VALUE:-}"
  echo "pgport=${PGPORT_VALUE:-}"
  echo "pguser=${PGUSER_VALUE:-}"
  echo "pgservice=${PGSERVICE_VALUE:-}"
  echo "pgpassfile=${PGPASSFILE_VALUE:-}"
  echo "current_block=${CURRENT_BLOCK}"
} > "$WORK_DIR/meta/bundle_meta.txt"

{
  echo "HOOK_ADDRESS=${HOOK}"
  echo "POOL_ID=${CONFIG_POOL_ID}"
  echo "POOL_MANAGER=${CONFIG_POOL_MANAGER}"
  echo "OWNER=${CONFIG_OWNER}"
  echo "HOOK_DEPLOY_TX=${CONFIG_HOOK_DEPLOY_TX}"
  echo "POOL_INIT_TX=${CONFIG_POOL_INIT_TX}"
} > "$WORK_DIR/meta/config_meta.txt"

{
  echo "owner=${ONCHAIN_OWNER}"
  echo "pool_manager=${ONCHAIN_POOL_MANAGER}"
  echo "is_paused=${ONCHAIN_IS_PAUSED}"
  echo "current_regime=${ONCHAIN_CURRENT_REGIME}"
  echo "pool_id=${ONCHAIN_POOL_ID}"
} > "$WORK_DIR/meta/onchain_meta.txt"

if [[ -x "$SHOW_CONFIG_SCRIPT" ]]; then
  "$SHOW_CONFIG_SCRIPT" --chain "$CHAIN" > "$WORK_DIR/runtime/show_hook_config.txt" 2>&1 || warn "show_hook_config.sh failed; see runtime/show_hook_config.txt"
else
  warn "show_hook_config.sh not found or not executable: $SHOW_CONFIG_SCRIPT"
fi

try_cast_multiline "getStateDebug()(uint8,uint8,uint8,uint8,uint8,uint64,uint64,uint96,bool)" > "$WORK_DIR/runtime/getStateDebug_raw.txt" || true

PSQL_ARGS=()
PG_DUMP_ARGS=()

if [[ -n "$DATABASE_URL_VALUE" ]]; then
  PSQL_ARGS+=("$DATABASE_URL_VALUE")
  PG_DUMP_ARGS+=("$DATABASE_URL_VALUE")
else
  PSQL_ARGS+=("-d" "${PGDATABASE_VALUE:-uniswap_lp_analytics}")
  PG_DUMP_ARGS+=("-d" "${PGDATABASE_VALUE:-uniswap_lp_analytics}")

  [[ -n "$PGHOST_VALUE" ]] && PSQL_ARGS+=("-h" "$PGHOST_VALUE") && PG_DUMP_ARGS+=("-h" "$PGHOST_VALUE")
  [[ -n "$PGPORT_VALUE" ]] && PSQL_ARGS+=("-p" "$PGPORT_VALUE") && PG_DUMP_ARGS+=("-p" "$PGPORT_VALUE")
  [[ -n "$PGUSER_VALUE" ]] && PSQL_ARGS+=("-U" "$PGUSER_VALUE") && PG_DUMP_ARGS+=("-U" "$PGUSER_VALUE")

  [[ -n "$PGSERVICE_VALUE" ]] && export PGSERVICE="$PGSERVICE_VALUE"
  [[ -n "$PGPASSFILE_VALUE" ]] && export PGPASSFILE="$PGPASSFILE_VALUE"
fi

DB_AVAILABLE="1"
if ! psql "${PSQL_ARGS[@]}" -v ON_ERROR_STOP=1 -c 'select 1' >/dev/null 2>&1; then
  DB_AVAILABLE="0"
  warn "Database connection check failed."
fi

SCHEMA_SWAP=""
SCHEMA_TRANSITION=""
SCHEMA_PERIOD=""
SCHEMA_FEE=""

if [[ "$DB_AVAILABLE" == "1" ]]; then
  SCHEMA_SWAP="$(detect_table_schema 'tbl_hook_pool_swap')"
  SCHEMA_TRANSITION="$(detect_table_schema 'tbl_hook_transition_trace')"
  SCHEMA_PERIOD="$(detect_table_schema 'tbl_hook_period_close')"
  SCHEMA_FEE="$(detect_table_schema 'tbl_hook_fee_change')"

  {
    echo "table_name,schema_name"
    echo "tbl_hook_pool_swap,${SCHEMA_SWAP}"
    echo "tbl_hook_transition_trace,${SCHEMA_TRANSITION}"
    echo "tbl_hook_period_close,${SCHEMA_PERIOD}"
    echo "tbl_hook_fee_change,${SCHEMA_FEE}"
  } > "$WORK_DIR/db/table_locations.csv"

  {
    echo "table_schema,table_name,row_count"
    [[ -n "$SCHEMA_SWAP" ]] && echo "${SCHEMA_SWAP},tbl_hook_pool_swap,$(count_table_rows "$SCHEMA_SWAP" "tbl_hook_pool_swap")"
    [[ -n "$SCHEMA_TRANSITION" ]] && echo "${SCHEMA_TRANSITION},tbl_hook_transition_trace,$(count_table_rows "$SCHEMA_TRANSITION" "tbl_hook_transition_trace")"
    [[ -n "$SCHEMA_PERIOD" ]] && echo "${SCHEMA_PERIOD},tbl_hook_period_close,$(count_table_rows "$SCHEMA_PERIOD" "tbl_hook_period_close")"
    [[ -n "$SCHEMA_FEE" ]] && echo "${SCHEMA_FEE},tbl_hook_fee_change,$(count_table_rows "$SCHEMA_FEE" "tbl_hook_fee_change")"
  } > "$WORK_DIR/db/hook_table_counts.csv"

  METADATA_SQL="${WORK_DIR}/db/export_metadata.sql"
  cat > "$METADATA_SQL" <<EOF2
\\pset footer off
\\copy (SELECT table_schema, table_name, ordinal_position, column_name, data_type, udt_name, is_nullable FROM information_schema.columns WHERE table_name IN ('tbl_hook_pool_swap','tbl_hook_transition_trace','tbl_hook_period_close','tbl_hook_fee_change') ORDER BY table_schema, table_name, ordinal_position) TO '${WORK_DIR}/db/hook_columns.csv' WITH CSV HEADER
\\copy (SELECT schemaname, tablename, indexname, indexdef FROM pg_indexes WHERE tablename IN ('tbl_hook_pool_swap','tbl_hook_transition_trace','tbl_hook_period_close','tbl_hook_fee_change') ORDER BY schemaname, tablename, indexname) TO '${WORK_DIR}/db/hook_indexes.csv' WITH CSV HEADER
\\copy (SELECT schemaname, relname AS table_name, n_live_tup AS approx_live_rows, n_dead_tup AS approx_dead_rows, seq_scan, seq_tup_read, idx_scan, idx_tup_fetch FROM pg_stat_user_tables WHERE relname IN ('tbl_hook_pool_swap','tbl_hook_transition_trace','tbl_hook_period_close','tbl_hook_fee_change') ORDER BY schemaname, relname) TO '${WORK_DIR}/db/hook_table_stats.csv' WITH CSV HEADER
EOF2

  if ! run_psql_file "$METADATA_SQL" > "$WORK_DIR/logs/psql_export.log" 2>&1; then
    warn "Database metadata export failed; see logs/psql_export.log"
  fi

  SUMMARY_SQL="${WORK_DIR}/db/export_summaries.sql"
  : > "$SUMMARY_SQL"
  echo "\\pset footer off" >> "$SUMMARY_SQL"

  [[ -n "$SCHEMA_SWAP" ]] && echo "\\copy (SELECT fee, count(*) AS swaps FROM ${SCHEMA_SWAP}.tbl_hook_pool_swap GROUP BY fee ORDER BY fee) TO '${WORK_DIR}/db/pool_swap_fee_hist.csv' WITH CSV HEADER" >> "$SUMMARY_SQL"
  [[ -n "$SCHEMA_TRANSITION" ]] && echo "\\copy (SELECT reason_code, count(*) AS transitions FROM ${SCHEMA_TRANSITION}.tbl_hook_transition_trace GROUP BY reason_code ORDER BY reason_code) TO '${WORK_DIR}/db/transition_reason_hist.csv' WITH CSV HEADER" >> "$SUMMARY_SQL"
  [[ -n "$SCHEMA_PERIOD" ]] && echo "\\copy (SELECT reason_code, count(*) AS periods FROM ${SCHEMA_PERIOD}.tbl_hook_period_close GROUP BY reason_code ORDER BY reason_code) TO '${WORK_DIR}/db/period_close_reason_hist.csv' WITH CSV HEADER" >> "$SUMMARY_SQL"

  if ! run_psql_file "$SUMMARY_SQL" > "$WORK_DIR/logs/psql_summary.log" 2>&1; then
    warn "Database summary export failed; see logs/psql_summary.log"
  fi

  export_table_csv "tbl_hook_pool_swap" "$SCHEMA_SWAP" || true
  export_table_csv "tbl_hook_transition_trace" "$SCHEMA_TRANSITION" || true
  export_table_csv "tbl_hook_period_close" "$SCHEMA_PERIOD" || true
  export_table_csv "tbl_hook_fee_change" "$SCHEMA_FEE" || true

  run_pg_dump_schema > "$WORK_DIR/db/hook_tables_schema.sql" 2>"$WORK_DIR/logs/pg_dump.log" || warn "pg_dump schema export failed; see logs/pg_dump.log"
else
  warn "Database export skipped."
fi

cat > "$WORK_DIR/README.txt" <<EOF2
Bundle: ${BUNDLE_NAME}
Generated at (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Chain: ${CHAIN}
Hook: ${HOOK}
RPC_URL: ${RPC_URL}

Contents:
- config/: full public chain configs + redacted private root env snapshot
- meta/: git metadata, config metadata, onchain metadata, bundle metadata
- runtime/: current hook config output and raw state debug
- db/: database exports, summaries, schema dump
- logs/: warnings and command logs
EOF2

find "$WORK_DIR" \( -name '.DS_Store' -o -name '._*' \) -delete 2>/dev/null || true

(
  cd "$OUT_DIR"
  COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 tar -czf "${BUNDLE_NAME}.tar.gz" "${BUNDLE_NAME}"
)

rm -rf "$WORK_DIR"

echo "${ARCHIVE_PATH}"
