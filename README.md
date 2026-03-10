# Uniswap v4 VolumeDynamicFeeHook

`VolumeDynamicFeeHook` is a single-pool Uniswap v4 hook that:
- updates dynamic LP fee tiers from stable-side volume telemetry,
- charges an additional trader-facing `HookFee` in `afterSwap` via return delta,
- keeps state compact and operational controls explicit.

## Key design points

- Single pool binding (no `PoolId => state` mapping).
- `BaseHook`-based implementation with minimal permissions:
  - `afterInitialize`
  - `afterSwap`
  - `afterSwapReturnDelta`
- Administrative role is `Owner`.
- `HookFeeRecipient` is a separate accounting entity from `Owner`.
- `setHookFeeRecipient(...)` is immediate (no timelock) by design.
- `HookFeePercent` is timelocked for 48 hours and capped at 10% (hard constant).
- HookFee accrual is persisted as PoolManager ERC6909 claims and claimed via `unlock` + `burn` + `take`.
- `pause()/unpause()` are freeze/resume only (no automatic floor reset, no swap stop, no HookFee stop).
- Emergency resets are explicit and available only while paused:
  - `emergencyResetToFloor()`
  - `emergencyResetToCash()`
- Telemetry fields are explicit:
  - counted volume threshold `minCountedSwapUsd6` (default `4e6`, bounded to `1e6..10e6`)
  - threshold update is pending-state only and activates from next period boundary (no timelock by design)
  - offchain threshold recalibration cadence target is 5 days
  - approximate LP fee metric `approxLpFeesUsd6`
  - scaled EMA storage (`emaVolumeUsd6Scaled`, scale = `1e6`)

## Documentation

- Specification: `docs/SPEC.md`
- FAQ: `docs/FAQ.md`
- Scripts and deployment flow: `scripts/README.md`
- Local ops runbook: `ops/local/RUNBOOK.md`
- Sepolia ops runbook: `ops/sepolia/RUNBOOK.md`

## Accepted risks (current scope)

- `setHookFeeRecipient(...)` remains immediate (owner governance/key risk, operational mitigation only).
- `scheduleMinCountedSwapUsd6Change(...)` has no timelock by design (pending + next-period activation only).

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

## License

Apache-2.0. See `LICENSE`.
