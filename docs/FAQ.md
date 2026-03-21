# FAQ

## Where is the authoritative behavior definition?

Short form: contract NatSpec in `src/VolumeDynamicFeeHook.sol` is primary, `docs/SPEC.md` is the normative operational mirror, and README/runbooks are operational guidance.
Legacy concept PDFs are archival and non-normative for this repository behavior.

## Can I change parameters without redeploy?

Yes, Owner can update runtime config onchain:
- `setRegimeFees(...)` (paused only)
- `setControllerParams(...)` (paused only)
- `setTimingParams(...)` (paused only)
- HookFee timelock flow (`schedule/cancel/execute`)

## What exactly happens on `setTimingParams(...)`?

Two explicit paths:
- Time-scale change (`periodSeconds` or `emaPeriods`) does a safe reset: FLOOR regime, EMA reset, counters reset, fresh open period, immediate LP-fee sync if tier changed.
- Non-time-scale change (only `lullResetSeconds`) preserves regime + EMA + counters and only restarts open period.

## What exactly happens on `setControllerParams(...)`?

While paused, it preserves active regime and EMA, clears hold/streak counters, and starts a fresh open period.
This avoids stale counter carry-over after config updates.

## Is HookFee the same as LP fee?

No.
- LP fee belongs to pool accounting.
- HookFee is an extra trader-facing fee returned from `afterSwap` delta.
- HookFee uses an approximate LP-fee estimate from the unspecified side, so exact-input vs exact-output can diverge by design.

## Is `proposeNewOwner(currentOwner)` allowed?

No. `proposeNewOwner(...)` rejects both zero address and current owner.

## Does HookFee use `poolManager.take()` in swap path?

No. Swap path uses `afterSwap` return delta plus `poolManager.mint(...)` to persist claim accounting.
Actual payout happens later in claim flow via `unlock` -> `burn` -> `take`.

## How is HookFee bounded?

`hookFeePercent` is hard-capped at 10% and can only change through 48-hour timelock.
Timelock transparency is intentional; the main exposed effect is HookFee timing. LP fee ownership/accrual is unchanged.

## What does pause do now?

`pause()` freezes controller evolution but does not reset to floor by default.
It preserves fee regime and EMA, clears only open period volume, and restarts period clock.
It does not stop swaps, but it does suspend HookFee accrual until `unpause()`.
The active LP fee regime stays frozen until `unpause()` or explicit paused-mode emergency reset.

## How do hold periods work?

Hold counter is decremented at the start of each closed period.
Configured hold `N` gives `N - 1` fully protected periods.
`cashHoldPeriods = 1` means zero effective extra hold protection.
Production guidance is `cashHoldPeriods >= 2` and `extremeHoldPeriods >= 2` (recommended `3..4`).
Non-local deploy/preflight guardrails block weak hold configs by default unless `ALLOW_WEAK_HOLD_PERIODS=true` is explicitly set.

## Can the automatic emergency floor trigger bypass hold protection?

Yes.
The automatic emergency floor trigger is evaluated before hold protection checks during normal unpaused runtime operation.
If consecutive closed periods stay below `emergencyFloorCloseVolUsd6` long enough to satisfy `emergencyConfirmPeriods`,
the controller resets to `FLOOR` even when `holdRemaining > 0`.

## Can one swap close multiple overdue periods?

Yes. If `elapsed / periodSeconds > 1`, one swap can close multiple overdue periods.
Only the first closed period uses accumulated close volume; later closes in the same transaction use zero close volume.
This can produce multi-step downward transitions and is accepted as an architectural/economic trade-off in current scope.
Treat repeated multi-close downward `PeriodClosed` sequences as notable monitoring signals.

## When should emergency reset be used?

Only when paused and explicit reset is required:
- `emergencyResetToFloor()` for full conservative reset.
- `emergencyResetToCash()` when you need fast recovery without forcing floor regime.

Operationally, `emergencyResetToCash()` is typically preferred default.
Monitoring should track emergency reset events directly, not only fee update events.

## What is `minCountedSwapUsd6`?

A telemetry dust filter:
- swaps below threshold are excluded from period volume statistics,
- swaps still execute and still pay LP fee/HookFee.

Default is `$4 / 4e6` (USD6), chosen from observed v1 telemetry.
Allowed update range is `1e6..10e6`.

This mitigates dust-splitting pressure but is not a formal proof against every fragmentation pattern on cheap L2.

## Can threshold changes apply mid-period?

No. Scheduled threshold changes are activated only at next period boundary.
This path intentionally has no timelock.

## How is HookFee payout recipient determined?

Payout recipient is always current `owner()`. There is no separate recipient setter.
After `proposeNewOwner(...)` + `acceptOwner()`, payout destination moves to new owner automatically, including for previously accrued and unclaimed HookFees.

Very large claims are settled in chunks under the hood so that `burn` / `take` stay within PoolManager `int128` accounting bounds.

## Do native-asset pools require a native-compatible owner?

Yes. If one pool currency is native (`address(0)`), claim payout can include native transfer from the PoolManager claim path.
Deployment/ensure/preflight flows validate owner native-payout compatibility; zero-address checks alone are not enough.
If ownership changes later, this compatibility requirement must still be preserved.

## Is `approxLpFeesUsd6` accounting-accurate?

No. It is approximate telemetry for regime analytics.

## What is `ControllerTransitionTrace`?

It is a compact diagnostics event emitted alongside `PeriodClosed` on:
- normal period close,
- multi-close catch-up periods,
- lull reset.

It does not replace `PeriodClosed` or `FeeUpdated`.
Use it when you need to understand why a close stayed in place, which trigger thresholds were met, whether hold protection applied, or whether the emergency rule forced floor.

Key points:
- `periodStart` identifies the specific closed period.
- `emaBeforeUsd6Scaled` / `emaAfterUsd6Scaled` show EMA before and after the close update.
- `countersBefore` / `countersAfter` compact-pack paused/hold/up/down/emergency counters around the decision.
- `decisionFlags` compact-pack bootstrap, hold-active, emergency-triggered, and trigger-hit signals.
- lull reset uses `closeVolumeUsd6 = 0`, `approxLpFeesUsd6 = 0`, and hard-resets `emaAfterUsd6Scaled` to `0`.

## When do ops flows reuse an existing hook?

Only when the existing hook is the canonical CREATE2 deployment derived from the current release and the frozen
`ops/<network>/config/deploy.env` constructor snapshot,
exposes the exact minimal callback surface, and matches the expected config identity:
- canonical mined hook address for current release + deployment snapshot,
- `poolManager()`,
- pool binding + exact permissions (`afterInitialize`, `afterSwap`, `afterSwapReturnDelta` only),
- `owner()`,
- no `pendingOwner()`,
- configured stable decimals mode,
- current `minCountedSwapUsd6()`,
- regime fees,
- `hookFeePercent`,
- timing params,
- controller params,
- and no pending `HookFeePercent` / `minCountedSwapUsd6` changes.

## Is wash-trading fully prevented onchain?

No. Residual manipulation risk remains (especially competitor-funded distortion / fee-poisoning in low-cost, adversarial routing environments).
Operational mitigations are conservative defaults plus monitoring of `PeriodClosed` and alerting on repeated abnormal regime escalations.

## Does `setRegimeFees(...)` reset EMA?

No. `setRegimeFees(...)` preserves EMA intentionally.
While paused, it resets hold/streak counters, starts a fresh open period, and keeps the current regime id.

## How does EMA bootstrap work after init/reset?

EMA is seeded by the first non-zero close period.
Early periods after init/reset should be treated as a calibration window.

## Can `periodVol` overflow?

It is intentionally bounded: `periodVol` saturates at `uint64.max` under theoretical/extreme flow.

## Is any dynamic fee encoding accepted in callbacks?

No. The key check is strict: `key.fee` must equal `LPFeeLibrary.DYNAMIC_FEE_FLAG` exactly.

## Why does `receive()` revert?

To avoid accidental ETH transfers into hook accounting. ETH movement is explicit through `rescueETH(uint256)`.

## Can emergency floor threshold be zero?

No. `emergencyFloorCloseVolUsd6` must be strictly greater than zero in constructor and paused config updates.
It must also stay strictly below `minCloseVolToCashUsd6`.
