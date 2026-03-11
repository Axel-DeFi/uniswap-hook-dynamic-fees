# FAQ

## Where is the authoritative behavior definition?

See `SOURCE_OF_TRUTH.md` for hierarchy.
Short form: contract NatSpec in `src/VolumeDynamicFeeHook.sol` is primary, `docs/SPEC.md` is normative operational mirror, README/runbooks are operational guidance.
Legacy concept PDFs are archival and non-normative for this repository behavior.

## Can I change parameters without redeploy?

Yes, Owner can update runtime config onchain:
- `setRegimeFees(...)` (paused only)
- `setControllerParams(...)` (paused only)
- `setTimingParams(...)` (paused only)
- `setHookFeeRecipient(...)`
- HookFee timelock flow (`schedule/cancel/execute`)

## What exactly happens on `setTimingParams(...)`?

Two explicit paths:
- Time-scale change (`periodSeconds` or `emaPeriods`) does a safe reset: FLOOR regime, EMA reset, counters reset, fresh open period, immediate LP-fee sync if tier changed.
- Non-time-scale change (only `lullResetSeconds` / `deadbandBps`) preserves regime + EMA + counters and only restarts open period.

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
It does not stop swaps and does not stop HookFee accrual.
The active LP fee regime stays frozen until `unpause()` or explicit paused-mode emergency reset.

## How do hold periods work?

Hold counter is decremented at the start of each closed period.
Configured hold `N` gives `N - 1` fully protected periods.
`cashHoldPeriods = 1` means zero effective extra hold protection.
Production guidance is `cashHoldPeriods >= 2` and `extremeHoldPeriods >= 2` (recommended `3..4`).
Non-local deploy/preflight guardrails block weak hold configs by default unless `ALLOW_WEAK_HOLD_PERIODS=true` is explicitly set.

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

## Is `setHookFeeRecipient(...)` timelocked?

No. Recipient change is immediate by design and treated as accepted owner-key governance risk.

No-op update (`newRecipient == currentRecipient`) is ignored and does not emit `HookFeeRecipientUpdated`.

Production guidance:
- owner must be multisig,
- owner key custody should be cold/hardware,
- hot-wallet owner usage is unacceptable for production,
- recipient-change event monitoring is mandatory.

## Do native-asset pools require a native-compatible `hookFeeRecipient`?

Yes. If one pool currency is native (`address(0)`), claim payout can include native transfer from the hook.
Deployment/ensure/preflight flows validate recipient native-payout compatibility; zero-address checks alone are not enough.
If governance changes `hookFeeRecipient` later, this compatibility requirement must still be preserved.

## Is `approxLpFeesUsd6` accounting-accurate?

No. It is approximate telemetry for regime analytics.

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
