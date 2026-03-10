# Local Runbook

## Start / stop

```bash
ops/local/scripts/anvil-up.sh
ops/local/scripts/anvil-down.sh
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

## Admin operation model

### Ownership transfer (2-step)

1. Current owner calls `proposeNewOwner(newOwner)`.
2. Current owner may cancel via `cancelOwnerTransfer()`.
3. Pending owner finalizes with `acceptOwner()`.

### HookFee timelock (48h)

1. `scheduleHookFeePercentChange(newPercent)`
2. optional `cancelHookFeePercentChange()`
3. after delay: `executeHookFeePercentChange()`

### HookFee claim settlement

- Use `claimHookFees(...)` / `claimAllHookFees(...)` as owner.
- Payout path is PoolManager accounting withdrawal: `unlock` -> `burn` -> `take`.
- Recipient must match current `hookFeeRecipient`.

## Pause vs emergency reset

### `pause()` / `unpause()`

- Freeze/resume controller evolution.
- Preserve fee regime and EMA.
- Clear only open `periodVol` and restart period boundary.
- Do not disable swaps.
- Do not disable HookFee accrual.

### Emergency resets (paused-only)

- `emergencyResetToFloor()`
- `emergencyResetToCash()`

Both clear EMA/streaks/hold counters and restart period. `resetToCash` is default emergency option unless floor lockdown is explicitly required.
If target tier already equals current tier, reset still applies but no `FeeUpdated` event is emitted.
Monitoring must consume `EmergencyResetToFloorApplied` / `EmergencyResetToCashApplied` events.

## Dust threshold operations

`minCountedSwapUsd6` is telemetry-only filtering and never blocks swaps.
Range for updates is `1e6..10e6`; default is `4e6`.

Flow:
1. `scheduleMinCountedSwapUsd6Change(value)`
2. optional `cancelMinCountedSwapUsd6Change()`
3. activation happens automatically at next period boundary.

Notes:
- No timelock for threshold updates (project decision).
- Recalibration target cadence: every 5 days from offchain analytics.

## Accepted governance risks

- `setHookFeeRecipient(...)` is immediate (no timelock) by design.
- Mitigation is operational: owner key controls + monitoring/alerting.
