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

The audit bundle is intended to include the tracked files needed for review of:
- contract source under `src/`,
- normative and supporting documentation under `docs/`,
- repository metadata and release files such as `README.md`, `CHANGELOG.md`, `VERSION`, `LICENSE`, `AGENTS.md`, and this manifest,
- shared live-ops code under `ops/shared/`,
- local and Sepolia operational materials under `ops/local/` and `ops/sepolia/`,
- Optimism deployment materials under `ops/optimism/`, except files explicitly excluded below,
- tests under `ops/tests/`,
- helper scripts under `scripts/` and `test/scripts/`.

## Explicit exclusions

The audit bundle intentionally excludes:
- vendored dependencies under `lib/`,
- generated outputs, caches, logs, and local state artifacts,
- `ops/optimism/RUNBOOK.md`.

## Interpretation

This file documents the intended bundle policy in human-readable form.
If an archive is generated with export rules, the resulting archive file list is authoritative for that artifact.
