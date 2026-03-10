# Unified Ops Testing Framework

`ops/` is the unified testing and operational validation architecture for:

1. Contract-level tests (`ops/tests`)
2. Local operational validation on Anvil (`ops/local`)
3. Sepolia operational validation (`ops/sepolia`)

## High-level layers

- `ops/shared` — reusable Solidity libs/types/config schema.
- `ops/tests` — unit/fuzz/invariant test suites.
- `ops/local` — deterministic local lifecycle + operational scenarios.
- `ops/sepolia` — public testnet preflight/inspect/ensure/operational flows.

## Contract test command

```bash
FOUNDRY_PROFILE=ops NO_PROXY='*' forge test
```

## Read-only vs broadcast phases

- Read-only: `preflight`, `inspect`
- Broadcast-capable: `bootstrap`, `ensure-*`, `smoke`, `full`, `rerun-safe`, `emergency`

## Operator docs

- Local: `ops/local/README.md`, `ops/local/RUNBOOK.md`, `ops/local/SCENARIOS.md`, `ops/local/ACCEPTANCE.md`
- Sepolia: `ops/sepolia/README.md`, `ops/sepolia/RUNBOOK.md`, `ops/sepolia/SCENARIOS.md`, `ops/sepolia/ACCEPTANCE.md`
- Shared schema: `ops/shared/config/schema.md`, `ops/shared/config/scenario.schema.md`
