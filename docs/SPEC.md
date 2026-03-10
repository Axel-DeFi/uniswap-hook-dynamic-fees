# VolumeDynamicFeeHook Specification

This document follows contract NatSpec in `src/VolumeDynamicFeeHook.sol` and is the operational source for behavior.

## Scope

`VolumeDynamicFeeHook` is a single-pool Uniswap v4 hook that:
- tracks stable-side notional volume (`USD6`) per period,
- updates LP fee tiers using a regime controller,
- charges an additional HookFee to traders via `afterSwap` return delta,
- persists accrued HookFees in PoolManager ERC6909 claims and allows explicit owner-driven claim.

## Permissions and hook flags

Enabled permissions:
- `afterInitialize = true`
- `afterSwap = true`
- `afterSwapReturnDelta = true`

No other hook callbacks are enabled.

Address mining must include:
- `Hooks.AFTER_INITIALIZE_FLAG`
- `Hooks.AFTER_SWAP_FLAG`
- `Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG`

## Roles and accounting entities

- `Owner`: admin role.
- `HookFeeRecipient`: recipient allowed by claim path.
- `LPs`: receive LP fee as part of pool accounting.
- `Traders`: pay LP fee and optional HookFee.

`Owner` and `HookFeeRecipient` are intentionally distinct names and concepts.

## Fee model

### LP fee

LP fee remains dynamic and is updated through the existing regime logic.

### HookFee

- HookFee is a separate trader charge returned from `afterSwap` delta path.
- HookFee is numerically tied to currently applied LP fee tier.
- HookFee is derived from an approximate LP-fee estimate, not from an exact LP-fee accounting replica.
- Estimation base is the unspecified side selected by current execution path (exact-input vs exact-output).
- Small systematic deviation between exact-input and exact-output paths is expected by design.
- Per swap approximation:
  1. infer unspecified-side absolute swap amount,
  2. estimate LP fee on that amount,
  3. apply `hookFeePercent` (0..10) to estimated LP fee.

Swap accrual path uses `poolManager.mint(...)` (claim accounting), not direct token withdrawal.

### HookFee cap and timelock

- Hard max `MAX_HOOK_FEE_PERCENT = 10`.
- No runtime-configurable fee cap.
- `hookFeePercent` changes are timelocked for 48 hours:
  - `scheduleHookFeePercentChange(uint16)`
  - `cancelHookFeePercentChange()`
  - `executeHookFeePercentChange()`
- Only one pending HookFee change can exist.

## Owner transfer flow

Two-step transfer is mandatory:
- `proposeNewOwner(address)`
- `cancelOwnerTransfer()`
- `acceptOwner()` by pending owner

Guardrails:
- `proposeNewOwner(address(0))` reverts.
- `proposeNewOwner(currentOwner)` reverts (self-pending-owner is disallowed).

Events:
- `OwnerTransferStarted`
- `OwnerTransferCancelled`
- `OwnerTransferAccepted`
- `OwnerUpdated`

## Timing guardrails

- `lullResetSeconds` must be strictly greater than `periodSeconds`.
- Equality (`lullResetSeconds == periodSeconds`) is rejected.
- Upper bound remains `lullResetSeconds <= periodSeconds * MAX_LULL_PERIODS`.

## Hold semantics

- Hold counter is decremented at the start of each closed period, before hold protection checks.
- Configured hold `N` therefore provides `N - 1` fully protected periods.
- `cashHoldPeriods = 1` provides zero effective extra hold protection.
- This behavior is intentional in the current design and is regression-tested.

## Pause and emergency semantics

### pause()

Freeze semantics only:
- keeps fee regime and streak counters,
- keeps EMA,
- clears only open-period volume,
- restarts period boundary (`periodStart`) for clean resume.
- freezes regulator transitions at the last active LP fee tier until `unpause()` or explicit paused-mode emergency reset.
- does not disable swaps,
- does not disable HookFee accrual,
- does not zero HookFee.

### unpause()

Resume semantics:
- keeps fee regime/counters/EMA,
- starts a fresh open period,
- does not perform global reset.

### Emergency resets (paused-only)

- `emergencyResetToFloor()`
- `emergencyResetToCash()`

Both explicitly:
- set target fee index,
- reset EMA to zero,
- clear hold/streak counters,
- reset `periodVol` and restart `periodStart`,
- keep contract paused.
- when target tier equals current tier, reset still happens but no `FeeUpdated` event is emitted.

`resetToCash` is generally preferred as default emergency option when total floor reset is not required.
Monitoring must consume `EmergencyResetToFloorApplied` / `EmergencyResetToCashApplied`, not only `FeeUpdated`.

## Volume telemetry and dust filtering

- `minCountedSwapUsd6` default is `4e6`.
- Allowed update range is `[1e6, 10e6]`.
- If swap stable-side notional is below threshold:
  - swap still executes,
  - LP fee and HookFee still apply,
  - swap is excluded from period volume telemetry.

Threshold updates are staged:
- `scheduleMinCountedSwapUsd6Change(uint64)`
- `cancelMinCountedSwapUsd6Change()`

Scheduled threshold is activated only at next period boundary (never mid-period).
There is no timelock for this update path by project decision.

Calibration policy:
- onchain auto-recalibration is intentionally out of scope,
- threshold tuning is expected from offchain historical analysis,
- operational target cadence for recalibration is 5 days.

## Stable decimals and scaling

Allowed stable decimals:
- `6`
- `18`

Any other value reverts (`InvalidStableDecimals`).

Scaling path is explicit and bounded for USD6 conversion.

## EMA model

Stored EMA is scaled:
- storage field: `emaVolumeUsd6Scaled`
- scale factor: `1e6`

This reduces integer precision loss versus unscaled EMA.

## State model cleanup

Removed legacy entities:
- legacy cap index field
- legacy direction marker field
- legacy next-fee wrapper function

Controller invariant remains:
- `floorIdx < cashIdx < extremeIdx`

## Approximate LP fee metric

`PeriodClosed` emits:
- `approxLpFeesUsd6`

This metric is approximate telemetry only, not accounting-grade LP revenue.

## ETH handling

- `receive()` always reverts.
- ETH can be moved only through explicit admin rescue:
  - `rescueETH(address,uint256)`

## Claim and rescue

HookFee accrual/claim surface:
- `hookFeesAccrued()`
- `claimHookFees(address,uint256,uint256)`
- `claimAllHookFees()`
- `claimAllHookFees(address)`

Claim settlement path:
1. owner request enters `poolManager.unlock(...)`,
2. callback burns hook ERC6909 claims (`burn`),
3. callback withdraws underlying currency (`take`) to `HookFeeRecipient`.

Rescue surface:
- `rescueToken(Currency,uint256)` (non-pool currencies only)
- `rescueETH(address,uint256)`

## Event coverage

All admin state transitions emit events, including:
- ownership transitions,
- fee recipient updates,
- timelock schedule/cancel/execute,
- threshold schedule/cancel/apply,
- pause/unpause,
- emergency resets,
- controller/tier/timing updates.

## Accepted risks in current scope

- `setHookFeeRecipient(...)` remains immediate (no timelock), accepted as owner governance/key risk.
- Mitigation is operational (key management + monitoring), not contract-level in this patch scope.
