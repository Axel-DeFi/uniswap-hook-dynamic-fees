# Uniswap v4 VolumeDynamicFeeHook

`VolumeDynamicFeeHook` is a single-pool Uniswap v4 hook that updates LP fees from stable-side volume telemetry and
charges a separate trader-facing `HookFee` through `afterSwap`.

## Project Entry Points

| Question | Answer |
| --- | --- |
| What is this project? | A Uniswap v4 hook with explicit `FLOOR`, `CASH`, and `EXTREME` LP-fee modes plus owner-claimed `HookFee` accounting. |
| Where is the main contract? | `src/VolumeDynamicFeeHook.sol` |
| How do I run tests? | `forge test --offline` |
| Where is the behavior spec? | `docs/SPEC.md` |
| Where is the deploy / ops flow? | `ops/README.md`, with network-specific runbooks under `ops/local`, `ops/sepolia`, and `ops/optimism` |

## Build And Test

```bash
forge build
forge test --offline
```

## Deploy And Operate

```bash
ops/local/scripts/bootstrap.sh

ops/sepolia/scripts/preflight.sh
ops/sepolia/scripts/ensure-hook.sh
ops/sepolia/scripts/ensure-pool.sh
ops/sepolia/scripts/ensure-liquidity.sh

ops/optimism/scripts/preflight.sh
ops/optimism/scripts/ensure-hook.sh
ops/optimism/scripts/ensure-pool.sh
ops/optimism/scripts/ensure-liquidity.sh
```

For operational details, use:
- `ops/README.md`
- `ops/local/RUNBOOK.md`
- `ops/sepolia/RUNBOOK.md`
- `ops/optimism/RUNBOOK.md`

## License / Usage Notice

This repository is source-available for review only. No license is granted for use, modification, deployment, or redistribution without prior written permission.
See `LICENSE` for the full terms.