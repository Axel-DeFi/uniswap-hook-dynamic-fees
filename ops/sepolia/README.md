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

- Config layering: `defaults.env` -> scenario overlay -> `.env` -> process env.
- `SWAP_DRIVER` and `LIQUIDITY_DRIVER` are helper contracts used by live swap/liquidity phases.
- If helper addresses are not set, wrappers auto-provision drivers via `EnsureDriversSepolia` and persist them in `ops/sepolia/out/state/sepolia.drivers.json`.
- `preflight` validates chain id, budget, token decimals, hook/pool consistency before broadcast-capable phases.
- Broadcast-capable scripts also re-check budget safety before sending transactions.
