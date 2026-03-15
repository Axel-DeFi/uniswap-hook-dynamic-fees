#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
source "${ROOT_DIR}/ops/shared/scripts/gas_common.sh"

load_local_config "gas"
gas_require_tools
gas_setup_paths "${OPS_LOCAL_DIR}" "local"

runs="${OPS_GAS_RUNS:-5}"
chain_id="${CHAIN_ID_EXPECTED:-31337}"

forge test --offline --match-path 'ops/tests/unit/MeasureGasLocalReport.t.sol' --match-test test_write_local_gas_samples
gas_render_reports_from_samples_file "local" "${chain_id}" "${runs}" "${OPS_GAS_SAMPLES_PATH}"

echo "gas samples: ${OPS_GAS_SAMPLES_PATH}"
echo "gas report json: ${OPS_GAS_REPORT_JSON}"
echo "gas report md: ${OPS_GAS_REPORT_MD}"
