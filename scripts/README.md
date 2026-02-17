# Scripts

This project uses plain-text `.conf` files in `./config/` and a small set of shell scripts in `./scripts/`.

## Structure

- `deploy_hook.sh` — deploys the hook (CREATE2-mined address with correct permission bits)
- `create_pool.sh` — creates + initializes the Uniswap v4 pool (dynamic fee flag) using a deployed hook
- `deploy.sh` — one-shot convenience wrapper: deploy hook, then create + initialize pool
- `foundry/` — Foundry Solidity scripts used internally by the shell scripts
- `scripts/out/` — script outputs (JSON)
- `out/` / `cache/` — Foundry build artifacts

## Usage

All scripts support an optional chain selector:

```bash
./scripts/deploy_hook.sh --chain arbitrum --broadcast
./scripts/create_pool.sh --chain arbitrum --broadcast
./scripts/deploy.sh --chain arbitrum --broadcast
```

### Config files

Scripts load configuration from:

- Hook deployment: `./config/hook.<chain>.conf` (preferred) or `./config/hook.conf`
- Pool creation: `./config/pool.<chain>.conf` (preferred) or `./config/pool.conf`

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

## Notes

- Foundry build artifacts are written under `./out` and `./cache` (see `foundry.toml`).
- For verification options (`--verify` etc.), pass flags through to the underlying `forge script` command.


## Apply pending pause/unpause immediately

- `./scripts/apply_pending_pause.sh --chain <chain> [<rpc_url>] [--broadcast]`
  Applies a pending pause/unpause fee update immediately via PoolManager.unlock.

## Script separation

> `/scripts` contains production/ops scripts only.
> Test-only scripts live under `/test/scripts` and `/test/foundry`.

