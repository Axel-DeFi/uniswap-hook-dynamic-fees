# VolumeDynamicFeeHook Audit Bundle (RU)

## Source of Truth

- Bundle rebuilt from scratch on 2026-03-10 from current workspace state only.
- Previous markdown bundle file was deleted before regeneration.
- Scope baseline:
  - Contract: `src/VolumeDynamicFeeHook.sol`
  - Tests: `ops/tests/unit`, `ops/tests/integration`, `ops/tests/fuzz`, `ops/tests/invariant`
  - Ops/docs: `README.md`, `docs/SPEC.md`, `docs/FAQ.md`, `ops/local/RUNBOOK.md`, `ops/sepolia/RUNBOOK.md`, `scripts/README.md`

## Active Findings Model

- Active model in this bundle: `Critical / High / Medium / Info` with issue IDs `M-*` and `I-*`.
- Legacy `F-*` naming is retired from active findings tracking in this deliverable.

## Findings Status

### Closed In Code

- `M-01` (misconfiguration trap): fixed.
  - Added validation in `_setControllerParamsInternal(...)` that `emergencyFloorCloseVolUsd6 == 0` reverts with `InvalidConfig()`.
  - Constructor path is covered through shared controller-param validation.
- `I-01` (dead branch): fixed.
  - Removed unreachable branch `periodStart > nowTs` from period catch-up path.
- `I-02` (redundant overload): fixed.
  - Removed `claimAllHookFees(address)` overload.
  - Kept single full-claim path `claimAllHookFees()`.
  - Updated script checks and docs accordingly.
- `I-03` (unused return value): fixed.
  - Removed unused `changed` return value from `_computeNextFeeIdxV2(...)`.
  - Cleaned signature, call sites, and tuple returns.
- `I-04` (event noise): fixed.
  - `setHookFeeRecipient(...)` now early-returns on no-op (`old == new`) and emits no `HookFeeRecipientUpdated` event.
- `I-05` (dead conversion branch): fixed.
  - Simplified `_toUsd6(...)` for supported stable decimals (6 or 18 only).
  - Removed unreachable `_scaleIsMul` branch and immutable.

### Documented by Design / Operational Warning

- `I-06`: not a code bug in current scope.
  - Behavior is documented as designed: configured `cashHoldPeriods = N` gives effective hold protection `N - 1`.
  - Explicit warning kept: `cashHoldPeriods = 1` gives zero effective extra hold protection.
  - Warning is present in:
    - `README.md`
    - `docs/SPEC.md`
    - `docs/FAQ.md`
    - NatSpec in `src/VolumeDynamicFeeHook.sol`

## Test Suite Rebuild

### Stale Checks Removed

- Removed obsolete script-level check that called deleted API `claimAllHookFees(address)`:
  - `test/scripts/simulate_fee_cycle.sh`
  - `scripts/anvil/preflight_local.sh`

### Added / Updated Coverage

- `M-01`
  - Constructor rejects zero emergency threshold (`ConfigAndEdges` test).
  - `setControllerParams` rejects zero emergency threshold (`Admin` test).
  - Positive emergency threshold still triggers emergency floor transition (`Admin` test).
- `I-01`
  - Added regression test for period catch-up alignment: periodStart remains aligned and never in future (`Admin` test).
- `I-02`
  - Removed obsolete overload checks from script-based test flows.
  - Claim flow coverage remains through `claimHookFees(...)` and `claimAllHookFees()` tests.
- `I-03`
  - Build/test suite updated to new `_computeNextFeeIdxV2(...)` signature.
- `I-04`
  - Added no-op recipient update test to ensure no `HookFeeRecipientUpdated` emission.
- `I-05`
  - Added 18-decimal conversion regression (`stable -> USD6` division path).
  - Supported decimals coverage retained (`6` and `18`, others revert).
- `I-06`
  - Existing semantic regression retained: `cashHoldPeriods = 1` gives zero effective extra hold protection.

## Documentation and Ops Sync

Synchronized with current behavior:
- `README.md`
- `docs/SPEC.md`
- `docs/FAQ.md`
- `ops/local/RUNBOOK.md`
- `ops/sepolia/RUNBOOK.md`
- `scripts/README.md`
- `ops/shared/config/schema.md`

Key sync points:
- `emergencyFloorCloseVolUsd6` must be strictly positive.
- Single full-claim API path (`claimAllHookFees()`).
- No event emission on no-op recipient update.
- Hold semantics warning (`N - 1`, and `N = 1` edge case).

## Build and Test Evidence

Commands executed in this workspace:
- `forge build`
- `forge test --offline --match-path 'ops/tests/unit/*.sol'`
- `forge test --offline --match-path 'ops/tests/integration/*.sol'`
- `forge test --offline --match-path 'ops/tests/fuzz/*.sol'`
- `forge test --offline --match-path 'ops/tests/invariant/*.sol' --match-contract VolumeDynamicFeeHookInvariant_Stable0_Tick10`
- `forge test --offline --match-path 'ops/tests/invariant/*.sol' --match-contract VolumeDynamicFeeHookInvariant_Stable1_Tick10`
- `forge test --offline --match-path 'ops/tests/invariant/*.sol' --match-contract VolumeDynamicFeeHookInvariant_Stable0_Tick60`
- `forge test --offline --match-path 'ops/tests/invariant/*.sol' --match-contract VolumeDynamicFeeHookInvariant_Stable1_Tick60`

Outcome summary:
- Build: success.
- Unit: 50/50 passed.
- Integration: 4/4 passed.
- Fuzz: 2/2 passed.
- Invariant suites: 24/24 passed across 4 configurations.

## Accepted Residual Risks (Separated From Open Findings)

- Economic manipulation risk in adversarial routing environments remains operationally managed.
- Immediate recipient update governance risk remains operationally managed.
- Telemetry dust filtering remains a mitigation, not a formal proof against all fragmentation patterns.

## Anti-Stale Verification

Forbidden token scan for this bundle file was executed after regeneration using the required deny-list from the production checklist.

Result:
- No forbidden token matches in `audit_bundle/audit_VolumeDynamicFeeHook_RU.md`.
