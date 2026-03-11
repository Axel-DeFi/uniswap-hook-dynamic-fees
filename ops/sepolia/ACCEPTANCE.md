# Sepolia Acceptance

## Mandatory checks

1. `preflight.sh` succeeds without sending transactions.
2. `inspect.sh` succeeds without sending transactions.
3. `ensure-hook.sh` is idempotent for the canonical hook identity (reuse canonical valid hook or deploy it if missing).
4. `ensure-pool.sh` is idempotent (skip when already initialized) and refuses non-canonical/stale hook identity.
5. `ensure-liquidity.sh` auto-ensures helper drivers, requires preflight by default, and refuses non-canonical/stale
   hook identity before broadcast.
6. `smoke/full/rerun-safe/emergency` only run after preflight passes.

## Artifact checks

- `jq . ops/sepolia/out/reports/preflight.sepolia.json`
- `jq . ops/sepolia/out/state/inspect.sepolia.json`
- `jq . ops/sepolia/out/reports/full.sepolia.json`

## Public testnet limits

Sepolia confirmations, liquidity depth, and helper contract availability can affect execution latency and coverage breadth.
