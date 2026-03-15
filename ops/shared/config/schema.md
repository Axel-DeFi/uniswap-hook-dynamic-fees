# Ops Config Schema

File-backed live config is loaded in this order:
- `defaults.env`
- scenario overlay
- repository root `.env`
- `deploy.env`

After file loading, wrapper scripts may hydrate runtime-only addresses from state JSON:
- `POOL_MANAGER`, `HOOK_ADDRESS`, `VOLATILE`, `STABLE` from `ops/<network>/out/state/*.addresses.json`
- `SWAP_DRIVER`, `LIQUIDITY_DRIVER` from `ops/<network>/out/state/*.drivers.json`

Canonical hook identity is derived only from `DEPLOY_*` keys, so state hydration must not change deployment
snapshot inputs.

## Required keys

- `OPS_RUNTIME` = `local|live`
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
    current release and the frozen deployment snapshot loaded from `ops/<network>/config/deploy.env`
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

Human-readable units for controller keys:
- percent keys are literal percentages, not bps. Example: `5` means `5%`, `180` means `180%`, `1.25` means `1.25%`.
- dollar keys are literal USD amounts per closed period, not `USD6`. Example: `1000` means `$1,000`, `0.50` means `$0.50`.
- loader compatibility: legacy `*_BPS`, `*_USD6`, `UP_*`, and `DOWN_*` keys are still accepted as fallback, but all checked-in configs should use the keys below.

- `PERIOD_SECONDS` — close period length in seconds. Example: `60`.
- `EMA_PERIODS` — EMA denominator in periods. Example: `12`.
- `DEADBAND_PERCENT` — hysteresis band applied around enter/exit thresholds. Example: `5`.
- `LULL_RESET_SECONDS` — inactivity timeout that forces a fresh open period. Example: `600`.
- `HOOK_FEE_PERCENT` — HookFee share of the LP fee. Example: `10`.
- `MIN_COUNTED_SWAP_USD6` — telemetry dust filter in raw `USD6`; defaults to `4_000_000` when omitted. Example: `4000000` for `$4`.
- `MIN_VOLUME_TO_ENTER_CASH_USD` — minimum close volume required before `FLOOR -> CASH` is allowed. Example: `1000`.
- `CASH_ENTER_EMA_PERCENT` — `closeVol / EMA` threshold for `FLOOR -> CASH`. Example: `180` means `180%` of EMA.
- `CASH_HOLD_PERIODS` — configured cash hold length `N` (`N - 1` fully protected periods). Example: `4`.
- `MIN_VOLUME_TO_ENTER_EXTREME_USD` — minimum close volume required before `CASH -> EXTREME` is allowed. Example: `4000`.
- `EXTREME_ENTER_EMA_PERCENT` — `closeVol / EMA` threshold for `CASH -> EXTREME`. Example: `400` means `400%` of EMA.
- `ENTER_EXTREME_CONFIRM_PERIODS` — consecutive qualifying closes required before entering `EXTREME`. Example: `2`.
- `EXTREME_HOLD_PERIODS` — configured hold length after entering `EXTREME`. Example: `4`.
- `EXTREME_EXIT_EMA_PERCENT` — `closeVol / EMA` ceiling for `EXTREME -> CASH`. Example: `130` means exit when close volume falls to `130%` of EMA or lower.
- `EXIT_EXTREME_CONFIRM_PERIODS` — consecutive qualifying closes required before leaving `EXTREME`. Example: `2`.
- `CASH_EXIT_EMA_PERCENT` — `closeVol / EMA` ceiling for `CASH -> FLOOR`. Example: `130`.
- `EXIT_CASH_CONFIRM_PERIODS` — consecutive qualifying closes required before leaving `CASH`. Example: `3`.
- `EMERGENCY_FLOOR_TRIGGER_USD` — emergency floor threshold checked against close volume. Example: `600`.
- `EMERGENCY_CONFIRM_PERIODS` — consecutive closes below `EMERGENCY_FLOOR_TRIGGER_USD` required for emergency reset. Example: `3`.

## Frozen deployment snapshot

These keys live in `ops/<network>/config/deploy.env` for live profiles. They define the constructor snapshot used to
derive the canonical CREATE2 hook address and must not be edited after the canonical hook is deployed. The ops shell
loaders source `deploy.env` after scenario overlays and root `.env`, so `DEPLOY_*` values win if duplicates exist.
`DEPLOY_*` entries must be literal values in `deploy.env`; shell interpolation like `${DEFAULT_OWNER}` is rejected so
the snapshot cannot drift with outer environment changes.

- `DEPLOY_POOL_MANAGER`
- `DEPLOY_VOLATILE`
- `DEPLOY_STABLE`
- `DEPLOY_STABLE_DECIMALS`
- `DEPLOY_TICK_SPACING`
- `DEPLOY_OWNER`
- `DEPLOY_FLOOR_FEE_PIPS`
- `DEPLOY_CASH_FEE_PIPS`
- `DEPLOY_EXTREME_FEE_PIPS`
- `DEPLOY_PERIOD_SECONDS`
- `DEPLOY_EMA_PERIODS`
- `DEPLOY_DEADBAND_PERCENT` — same meaning as `DEADBAND_PERCENT`. Example: `5`.
- `DEPLOY_LULL_RESET_SECONDS`
- `DEPLOY_HOOK_FEE_PERCENT`
- `DEPLOY_MIN_VOLUME_TO_ENTER_CASH_USD` — same meaning as `MIN_VOLUME_TO_ENTER_CASH_USD`. Example: `1000`.
- `DEPLOY_CASH_ENTER_EMA_PERCENT` — same meaning as `CASH_ENTER_EMA_PERCENT`. Example: `180`.
- `DEPLOY_CASH_HOLD_PERIODS`
- `DEPLOY_MIN_VOLUME_TO_ENTER_EXTREME_USD` — same meaning as `MIN_VOLUME_TO_ENTER_EXTREME_USD`. Example: `4000`.
- `DEPLOY_EXTREME_ENTER_EMA_PERCENT` — same meaning as `EXTREME_ENTER_EMA_PERCENT`. Example: `400`.
- `DEPLOY_ENTER_EXTREME_CONFIRM_PERIODS` — same meaning as `ENTER_EXTREME_CONFIRM_PERIODS`. Example: `2`.
- `DEPLOY_EXTREME_HOLD_PERIODS`
- `DEPLOY_EXTREME_EXIT_EMA_PERCENT` — same meaning as `EXTREME_EXIT_EMA_PERCENT`. Example: `130`.
- `DEPLOY_EXIT_EXTREME_CONFIRM_PERIODS` — same meaning as `EXIT_EXTREME_CONFIRM_PERIODS`. Example: `2`.
- `DEPLOY_CASH_EXIT_EMA_PERCENT` — same meaning as `CASH_EXIT_EMA_PERCENT`. Example: `130`.
- `DEPLOY_EXIT_CASH_CONFIRM_PERIODS` — same meaning as `EXIT_CASH_CONFIRM_PERIODS`. Example: `3`.
- `DEPLOY_EMERGENCY_FLOOR_TRIGGER_USD` — same meaning as `EMERGENCY_FLOOR_TRIGGER_USD`. Example: `600`.
- `DEPLOY_EMERGENCY_CONFIRM_PERIODS`

For local profiles the same keys are optional and fall back to the current runtime values in `defaults.env`.

Controller constraint notes:
- `EMERGENCY_FLOOR_TRIGGER_USD` must be strictly greater than zero.
- `EMERGENCY_FLOOR_TRIGGER_USD` must be strictly lower than `MIN_VOLUME_TO_ENTER_CASH_USD`.
- `DEADBAND_PERCENT` must be strictly lower than both `EXTREME_EXIT_EMA_PERCENT` and `CASH_EXIT_EMA_PERCENT`.
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
- `OPS_NETWORK` (normally set by wrappers; `sepolia` or `optimism` for shared live paths)
- `ALLOW_WEAK_HOLD_PERIODS` (`0|1`, default `0`; explicit override for non-local weak hold configs)
- `SMOKE_SWAP_STABLE_RAW`
- `FULL_SWAP_STABLE_RAW`
- `FULL_SWAP_ITERATIONS`
- `RERUN_SWAP_STABLE_RAW`
- `SEED_STABLE_RAW`
- `SEED_VOLATILE_RAW`
- `PERIODS_TO_WARP`
- `WARP_CLOSE_PERIOD`
- `INIT_SQRT_PRICE_X96` (needed for `EnsurePoolLive` if init tx is required)
- `SWAP_DRIVER` (external helper contract for live swaps; reused only if runtime codehash and bound `manager()`
  match the expected canonical helper for the current `POOL_MANAGER`, otherwise auto-reprovisioned)
- `LIQUIDITY_DRIVER` (external helper contract for live liquidity actions; same validation/reprovision rule as
  `SWAP_DRIVER`)
