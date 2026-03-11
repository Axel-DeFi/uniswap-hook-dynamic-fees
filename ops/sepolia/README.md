# Sepolia Ops

Sepolia validation scripts mirror local phase names, with explicit read-only and broadcast-capable separation.

## Read-only phases

- `ops/sepolia/scripts/preflight.sh`
- `ops/sepolia/scripts/inspect.sh`

## Broadcast-capable phases

- `ops/sepolia/scripts/ensure-hook.sh`
- `ops/sepolia/scripts/ensure-pool.sh`
- `ops/sepolia/scripts/ensure-liquidity.sh`
- `ops/sepolia/scripts/smoke.sh`
- `ops/sepolia/scripts/full.sh`
- `ops/sepolia/scripts/rerun-safe.sh`
- `ops/sepolia/scripts/emergency.sh`

## Outputs

- `ops/sepolia/out/reports/*.json`
- `ops/sepolia/out/state/*.json`
- `ops/sepolia/out/logs/*.log`

## Notes

- Live file layering is `defaults.env` -> scenario overlay -> `.env` -> `deploy.env`; runtime state files may hydrate
  current hook/pool/driver addresses afterward without changing `DEPLOY_*` identity inputs.
- `SWAP_DRIVER` and `LIQUIDITY_DRIVER` are helper contracts used by live swap/liquidity phases.
- If helper addresses are missing or invalid, wrappers auto-provision canonical drivers via the shared
  `EnsureDriversLive` path and persist them in `ops/sepolia/out/state/sepolia.drivers.json`.
- `preflight` validates chain id, budget, token decimals, hook/pool consistency before broadcast-capable phases.
- `smoke/full/rerun-safe/emergency` enforce preflight gate by default and stop on preflight failure.
- `ensure-pool` and `ensure-liquidity` now also enforce the same preflight gate by default.
- Broadcast-capable hook/pool/liquidity scripts resolve `HOOK_ADDRESS` to the canonical hook for the current
  release + deployment snapshot before sending transactions.
- Set `OPS_REQUIRE_PREFLIGHT=0` only for explicit break-glass diagnostics.
- Broadcast-capable scripts also re-check budget safety before sending transactions.
