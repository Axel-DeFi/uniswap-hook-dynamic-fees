# Shared Ops Layer

`ops/shared` contains reusable Solidity and shell utilities for:
- local deterministic ops under `ops/local`
- shared live ops under `ops/sepolia` and `ops/optimism`

## Layout

- `types/OpsTypes.sol` — common structs for config, budget, range, hook validation and snapshots.
- `lib/ConfigLoader.sol` — env/config loading + basic chain/config validation.
- `lib/DriverValidationLib.sol` — canonical helper-driver validation for live liquidity/swap phases.
- `lib/EnvLib.sol` — strict env parsing helpers.
- `lib/BudgetLib.sol` — pre-broadcast budget checks and balance snapshots.
- `lib/RangeSafetyLib.sol` — init price presence checks and default swap sizing for validation flows.
- `lib/PoolStateLib.sol` — hook state snapshots.
- `lib/HookValidationLib.sol` — hook permission + pool binding validation.
- `lib/TokenValidationLib.sol` — token address/decimals checks.
- `lib/JsonReportLib.sol` — machine-readable report writers.
- `lib/LoggingLib.sol` — standardized console logging.
- `lib/ErrorLib.sol` — shared custom errors.
- `foundry/*.s.sol` — shared live Foundry entrypoints reused by Sepolia and Optimism.
- `scripts/live_common.sh` — shared live wrapper logic for shell entrypoints.
- `config/schema.md` — full env key schema.
- `config/scenario.schema.md` — scenario overlay schema.

## Design constraints

- Config-driven; no hardcoded operational addresses.
- Canonical hook identity is derived from a frozen `deploy.env` snapshot; this is the main operator-edited file.
- `defaults.env` carries runtime wiring, budgets, and optional overrides for post-deploy admin drift.
- Fail-fast preflight before broadcast-capable phases.
- Rerun-safe checks for stale/missing contract state.
- Shared live paths must differ by config only, not by validation or deployment semantics.
