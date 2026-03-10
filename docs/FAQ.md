# FAQ

## Where is the authoritative behavior definition?

Contract NatSpec in `src/VolumeDynamicFeeHook.sol` is primary. `docs/SPEC.md` mirrors it for operations.

## Can I change parameters without redeploy?

Yes, Owner can update runtime config onchain:
- `setFeeTiersAndRoles(...)` (paused only)
- `setControllerParams(...)` (paused only)
- `setTimingParams(...)` (paused only)
- `setHookFeeRecipient(...)`
- HookFee timelock flow (`schedule/cancel/execute`)

## Is HookFee the same as LP fee?

No.
- LP fee belongs to pool accounting.
- HookFee is an extra trader-facing fee returned from `afterSwap` delta.

## Does HookFee use `poolManager.take()` in swap path?

No. Swap path uses `afterSwap` return delta plus `poolManager.mint(...)` to persist claim accounting.
Actual payout happens later in claim flow via `unlock` -> `burn` -> `take`.

## How is HookFee bounded?

`hookFeePercent` is hard-capped at 10% and can only change through 48-hour timelock.

## What does pause do now?

`pause()` freezes controller evolution but does not reset to floor by default.
It preserves fee regime and EMA, clears only open period volume, and restarts period clock.
It does not stop swaps and does not stop HookFee accrual.

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

Default is `4e6` (USD6).
Allowed update range is `1e6..10e6`.

## Can threshold changes apply mid-period?

No. Scheduled threshold changes are activated only at next period boundary.
This path intentionally has no timelock.

## Is `setHookFeeRecipient(...)` timelocked?

No. Recipient change is immediate by design and treated as accepted owner-key governance risk.

## Is `approxLpFeesUsd6` accounting-accurate?

No. It is approximate telemetry for regime analytics.

## Why does `receive()` revert?

To avoid accidental ETH transfers into hook accounting. ETH movement is explicit through `rescueETH(...)`.
