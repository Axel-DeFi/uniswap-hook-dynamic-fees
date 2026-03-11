# Optimism Acceptance

Acceptance criteria mirror the shared live-ops standard:

1. `preflight.sh` must pass before any broadcast-capable phase.
2. `ensure-hook.sh` reuses only the canonical valid hook for the current release/config or deploys it if missing.
3. `ensure-pool.sh` is idempotent and refuses non-canonical/stale hook identity.
4. `ensure-liquidity.sh` never targets a pool outside the canonical hook-bound path.
5. `smoke/full/rerun-safe/emergency` execute through the same shared Foundry layer used by Sepolia.
