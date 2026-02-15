# Uniswap v4 Volume-Based Dynamic Fee Hook (Lazy Updates)

A single-pool Uniswap v4 hook that implements **dynamic LP fees** using a **volume-regime** model and **lazy, afterSwap-only updates**.

- No admin fee setter (fees are changed only by the algorithm).
- One hook instance = one pool (no mapping keyed by PoolId).
- Minimal persistent state: **one 32-byte storage slot**, bit-packed.
- Updates are **lazy**: the fee is recomputed only when a swap arrives and the period has elapsed.
- Volume is measured using a configurable **USD stable token** (assumed to be $1).

## Docs

- Specification: `docs/SPEC.md`
- Deployment: `scripts/README.md`
- FAQ: `docs/FAQ.md`
- Changelog: `CHANGELOG.md`

## Build & test

Prerequisites:

- Foundry (latest stable)
- Git

Install dependencies (one-time):

```bash
forge install foundry-rs/forge-std --no-commit
forge install uniswap/v4-core --no-commit
forge install uniswap/v4-periphery --no-commit
forge install uniswapfoundation/v4-hooks-public --no-commit
```

Build:

```bash
forge build
```

Run tests:

```bash
forge test -vvv
```

## License

Apache 2.0. See `LICENSE`.
