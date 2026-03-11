# Scripts

Top-level `scripts/` now contains only auxiliary tooling:
1. observability / diagnostics helpers,
2. release helpers,
3. local gas-measurement helpers.

Canonical deployment and live operational flows are under:
- `ops/local`
- `ops/sepolia`
- `ops/optimism`

## Required hook flags

Deployment/mining must include:
- `AFTER_INITIALIZE`
- `AFTER_SWAP`
- `AFTER_SWAP_RETURNS_DELTA`

## Core config concepts

- `OWNER`: admin role and claim recipient for accrued HookFees.
- `HOOK_FEE_PERCENT`: HookFee percent (0..10, timelocked in contract).
- `FLOOR_TIER`, `CASH_TIER`, `EXTREME_TIER`: explicit LP fee regime model.
- `STABLE`, `STABLE_DECIMALS`: telemetry quote token and scaling mode.

## Canonical operational flows

Use the `ops/*` wrappers instead of ad-hoc deploy/create scripts:

```bash
ops/local/scripts/bootstrap.sh
ops/sepolia/scripts/ensure-hook.sh
ops/sepolia/scripts/ensure-pool.sh
ops/sepolia/scripts/ensure-liquidity.sh
ops/optimism/scripts/ensure-hook.sh
ops/optimism/scripts/ensure-pool.sh
ops/optimism/scripts/ensure-liquidity.sh
```

### Inspect hook state

```bash
./scripts/hook_status.sh --chain <local|sepolia|optimism>
./scripts/hook_status.sh --chain optimism --refresh 15
./scripts/show_deposits.sh --chain optimism
```

### Release helpers

```bash
scripts/release/check.sh
scripts/release/cut.sh --bump patch --push
```

## Gas artifacts (local)

Use this reproducible flow for audit gas evidence:

```bash
export NO_PROXY='127.0.0.1,localhost'
export no_proxy='127.0.0.1,localhost'
export HTTP_PROXY='http://127.0.0.1:9'
export HTTPS_PROXY='http://127.0.0.1:9'
export ALL_PROXY='http://127.0.0.1:9'

ops/local/scripts/anvil-up.sh
forge test --offline --gas-report --match-contract VolumeDynamicFeeHookAdminTest > ops/local/out/reports/gas.admin.report.txt
forge script scripts/foundry/MeasureGasLocal.s.sol:MeasureGasLocal --rpc-url http://127.0.0.1:8545 --broadcast
ops/local/scripts/anvil-down.sh
```

Primary artifacts:
- `ops/local/out/reports/gas.admin.report.txt`
- `scripts/out/broadcast/MeasureGasLocal.s.sol/31337/run-latest.json`

## Operational notes

- `pause()`/`unpause()` are freeze/resume semantics (not swap stop, not HookFee stop).
- Emergency resets are paused-only and explicit (`toFloor` / `toCash`).
- `minCountedSwapUsd6` is telemetry-only dust filtering, not a swap gate.
- Default telemetry dust threshold is `$4 / 4e6` (selected from observed v1 telemetry).
- Threshold updates are pending-state only, bounded to `1e6..10e6`, and activate at next period boundary.
- Threshold updates intentionally have no timelock; recalibration target cadence is 5 days offchain.
- Claim payout path uses PoolManager accounting withdrawal (`unlock` -> `burn` -> `take`).
- Oversized claim payouts are chunked automatically to fit PoolManager `int128` accounting bounds.
- Full claim path is `claimAllHookFees()` only and always pays current `owner()`.
- `MIN_COUNTED_SWAP_USD6` is the expected current telemetry threshold used for deploy/ensure/preflight reuse validation
  (defaults to `4_000_000` if omitted).
- For native-asset pools (`token0 == address(0)` or `token1 == address(0)`), deploy/ensure/preflight validates that current `owner()` can receive native payout from PoolManager sender context in the claim path.
- Existing hook reuse is pinned to the canonical CREATE2 address for the current release and current constructor args,
  requires the exact minimal callback surface (`afterInitialize`, `afterSwap`, `afterSwapReturnDelta` only), and
  requires full config identity match plus exact PoolManager binding and zero pending state:
  `owner()`, no `pendingOwner()`, stable decimals mode, current `minCountedSwapUsd6()`, fees, HookFee percent,
  timing params, controller params, and no pending HookFee / min-counted-swap changes.
- Auxiliary scripts resolve network defaults from `ops/<network>/config/defaults.env` and live addresses from
  `ops/<network>/out/state/<network>.addresses.json`.
- Ownership transfer (`proposeNewOwner` -> `acceptOwner`) automatically moves payout destination without extra sync calls.
- `approxLpFeesUsd6` is approximate analytics, not accounting output.
- Pool key uses strict dynamic fee flag matching (`key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG`).
- `emergencyFloorCloseVolUsd6` must satisfy `0 < emergencyFloorCloseVolUsd6 < minCloseVolToCashUsd6`.
- Hold semantics are `N -> N - 1` effective protected periods; production guidance is
  `CASH_HOLD_PERIODS >= 2` and `EXTREME_HOLD_PERIODS >= 2` (recommended `3..4`).
- Non-local deploy/ensure/preflight guardrails block weak hold configs by default; explicit override:
  `ALLOW_WEAK_HOLD_PERIODS=1`.
- Production owner baseline: multisig + cold/hardware key custody; hot-wallet ownership is not acceptable.
- Overdue catch-up can close multiple periods in one swap; only the first close uses accumulated close volume while later closes use zero close volume.
- Multi-close downward sequences are accepted architectural/economic behavior in current scope and should be monitored.
