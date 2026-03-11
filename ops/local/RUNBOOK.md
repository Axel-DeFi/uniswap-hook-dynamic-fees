# Local Runbook

## Start / stop

```bash
ops/local/scripts/anvil-up.sh
ops/local/scripts/anvil-down.sh
```

### Proxy-stable environment (Foundry on macOS)

If Foundry panics on system proxy discovery, pin proxy vars before running scripts:

```bash
export NO_PROXY='127.0.0.1,localhost'
export no_proxy='127.0.0.1,localhost'
export HTTP_PROXY='http://127.0.0.1:9'
export HTTPS_PROXY='http://127.0.0.1:9'
export ALL_PROXY='http://127.0.0.1:9'
```

## Bootstrap and checks

```bash
ops/local/scripts/preflight.sh
ops/local/scripts/bootstrap.sh
ops/local/scripts/inspect.sh
ops/local/scripts/smoke.sh
ops/local/scripts/full.sh
ops/local/scripts/rerun-safe.sh
ops/local/scripts/emergency.sh
```

## Gas evidence reproduction

```bash
forge test --offline --gas-report --match-contract VolumeDynamicFeeHookAdminTest > ops/local/out/reports/gas.admin.report.txt
forge script scripts/foundry/MeasureGasLocal.s.sol:MeasureGasLocal --rpc-url http://127.0.0.1:8545 --broadcast
```

Artifacts:
- `ops/local/out/reports/gas.admin.report.txt`
- `scripts/out/broadcast/MeasureGasLocal.s.sol/31337/run-latest.json`

## Admin operation model

### Ownership transfer (2-step)

1. Current owner calls `proposeNewOwner(newOwner)`.
2. Current owner may cancel via `cancelOwnerTransfer()`.
3. Pending owner finalizes with `acceptOwner()`.

### HookFee timelock (48h)

1. `scheduleHookFeePercentChange(newPercent)`
2. optional `cancelHookFeePercentChange()`
3. after delay: `executeHookFeePercentChange()`

Timelock visibility is intentional. The main exposed effect is HookFee timing; LP fee ownership/accrual is unchanged.

### HookFee claim settlement

- Use `claimHookFees(...)` / `claimAllHookFees(...)` as owner.
- `claimAllHookFees(...)` has no recipient overload; full claim always pays to current `owner()`.
- Payout path is PoolManager accounting withdrawal: `unlock` -> `burn` -> `take`.
- Oversized payouts are chunked automatically so each `burn` / `take` fits PoolManager `int128` accounting bounds.
- `claimHookFees(...)` requires `to == owner()`.
- If pool includes native currency, recipient must be compatible with native payout from PoolManager sender context in the claim path.
- Local preflight/deploy flow validates this compatibility before deployment/ensure.
- If ownership changes later in a native-asset pool, keep this compatibility invariant.

## Pause vs emergency reset

### `pause()` / `unpause()`

- Freeze/resume controller evolution.
- Preserve fee regime and EMA.
- Clear only open `periodVol` and restart period boundary.
- Do not disable swaps.
- Do not disable HookFee accrual.

### Paused maintenance updates

- `setControllerParams(...)` preserves active regime + EMA, clears hold/streak counters, and starts a fresh open period.
- `setTimingParams(...)` behavior depends on what changed:
  - if `periodSeconds` or `emaPeriods` changed: safe reset to FLOOR, EMA/counters cleared, fresh open period, immediate LP-fee sync if needed.
  - if only `lullResetSeconds` and/or `deadbandBps` changed: preserve regime + EMA + counters, fresh open period only.

### Emergency resets (paused-only)

- `emergencyResetToFloor()`
- `emergencyResetToCash()`

Both clear EMA/streaks/hold counters and restart period. `resetToCash` is default emergency option unless floor lockdown is explicitly required.
If target tier already equals current tier, reset still applies but no `FeeUpdated` event is emitted.
Monitoring must consume `EmergencyResetToFloorApplied` / `EmergencyResetToCashApplied` events.

## Dust threshold operations

`minCountedSwapUsd6` is telemetry-only filtering and never blocks swaps.
Range for updates is `1e6..10e6`; default is `$4 / 4e6` (selected from observed v1 telemetry).

Flow:
1. `scheduleMinCountedSwapUsd6Change(value)`
2. optional `cancelMinCountedSwapUsd6Change()`
3. activation happens automatically at next period boundary.

Notes:
- No timelock for threshold updates (project decision).
- Recalibration target cadence: every 5 days from offchain analytics.
- Dust filtering is mitigation, not a formal proof against all fragmentation patterns on cheap L2.
- Overdue catch-up can close multiple periods in one swap; only the first close uses accumulated close volume and later closes use zero close volume.
- Multi-close downward sequences are accepted architectural/economic behavior in this scope and should be monitored as notable routing/yield events.

## Accepted governance risks

- Mitigation is operational: owner key controls + monitoring/alerting.
- Production owner must be multisig; local EOA owner is acceptable only for dev/test.
- Hot-wallet owner usage is unacceptable for production; use cold/hardware custody.
- Reuse of an existing hook in deploy/ensure/preflight is pinned to the canonical CREATE2 address for the current
  release and current constructor args, requires the exact minimal callback surface, exact PoolManager binding,
  current `minCountedSwapUsd6`, and zero pending owner / pending config changes.

Controller safety note:
- `emergencyFloorCloseVolUsd6` must remain strictly greater than zero.
- `emergencyFloorCloseVolUsd6` must remain strictly less than `minCloseVolToCashUsd6`.
- Hold semantics are `N -> N - 1`; production guidance is `cashHoldPeriods >= 2`, `extremeHoldPeriods >= 2` (recommended `3..4`).
- Non-local deploy/preflight paths block weak hold configs by default; explicit override: `ALLOW_WEAK_HOLD_PERIODS=1`.

## Monitoring minimums

- Track `PeriodClosed` and alert on repeated abnormal regime escalations.
- Track admin/security events: `RegimeFeesUpdated`, `ControllerParamsUpdated`, `TimingParamsUpdated`, `Paused`, `Unpaused`, emergency-reset events.
- Treat wash-trading and fee-poisoning as residual economic risks in adversarial routing environments.
