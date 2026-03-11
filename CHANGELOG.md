# CHANGELOG

## v2.0.5 - 2026-03-11

### Release summary
- Fixed controller misconfiguration trap: `0 < emergencyFloorCloseVolUsd6 < minCloseVolToCashUsd6` is now enforced onchain in shared validation path.
- Updated paused `setTimingParams(...)` semantics:
  - time-scale updates (`periodSeconds` / `emaPeriods`) perform safe reset to FLOOR with EMA/counter reset and immediate LP-fee sync when tier changes;
  - non-time-scale updates preserve regime + EMA + counters and only restart open period.
- Updated paused `setControllerParams(...)` semantics:
  - preserve active regime + EMA,
  - clear hold/streak counters,
  - restart fresh open period.
- Added/updated tests for constructor/admin guards, timing reset split behavior, and stale-counter clearing after controller updates.
- Added deploy/preflight guardrails and docs for weak hold configs in non-local runtime
  (`ALLOW_WEAK_HOLD_PERIODS` explicit override).
- Added explicit source-of-truth hierarchy document (`SOURCE_OF_TRUTH.md`) and aligned README/SPEC/FAQ/runbooks.


## v2.0.4 - 2026-03-11

### Release summary
- Release notes captured in git history and audit bundle updates.


## v2.0.3 - 2026-03-10

### Release summary
- Release notes captured in git history and audit bundle updates.


## v2.0.2 - 2026-03-10

### Release summary
- Release notes captured in git history and audit bundle updates.


## v2.0.1 - 2026-03-10

### Packaging cleanup
- Kept gas artifacts only inside the final audit archive bundle.

## v2.0.0 - 2026-03-10

### Final hardening baseline
- Synced dust-threshold defaults, controller checks, documentation, and audit bundle state for the hardened baseline.

## v1.1.0 - 2026-02-17

### Immediate pause/unpause fee application
- `pause()` and `unpause()` now apply the target fee immediately for initialized pools via direct `PoolManager.updateDynamicLPFee(...)` calls from the hook.
- Pre-initialize behavior remains safe: pending application is still supported and resolved on initialize.

### Tick spacing standardization
- Standardized deployment configs to `TICK_SPACING=10` across environments.
- Updated tests to use `tickSpacing = 10`.

### Test coverage expansion
- Added deterministic tests for:
  - immediate pause/unpause application
  - pending-apply no-op behavior
  - pre-initialize pause flow
  - deadband stability
  - reversal-lock behavior
  - multi-period catch-up
  - lull reset behavior

### Script and tooling hardening
- Improved deployment and operations scripts:
  - robust config fallback (`<chain>.conf` -> default conf)
  - safer RPC resolution (CLI overrides config)
  - stricter required variable checks
  - wallet flag auto-wiring for `--broadcast`
- Aligned Foundry script env usage (`HOOK_ADDRESS` in `CreatePool.s.sol`).
- Moved script artifacts under `scripts/out/{broadcast,cache}` and updated docs.

## 2026-02-14

### Updated fee model
- Switched from `score = volumeUSD * fee` to a **volume-regime** model:
  - Maintain `emaVolume` (EMA of period volume).
  - Adjust fee based on deviation of `volumeUSD` from `emaVolume`.
- Enforced **max one step per period** (`maxStep = 1`).

### Updated fee buckets
- New fixed buckets (feeUnits):
  - `[95, 400, 900, 2500, 3000, 6000, 9000]`

### Explicit cap behavior
- Added `capIdx` (immutable) and documented it prominently.
- Default `capIdx` is the index of `3000` (0.30%), but it is configurable at deploy time.

### Inactivity handling
- Added `lullResetSeconds` (immutable). On the first swap after a long lull, the hook resets
  `feeIdx` to floor regime and clears `emaVolume` to re-learn quickly.

### License
- Set license to Apache-2.0.

## 2026-02-15

### Catch-up for missed periods
- Implemented an exact **fast-forward** mechanism when multiple full periods elapse between swaps (within the lull corridor).
- Simulates `k = floor(elapsed / PERIOD_SECONDS)` closes in memory:
  - first close uses the accumulated `volumeUSD`
  - remaining closes use `0` volume
- Correctly simulates `lastDir` (reversal-lock) inside the loop.
- Batches writes: at most **one** `updateDynamicLPFee` call for the final `feeIdx`.
