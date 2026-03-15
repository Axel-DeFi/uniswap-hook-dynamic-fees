# VolumeDynamicFeeHook Specification

This document follows contract NatSpec in `src/VolumeDynamicFeeHook.sol` and is the normative operational mirror for behavior.
If there is any mismatch, contract NatSpec takes precedence over this document, and this document takes precedence over README/FAQ/runbooks.

## Scope

`VolumeDynamicFeeHook` is a single-pool Uniswap v4 hook that:
- tracks stable-side notional volume (`USD6`) per period,
- updates LP fee using an explicit three-regime controller,
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
- `Owner`: claim recipient in HookFee withdrawal path.
- `LPs`: receive LP fee as part of pool accounting.
- `Traders`: pay LP fee and optional HookFee.

## Fee model

### LP fee

LP fee remains dynamic and is updated through the existing regime logic.

### HookFee

- HookFee is a separate trader charge returned from `afterSwap` delta path.
- HookFee is numerically tied to currently applied LP fee for active regime.
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
- `setTimingParams(...)` semantics are explicit:
  - if `periodSeconds` or `emaPeriods` changes, this is a time-scale change and triggers a safe reset:
    FLOOR regime, EMA reset, hold/streak counters reset, fresh open period, immediate LP-fee sync when active tier changes.
  - if only `lullResetSeconds` and/or `deadbandBps` changes, regime + EMA + counters are preserved and only a fresh open period is started.

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
- Automatic emergency floor evaluation has priority over hold protection.
- If `closeVol < emergencyFloorCloseVolUsd6` for `emergencyConfirmPeriods` consecutive closes, the controller resets
  to `FLOOR` even when `holdRemaining > 0`.
- This behavior is intentional in the current design and is regression-tested.

## Controller parameter consistency

Controller params are validated with cross-invariants:
- `minCloseVolToCashUsd6 <= minCloseVolToExtremeUsd6`
- `upRToCashBps <= upRToExtremeBps`
- `downRFromCashBps >= downRFromExtremeBps`
- `deadbandBps < downRFromExtremeBps`
- `deadbandBps < downRFromCashBps`
- `0 < emergencyFloorCloseVolUsd6 < minCloseVolToCashUsd6`

Invalid combinations revert with `InvalidConfig`.

Paused maintenance behavior:
- `setControllerParams(...)` preserves active regime id and EMA.
- It always clears hold/streak counters (`holdRemaining`, `upExtremeStreak`, `downStreak`, `emergencyStreak`).
- It always starts a fresh open period (`periodVol = 0`, refreshed `periodStart`).

## Pause and emergency semantics

### pause()

Freeze semantics only:
- keeps fee regime and streak counters,
- keeps EMA,
- clears only open-period volume,
- restarts period boundary (`periodStart`) for clean resume.
- freezes regulator transitions at the last active LP fee regime until `unpause()` or explicit paused-mode emergency reset.
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
- set target regime id,
- reset EMA to zero,
- clear hold/streak counters,
- reset `periodVol` and restart `periodStart`,
- keep contract paused.
- when target regime equals current regime, reset still happens but no `FeeUpdated` event is emitted.

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
Configured stable decimals mode is exposed as `stableDecimals()` for deployment/reuse validation.

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
- arbitrary fee-tier arrays and index-driven tier-role plumbing
- legacy cap index field
- legacy direction marker field
- legacy next-fee wrapper function

Controller model now uses fixed regime ids:
- `0 = FLOOR`
- `1 = CASH`
- `2 = EXTREME`

Bit-packing note:
- packed `_state` layout is retained intentionally for gas/storage efficiency.
- correctness is covered by unit/fuzz/invariant tests (field bounds and transitions).

## Approximate LP fee metric

`PeriodClosed` emits:
- `approxLpFeesUsd6`

This metric is approximate telemetry only, not accounting-grade LP revenue.

## Period-close diagnostics

`ControllerTransitionTrace` is emitted as a compact telemetry companion to `PeriodClosed`.
It is an additive event only and does not replace `PeriodClosed` or `FeeUpdated`.

Emission rules:
- emits only on period-close path inside `_afterSwap()` and on the explicit lull-reset path,
- does not emit for ordinary in-period swaps,
- keeps existing event behavior unchanged:
  `PeriodClosed` still emits for every close, `FeeUpdated` still emits only when active fee actually changes.

Field semantics:
- `periodStart`: start timestamp of the period being closed. In multi-close catch-up, this advances by `periodSeconds` per closed period.
- `fromFee` / `fromFeeIdx`: regime before controller evaluation for this closed period.
- `toFee` / `toFeeIdx`: regime after controller evaluation for this closed period.
- `closeVolumeUsd6`: counted volume of the closed period (`0` for zero-volume catch-up closes and lull reset).
- `emaBeforeUsd6Scaled`: EMA before `_updateEmaScaled(...)`.
- `emaAfterUsd6Scaled`: EMA immediately after `_updateEmaScaled(...)`. This is still non-zero for ordinary zero-volume closes; only lull reset forces it to `0`.
- `approxLpFeesUsd6`: same approximate telemetry metric as `PeriodClosed`, based on `fromFee`.
- `reasonCode`: unchanged controller reason code already used by `PeriodClosed`.

Compact counter packing:
- `countersBefore` and `countersAfter` use:
  bit `0` paused,
  bits `1..5` holdRemaining,
  bits `6..7` upExtremeStreak,
  bits `8..10` downStreak,
  bits `11..12` emergencyStreak.
- These counters describe the controller state immediately before and immediately after the close evaluation, not the long-lived packed `_state` bit positions.

Compact decision flag packing:
- bit `0`: `bootstrapV2`
- bit `1`: `deadbandBlocked`
- bit `2`: `holdWasActive`
- bit `3`: `emergencyTriggered`
- bit `4`: `upCashRaw`
- bit `5`: `upExtremeRaw`
- bit `6`: `downExtremeRaw`
- bit `7`: `downCashRaw`

Interpretation notes:
- `holdWasActive` refers to the pre-decrement hold state at close start; `countersAfter` reflects post-decrement/post-transition counters.
- `deadbandBlocked` means a raw threshold was reached but the deadband still prevented the transition on that close.
- `emergencyTriggered` means the automatic emergency-floor rule fired before ordinary regime logic.
- raw-direction flags are diagnostic hints for what the controller observed on that close; they do not imply a transition actually happened.

Lull reset trace semantics:
- `closeVolumeUsd6 = 0`
- `emaBeforeUsd6Scaled =` previous EMA
- `emaAfterUsd6Scaled = 0`
- `approxLpFeesUsd6 = 0`
- `decisionFlags = 0`
- `countersBefore` captures the pre-reset controller counters and `countersAfter` is the zeroed post-reset state.

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
- `claimAllHookFees()` always pays to current `owner()`.
- `claimHookFees(address,uint256,uint256)` requires `to == owner()`.
- Ownership transfer (`proposeNewOwner` -> `acceptOwner`) automatically moves payout destination.

Claim settlement path:
1. owner request enters `poolManager.unlock(...)`,
2. callback burns hook ERC6909 claims (`burn`) in one or more chunks when needed,
3. callback withdraws underlying currency (`take`) to current owner, chunked to stay within PoolManager `int128` accounting bounds.

Native recipient compatibility:
- For pools with native currency in `token0` or `token1`, claim payout can include native transfer via the PoolManager claim path.
- Deployment/ensure/preflight flows validate that current owner can receive native payout from PoolManager sender context in the claim path.
- Owner configuration must preserve native payout compatibility in native-asset pools.

Rescue surface:
- `rescueToken(Currency,uint256)` (non-pool currencies only)
- `rescueETH(uint256)`

## Event coverage

All admin state transitions emit events, including:
- ownership transitions,
- timelock schedule/cancel/execute,
- threshold schedule/cancel/apply,
- pause/unpause,
- emergency resets,
- controller/regime/timing updates.

Monitoring interpretation note:
- `downStreak` is context-dependent and must be interpreted together with current `feeIdx`.
- In CASH it tracks cash->floor confirmations; in EXTREME it tracks extreme->cash confirmations.

## Accepted risks in current scope

- Mitigation remains operational (key management + monitoring), not contract-level in this patch scope.
- wash-trading / extreme-tier manipulation remains a residual economic risk (more realistic as competitor-funded distortion/DoS in adversarial routing contexts, especially on cheap environments).
- multi-period catch-up with first-period volume + subsequent zero-volume closes remains accepted as architectural/economic behavior in this scope.

## Operational requirements

- production owner must be a multisig; EOA owner is acceptable only for local/dev/test.
- hot-wallet owner usage is unacceptable for production.
- owner key custody should use cold/hardware wallet standards.
- deploy/ensure/preflight reuse of an existing hook is pinned to the canonical CREATE2 address derived from the
  current release and the frozen `ops/<network>/config/deploy.env` constructor snapshot, while current runtime/admin
  expectations come from `ops/<network>/config/defaults.env`. Reuse also requires the exact minimal callback surface
  (`afterInitialize`, `afterSwap`, `afterSwapReturnDelta` only) plus exact PoolManager binding: owner, no pending
  owner transfer, stable decimals mode, current `minCountedSwapUsd6`, regime fees, HookFee percent, timing params,
  controller params, and no pending HookFee / min-counted-swap changes.
- monitor `PeriodClosed` and alert on repeated abnormal regime escalations.
- consume `ControllerTransitionTrace` together with `PeriodClosed` when debugging controller decisions, especially
  deadband-blocked closes, hold-protected closes, emergency-floor triggers, and lull resets.
- monitor admin/security events as a minimum set:
  `RegimeFeesUpdated`, `ControllerParamsUpdated`, `TimingParamsUpdated`, `Paused`, `Unpaused`,
  `EmergencyResetToFloorApplied`, `EmergencyResetToCashApplied`.
- for native-asset pools, ownership changes must preserve native payout compatibility.
- EMA preservation across `setRegimeFees(...)` is intentional for paused maintenance updates.
- production guidance for hold parameters:
  `cashHoldPeriods >= 2`, `extremeHoldPeriods >= 2`, recommended `3..4`.
- deploy/preflight guardrails block weak hold configs in non-local runtime by default; explicit override is
  `ALLOW_WEAK_HOLD_PERIODS=true`.

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
  - `audit_bundle/validation/gas/*` (bundle workspace, generated by `scripts/build_audit_bundle.sh`)

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
