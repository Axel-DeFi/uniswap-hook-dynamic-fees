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

- `OWNER`: admin role for hook configuration and emergency actions.
- `HOOK_FEE_ADDRESS`: claim recipient for accrued HookFees.
- `HOOK_FEE_PERCENT`: HookFee percent (0..10, timelocked in contract).
- `FEE_TIERS`, `FLOOR_TIER`, `CASH_TIER`, `EXTREME_TIER`: LP fee tier model.
- `STABLE`, `STABLE_DECIMALS`: telemetry quote token and scaling mode.

## Main flows

### Deploy hook

```bash
./scripts/deploy_hook.sh --chain <chain> --rpc-url <url> --private-key <pk> --broadcast
```

Uses:
- `scripts/foundry/DeployHook.s.sol`

### Create + initialize pool

```bash
./scripts/create_pool.sh --chain <chain> --rpc-url <url> --private-key <pk> --broadcast
```

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

## Operational notes

- `pause()`/`unpause()` are freeze/resume semantics (not swap stop, not HookFee stop).
- Emergency resets are paused-only and explicit (`toFloor` / `toCash`).
- `minCountedSwapUsd6` is telemetry-only dust filtering, not a swap gate.
- Default telemetry dust threshold is `$4 / 4e6` (selected from observed v1 telemetry).
- Threshold updates are pending-state only, bounded to `1e6..10e6`, and activate at next period boundary.
- Threshold updates intentionally have no timelock; recalibration target cadence is 5 days offchain.
- Claim payout path uses PoolManager accounting withdrawal (`unlock` -> `burn` -> `take`).
- Full claim path is `claimAllHookFees()` only; recipient override is intentionally unavailable.
- For native-asset pools (`token0 == address(0)` or `token1 == address(0)`), deploy/ensure/preflight validates that `HOOK_FEE_ADDRESS` can receive native payout from hook sender context.
- Zero-address recipient checks alone are insufficient in native-asset pools; if governance changes recipient later, native compatibility must still hold.
- `approxLpFeesUsd6` is approximate analytics, not accounting output.
- Pool key uses strict dynamic fee flag matching (`key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG`).
- `emergencyFloorCloseVolUsd6` must be configured as strictly positive.
- Production owner baseline: multisig + cold/hardware key custody; hot-wallet ownership is not acceptable.
- Overdue catch-up can close multiple periods in one swap; only the first close uses accumulated close volume while later closes use zero close volume.
- Multi-close downward sequences are accepted architectural/economic behavior in current scope and should be monitored.
