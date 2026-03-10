# Sepolia Runbook

## Read-only gate

```bash
ops/sepolia/scripts/preflight.sh
ops/sepolia/scripts/inspect.sh
```

Stop if preflight fails.

## Ensure state

```bash
ops/sepolia/scripts/ensure-hook.sh
ops/sepolia/scripts/ensure-pool.sh
ops/sepolia/scripts/ensure-liquidity.sh
```

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

### HookFee claim settlement

- Use `claimHookFees(...)` / `claimAllHookFees(...)` as owner.
- Payout path is PoolManager accounting withdrawal: `unlock` -> `burn` -> `take`.
- Recipient must match current `hookFeeRecipient`.

## Runtime semantics reminder

- `pause()`/`unpause()` are freeze/resume, not implicit floor reset.
- Pause does not disable swaps and does not disable HookFee accrual.
- Emergency resets are explicit and paused-only:
  - `emergencyResetToFloor()`
  - `emergencyResetToCash()`
- `resetToCash` is default emergency path unless strict floor mode is required.
- If reset target tier already equals current tier, state still resets and emits reset event, but no `FeeUpdated`.
- Monitoring should consume reset events, not only fee update events.

## Telemetry controls

- `minCountedSwapUsd6` filters dust from telemetry only.
- Swap execution and fee charging are unchanged for filtered trades.
- Scheduled threshold changes activate only at next period boundary.
- Allowed threshold update range is `1e6..10e6` (default `4e6`).
- No timelock for threshold updates (project decision).
- Recalibration target cadence: every 5 days from offchain analytics.

## Accepted governance risks

- `setHookFeeRecipient(...)` remains immediate by design.
- This is accepted owner-key risk; mitigation is operational in current scope.
