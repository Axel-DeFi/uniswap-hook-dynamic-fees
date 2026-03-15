# Ops Config Schema

File-backed live config is loaded in this order:
- `defaults.env`
- scenario overlay
- repository root `.env`
- `deploy.env`

In normal day-to-day setup, edit `deploy.env`.
Keep `defaults.env` for runtime wiring, budgets, and explicit post-deploy runtime overrides.

After file loading, wrapper scripts may hydrate runtime-only addresses from state JSON:
- `POOL_MANAGER`, `HOOK_ADDRESS`, `VOLATILE`, `STABLE` from `ops/<network>/out/state/*.addresses.json`
- `SWAP_DRIVER`, `LIQUIDITY_DRIVER` from `ops/<network>/out/state/*.drivers.json`

Canonical hook identity is derived only from `DEPLOY_*` keys, so state hydration must not change deployment
snapshot inputs.

## Required keys

- `OPS_RUNTIME` = `local|live`
- `CHAIN_ID_EXPECTED`
- `RPC_URL` (required for real RPC execution)
- `PRIVATE_KEY` or `DEPLOYER`

Binding keys may come from either the runtime key or the frozen deployment snapshot:
- `POOL_MANAGER` or `DEPLOY_POOL_MANAGER`
- `VOLATILE` or `DEPLOY_VOLATILE`
- `STABLE` or `DEPLOY_STABLE`
- `STABLE_DECIMALS` or `DEPLOY_STABLE_DECIMALS`
- `TICK_SPACING` or `DEPLOY_TICK_SPACING`

## Hook / pool binding

- `HOOK_ADDRESS` (optional for bootstrap, required for ensure/smoke/full/emergency)
  - when provided for deploy/ensure/preflight validation, it must be the canonical CREATE2 hook address for the
    current release and the frozen deployment snapshot loaded from `ops/<network>/config/deploy.env`
- `POOL_ADDRESS` (optional, validated when provided)

## Pool initialization

- `INIT_PRICE_USD` — initial pool price in USD stored in `deploy.env`. Example: `2500`.
- `EnsurePoolLive` derives `sqrtPriceX96` directly from `INIT_PRICE_USD` and token decimals.

## Explicit regime fees

- Runtime fee/controller keys may be omitted from `defaults.env`. If omitted, the loader inherits the corresponding
  `DEPLOY_*` value. Set the runtime key only when post-deploy admin changes are expected onchain.
- `FLOOR_FEE_PERCENT` — LP fee for the `FLOOR` regime, as a percent. Example: `0.04`.
- `CASH_FEE_PERCENT` — LP fee for the `CASH` regime, as a percent. Example: `0.25`.
- `EXTREME_FEE_PERCENT` — LP fee for the `EXTREME` regime, as a percent. Example: `0.9`.

## Timing / controller

Human-readable units for controller keys:
- `*_TRIGGER_EMA_X` keys use the close-volume trigger as a multiple of EMA. Example: `1.25` means `1.25x EMA`.
- dollar keys use literal USD amounts per closed period. Example: `1000` means `$1,000`, `0.50` means `$0.50`.

- `PERIOD_SECONDS` — close period length in seconds. Example: `60`.
- `EMA_PERIODS` — EMA denominator in periods. Example: `12`.
- `LULL_RESET_SECONDS` — inactivity timeout that forces a fresh open period. Example: `600`.
- `HOOK_FEE_PERCENT` — additional trader fee as a percent of the active LP fee. Example: `10`.
- `MIN_VOLUME_TO_ENTER_CASH_USD` — minimum close volume required before `FLOOR -> CASH` is allowed. Example: `1000`.
- `CASH_ENTER_TRIGGER_EMA_X` — `closeVol / EMA` trigger for `FLOOR -> CASH`. Example: `1.90`.
- `CASH_HOLD_PERIODS` — configured cash hold length `N` (`N - 1` fully protected periods). Example: `4`.
- `MIN_VOLUME_TO_ENTER_EXTREME_USD` — minimum close volume required before `CASH -> EXTREME` is allowed. Example: `4000`.
- `EXTREME_ENTER_TRIGGER_EMA_X` — `closeVol / EMA` trigger for `CASH -> EXTREME`. Example: `4.10`.
- `ENTER_EXTREME_CONFIRM_PERIODS` — consecutive qualifying closes required before entering `EXTREME`. Example: `2`.
- `EXTREME_HOLD_PERIODS` — configured hold length after entering `EXTREME`. Example: `4`.
- `EXTREME_EXIT_TRIGGER_EMA_X` — `closeVol / EMA` trigger for `EXTREME -> CASH`. Example: `1.20`.
- `EXIT_EXTREME_CONFIRM_PERIODS` — consecutive qualifying closes required before leaving `EXTREME`. Example: `2`.
- `CASH_EXIT_TRIGGER_EMA_X` — `closeVol / EMA` trigger for `CASH -> FLOOR`. Example: `1.20`.
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
- `DEPLOY_FLOOR_FEE_PERCENT` — same meaning as `FLOOR_FEE_PERCENT`. Example: `0.04`.
- `DEPLOY_CASH_FEE_PERCENT` — same meaning as `CASH_FEE_PERCENT`. Example: `0.25`.
- `DEPLOY_EXTREME_FEE_PERCENT` — same meaning as `EXTREME_FEE_PERCENT`. Example: `0.9`.
- `DEPLOY_PERIOD_SECONDS`
- `DEPLOY_EMA_PERIODS`
- `DEPLOY_LULL_RESET_SECONDS`
- `DEPLOY_HOOK_FEE_PERCENT`
- `DEPLOY_MIN_VOLUME_TO_ENTER_CASH_USD` — same meaning as `MIN_VOLUME_TO_ENTER_CASH_USD`. Example: `1000`.
- `DEPLOY_CASH_ENTER_TRIGGER_EMA_X` — same meaning as `CASH_ENTER_TRIGGER_EMA_X`. Example: `1.90`.
- `DEPLOY_CASH_HOLD_PERIODS`
- `DEPLOY_MIN_VOLUME_TO_ENTER_EXTREME_USD` — same meaning as `MIN_VOLUME_TO_ENTER_EXTREME_USD`. Example: `4000`.
- `DEPLOY_EXTREME_ENTER_TRIGGER_EMA_X` — same meaning as `EXTREME_ENTER_TRIGGER_EMA_X`. Example: `4.10`.
- `DEPLOY_ENTER_EXTREME_CONFIRM_PERIODS` — same meaning as `ENTER_EXTREME_CONFIRM_PERIODS`. Example: `2`.
- `DEPLOY_EXTREME_HOLD_PERIODS`
- `DEPLOY_EXTREME_EXIT_TRIGGER_EMA_X` — same meaning as `EXTREME_EXIT_TRIGGER_EMA_X`. Example: `1.20`.
- `DEPLOY_EXIT_EXTREME_CONFIRM_PERIODS` — same meaning as `EXIT_EXTREME_CONFIRM_PERIODS`. Example: `2`.
- `DEPLOY_CASH_EXIT_TRIGGER_EMA_X` — same meaning as `CASH_EXIT_TRIGGER_EMA_X`. Example: `1.20`.
- `DEPLOY_EXIT_CASH_CONFIRM_PERIODS` — same meaning as `EXIT_CASH_CONFIRM_PERIODS`. Example: `3`.
- `DEPLOY_EMERGENCY_FLOOR_TRIGGER_USD` — same meaning as `EMERGENCY_FLOOR_TRIGGER_USD`. Example: `600`.
- `DEPLOY_EMERGENCY_CONFIRM_PERIODS`
- `INIT_PRICE_USD` — pool bootstrap price consumed by `ensure-pool`. Example: `2500`.

For all profiles, constructor-aligned runtime keys are optional and fall back to the corresponding `DEPLOY_*` values.
Use the runtime key only when validation should expect post-deploy drift from the frozen snapshot.

## Optional runtime overrides

- `MIN_COUNTED_SWAP_USD6` — telemetry dust filter in raw `USD6` when a non-default runtime threshold is required.
  When omitted, the loader uses `4_000_000`. Example: `4000000` for `$4`.

Controller constraint notes:
- `EMERGENCY_FLOOR_TRIGGER_USD` must be strictly greater than zero.
- `EMERGENCY_FLOOR_TRIGGER_USD` must be strictly lower than `MIN_VOLUME_TO_ENTER_CASH_USD`.
- `CASH_ENTER_TRIGGER_EMA_X` must be less than or equal to `EXTREME_ENTER_TRIGGER_EMA_X`.
- `EXTREME_EXIT_TRIGGER_EMA_X` must be less than or equal to `CASH_EXIT_TRIGGER_EMA_X`.
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
- `SWAP_DRIVER` (external helper contract for live swaps; reused only if runtime codehash and bound `manager()`
  match the expected canonical helper for the current `POOL_MANAGER`, otherwise auto-reprovisioned)
- `LIQUIDITY_DRIVER` (external helper contract for live liquidity actions; same validation/reprovision rule as
  `SWAP_DRIVER`)
