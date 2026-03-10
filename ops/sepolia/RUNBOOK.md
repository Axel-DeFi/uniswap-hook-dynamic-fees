# Sepolia Runbook

## Read-only gate

```bash
ops/sepolia/scripts/preflight.sh
ops/sepolia/scripts/inspect.sh
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
- `claimAllHookFees(...)` has no recipient overload; full claim always pays to current `hookFeeRecipient`.
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
- Allowed threshold update range is `1e6..10e6` (default `$4 / 4e6`, selected from observed v1 telemetry).
- No timelock for threshold updates (project decision).
- Recalibration target cadence: every 5 days from offchain analytics.
- This is mitigation, not a formal proof against all fragmentation patterns on cheap L2.

## Accepted governance risks

- `setHookFeeRecipient(...)` remains immediate by design.
- No-op recipient update does not emit `HookFeeRecipientUpdated`.
- This is accepted owner-key risk; mitigation is operational in current scope.
- Production owner must be multisig; EOA owner is acceptable only for local/dev/test.
- Hot-wallet owner usage is unacceptable for production.
- Owner key custody should be cold/hardware.

Controller safety note:
- `emergencyFloorCloseVolUsd6` must remain strictly greater than zero.

## Monitoring and response

- Monitor `PeriodClosed` for repeated abnormal regime escalations.
- Monitor `HookFeeRecipientUpdated` and emergency reset events.
- Treat wash-trading / fee-poisoning as residual economic manipulation risk, especially on low-cost networks.
- For material controller/topology reconfiguration: keep paused, apply maintenance changes, execute explicit emergency reset-to-floor, then resume.
