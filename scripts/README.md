# Scripts

This project uses plain-text `.conf` files in `./config/` and a small set of shell scripts in `./scripts/`.

## Structure

- `deploy_hook.sh` — deploys the hook (CREATE2-mined address with correct permission bits)
- `create_pool.sh` — creates + initializes the Uniswap v4 pool (dynamic fee flag) using a deployed hook
- `deploy.sh` — one-shot convenience wrapper: deploy hook, then create + initialize pool
- `foundry/` — Foundry Solidity scripts used internally by the shell scripts
- `scripts/out/` — script outputs, cache, and broadcast artifacts
- `out/` — Foundry build artifacts

## Usage

All scripts support an optional chain selector:

```bash
./scripts/deploy_hook.sh --chain arbitrum --broadcast
./scripts/create_pool.sh --chain arbitrum --broadcast
./scripts/deploy.sh --chain arbitrum --broadcast
```

### Config files

Scripts load configuration from:

- Hook deployment: `./config/hook.<chain>.conf` (preferred) or `./config/hook.conf` (fallback)
- Pool creation: `./config/pool.<chain>.conf` (preferred) or `./config/pool.conf` (fallback)

You can also pass `--rpc-url <...>` or a positional RPC URL; CLI overrides config.

### Stable decimals safety check

`deploy_hook.sh` verifies `STABLE_DECIMALS` matches the token's on-chain `decimals()` call.
To bypass (not recommended), set:

```bash
export SKIP_DECIMALS_CHECK=1
```

### Outputs

- Hook deployment output: `./scripts/out/deploy.<chain>.json`
- Pool creation reads the hook address from the deploy JSON unless `HOOK_ADDRESS` is set in `pool.conf`.
- Foundry script broadcast logs: `./scripts/out/broadcast/`
- Foundry script cache: `./scripts/out/cache/`

## Notes

- Foundry build artifacts are written under `./out` (see `foundry.toml`).
- For verification options (`--verify` etc.), pass flags through to the underlying `forge script` command.


## Apply pending pause/unpause immediately

- `./scripts/apply_pending_pause.sh --chain <chain> [<rpc_url>] [--broadcast]`
  Applies any still-pending pause/unpause update via PoolManager.unlock.
  Normally pause/unpause are already immediate for initialized pools; this is mainly a recovery helper.

## Dynamic fee cycle simulation (manual run + report)

- `./scripts/simulate_fee_cycle.sh --chain <chain> [--rpc-url <url>] [--swap-test-address <addr>]`
  Runs a full live sequence on the configured hook/pool with adaptive swap sizing from current EMA:
  1. force an `UP` move,
  2. reversal-lock check (fee/index unchanged),
  3. force a `DOWN` move.
  Prints the final report directly to console (stdout), including tx hashes and before/after states.

Required:

- `HOOK_ADDRESS`, `TOKEN0`, `TOKEN1`, `TICK_SPACING`, `PRIVATE_KEY` from `config/pool.<chain>.conf` (+ `.env` key interpolation).
- `PoolSwapTest` helper address, passed via `--swap-test-address`, `SWAP_TEST_ADDRESS`, or autodetected from
  `scripts/out/broadcast/03_PoolSwapTest.s.sol/<chainId>/run-latest.json`.

## Script separation

> `/scripts` contains production/ops scripts only.
> Test-only scripts live under `/test/scripts` and `/test/foundry`.
