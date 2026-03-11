# Optimism Ops

Optimism production operations use the same shared live-ops surface as Sepolia.

## Read-only phases

- `ops/optimism/scripts/preflight.sh`
- `ops/optimism/scripts/inspect.sh`

## Broadcast-capable phases

- `ops/optimism/scripts/ensure-hook.sh`
- `ops/optimism/scripts/ensure-pool.sh`
- `ops/optimism/scripts/ensure-liquidity.sh`
- `ops/optimism/scripts/smoke.sh`
- `ops/optimism/scripts/full.sh`
- `ops/optimism/scripts/rerun-safe.sh`
- `ops/optimism/scripts/emergency.sh`

## Notes

- Shell wrappers and Foundry scripts are shared with Sepolia under `ops/shared`.
- Config layering matches the live standard: `defaults.env -> scenario overlay -> .env -> process env`.
- `preflight` is the required read-only gate before all broadcast-capable phases.
- Drivers are auto-provisioned on demand for liquidity/swap validation phases and persisted in `ops/optimism/out/state/optimism.drivers.json`.
- Pool/liquidity scripts resolve hook identity through the same canonical shared validation stack as Sepolia.
