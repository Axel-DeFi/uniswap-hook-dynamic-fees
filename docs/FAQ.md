# FAQ

## Where are deployment instructions?

See `./scripts/README.md`.

## What is "lull"?

"Lull" means a quiet period (low activity / inactivity). In this hook, a lull is detected when no swaps happened for at least `lullResetSeconds`.

## Why no oracles / TWAP?


This hook intentionally avoids on-chain price oracles (e.g., Chainlink) and cross-pool TWAP reads.

### Motivation
1. **Gas predictability**
   - Oracle reads add overhead on every hook execution.
   - In extreme gas conditions (Ethereum mainnet spikes), oracle-heavy hooks become economically unattractive.

2. **Reliability / liveness**
   - External oracles can be paused, stale, or revert.
   - A reverting oracle call inside a hook can break swaps (availability risk).

3. **Attack surface**
   - Any dependency expands the audit scope and introduces new failure modes.
   - Cross-pool TWAP introduces additional protocol and integration assumptions.

4. **Simplicity and auditability**
   - The model is designed to be explainable and fully contained:
     - fixed fee buckets,
     - one step per period,
     - EMA smoothing,
     - hard cap (`capIdx`) and floor (`floorIdx`),
     - bounded catch-up via a capped lull reset window.

### Trade-off (explicitly accepted)
- The hook treats the configured stable token as a USD proxy.
- Depeg risk is handled operationally (monitoring + guardian pause), not by on-chain oracle logic.

### When to consider adding oracles anyway
If your primary goal shifts from gas efficiency to maximizing *pricing accuracy* under stable depegs, then:
- a stablecoin price oracle, or
- a cross-pool TWAP (from a deep reference pool)
may be appropriate — but this is a **different design point** with a higher complexity and reliability cost.

## Does this assume every stable = $1?

Yes. For stable-paired pools, the stable side is treated as USD.
This is a deliberate simplification to keep the hook stateless and cheap.
If a stable depegs, the USD proxy volume becomes inaccurate. This is an accepted risk.

## How should I choose tickSpacing?

This hook is compatible with any tickSpacing supported by the pool.
In this repository, deployment configs are standardized to **tickSpacing = 10** across environments.

## Can I use WBTC or other non-ETH assets?

Yes, as long as the pool has a stable (USD proxy) token on one side and you configure:
- which currency is stable (`STABLE`)
- stable decimals (`STABLE_DECIMALS`) — deployment script validates on-chain decimals()

## Does pause/unpause apply immediately?

Yes, for initialized pools.
`pause()` / `unpause()` enter `PoolManager.unlock()` and apply the fee in the hook callback immediately in the same transaction.

If called before pool initialization, the hook keeps a pending flag and finalizes state on initialize.
