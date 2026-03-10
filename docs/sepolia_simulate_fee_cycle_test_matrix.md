# Sepolia simulate_fee_cycle Test Matrix

This matrix tracks deterministic checks for `test/scripts/simulate_fee_cycle.sh` against current hook semantics.

## Functional checks

| ID | Scenario | Expected |
|---|---|---|
| F-01 | Dynamic pool + hook init | Pool initializes with dynamic fee and hook binding |
| F-02 | Swap path | `afterSwap` executes and returns HookFee delta |
| F-03 | HookFee accrual | `hookFeesAccrued` increases after swaps |
| F-04 | HookFee claim | `claimAllHookFees` clears accrued balances and increases recipient balance via `unlock` -> `burn` -> `take` |
| F-05 | Pause freeze | fee regime + EMA preserved, open period reset |
| F-06 | Unpause resume | controller resumes without forced floor reset |
| F-07 | Emergency reset floor | paused-only reset to floor regime |
| F-08 | Emergency reset cash | paused-only reset to cash regime |
| F-09 | Dust filter | swaps below `minCountedSwapUsd6` excluded from `periodVol` only (default `$4 / 4e6`) |
| F-10 | Scaled EMA | `emaVolumeUsd6Scaled` updates with scale `1e6` |
| F-11 | EMA preservation on tier-role maintenance | `setFeeTiersAndRoles(...)` preserves EMA by design |
| F-12 | Saturation bound | extreme `periodVol` growth saturates at `uint64.max` |

## Security / guard checks

| ID | Scenario | Expected |
|---|---|---|
| A-01 | HookFee percent > 10 | `HookFeePercentLimitExceeded` |
| A-02 | Execute HookFee timelock too early | `HookFeePercentChangeNotReady` |
| A-03 | Parallel HookFee schedules | `PendingHookFeePercentChangeExists` |
| A-04 | Owner-only admin call by outsider | `NotOwner` |
| A-05 | Emergency reset while unpaused | `RequiresPaused` |
| A-06 | Invalid stable decimals | `InvalidStableDecimals` |
| A-07 | Direct ETH transfer | `EthReceiveRejected` |
| A-08 | Direct `afterSwap` callback call (not PoolManager) | PoolManager-only guard revert |
| A-09 | `minCountedSwapUsd6` out of `[1e6,10e6]` | `InvalidMinCountedSwapUsd6` |
| A-10 | Controller cross-check: cash volume > extreme volume | `InvalidConfig` |
| A-11 | Controller cross-check: cash up ratio > extreme up ratio | `InvalidConfig` |
| A-12 | Controller cross-check: cash down ratio < extreme down ratio | `InvalidConfig` |
| A-13 | Non-exact dynamic fee flag in key | `NotDynamicFeePool` |

## Invariant checks

| ID | Invariant |
|---|---|
| I-01 | `floorIdx < cashIdx < extremeIdx` |
| I-02 | `feeIdx` always inside `[floorIdx, extremeIdx]` |
| I-03 | Fee tiers strictly increasing |
| I-04 | Packed state counters remain in bit-width bounds |
| I-05 | Pending timelock state is internally consistent |
| I-06 | HookFee accrued balances match observed delta accounting |
