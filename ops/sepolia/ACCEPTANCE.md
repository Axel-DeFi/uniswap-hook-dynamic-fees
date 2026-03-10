# Sepolia Acceptance

## Mandatory checks

1. `preflight.sh` succeeds without sending transactions.
2. `inspect.sh` succeeds without sending transactions.
3. `ensure-hook.sh` is idempotent (reuse existing valid hook or deploy if missing).
4. `ensure-pool.sh` is idempotent (skip when already initialized).
5. `ensure-liquidity.sh` auto-ensures helper drivers and fails early if budget is unsafe.
6. `smoke/full/rerun-safe/emergency` only run after preflight passes.

## Artifact checks

- `jq . ops/sepolia/out/reports/preflight.sepolia.json`
- `jq . ops/sepolia/out/state/inspect.sepolia.json`
- `jq . ops/sepolia/out/reports/full.sepolia.json`

## Public testnet limits

Sepolia confirmations, liquidity depth, and helper contract availability can affect execution latency and coverage breadth.
