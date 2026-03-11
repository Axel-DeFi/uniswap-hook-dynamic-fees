# Sepolia Runbook

## Read-only gate

```bash
ops/sepolia/scripts/preflight.sh
ops/sepolia/scripts/inspect.sh
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

Stop if preflight fails.
`smoke/full/rerun-safe/emergency` wrappers enforce this gate by default.

## Ensure state

```bash
ops/sepolia/scripts/ensure-hook.sh
ops/sepolia/scripts/ensure-pool.sh
ops/sepolia/scripts/ensure-liquidity.sh
```

`ensure-hook.sh` reuses a valid hook; if existing hook is stale/invalid, it deploys a replacement hook and refreshes state.

## Validation suite

```bash
ops/sepolia/scripts/smoke.sh
ops/sepolia/scripts/full.sh
ops/sepolia/scripts/rerun-safe.sh
ops/sepolia/scripts/emergency.sh
```

## Owner flows

### Owner transfer

- `proposeNewOwner(newOwner)`
- optional `cancelOwnerTransfer()`
- `acceptOwner()` by pending owner

### HookFee percent timelock

- `scheduleHookFeePercentChange(newPercent)`
- optional `cancelHookFeePercentChange()`
- `executeHookFeePercentChange()` after 48h

Timelock visibility is intentional. The main exposed effect is HookFee timing; LP fee ownership/accrual is unchanged.

### HookFee claim settlement

- Use `claimHookFees(...)` / `claimAllHookFees(...)` as owner.
- `claimAllHookFees(...)` has no recipient overload; full claim always pays to current `owner()`.
- Payout path is PoolManager accounting withdrawal: `unlock` -> `burn` -> `take`.
- `claimHookFees(...)` requires `to == owner()`.
- If pool includes native currency, recipient must be compatible with native payout from PoolManager sender context in the claim path.
- Sepolia preflight/ensure flow validates this compatibility before deploy/reuse success.
- If ownership changes later in a native-asset pool, preserve this compatibility invariant.

## Runtime semantics reminder

- `pause()`/`unpause()` are freeze/resume, not implicit floor reset.
- Pause does not disable swaps and does not disable HookFee accrual.
- Emergency resets are explicit and paused-only:
  - `emergencyResetToFloor()`
  - `emergencyResetToCash()`
- `resetToCash` is default emergency path unless strict floor mode is required.
- If reset target tier already equals current tier, state still resets and emits reset event, but no `FeeUpdated`.
- Monitoring should consume reset events, not only fee update events.
- Paused maintenance updates:
  - `setControllerParams(...)` preserves regime + EMA, clears counters, and starts a fresh open period.
  - `setTimingParams(...)` does a safe reset only for time-scale changes (`periodSeconds`/`emaPeriods`); otherwise it preserves regime + EMA + counters and restarts open period only.

## Telemetry controls

- `minCountedSwapUsd6` filters dust from telemetry only.
- Swap execution and fee charging are unchanged for filtered trades.
- Scheduled threshold changes activate only at next period boundary.
- Allowed threshold update range is `1e6..10e6` (default `$4 / 4e6`, selected from observed v1 telemetry).
- No timelock for threshold updates (project decision).
- Recalibration target cadence: every 5 days from offchain analytics.
- This is mitigation, not a formal proof against all fragmentation patterns on cheap L2.
- Overdue catch-up can close multiple periods in one swap; only the first close uses accumulated close volume and later closes use zero close volume.
- Multi-close downward sequences are accepted architectural/economic behavior in this scope and should be monitored as notable routing/yield events.

## Accepted governance risks

- This is accepted owner-key risk; mitigation is operational in current scope.
- Production owner must be multisig; EOA owner is acceptable only for local/dev/test.
- Hot-wallet owner usage is unacceptable for production.
- Owner key custody should be cold/hardware.

Controller safety note:
- `emergencyFloorCloseVolUsd6` must remain strictly greater than zero.
- `emergencyFloorCloseVolUsd6` must remain strictly less than `minCloseVolToCashUsd6`.
- Hold semantics are `N -> N - 1`; production guidance is `cashHoldPeriods >= 2`, `extremeHoldPeriods >= 2` (recommended `3..4`).
- Non-local deploy/preflight paths block weak hold configs by default; explicit override: `ALLOW_WEAK_HOLD_PERIODS=1`.

## Monitoring and response

- Monitor `PeriodClosed` for repeated abnormal regime escalations.
- Monitor admin/security events: `RegimeFeesUpdated`, `ControllerParamsUpdated`, `TimingParamsUpdated`, `Paused`, `Unpaused`, emergency reset events.
- Treat wash-trading / fee-poisoning as residual economic manipulation risk, especially on low-cost networks.
