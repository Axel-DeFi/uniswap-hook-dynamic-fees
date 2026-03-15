# Scenario Overlay Schema

Scenario files are dotenv overlays loaded **after** `defaults.env`.

## Rules

1. Keep overlays minimal: override only scenario-specific keys.
2. Do not redefine fixed bindings unless scenario requires it.
3. Avoid secrets in scenario files.
4. Scenario files must remain rerun-safe.

## Recommended override keys

- `OPS_SCENARIO`
- `SMOKE_SWAP_STABLE_RAW`
- `FULL_SWAP_STABLE_RAW`
- `FULL_SWAP_ITERATIONS`
- `RERUN_SWAP_STABLE_RAW`
- Budget keys (`BUDGET_*`) for stress / constrained runs

## Scenario intent

- `bootstrap`: deterministic environment setup
- `smoke`: minimal transaction path with fast signal
- `full`: broader sampling of operational path
- `fuzz-lite` (local only): higher iteration count with smaller swaps
- `rerun`: idempotency / repeated execution
- `emergency`: pause/reset/unpause validation path
