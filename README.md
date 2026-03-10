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
- `HookFeeRecipient` is a separate accounting entity from `Owner`.
- Ownership transfer is two-step; `proposeNewOwner(...)` rejects zero address and current owner.
- `setHookFeeRecipient(...)` is immediate (no timelock) by design.
- No-op `setHookFeeRecipient(...)` calls (same address) are ignored and do not emit `HookFeeRecipientUpdated`.
- `HookFeePercent` is timelocked for 48 hours and capped at 10% (hard constant).
- HookFee is based on an approximate LP-fee estimate from the unspecified side; exact-input vs exact-output can diverge by design.
- HookFee accrual is persisted as PoolManager ERC6909 claims and claimed via `unlock` + `burn` + `take`.
- Claim-all path is single and explicit: `claimAllHookFees()` always pays to current `hookFeeRecipient`.
- For native-asset pools (`token0 == address(0)` or `token1 == address(0)`), deploy/ensure/preflight flows validate that `hookFeeRecipient` can accept native payout from the hook claim path.
- `pause()/unpause()` freeze/resume regulator transitions at the current LP fee regime (no automatic floor reset, no swap stop, no HookFee stop).
- `setRegimeFees(...)` (paused-only) preserves EMA, resets hold/streak counters, starts a fresh open period, and updates current LP fee immediately if active regime fee changed.
- Emergency resets are explicit and available only while paused:
  - `emergencyResetToFloor()`
  - `emergencyResetToCash()`
- Timing guardrail: `lullResetSeconds` must be strictly greater than `periodSeconds`.
- Hold semantics: configured `cashHoldPeriods = N` gives `N - 1` fully protected periods (`N = 1` means zero effective hold protection).
- Controller parameter cross-checks are enforced:
  - `minCloseVolToCashUsd6 <= minCloseVolToExtremeUsd6`
  - `upRToCashBps <= upRToExtremeBps`
  - `downRFromCashBps >= downRFromExtremeBps`
  - `deadbandBps < downRFromExtremeBps`
  - `deadbandBps < downRFromCashBps`
  - `emergencyFloorCloseVolUsd6 > 0`
- Pool key validation requires exact dynamic-fee flag: `key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG`.
- Telemetry fields are explicit:
  - counted volume threshold `minCountedSwapUsd6` (default `$4 / 4e6`, bounded to `1e6..10e6`)
  - threshold update is pending-state only and activates from next period boundary (no timelock by design)
  - offchain threshold recalibration cadence target is 5 days
  - approximate LP fee metric `approxLpFeesUsd6`
  - scaled EMA storage (`emaVolumeUsd6Scaled`, scale = `1e6`)

## Documentation

- Specification: `docs/SPEC.md`
- FAQ: `docs/FAQ.md`
- Release process: `docs/RELEASE.md`
- Scripts and deployment flow: `scripts/README.md`
- Local ops runbook: `ops/local/RUNBOOK.md`
- Sepolia ops runbook: `ops/sepolia/RUNBOOK.md`

## Accepted risks (current scope)

- Dust-splitting remains a residual architectural/model risk. The configurable dust filter mitigates it, and the default `$4 / 4e6` was selected from observed v1 telemetry. This is not a formal proof against all fragmentation patterns on cheap L2.
- Wash-trading / regime-poisoning remains a residual economic manipulation risk (more realistic as competitor-funded distortion/DoS in adversarial routing environments).
- `setHookFeeRecipient(...)` remains immediate (owner governance/key risk, operational mitigation only).
- HookFee percent timelock is intentionally transparent; observable pending changes mainly affect HookFee timing while LP fee ownership/accrual remains unchanged.
- `scheduleMinCountedSwapUsd6Change(...)` has no timelock by design (pending + next-period activation only).
- Overdue period catch-up can close multiple periods in one swap. Only the first closed period uses accumulated close volume, while subsequent closed periods use zero close volume; this can produce multi-step downward transitions in one transaction and is accepted as an architectural/economic trade-off in current scope.

## Ops baseline

- Production owner must be a multisig. EOA owner is acceptable only for local/dev/test.
- Hot-wallet owner usage is unacceptable for production.
- Owner key material should be held in cold/hardware custody.
- Zero-address recipient checks alone are insufficient for native-asset pools; recipient native-payout compatibility must be preserved if governance later updates `hookFeeRecipient`.
- Monitor `PeriodClosed`, `HookFeeRecipientUpdated`, and emergency-reset events; alert on repeated abnormal regime escalations.
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

## Release versioning

```bash
scripts/release/check.sh
scripts/release/cut.sh --bump patch --push
```

`VERSION`, git tag `vX.Y.Z`, and `CHANGELOG.md` heading are enforced as a single source of truth.
