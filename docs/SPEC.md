# Volume-Based Dynamic Fee Hook (Uniswap v4) — Specification

This document is the single source of truth for the hook's design, configuration, and operational semantics.

## Goals

- Increase LP fee revenue by adapting the LP fee tier to *volume regimes*.
- Stateless with respect to price and external signals: **no oracles, no TWAP, no volatility state**.
- Gas-efficient: fee decisions happen **lazily** at period boundaries (and bounded catch-up).
- No owner-controlled fee: the hook has **no manual fee setter**.

## Non-goals

- Impermanent loss optimization.
- Price prediction.
- MEV/arb filtering.

## High-level behavior

- Track a **USD proxy volume** per period from swap deltas:
  - For stable-paired pools, the stable side is treated as **USD** (assume 1 stable = $1).
  - USD proxy volume is computed as: `volumeUSD6 += 2 * abs(stableAmount)` and normalized to **USD6** (1e6).
- Maintain an **EMA of volume** (emaVolumeUSD6) over a fixed number of periods.
- At each period close, compare the closed volume to EMA and move the fee tier by **at most one step**.
- Use a **deadband** (relative band) to prevent oscillation around the mean.
- **Cap growth**: fee index is bounded by `[floorIdx, capIdx]` (cap is explicit and enforced).
- **Lull reset**: after inactivity ≥ `lullResetSeconds`, reset to `initialFeeIdx` and clear EMA.

## Fee tiers

The fee tier is selected from a fixed grid of discrete tiers (in **fee units** used by Uniswap v4).
Example grid (basis points * 1e4): `95, 400, 900, 2500, 3000, 6000, 9000`.

- `floorIdx` sets the minimum fee tier index.
- `capIdx` sets the maximum fee tier index (explicit cap).
- `initialFeeIdx` is used on pool initialization and on lull reset.

## Perioding model

- Period length: `periodSeconds` (e.g., 300 seconds).
- The hook aggregates swap volume into `periodVolUSD6`.
- When `elapsed >= periodSeconds`, the hook "closes" the current period:
  - Update EMA with the period volume.
  - Decide whether to move the fee index (up/down/no-change).
  - Start a new period and count the triggering swap into it.
- If multiple full periods elapsed (but still below `lullResetSeconds`), the hook simulates missed closes in-memory:
  - The first closed period uses the accumulated `periodVolUSD6`.
  - Subsequent missed periods are treated as **0 volume**.
  - **Bounded** by `lullResetSeconds <= periodSeconds * MAX_LULL_PERIODS` (constructor enforces this).

## Decision logic

Let:
- `v` = closed period volume (USD6)
- `ema` = EMA volume (USD6)

Compute ratio-like score implicitly and apply:
- **Deadband**: if `v` is within `± deadbandBps` of `ema`, keep the current fee tier.
- Otherwise:
  - If `v` is meaningfully above EMA: **increase fee tier** by 1 step (up to cap).
  - If `v` is meaningfully below EMA: **decrease fee tier** by 1 step (down to floor).

Additional constraint:
- **At most one fee step per period** (hard rule).

### "Volume regimes" in practice

- **Regime A (quiet):** `v < ema` for multiple periods → fee trends downward toward `floorIdx` to attract flow.
- **Regime B (normal):** `v ≈ ema` → fee stays stable (deadband prevents “sawtooth”).
- **Regime C (hot):** `v > ema` for multiple periods → fee trends upward toward `capIdx` to monetize heavy flow.

## Pause / Guardian

The guardian can pause/unpause the algorithm, but cannot set arbitrary fees.

### Pause semantics

- `pause()`:
  - Freezes model updates.
  - Resets volumes/EMA and sets the **target fee tier** to `pauseFeeIdx`.
  - Marks a **one-shot pending fee update**.
- `unpause()`:
  - Resets volumes/EMA and sets target to `initialFeeIdx`.
  - Marks a **one-shot pending fee update**.

**Important:** The PoolManager dynamic fee is updated **only during hook callbacks** (e.g., `afterInitialize`, `afterSwap`), because the PoolManager is unlocked there.
Therefore:
- Pause/unpause **do not** directly call `updateDynamicLPFee`.
- The fee update is applied on the **next callback** (init or next swap).

This is deliberate and avoids reverts due to calling PoolManager update functions while locked.

## Storage and packing

All per-pool state is packed into a single `uint256`:
- `periodVolUSD6` (uint64)
- `emaVolumeUSD6` (uint96)
- `periodStart` (uint32)
- `feeIdx` (uint8)
- `lastDir` (2 bits)
- `paused` bit
- `pauseApplyPending` bit

This keeps updates efficient and minimizes SSTOREs.

## Events (no spam)

No "period closed" event is emitted.
Events are emitted only for meaningful transitions:
- `FeeUpdated(...)` — only when fee tier changes (and also on init/pause-apply)
- `Paused(...)`, `Unpaused()`
- `LullReset(...)`

## Operational guidance

- See `./scripts/README.md` for deployment and pool creation flows.
- Use the `.conf` files in `./config/` to parameterize deployment per chain.

## Accepted risks and runbooks

This hook intentionally does **not** use oracles/TWAP.
See `docs/FAQ.md` for the full rationale (“Why no oracles”).

### Threats we explicitly accept

- If a pool becomes extremely inactive, some updates happen only on the next swap (lull reset and pause/unpause application).
  - **Runbook:** if you need an immediate state transition, trigger a minimal swap on the pool to invoke `afterSwap`.

### Guardian key risk

- Guardian is a single EOA by default.
  - **Recommendation:** for production / enterprise, use a multisig as guardian.
