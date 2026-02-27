# Test scripts

This directory is reserved for **test-only** scripts (local Anvil helpers, fuzz harness runners, etc.).
Production/ops scripts live in `/scripts`.

Current long-run live traffic simulator:
- `./test/scripts/simulate_fee_cycle.sh` (supports `--mode cycle|random|cases`).
