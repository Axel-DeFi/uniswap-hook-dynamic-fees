# Source of Truth

- This bundle was rebuilt from scratch on March 10, 2026 after deleting the previous `audit_bundle/audit_VolumeDynamicFeeHook_RU.md` file.
- Source of truth for this bundle is the current workspace state only (code, tests, docs, runbooks, and generated artifacts at this revision).
- Primary contract: `src/VolumeDynamicFeeHook.sol`.
- Primary tests: `ops/tests/unit/*`, `ops/tests/integration/*`, `ops/tests/fuzz/*`.
- Primary docs and runbooks: `README.md`, `docs/SPEC.md`, `docs/FAQ.md`, `ops/local/RUNBOOK.md`, `ops/sepolia/RUNBOOK.md`, `scripts/README.md`, `docs/sepolia_simulate_fee_cycle_test_matrix.md`.
- Gas artifacts produced for this run:
  - `audit_bundle/gas_artifacts/gas.anvil.measurements.json`
  - `audit_bundle/gas_artifacts/gas.anvil.measurements.md`
  - `audit_bundle/gas_artifacts/forge.gas_report.unit_admin.txt`
  - `audit_bundle/gas_artifacts/gas.sepolia.not_reproduced.md`

# Executive Summary

- Final hardening patch applied for F-03 and F-06.
- Default dust threshold is synchronized as `$4 / 4e6` (`4_000_000`) across code, tests, docs, configs, and this bundle.
- No economic model redesign and no new governance mechanism were introduced.
- F-13 packaging defect is closed: stale bundle removed, new bundle generated from current workspace, anti-stale token check passed.

# Current Contract Architecture

- `VolumeDynamicFeeHook` is a single-pool hook with strict pool binding (`currency0`, `currency1`, `tickSpacing`, and hook address).
- Dynamic LP fee behavior is controlled by period-close state-machine logic with EMA (`emaVolumeUsd6Scaled`).
- Trader-facing `HookFee` is accrued in swap callbacks with return-delta based accounting and claimed through PoolManager accounting flow.
- Telemetry dust filter (`minCountedSwapUsd6`) only affects counted period volume and does not block swap execution.
- Paused mode preserves regime/EMA; emergency reset actions are explicit admin operations in paused mode.
- Packed state layout is intentionally retained; correctness is covered by unit/fuzz/invariant-style assertions.

# Threat Model

- External manipulation risks:
  - Dust fragmentation aimed at telemetry distortion.
  - Wash-trading / fee poisoning / regime manipulation.
  - Owner key misuse for privileged operations.
- Internal operational risks:
  - Misconfigured controller thresholds.
  - Approximation drift in HookFee vs LP-fee idealization.
  - Unsafe reconfiguration and maintenance sequences.
- Scope constraints for this patch:
  - No fee model redesign.
  - No additional governance layers.

# Findings Status

## Fixed in Code

- F-03 controller cross-validations implemented in `_setControllerParamsInternal(...)`:
  - `minCloseVolToCashUsd6 <= minCloseVolToExtremeUsd6`
  - `upRToCashBps <= upRToExtremeBps`
  - `downRFromCashBps >= downRFromExtremeBps`
  - Invalid combinations revert with existing `InvalidConfig()` custom error.
- F-06 exact dynamic-fee flag validation implemented in `_validateKey(...)`:
  - Strict check `key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG`.
- Default dust threshold fixed to `DEFAULT_MIN_COUNTED_SWAP_USD6 = 4_000_000`.

## Documented by Design

- F-04 HookFee approximation:
  - HookFee is approximate by design.
  - It is not an accounting-grade replica of LP fee.
  - Exact-input and exact-output paths may show small systematic deviation.
  - Approximation is accepted in current design.
- F-07 EMA preservation on `setFeeTiersAndRoles(...)`:
  - Preservation is intentional and acceptable for minor fee-ladder maintenance.
  - For material controller/topology changes, operator procedure is paused maintenance + explicit emergency reset-to-floor before return to live operation.
- F-08 EMA bootstrap:
  - EMA is seeded by the first non-zero close period.
  - Early periods after init/reset should be treated as calibration window.
- F-09 period volume saturation:
  - Saturation at `uint64.max` is theoretical/extreme and intentionally bounded.
- F-10 catch-up gas behavior:
  - Inactivity catch-up overhead is bounded by implementation limits.
  - Actual gas usage remains environment-dependent.
- F-11 bit-packing:
  - Packed layout is intentionally retained.
  - Correctness is supported by tests and invariant-style checks.

## Accepted Residual Risks

- F-01 dust-splitting:
  - Residual architectural/model risk.
  - Mitigated by configurable dust filter.
  - Current default is `$4 / 4e6`, selected from observed v1 telemetry.
  - Not a formal proof against all fragmentation patterns on cheap L2.
- F-02 wash-trading / extreme-tier manipulation:
  - Residual economic manipulation risk.
  - Realistic competitor-funded distortion / DoS / fee-poisoning scenario.
  - More relevant in low-cost environments and adversarial routing contexts.
- F-05 immediate `setHookFeeRecipient`:
  - Accepted owner/key risk in current scope.
- F-12 owner model baseline:
  - Production owner must be multisig.
  - EOA owner is acceptable only for local/dev/test flows.

## Operational Prerequisites

- Owner key custody policy:
  - Production owner key must be cold/hardware secured.
  - Hot-wallet owner usage is unacceptable for production.
- Monitoring and alerting requirements:
  - Monitor `PeriodClosed` for repeated abnormal regime escalations.
  - Monitor hook-fee recipient change events.
  - Monitor emergency reset events.
- Parameter discipline:
  - Keep conservative controller defaults in adversarial routing contexts.

# Audit Scope / Out of Scope / Assumptions

## Audit Scope

- Hardening and validation of `src/VolumeDynamicFeeHook.sol` for agreed findings.
- Regression verification through unit/integration/fuzz tests.
- Documentation and runbook alignment with current behavior.
- Engineering gas measurements on local Anvil setup.

## Out of Scope

- Independent re-audit of Uniswap dependency internals.
- Independent review of PoolManager internals beyond hook call-site assumptions.
- Independent review of address-mining and hook-flag correctness logic.
- Governance redesign, multisig enforcement in code, and economic-model changes.

## Assumptions

- `BaseHook`, `LPFeeLibrary`, and other Uniswap dependencies are treated as trusted dependencies in this review.
- PoolManager internals are assumed correct outside explicit hook call-site assumptions.
- HookMiner/address-mining/hook-flag correctness is not independently audited here and must be verified at deployment time.

## Operational Measurements

- Gas section is engineering measurement, not a full formal gas audit.
- Real Anvil measurements were collected in this run.
- Sepolia live operational measurements were not reproduced in this run; this is explicitly recorded in artifacts.

# Test Coverage

- Updated and added regression coverage:
  - `ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol`
    - F-03 revert tests for all three controller inequalities.
    - EMA preservation semantics test for tier-role maintenance.
    - Saturation test for `periodVol` at `uint64.max`.
    - HookFee approximation behavior test coverage.
  - `ops/tests/unit/VolumeDynamicFeeHook.ConfigAndEdges.t.sol`
    - Exact dynamic-fee flag validation test for F-06.
    - Default dust threshold assertion at `4_000_000`.
  - `ops/tests/integration/VolumeDynamicFeeHook.ClaimAccounting.t.sol`
    - Default threshold consistency assertion updated to `4_000_000`.
- Broader safety coverage retained:
  - Fuzz suite assertions covering packed-state bounds, accounting drift checks, and saturation behavior.

# Gas Observations

## Anvil (reproduced in this run)

Source: `audit_bundle/gas_artifacts/gas.anvil.measurements.json`

| Operation | txHash | gasUsed | effectiveGasPrice (gwei) |
|---|---|---:|---:|
| Deploy hook | `0xc6d1f80a7a663ff6d68555d5955fded3cc69cca140a19ef08b21daeed6785de7` | 4,866,228 | 0.882977951 |
| Create/init pool path | `0x5c90ce085105fe1dd6379686a6b4ebd682940148ec47bc37a4ddc92e1e1f0219` | 130,715 | 0.882977951 |
| Normal swap without rollover | `0xfbcf4ee98b7e4e2f816fb0d6765394f1652a8c2f1e1db21e9204bf73d8c4805d` | 167,695 | 0.882977951 |
| Swap with period close | `0xa12ec72bf7874be3105db42247f9d14cc14626d0f8266887b72ec65770ef510d` | 69,716 | 0.712486380 |
| Swap with lull reset | `0x33ca2f31fbe5703004ca9baec2dcde10c0fa81e841e65ce94cde1c5289c77604` | 121,122 | 0.545859575 |
| `pause()` | `0xb96f8f562775399330e5549cd8dc90f1264c1e4d479c938553e37a854698a085` | 35,721 | 0.882977951 |
| `unpause()` | `0x2fc4dade183b65bbeec9fd6d332c3f5ae054b9dd76f93aaa5e4d5f0e8a49f190` | 35,219 | 0.882977951 |
| `emergencyResetToFloor()` | `0x4f40b9e972416d5277e85339cb1d18633a2caab1260413e1fe01bd585da12848` | 31,840 | 0.882977951 |
| `claimAllHookFees()` | `0xf73477fc7710443d1d5238ffcc924338166493b482d1083340bc50f9d7c01e12` | 112,998 | 0.882977951 |

Notes:
- Measurements are environment-dependent engineering observations.
- Cost breakdown is documented in `audit_bundle/gas_artifacts/gas.anvil.measurements.md`.
- Unit-test gas report is recorded in `audit_bundle/gas_artifacts/forge.gas_report.unit_admin.txt`.

## Sepolia (status for this run)

- Live-network operational measurements were not reproduced in this run.
- Explicit status artifact: `audit_bundle/gas_artifacts/gas.sepolia.not_reproduced.md`.
- No claim is made here about fresh Sepolia tx-level gas usage for operational flows.

# Deployment and Ops Requirements

- Production ownership and custody:
  - Production owner must be multisig.
  - Owner key custody must be cold/hardware.
  - EOA owner is only acceptable for local/dev/test.
- Operations:
  - Use conservative controller defaults for adversarial environments.
  - Maintain monitoring/alerts for abnormal `PeriodClosed` escalation patterns.
  - Track recipient-update and emergency-reset events.
- Maintenance policy:
  - EMA preservation is acceptable for minor fee-ladder maintenance.
  - Material controller/topology changes require paused maintenance and explicit reset-to-floor procedure before live re-entry.

# References / Appendix

- Core code:
  - `src/VolumeDynamicFeeHook.sol`
- Tests:
  - `ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol`
  - `ops/tests/unit/VolumeDynamicFeeHook.ConfigAndEdges.t.sol`
  - `ops/tests/integration/VolumeDynamicFeeHook.ClaimAccounting.t.sol`
  - `ops/tests/fuzz/VolumeDynamicFeeHook.Fuzz.t.sol`
- Docs and runbooks:
  - `README.md`
  - `docs/SPEC.md`
  - `docs/FAQ.md`
  - `ops/local/RUNBOOK.md`
  - `ops/sepolia/RUNBOOK.md`
  - `scripts/README.md`
  - `config/_hook.template.conf`
  - `docs/sepolia_simulate_fee_cycle_test_matrix.md`
- Gas artifacts:
  - `audit_bundle/gas_artifacts/gas.anvil.measurements.json`
  - `audit_bundle/gas_artifacts/gas.anvil.measurements.md`
  - `audit_bundle/gas_artifacts/forge.gas_report.unit_admin.txt`
  - `audit_bundle/gas_artifacts/gas.sepolia.not_reproduced.md`
- F-13 packaging closure evidence:
  - stale bundle deleted;
  - bundle rebuilt from current workspace state;
  - anti-stale token scan performed and passed.
