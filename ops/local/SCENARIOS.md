# Local Scenarios

Scenario overlays are in `ops/local/config/scenarios`.

- `bootstrap.env` — deterministic setup profile.
- `smoke.env` — small swap budget, quick signal.
- `full.env` — broader operational sampling.
- `fuzz-lite.env` — more iterations with conservative swap caps.
- `rerun.env` — idempotency stress profile.
- `emergency.env` — pause/reset/unpause focused profile.

Select scenario via:

```bash
OPS_SCENARIO=full ops/local/scripts/preflight.sh
```

Defaults are loaded from `ops/local/config/defaults.env`.
