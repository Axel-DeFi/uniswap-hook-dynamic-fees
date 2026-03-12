# Sepolia Scenarios

Scenario overlays are in `ops/sepolia/config/scenarios`.

- `smoke.env` — conservative swap budget and guardrails.
- `full.env` — broader operational sampling.
- `rerun.env` — idempotency profile.
- `emergency.env` — emergency path profile.

Set scenario explicitly when needed:

```bash
OPS_SCENARIO=full ops/sepolia/scripts/preflight.sh
```

Budget keys in the selected scenario are enforced before every broadcast-capable phase.
