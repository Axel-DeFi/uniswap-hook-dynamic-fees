# Scripts

Shell + Foundry scripts are used to:
1) deploy the hook at a mined CREATE2 address,
2) initialize pool and liquidity,
3) run operational checks.

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

## Main flows

### Deploy hook

```bash
./scripts/deploy_hook.sh --chain <chain> --rpc-url <url> --private-key <pk> --broadcast
```

Uses:
- `scripts/foundry/DeployHook.s.sol`
- Deployment is constructor-driven only; no post-deploy admin setter phase is executed.
- The script derives the canonical CREATE2 address from the current release/config constructor args, reuses an
  already-valid canonical hook, and never mines an alternate duplicate address on rerun.

### Create + initialize pool

```bash
./scripts/create_pool.sh --chain <chain> --rpc-url <url> --private-key <pk> --broadcast
```

The pool-init script reconstructs constructor identity, requires `HOOK_ADDRESS` to match the canonical hook for the
current release/config, and validates the canonical deployed hook before broadcasting pool initialization.

### Inspect hook state

```bash
./scripts/hook_status.sh --chain <chain>
./scripts/hook_status.sh --chain <chain> --watch-seconds 15
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
