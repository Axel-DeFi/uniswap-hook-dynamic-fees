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

## Outputs

Runtime artifacts are stored under:

- `./scripts/out/` — deploy JSON and Forge broadcast/cache outputs

These are runtime outputs and typically should not be committed.