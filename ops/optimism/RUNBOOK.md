# Optimism Runbook

## Read-only gate

```bash
ops/optimism/scripts/preflight.sh
ops/optimism/scripts/inspect.sh
```

Stop if preflight fails.
`smoke/full/rerun-safe/emergency` wrappers enforce this gate by default.

## Ensure state

```bash
ops/optimism/scripts/ensure-hook.sh
ops/optimism/scripts/ensure-pool.sh
ops/optimism/scripts/ensure-liquidity.sh
```

All three phases use the shared canonical live-ops stack:
- canonical CREATE2 hook identity derived from the current release and `ops/optimism/config/deploy.env`,
- exact callback surface validation,
- exact PoolManager binding,
- full runtime config validation,
- zero pending owner / pending config changes.

## Validation suite

```bash
ops/optimism/scripts/smoke.sh
ops/optimism/scripts/full.sh
ops/optimism/scripts/rerun-safe.sh
ops/optimism/scripts/emergency.sh
```

## Operational requirements

- Production owner must be multisig with cold/hardware custody.
- Fill `ops/optimism/config/deploy.env` for constructor and bootstrap values, including `INIT_PRICE_USD` before `ensure-pool`.
- Leave `ops/optimism/config/defaults.env` for runtime wiring, budgets, and optional runtime overrides.
- Live budgets default to zero; set budget env values explicitly before `ensure-liquidity` or swap-validation phases.
- Liquidity/swap helper drivers are reused only if their runtime codehash and bound `manager()` match the expected
  canonical helper for the configured `POOL_MANAGER`; otherwise wrappers reprovision them.
- For native-asset pools, owner must remain compatible with native payout from the PoolManager claim path.
- Hold guidance remains `cashHoldPeriods >= 2`, `extremeHoldPeriods >= 2` unless an explicit override is justified.
- `ops/optimism/config/deploy.env` is the primary file to fill before deployment; `defaults.env` may stay minimal and
  only needs explicit overrides when runtime/admin expectations drift from that snapshot.
- The shared shell loader sources `deploy.env` after scenario overlays and root `.env`, so stray `DEPLOY_*` values in
  overlays cannot silently override the canonical snapshot.
- `DEPLOY_*` entries in `deploy.env` must be literal values; shell interpolation is rejected. Set the exact production
  multisig directly in `DEPLOY_OWNER` before first live deployment.
