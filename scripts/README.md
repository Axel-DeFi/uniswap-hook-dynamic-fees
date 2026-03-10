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

## Operational notes

- `pause()`/`unpause()` are freeze/resume semantics (not swap stop, not HookFee stop).
- Emergency resets are paused-only and explicit (`toFloor` / `toCash`).
- `minCountedSwapUsd6` is telemetry-only dust filtering, not a swap gate.
- Threshold updates are pending-state only, bounded to `1e6..10e6`, and activate at next period boundary.
- Threshold updates intentionally have no timelock; recalibration target cadence is 5 days offchain.
- Claim payout path uses PoolManager accounting withdrawal (`unlock` -> `burn` -> `take`).
- `approxLpFeesUsd6` is approximate analytics, not accounting output.
