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
- Timelock transparency is intentional; the main exposed effect is HookFee timing. LP fee ownership/accrual for LPs is unchanged.

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

## Overdue catch-up semantics (accepted behavior)

- A single swap can close multiple overdue periods when `elapsed / periodSeconds > 1`.
- In this catch-up path, only the first closed period uses accumulated close volume from the open period.
- Subsequent closed periods in the same transaction use `closeVol = 0`.
- Under these semantics, one transaction can move fee state down by multiple steps (`REASON_DOWN_TO_CASH` / `REASON_DOWN_TO_FLOOR`) depending on current counters and thresholds.
- This is accepted in current scope as an architectural/economic trade-off, primarily affecting LP yield/routing behavior rather than LP principal ownership.
- Operations should monitor repeated multi-close downward sequences in `PeriodClosed` as notable behavior.

## Hold semantics

- Hold counter is decremented at the start of each closed period, before hold protection checks.
- Configured hold `N` therefore provides `N - 1` fully protected periods.
- `cashHoldPeriods = 1` provides zero effective extra hold protection.
- This behavior is intentional in the current design and is regression-tested.

## Controller parameter consistency

Controller params are validated with cross-invariants:
- `minCloseVolToCashUsd6 <= minCloseVolToExtremeUsd6`
- `upRToCashBps <= upRToExtremeBps`
- `downRFromCashBps >= downRFromExtremeBps`
- `emergencyFloorCloseVolUsd6 > 0`

Invalid combinations revert with `InvalidConfig`.

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

- `minCountedSwapUsd6` default is `$4 / 4e6`.
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
- default `$4 / 4e6` was selected from observed v1 telemetry.
- this is mitigation, not a formal proof against all dust-fragmentation patterns on cheap L2.

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

Bootstrap behavior:
- EMA is seeded by the first non-zero close period.
- first periods after init/reset should be treated as a calibration window.

Saturation behavior:
- `periodVol` saturates at `uint64.max` by design under theoretical/extreme flow.
- this is bounded behavior and not expected under ordinary trading conditions.

## State model cleanup

Removed legacy entities:
- legacy cap index field
- legacy direction marker field
- legacy next-fee wrapper function

Controller invariant remains:
- `floorIdx < cashIdx < extremeIdx`

Bit-packing note:
- packed `_state` layout is retained intentionally for gas/storage efficiency.
- correctness is covered by unit/fuzz/invariant tests (field bounds and transitions).

## Approximate LP fee metric

`PeriodClosed` emits:
- `approxLpFeesUsd6`

This metric is approximate telemetry only, not accounting-grade LP revenue.

## ETH handling

- `receive()` always reverts.
- ETH can be moved only through explicit admin rescue:
  - `rescueETH(uint256)`

## Claim and rescue

HookFee accrual/claim surface:
- `hookFeesAccrued()`
- `claimHookFees(address,uint256,uint256)`
- `claimAllHookFees()`

Recipient semantics:
- `claimAllHookFees()` always pays to current `hookFeeRecipient`.
- `claimHookFees(address,uint256,uint256)` requires `to == hookFeeRecipient`.
- No-op `setHookFeeRecipient(...)` updates do not emit `HookFeeRecipientUpdated`.

Claim settlement path:
1. owner request enters `poolManager.unlock(...)`,
2. callback burns hook ERC6909 claims (`burn`),
3. callback withdraws underlying currency (`take`) to `HookFeeRecipient`.

Native recipient compatibility:
- For pools with native currency in `token0` or `token1`, claim payout can include native transfer from the hook.
- Deployment/ensure/preflight flows validate that configured `hookFeeRecipient` can receive native payout from hook sender context.
- Zero-address recipient checks alone are insufficient for native-asset pools.

Rescue surface:
- `rescueToken(Currency,uint256)` (non-pool currencies only)
- `rescueETH(uint256)`

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
- wash-trading / extreme-tier manipulation remains a residual economic risk (more realistic as competitor-funded distortion/DoS in adversarial routing contexts, especially on cheap environments).
- multi-period catch-up with first-period volume + subsequent zero-volume closes remains accepted as architectural/economic behavior in this scope.

## Operational requirements

- production owner must be a multisig; EOA owner is acceptable only for local/dev/test.
- hot-wallet owner usage is unacceptable for production.
- owner key custody should use cold/hardware wallet standards.
- monitor `PeriodClosed` and alert on repeated abnormal regime escalations.
- monitor recipient-change events (`HookFeeRecipientUpdated`) as a mandatory operational control.
- for native-asset pools, any governance update to `hookFeeRecipient` must preserve native payout compatibility.
- EMA preservation across `setFeeTiersAndRoles(...)` is intentional for minor fee-ladder maintenance updates.
- for material fee-ladder or controller reconfiguration, keep paused, apply maintenance updates, run explicit emergency reset-to-floor, then unpause.

## Hook key validation

Pool callback key validation requires:
- exact currencies, tick spacing, and hook address,
- exact fee flag match: `key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG`.

Any non-exact dynamic-flag encoding is rejected (`NotDynamicFeePool`).

## Gas interpretation note

- inactivity catch-up overhead in period-closing logic is bounded by construction (`periods = elapsed / periodSeconds` with explicit loop semantics).
- measurement flow includes: normal swap, single-period close, lull reset, and worst-case catch-up (`MAX_LULL_PERIODS - 1` closed periods with inactivity just below lull reset).
- gas observations in this repository are engineering measurements, environment-dependent.
- this is not presented as a formal, exhaustive gas audit.
- latest local observation artifacts:
  - `ops/local/out/reports/*.json`
  - `ops/local/out/reports/*.md`
  - `audit/gas/*.json` (inside audit bundle package)
  - `audit/gas/*.md` (inside audit bundle package)

## Audit boundary

### Audit Scope

- hardening and behavior verification for `src/VolumeDynamicFeeHook.sol` and directly related operational docs/tests.

### Out of Scope

- independent review of external Uniswap dependency internals.
- independent review of PoolManager internals beyond call-site assumptions.
- independent review of hook address mining procedure correctness as a cryptographic/system proof.

### Assumptions

- `BaseHook`, `LPFeeLibrary`, and related Uniswap dependencies are treated as trusted dependencies for this review scope.
- hook deployment process verifies mined hook flags at deployment time.

### Operational Measurements

- local gas values are engineering measurements and environment-dependent.
- if live-network measurements are not reproduced in a run, reports must state that explicitly.
