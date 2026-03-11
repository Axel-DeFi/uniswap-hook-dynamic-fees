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
- `INIT_PRICE_USD`, `LIQ_RANGE_MIN_USD`, `LIQ_RANGE_MAX_USD`, and `INIT_SQRT_PRICE_X96` must be set explicitly before pool/liquidity flows.
- Live budgets default to zero; set budget env values explicitly before `ensure-liquidity` or swap-validation phases.
- For native-asset pools, owner must remain compatible with native payout from the PoolManager claim path.
- Hold guidance remains `cashHoldPeriods >= 2`, `extremeHoldPeriods >= 2` unless an explicit override is justified.
- `ops/optimism/config/deploy.env` is a frozen constructor snapshot after deployment; change `defaults.env` for
  expected runtime/admin drift, not `deploy.env`.
- The shared shell loader sources `deploy.env` after scenario overlays and root `.env`, so stray `DEPLOY_*` values in
  overlays cannot silently override the canonical snapshot.
