# Local Ops (Anvil)

Local operational validation lives under `ops/local` and is split into thin shell wrappers and Foundry scripts.

## Read-only phases

- `ops/local/scripts/preflight.sh`
- `ops/local/scripts/inspect.sh`

## Broadcast-capable phases

- `ops/local/scripts/bootstrap.sh`
- `ops/local/scripts/ensure-hook.sh`
- `ops/local/scripts/ensure-pool.sh`
- `ops/local/scripts/ensure-liquidity.sh`
- `ops/local/scripts/smoke.sh`
- `ops/local/scripts/full.sh`
- `ops/local/scripts/rerun-safe.sh`
- `ops/local/scripts/emergency.sh`

## Process control

- `ops/local/scripts/anvil-up.sh`
- `ops/local/scripts/anvil-down.sh`
- `ops/local/scripts/reset-state.sh`

## Outputs

- `ops/local/out/reports/*.json`
- `ops/local/out/state/*.json`
- `ops/local/out/logs/*.log`

## Notes

- Config layering: `defaults.env` -> `scenarios/<name>.env` -> `.env` -> process env.
- State hydration: `ops/local/out/state/local.addresses.json` is reused by wrappers.
- `bootstrap` preflight tolerates stale hook addresses and treats them as bootstrap replacements.
- `OPS_FORCE_SIMULATION=1` runs scripts without RPC/broadcast for deterministic dry operational checks.
