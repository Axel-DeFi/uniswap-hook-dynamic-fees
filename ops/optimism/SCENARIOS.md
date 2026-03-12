# Optimism Scenarios

Scenario overlays follow the same naming as Sepolia and only adjust phase-specific execution knobs:

- `smoke`
- `full`
- `rerun`
- `emergency`

Primary source of truth for live config remains `ops/optimism/config/defaults.env`, overridden by:

1. scenario overlay
2. `.env`
3. process environment
