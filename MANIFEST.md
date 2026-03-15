# Audit Bundle Manifest

This manifest describes the intended review scope of the `VolumeDynamicFeeHook` audit bundle.

## Canonical repository

Repository: https://github.com/Axel-DeFi/uniswap-hook-dynamic-fees

This repository is the canonical location for:
- source code,
- documentation,
- audit reports and related review artifacts.

## Documentation hierarchy

Behavioral interpretation follows this order:
- contract NatSpec in `src/VolumeDynamicFeeHook.sol`,
- normative specification in `docs/SPEC.md`,
- operational guidance in `README.md`, `docs/FAQ.md`, and runbooks.

If there is any mismatch, contract NatSpec and `docs/SPEC.md` take precedence.

## Included scope

The audit bundle is intended to include the minimum tracked files needed for review of:
- contract source under `src/`,
- normative and supporting documentation under `docs/`,
- repository metadata and release files: `README.md`, `CHANGELOG.md`, `VERSION`, `LICENSE`, `AGENTS.md`, `MANIFEST.md`, `foundry.toml`, `foundry.lock`, and `remappings.txt`,
- shared live-ops code under `ops/shared/`,
- local, Sepolia, and Optimism operational materials under `ops/local/`, `ops/sepolia/`, and `ops/optimism/`,
- tests under `ops/tests/`,
- curated helper scripts under `scripts/`: `scripts/README.md`, `scripts/build_audit_bundle.sh`, `scripts/calc_init_sqrt_price.sh`, `scripts/simulate_fee_cycle.sh`, and `scripts/release/`,
- generated gas-evidence files under `validation/gas/` inside the bundle workspace.

## Explicit exclusions

The audit bundle intentionally excludes:
- vendored dependencies under `lib/`,
- generated outputs, caches, logs, and local state artifacts, except copied gas evidence under `validation/gas/`,
- git and CI helper files not required for review: `.env.example`, `.gitattributes`, `.gitignore`, `.gitmodules`, and `.github/`,
- post-deploy monitoring and analytics helpers: `scripts/hook_status.sh`, `scripts/show_deposits.sh`, and `scripts/pool_stats_op.sh`,
- local environment lifecycle wrappers: `ops/local/scripts/anvil-up.sh`, `ops/local/scripts/anvil-down.sh`, `ops/local/scripts/bootstrap.sh`, and `ops/local/scripts/reset-state.sh`.

## Interpretation

This file documents the intended bundle policy in human-readable form.
If an archive is generated with export rules, the resulting archive file list is authoritative for that artifact.
