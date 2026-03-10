# Local Acceptance

## Mandatory checks

1. `preflight.sh` succeeds and writes `ops/local/out/reports/preflight.local.json`.
2. `bootstrap.sh` writes `ops/local/out/state/local.addresses.json` with non-zero `poolManager` and `hookAddress`.
3. `smoke.sh` succeeds and keeps hook state initialized.
4. `full.sh` writes `ops/local/out/reports/full.local.json` with fee index inside floor/cap bounds.
5. `rerun-safe.sh` can be executed twice without errors.
6. `emergency.sh` ends with hook unpaused and fee index reset to floor.

## Artifact checks

- `jq . ops/local/out/state/local.addresses.json`
- `jq . ops/local/out/reports/preflight.local.json`
- `jq . ops/local/out/reports/full.local.json`

## Failure policy

Any budget/range/config mismatch must fail before broadcast phase execution.
