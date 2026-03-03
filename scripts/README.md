# Scripts

This repository uses a small set of shell + Foundry scripts to:
1) deploy the Uniswap v4 hook (CREATE2 mined address with hook flags),
2) create + initialize a dynamic-fee pool,
3) run the same test suite across environments.

## Configuration

All scripts read dotenv-style config files from `./config/`.

### Pool binding (explicit roles)

We **do not** rely on `TOKEN0/TOKEN1` in configs anymore. Use:

- `VOLATILE` — the risky asset (e.g. WETH)
- `STABLE` — USD-like token used as the unit for `INIT_PRICE_USD`
- `STABLE_DECIMALS` — decimals for `STABLE` (usually 6)
- `TICK_SPACING` — pool tick spacing

### Init price

Use a human price:

- `INIT_PRICE_USD` — interpreted as **STABLE per 1 VOLATILE**

Scripts will automatically:
- sort currencies by address to derive `currency0/currency1` (PoolKey ordering),
- convert `INIT_PRICE_USD` into `INIT_SQRT_PRICE_X96` for pool initialization.

### Secrets

Secrets should live in `./.env` (repo root). Typical variables:

- `DEFAULT_PRIVATE_KEY` — deployer key (used by configs via `PRIVATE_KEY=${DEFAULT_PRIVATE_KEY:-}`)
- `DEFAULT_GUARDIAN` — guardian address (optional)
- `REQUIRE_GUARDIAN_CONTRACT=1` — optional strict mode to require contract guardian (recommended for production)

### Strategy / monetization params

- `INITIAL_FEE_IDX`, `FLOOR_IDX`, `CAP_IDX` — dynamic LP fee tier bounds
- `PAUSE_FEE_IDX` — fee tier used while paused
- `CREATOR_FEE_PERCENT` — creator fee share in percent (for example `10` = 10%)
- `CREATOR_FEE_ADDRESS` — optional payout recipient for creator fees (defaults to `GUARDIAN`)

## Unified test runner

Single entry point:

- `./test/scripts/test_run.sh <local|sepolia|prod> <fast|full> [chain] [--dry-run] [--anvil-port <port>]`

Examples:

- Local (Anvil fork of Sepolia):
  - `./test/scripts/test_run.sh local fast`
  - `./test/scripts/test_run.sh local full --anvil-port 8546`

- Sepolia (live):
  - `./test/scripts/test_run.sh sepolia fast --dry-run`
  - `./test/scripts/test_run.sh sepolia fast`

Notes:
- `fast` is a quick pre-deploy gate.
- `full` is a deeper run (more coverage / stress).

## Core scripts

### Deploy hook

`./scripts/deploy_hook.sh --chain <chain> --rpc-url <url> --private-key <pk> --broadcast`

This runs the Foundry script:

- `scripts/foundry/DeployHook.s.sol`

Outputs:
- `./scripts/out/deploy.<chain>.json` (contains the deployed hook address)

### Create + initialize pool

`./scripts/create_pool.sh --chain <chain> --rpc-url <url> --private-key <pk> --broadcast`

This:
- reads `VOLATILE/STABLE/INIT_PRICE_USD` from config,
- computes `INIT_SQRT_PRICE_X96`,
- reads hook address from `./scripts/out/deploy.<chain>.json` if `HOOK_ADDRESS` is not set,
- runs the Foundry script:
  - `scripts/foundry/CreatePool.s.sol`

### Hook + pool status

`./scripts/hook_status.sh --chain <chain> [--watch-seconds <int>]`

This script prints:
- hook immutable params and current runtime state,
- computed `pool_id` for the bound pool key,
- pool slot0 + liquidity (if `StateView` is available),
- live TVL estimate in USD (mark-to-market at current pool price),
- pool activity from on-chain logs: lifetime + rolling windows (`24h/7d/30d/90d/180d/365d`).
- fee-level activity split (swaps/volume/fees by fee tier).

Notes:
- `lpProviders` is counted by unique transaction senders (`tx.from`) in `ModifyLiquidity` calls for this pool over lifetime.

Optional env tuning:
- `HOOK_STATUS_START_BLOCK` — optional manual start block for lifetime activity (if unset, script tries CreatePool artifact and falls back to `0`).
- `HOOK_STATUS_CHUNK_BLOCKS` — max block span per `eth_getLogs` chunk for lifetime backfill (default: `50000`).

Output mode:
- interactive terminal (TTY): dashboard view with screen redraw (no scrolling in watch mode),
- piped/non-interactive: raw `key=value` lines (stable format for script integrations).

Examples:

```bash
./scripts/hook_status.sh --chain optimism
./scripts/hook_status.sh --chain optimism --watch-seconds 15
```

## Outputs

Runtime artifacts are stored under:

- `./scripts/out/` — deploy JSON and Forge broadcast/cache outputs

These are runtime outputs and typically should not be committed.
