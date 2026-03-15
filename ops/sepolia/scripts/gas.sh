#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
source "${ROOT_DIR}/ops/shared/scripts/gas_common.sh"

load_live_config "gas"
require_live_preflight
ensure_live_drivers
gas_require_tools
gas_setup_paths "${OPS_NETWORK_DIR}" "${OPS_NETWORK}"

runs="${OPS_GAS_RUNS:-2}"
chain_id="${CHAIN_ID_EXPECTED:-11155111}"
measure_script="ops/shared/foundry/MeasureGasLive.s.sol:MeasureGasLive"
prepare_script="ops/shared/foundry/PrepareGasScenarioLive.s.sol:PrepareGasScenarioLive"
restore_script="ops/shared/foundry/RestoreGasScenarioLive.s.sol:RestoreGasScenarioLive"
broadcast_path="$(gas_broadcast_path "MeasureGasLive.s.sol" "${chain_id}")"
snapshot_path="${OPS_GAS_TIMING_SNAPSHOT:-${OPS_NETWORK_DIR}/out/state/gas.${OPS_NETWORK}.timing.json}"
samples_jsonl="$(mktemp)"
prepared=0

cleanup() {
  local status=$?
  if [[ "${prepared}" == "1" && -f "${snapshot_path}" ]]; then
    export OPS_GAS_TIMING_SNAPSHOT="${snapshot_path}"
    forge_live "${restore_script}" "broadcast" || true
  fi
  rm -f "${samples_jsonl}"
  exit "${status}"
}
trap cleanup EXIT

: > "${samples_jsonl}"
export OPS_GAS_TIMING_SNAPSHOT="${snapshot_path}"
forge_live "${prepare_script}" "broadcast"
prepared=1

while IFS= read -r operation; do
  [[ -n "${operation}" ]] || continue
  for ((run = 1; run <= runs; run++)); do
    export OPS_GAS_OPERATION="${operation}"
    forge_live "${measure_script}" "broadcast"
    gas_append_last_receipt_sample "${broadcast_path}" "${OPS_NETWORK}" "${chain_id}" "${operation}" "${run}" "${samples_jsonl}"
  done
done < <(gas_operation_list)

gas_render_reports "${OPS_NETWORK}" "${chain_id}" "${runs}" "${samples_jsonl}"

forge_live "${restore_script}" "broadcast"
prepared=0

echo "gas samples: ${OPS_GAS_SAMPLES_PATH}"
echo "gas report json: ${OPS_GAS_REPORT_JSON}"
echo "gas report md: ${OPS_GAS_REPORT_MD}"
