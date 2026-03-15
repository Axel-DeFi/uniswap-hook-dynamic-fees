#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/audit_bundle"
REFRESH_GAS=0
OVERWRITE=0

usage() {
  cat <<'EOF'
Usage: scripts/build_audit_bundle.sh [--refresh-gas] [--overwrite]

Builds the curated audit bundle archive:
  audit_bundle/dynamic-fees_v<VERSION>_<short-sha>.zip

Options:
  --refresh-gas   Regenerate local gas artifacts before packaging.
  --overwrite     Replace an existing zip/checksum for the current HEAD.
  -h, --help      Show this help.
EOF
}

while (($# > 0)); do
  case "$1" in
    --refresh-gas)
      REFRESH_GAS=1
      shift
      ;;
    --overwrite)
      OVERWRITE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

require_tool git
require_tool rsync
require_tool zip
require_tool rg

VERSION="$(<"${ROOT_DIR}/VERSION")"
SHORT_SHA="$(git -C "${ROOT_DIR}" rev-parse --short=7 HEAD)"
BUNDLE_NAME="dynamic-fees_v${VERSION}_${SHORT_SHA}"
BUNDLE_ZIP="${OUT_DIR}/${BUNDLE_NAME}.zip"
BUNDLE_SHA256="${BUNDLE_ZIP}.sha256"
LEGACY_BUNDLE_DIR="${OUT_DIR}/${BUNDLE_NAME}_nolib"

if (( OVERWRITE )); then
  rm -rf "${BUNDLE_ZIP}" "${BUNDLE_SHA256}" "${OUT_DIR}/${BUNDLE_NAME}" "${LEGACY_BUNDLE_DIR}" "${OUT_DIR}/${BUNDLE_NAME}_nolib.zip" "${OUT_DIR}/${BUNDLE_NAME}_nolib.zip.sha256"
fi

if [[ -e "${BUNDLE_ZIP}" || -e "${BUNDLE_SHA256}" ]]; then
  echo "Bundle target already exists: ${BUNDLE_NAME}" >&2
  echo "Use --overwrite to replace it." >&2
  exit 1
fi

if (( REFRESH_GAS )); then
  mkdir -p "${ROOT_DIR}/ops/local/out/reports"
  (
    cd "${ROOT_DIR}"
    forge test --offline --gas-report --match-contract VolumeDynamicFeeHookAdminTest \
      > ops/local/out/reports/gas.admin.report.txt
    ops/local/scripts/gas.sh
  )
fi

mkdir -p "${OUT_DIR}"

STAGING_DIR="$(mktemp -d "${OUT_DIR}/.${BUNDLE_NAME}.tmp.XXXXXX")"
cleanup() {
  rm -f "${TRACKED_LIST_FILE:-}"
  rm -rf "${STAGING_DIR:-}"
}
trap cleanup EXIT

mkdir -p "${STAGING_DIR}/validation/gas"

INCLUDE_PATHS=(
  AGENTS.md
  CHANGELOG.md
  LICENSE
  MANIFEST.md
  README.md
  VERSION
  foundry.lock
  foundry.toml
  remappings.txt
  src
  docs
  ops/README.md
  ops/shared
  ops/local
  ops/sepolia
  ops/optimism
  ops/tests
  scripts/README.md
  scripts/build_audit_bundle.sh
  scripts/calc_init_sqrt_price.sh
  scripts/simulate_fee_cycle.sh
  scripts/release
)

EXCLUDE_PATTERN='^(lib/|\.env\.example$|\.gitattributes$|\.github/|\.gitignore$|\.gitmodules$|scripts/hook_status\.sh$|scripts/pool_stats_op\.sh$|scripts/show_deposits\.sh$|ops/local/scripts/anvil-up\.sh$|ops/local/scripts/anvil-down\.sh$|ops/local/scripts/bootstrap\.sh$|ops/local/scripts/reset-state\.sh$)'

TRACKED_LIST_FILE="$(mktemp)"

(
  cd "${ROOT_DIR}"
  git ls-files -- "${INCLUDE_PATHS[@]}"
) | rg -v "${EXCLUDE_PATTERN}" > "${TRACKED_LIST_FILE}"

rsync -a --files-from="${TRACKED_LIST_FILE}" "${ROOT_DIR}/" "${STAGING_DIR}/"

copy_gas_artifact() {
  local src="$1"
  local dst_name="$2"
  if [[ -f "${ROOT_DIR}/${src}" ]]; then
    mkdir -p "$(dirname "${STAGING_DIR}/validation/gas/${dst_name}")"
    cp "${ROOT_DIR}/${src}" "${STAGING_DIR}/validation/gas/${dst_name}"
    printf '%s -> validation/gas/%s\n' "${src}" "${dst_name}" >> "${STAGING_DIR}/validation/gas/copied_artifacts.txt"
  fi
}

cat > "${STAGING_DIR}/validation/gas/README.md" <<EOF
# Gas Evidence

Bundle: \`${BUNDLE_NAME}\`  
Version: \`${VERSION}\`  
Commit: \`${SHORT_SHA}\`

This directory contains gas-efficiency evidence copied into the audit bundle workspace.
The canonical local reproduction flow is:

\`\`\`bash
forge test --offline --gas-report --match-contract VolumeDynamicFeeHookAdminTest > ops/local/out/reports/gas.admin.report.txt
ops/local/scripts/gas.sh
\`\`\`

Primary gas-related source files in this repository:
- \`ops/tests/unit/MeasureGasLocalReport.t.sol\`
- \`ops/tests/unit/MeasureGasLocalScenario.t.sol\`
- \`ops/tests/unit/GasMeasurementLib.t.sol\`
- \`ops/shared/lib/GasMeasurementLib.sol\`
- \`ops/local/scripts/gas.sh\`
- \`ops/shared/scripts/gas_common.sh\`
- \`ops/local/foundry/MeasureGasLocal.s.sol\`
- \`ops/local/foundry/CollectGasObservationsLocal.s.sol\`
- \`ops/shared/foundry/MeasureGasLive.s.sol\`

Copied workspace artifacts, if present, are listed in \`copied_artifacts.txt\`.
EOF

: > "${STAGING_DIR}/validation/gas/copied_artifacts.txt"
copy_gas_artifact "ops/local/out/reports/gas.admin.report.txt" "gas.admin.report.txt"
copy_gas_artifact "ops/local/out/reports/gas.samples.local.json" "gas.samples.local.json"
copy_gas_artifact "ops/local/out/reports/gas.local.json" "gas.local.json"
copy_gas_artifact "ops/local/out/reports/gas.local.md" "gas.local.md"
copy_gas_artifact "ops/local/out/reports/gas.anvil.measurements.md" "gas.anvil.measurements.md"
copy_gas_artifact "ops/sepolia/out/reports/gas.sepolia.not_reproduced.md" "gas.sepolia.not_reproduced.md"

(
  cd "${STAGING_DIR}"
  find . -type f | sed 's#^\./##' | sort > validation/bundle_file_list.txt
  zip -qr "${BUNDLE_ZIP}" .
)

sha256sum_cmd=""
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "${BUNDLE_ZIP}" > "${BUNDLE_SHA256}"
  sha256sum_cmd="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${BUNDLE_ZIP}" > "${BUNDLE_SHA256}"
  sha256sum_cmd="sha256sum"
fi

echo "bundle_zip=${BUNDLE_ZIP}"
if [[ -n "${sha256sum_cmd}" ]]; then
  echo "bundle_sha256_file=${BUNDLE_SHA256}"
fi
