# Ops Config Schema

All values are loaded from environment variables (defaults + scenario overlay + process env).

## Required keys

- `OPS_RUNTIME` = `local|sepolia`
- `CHAIN_ID_EXPECTED`
- `RPC_URL` (required for real RPC execution)
- `POOL_MANAGER`
- `VOLATILE`
- `STABLE`
- `STABLE_DECIMALS`
- `TICK_SPACING`
- `PRIVATE_KEY` or `DEPLOYER`

## Hook / pool binding

- `HOOK_ADDRESS` (optional for bootstrap, required for ensure/smoke/full/emergency)
  - when provided for deploy/ensure/preflight validation, it must be the canonical CREATE2 hook address for the
    current release and current constructor args
- `POOL_ADDRESS` (optional, validated when provided)

## Price / range survivability

- `INIT_PRICE_USD`
- `LIQ_RANGE_MIN_USD`
- `LIQ_RANGE_MAX_USD`
- `MAX_SWAP_FRACTION_BPS`

## Explicit regime fees

- `FLOOR_FEE_PIPS` (uint24)
- `CASH_FEE_PIPS` (uint24)
- `EXTREME_FEE_PIPS` (uint24)

## Timing / controller

- `PERIOD_SECONDS`
- `EMA_PERIODS`
- `DEADBAND_BPS`
- `LULL_RESET_SECONDS`
- `HOOK_FEE_PERCENT`
- `MIN_COUNTED_SWAP_USD6` (expected current telemetry threshold for reuse validation; defaults to `4_000_000` when omitted)
- `MIN_CLOSEVOL_TO_CASH_USD6`
- `UP_R_TO_CASH_BPS`
- `CASH_HOLD_PERIODS`
- `MIN_CLOSEVOL_TO_EXTREME_USD6`
- `UP_R_TO_EXTREME_BPS`
- `UP_EXTREME_CONFIRM_PERIODS`
- `EXTREME_HOLD_PERIODS`
- `DOWN_R_FROM_EXTREME_BPS`
- `DOWN_EXTREME_CONFIRM_PERIODS`
- `DOWN_R_FROM_CASH_BPS`
- `DOWN_CASH_CONFIRM_PERIODS`
- `EMERGENCY_FLOOR_CLOSEVOL_USD6`
- `EMERGENCY_CONFIRM_PERIODS`

Controller constraint notes:
- `EMERGENCY_FLOOR_CLOSEVOL_USD6` must be strictly greater than zero.
- `EMERGENCY_FLOOR_CLOSEVOL_USD6` must be strictly lower than `MIN_CLOSEVOL_TO_CASH_USD6`.
- `DEADBAND_BPS` must be strictly lower than both `DOWN_R_FROM_EXTREME_BPS` and `DOWN_R_FROM_CASH_BPS`.
- Hold semantics are `N -> N - 1` fully protected periods; production guidance is
  `CASH_HOLD_PERIODS >= 2` and `EXTREME_HOLD_PERIODS >= 2` (recommended `3..4`).

## Budget safety keys

- `BUDGET_MIN_ETH_WEI`
- `BUDGET_MIN_STABLE_RAW`
- `BUDGET_MIN_VOLATILE_RAW`
- `BUDGET_LIQ_STABLE_RAW`
- `BUDGET_LIQ_VOLATILE_RAW`
- `BUDGET_SWAP_STABLE_RAW`
- `BUDGET_SWAP_VOLATILE_RAW`
- `BUDGET_SAFETY_BUFFER_ETH_WEI`

## Optional execution knobs

- `OPS_BROADCAST` (`0|1`)
- `OPS_FORCE_SIMULATION` (`0|1`)
- `ALLOW_WEAK_HOLD_PERIODS` (`0|1`, default `0`; explicit override for non-local weak hold configs)
- `SMOKE_SWAP_STABLE_RAW`
- `FULL_SWAP_STABLE_RAW`
- `FULL_SWAP_ITERATIONS`
- `RERUN_SWAP_STABLE_RAW`
- `SEED_STABLE_RAW`
- `SEED_VOLATILE_RAW`
- `PERIODS_TO_WARP`
- `WARP_CLOSE_PERIOD`
- `INIT_SQRT_PRICE_X96` (needed for `EnsurePoolSepolia` if init tx is required)
- `SWAP_DRIVER` (external helper contract for live swaps; auto-provisioned when wrappers detect missing state)
- `LIQUIDITY_DRIVER` (external helper contract for live liquidity actions; auto-provisioned when wrappers detect missing state)
