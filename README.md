# Uniswap v4 VolumeDynamicFeeHook

`VolumeDynamicFeeHook` is a single-pool Uniswap v4 hook that:
- updates dynamic LP fee across explicit FLOOR/CASH/EXTREME regimes from stable-side volume telemetry,
- charges an additional trader-facing `HookFee` in `afterSwap` via return delta,
- keeps state compact and operational controls explicit.

## License / Usage Notice

This repository is source-available strictly for public audit, security review, technical research, and bug reporting.
It is not open source, and no commercial or general non-commercial usage rights are granted.
Without prior written permission, you may not deploy, operate, reuse, redistribute, sublicense, or create derivative works from this code.
See `LICENSE` for full terms.

## Key design points

- Single pool binding (no `PoolId => state` mapping).
- `BaseHook`-based implementation with minimal permissions:
  - `afterInitialize`
  - `afterSwap`
  - `afterSwapReturnDelta`
- Administrative role is `Owner`.
- Current `owner()` is always the HookFee payout recipient.
- Ownership transfer is two-step; `proposeNewOwner(...)` rejects zero address and current owner.
- `HookFeePercent` is timelocked for 48 hours and capped at 10% (hard constant).
- HookFee is based on an approximate LP-fee estimate from the unspecified side; exact-input vs exact-output can diverge by design.
- HookFee accrual is persisted as PoolManager ERC6909 claims and claimed via `unlock` + `burn` + `take`.
- Claim-all path is single and explicit: `claimAllHookFees()` always pays to current `owner()`.
- Claim settlement automatically chunks oversized payouts to fit PoolManager `int128` accounting bounds.
- For native-asset pools (`token0 == address(0)` or `token1 == address(0)`), deploy/ensure/preflight flows validate that current `owner()` can accept native payout from the PoolManager claim path.
- Deploy/ensure/preflight hook reuse is pinned to the canonical CREATE2 address derived from the current release and
  the frozen constructor snapshot in `ops/<network>/config/deploy.env`; current runtime/admin expectations continue to
  come from `ops/<network>/config/defaults.env`. Reuse also requires the exact minimal callback surface
  (`afterInitialize`, `afterSwap`, `afterSwapReturnDelta` only), expected PoolManager binding, current
  `minCountedSwapUsd6`, and zero pending owner / pending config changes.
- The frozen deployment snapshot covers the full constructor identity, including `PoolManager`, pool currencies,
  `tickSpacing`, stable token/decimals, owner, fee tiers, and controller/timing params.
- `deploy.env` snapshot entries are expected to be literal `DEPLOY_*` values; shell interpolation in frozen snapshot
  files is rejected to avoid canonical address drift from outer environment changes.
- Live deployment and validation now run only through the unified `ops/*` contours:
  - `ops/local` for deterministic Anvil lifecycle
  - `ops/sepolia` for public-testnet rehearsal
  - `ops/optimism` for production deployment and operations
  - `ops/<network>/config/deploy.env` is loaded after scenario overlays and root `.env`, so `DEPLOY_*` keys remain the
    winning frozen constructor snapshot for canonical identity
- Live liquidity/swap helper drivers are reused only if their runtime codehash and bound `manager()` match the expected
  canonical helper for the configured `POOL_MANAGER`; otherwise wrappers reprovision them before broadcast-capable
  phases.
- `pause()/unpause()` freeze/resume regulator transitions at the current LP fee regime (no automatic floor reset, no swap stop; HookFee accrual is suspended while paused).
- `setRegimeFees(...)` (paused-only) preserves EMA, resets hold/streak counters, starts a fresh open period, and updates current LP fee immediately if active regime fee changed.
- `setControllerParams(...)` (paused-only) preserves active regime + EMA, clears hold/streak counters, and starts a fresh open period.
- `setTimingParams(...)` (paused-only) has explicit split semantics:
  - time-scale change (`periodSeconds` or `emaPeriods`) => safe reset to FLOOR, EMA/counters cleared, fresh open period, immediate LP-fee sync if tier changed.
  - non-time-scale change (`lullResetSeconds` only) => preserve regime + EMA/counters, fresh open period only.
- Emergency resets are explicit and available only while paused:
  - `emergencyResetToFloor()`
  - `emergencyResetToCash()`
- Timing guardrail: `lullResetSeconds` must be strictly greater than `periodSeconds`.
- Hold semantics: configured `cashHoldPeriods = N` gives `N - 1` fully protected periods (`N = 1` means zero effective hold protection).
- Automatic emergency floor evaluation has priority over hold protection and can reset to `FLOOR` even when `holdRemaining > 0`.
- Controller parameter cross-checks are enforced:
  - `minCloseVolToCashUsd6 <= minCloseVolToExtremeUsd6`
  - `cashEnterTriggerBps <= extremeEnterTriggerBps`
  - `cashExitTriggerBps >= extremeExitTriggerBps`
  - `0 < emergencyFloorCloseVolUsd6 < minCloseVolToCashUsd6`
- Pool key validation requires exact dynamic-fee flag: `key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG`.
- Telemetry fields are explicit:
  - counted volume threshold `minCountedSwapUsd6` (default `$4 / 4e6`, bounded to `1e6..10e6`)
  - threshold update is pending-state only and activates from next period boundary (no timelock by design)
  - offchain threshold recalibration cadence target is 5 days
  - approximate LP fee metric `approxLpFeesUsd6`
  - scaled EMA storage (`emaVolumeUsd6Scaled`, scale = `1e6`)

## Documentation

- Documentation hierarchy: contract NatSpec is authoritative, `docs/SPEC.md` is the normative mirror, and README/FAQ/runbooks are operational guidance.
- Specification: `docs/SPEC.md`
- FAQ: `docs/FAQ.md`
- Release process: `docs/RELEASE.md`
- Ops and deployment flow: `ops/README.md`
- Auxiliary scripts: `scripts/README.md`
- Local ops runbook: `ops/local/RUNBOOK.md`
- Sepolia ops runbook: `ops/sepolia/RUNBOOK.md`
- Optimism ops runbook: `ops/optimism/RUNBOOK.md`

## Accepted risks (current scope)

- Dust-splitting remains a residual architectural/model risk. The configurable dust filter mitigates it, and the default `$4 / 4e6` was selected from observed v1 telemetry. This is not a formal proof against all fragmentation patterns on cheap L2.
- Wash-trading / regime-poisoning remains a residual economic manipulation risk (more realistic as competitor-funded distortion/DoS in adversarial routing environments).
- HookFee percent timelock is intentionally transparent; observable pending changes mainly affect HookFee timing while LP fee ownership/accrual remains unchanged.
- `scheduleMinCountedSwapUsd6Change(...)` has no timelock by design (pending + next-period activation only).
- Overdue period catch-up can close multiple periods in one swap. Only the first closed period uses accumulated close volume, while subsequent closed periods use zero close volume; this can produce multi-step downward transitions in one transaction and is accepted as an architectural/economic trade-off in current scope.

## Ops baseline

- Production owner must be a multisig. EOA owner is acceptable only for local/dev/test.
- Hot-wallet owner usage is unacceptable for production.
- Owner key material should be held in cold/hardware custody.
- For native-asset pools, ownership changes must keep native payout compatibility because payout always follows current `owner()`.
- Monitor `PeriodClosed`, `RegimeFeesUpdated`, `ControllerParamsUpdated`, `TimingParamsUpdated`, `Paused`, `Unpaused`, and emergency-reset events; alert on repeated abnormal regime escalations.
- Monitoring should treat repeated multi-close downward `PeriodClosed` sequences as notable routing/yield behavior.

## Build and test

```bash
forge build
forge test --offline --match-path 'ops/tests/unit/*.sol'
forge test --offline --match-path 'ops/tests/fuzz/*.sol'
forge test --offline --match-path 'ops/tests/invariant/*.sol' --match-contract VolumeDynamicFeeHookInvariant_Stable0_Tick10
forge test --offline --match-path 'ops/tests/invariant/*.sol' --match-contract VolumeDynamicFeeHookInvariant_Stable1_Tick10
forge test --offline --match-path 'ops/tests/invariant/*.sol' --match-contract VolumeDynamicFeeHookInvariant_Stable0_Tick60
forge test --offline --match-path 'ops/tests/invariant/*.sol' --match-contract VolumeDynamicFeeHookInvariant_Stable1_Tick60
```

## Gas measurements (local)

```bash
forge test --offline --gas-report --match-contract VolumeDynamicFeeHookAdminTest > ops/local/out/reports/gas.admin.report.txt
ops/local/scripts/gas.sh
```

Artifacts:
- `ops/local/out/reports/gas.admin.report.txt`
- `ops/local/out/reports/gas.samples.local.json`
- `ops/local/out/reports/gas.local.json`
- `ops/local/out/reports/gas.local.md`

## Release versioning

```bash
scripts/release/check.sh
scripts/release/cut.sh --bump patch --push
```

`VERSION`, git tag `vX.Y.Z`, and `CHANGELOG.md` heading are enforced as a single source of truth.
