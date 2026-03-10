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
- `POOL_ADDRESS` (optional, validated when provided)

## Price / range survivability

- `INIT_PRICE_USD`
- `LIQ_RANGE_MIN_USD`
- `LIQ_RANGE_MAX_USD`
- `MAX_SWAP_FRACTION_BPS`

## Fee tiers

- `FEE_TIERS_PIPS` (comma-separated uint24 list, e.g. `400,2500,9000`)
- `FLOOR_IDX`
- `CASH_IDX`
- `EXTREME_IDX`
- `EXTREME_IDX`

## Timing / controller

- `PERIOD_SECONDS`
- `EMA_PERIODS`
- `DEADBAND_BPS`
- `LULL_RESET_SECONDS`
- `HOOK_FEE_LIMIT_PERCENT`
- `HOOK_FEE_PERCENT`
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
