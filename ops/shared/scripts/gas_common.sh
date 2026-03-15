#!/usr/bin/env bash
set -euo pipefail

gas_require_tools() {
  require_cmd jq
}

gas_default_operations() {
  cat <<'EOF'
normal_swap
period_close
floor_to_cash
cash_to_extreme
extreme_to_cash
cash_to_floor
lull_reset
pause
unpause
emergency_reset_to_floor
emergency_reset_to_cash
claim_all_hook_fees
EOF
}

gas_operation_list() {
  local raw="${OPS_GAS_OPERATIONS:-}"
  if [[ -z "${raw}" ]]; then
    gas_default_operations
    return 0
  fi

  raw="${raw//,/ }"
  # shellcheck disable=SC2086
  printf '%s\n' ${raw}
}

gas_setup_paths() {
  local network_dir="$1"
  local network="$2"

  export OPS_GAS_SAMPLES_PATH="${OPS_GAS_SAMPLES_PATH:-${network_dir}/out/reports/gas.samples.${network}.json}"
  export OPS_GAS_REPORT_JSON="${OPS_GAS_REPORT_JSON:-${network_dir}/out/reports/gas.${network}.json}"
  export OPS_GAS_REPORT_MD="${OPS_GAS_REPORT_MD:-${network_dir}/out/reports/gas.${network}.md}"
}

gas_broadcast_path() {
  local script_file="$1"
  local chain_id="$2"
  printf '%s/scripts/out/broadcast/%s/%s/run-latest.json\n' "${ROOT_DIR}" "${script_file}" "${chain_id}"
}

gas_hex_to_dec() {
  local raw="${1#0x}"
  printf '%s\n' "$((16#${raw}))"
}

gas_append_last_receipt_sample() {
  local broadcast_path="$1"
  local network="$2"
  local chain_id="$3"
  local operation="$4"
  local run_index="$5"
  local samples_jsonl="$6"

  [[ -f "${broadcast_path}" ]] || {
    echo "ERROR: broadcast artifact missing: ${broadcast_path}" >&2
    return 1
  }

  local status tx_hash gas_used_hex gas_price_hex gas_used gas_price
  status="$(jq -r '.receipts[-1].status // empty' "${broadcast_path}")"
  tx_hash="$(jq -r '.receipts[-1].transactionHash // empty' "${broadcast_path}")"
  gas_used_hex="$(jq -r '.receipts[-1].gasUsed // empty' "${broadcast_path}")"
  gas_price_hex="$(jq -r '.receipts[-1].effectiveGasPrice // empty' "${broadcast_path}")"

  [[ -n "${status}" && "${status}" != "null" ]] || {
    echo "ERROR: last receipt missing in ${broadcast_path}" >&2
    return 1
  }
  [[ "${status}" == "0x1" ]] || {
    echo "ERROR: last receipt failed for ${operation} run ${run_index}" >&2
    return 1
  }

  gas_used="$(gas_hex_to_dec "${gas_used_hex}")"
  gas_price="$(gas_hex_to_dec "${gas_price_hex}")"

  jq -cn \
    --arg network "${network}" \
    --argjson chainId "${chain_id}" \
    --arg operation "${operation}" \
    --argjson run "${run_index}" \
    --arg txHash "${tx_hash}" \
    --argjson gasUsed "${gas_used}" \
    --argjson effectiveGasPriceWei "${gas_price}" \
    '{
      network: $network,
      chainId: $chainId,
      operation: $operation,
      run: $run,
      txHash: $txHash,
      gasUsed: $gasUsed,
      effectiveGasPriceWei: $effectiveGasPriceWei
    }' >> "${samples_jsonl}"
}

gas_render_reports() {
  local network="$1"
  local chain_id="$2"
  local runs_per_operation="$3"
  local samples_jsonl="$4"

  jq -s '.' "${samples_jsonl}" > "${OPS_GAS_SAMPLES_PATH}"
  gas_render_reports_from_samples_file "${network}" "${chain_id}" "${runs_per_operation}" "${OPS_GAS_SAMPLES_PATH}"
}

gas_render_reports_from_samples_file() {
  local network="$1"
  local chain_id="$2"
  local runs_per_operation="$3"
  local samples_file="$4"
  local network_title
  network_title="$(printf '%s' "${network}" | tr '[:lower:]' '[:upper:]' | awk '{print substr($0,1,1) tolower(substr($0,2))}')"

  jq \
    --arg network "${network}" \
    --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson chainId "${chain_id}" \
    --argjson runsPerOperation "${runs_per_operation}" \
    '
      . as $samples
      | {
          network: $network,
          chainId: $chainId,
          generatedAt: $generatedAt,
          runsPerOperation: $runsPerOperation,
          sampleCount: ($samples | length),
          operations: (
            $samples
            | sort_by(.operation, .run)
            | group_by(.operation)
            | map({
                operation: .[0].operation,
                runs: length,
                minGasUsed: (map(.gasUsed) | min),
                maxGasUsed: (map(.gasUsed) | max),
                avgGasUsed: ((map(.gasUsed) | add) / length | floor),
                minEffectiveGasPriceWei: (map(.effectiveGasPriceWei) | min),
                maxEffectiveGasPriceWei: (map(.effectiveGasPriceWei) | max),
                avgEffectiveGasPriceWei: ((map(.effectiveGasPriceWei) | add) / length | floor),
                txHashes: map(.txHash)
              })
          )
        }
    ' "${samples_file}" > "${OPS_GAS_REPORT_JSON}"

  {
    printf '# %s Gas Measurements\n\n' "${network_title}"
    printf 'Source samples: `%s`\n\n' "${samples_file}"
    printf '| Operation | Runs | Min gas | Max gas | Avg gas | Min gas price (wei) | Max gas price (wei) | Avg gas price (wei) |\n'
    printf '|---|---:|---:|---:|---:|---:|---:|---:|\n'
    jq -r '
      .operations[]
      | [
          .operation,
          (.runs | tostring),
          (.minGasUsed | tostring),
          (.maxGasUsed | tostring),
          (.avgGasUsed | tostring),
          (.minEffectiveGasPriceWei | tostring),
          (.maxEffectiveGasPriceWei | tostring),
          (.avgEffectiveGasPriceWei | tostring)
        ]
      | @tsv
    ' "${OPS_GAS_REPORT_JSON}" | while IFS=$'\t' read -r operation runs min_gas max_gas avg_gas min_price max_price avg_price; do
      printf '| `%s` | %s | %s | %s | %s | %s | %s | %s |\n' \
        "${operation}" "${runs}" "${min_gas}" "${max_gas}" "${avg_gas}" "${min_price}" "${max_price}" "${avg_price}"
    done
  } > "${OPS_GAS_REPORT_MD}"
}
