# Test scripts

This directory is reserved for **test-only** scripts (local Anvil helpers, fuzz harness runners, etc.).
Production/ops scripts live in `/scripts`.

Current long-run live traffic simulator:
- `./test/scripts/simulate_fee_cycle.sh`

`simulate_fee_cycle.sh` modes:
- `--mode cases` (default): deterministic suite for hook behavior coverage.
- `--mode random`: long-running random traffic with anti-drift protection.

Default run profile:
- chain is fixed to `sepolia` in this workflow.
- broadcast is enabled by default.
- hook address is read from `config/hook.sepolia.conf` (`HOOK_ADDRESS`) with optional override.

`cases` mode flow (high-level):
- EMA bootstrap from zero-volume baseline.
- v2 controller transitions: `JUMP_CASH`, `JUMP_EXTREME`, `HOLD`, `DOWN_TO_CASH`, `DOWN_TO_FLOOR`.
- Runtime safety transitions: `DEADBAND`, `NO_SWAPS`, `EMERGENCY_FLOOR`, `LULL_RESET`.
- Governance and monetization checks: pause/unpause/freeze-resume, hook fee accrue/claim.
- Defensive anomaly checks (revert paths) via `eth_call`.

`cases` mode accounting:
- Case completion is strict per current run cycle: a scenario is counted only when observed in its expected stage.
- Early/accidental observations outside the current stage do not complete the scenario checklist.
- Stage order is fixed and deterministic: `up_to_cap -> cap_probe -> reversal_mid -> reversal_seed -> reversal_opposite -> down_to_floor -> floor_probe -> deadband_probe -> lull_wait`.
- Final checks are executed after lull stage: `post_checks` in strict sequence:
  1) pause + floor lock
  2) paused freeze probe (qualifying swap must not move level)
  3) unpause
  4) post-unpause resume probe (qualifying swap must move level again)
  5) monetization accrue/claim
  6) anomaly matrix checks
- If run starts already at cap, `up_to_cap` is skipped and run starts from `cap_probe`.

Run control:
- `--cases-runs <N>`: run deterministic suite `N` times.
- `--duration-seconds <N>`: stop by wall-clock time (`0` = unlimited).
- Stop condition is whichever comes first (`cases-runs` or `duration`).

Important timing note:
- In `cases` mode, one full run always includes the lull-reset wait (`HOOK_LULL_RESET_SECONDS + 3`), so minimal runtime of a full run is bounded by that pause plus tx confirmation time.
- In strict cases mode, swaps are period-synchronized (one controlled close per period) to keep stage checks reproducible.

Why one transaction can move fee by 2+ levels down:
- A single swap can close multiple overdue periods (`elapsed / periodSeconds > 1`).
- Only the first closed period uses accumulated volume; subsequent closed periods use zero close-volume.
- If fee is above floor, each extra zero-volume close can apply one-step down (`zero-ema decay`), so total downshift in one tx may be 2+ levels.
- Upward multi-step in one tx is not expected in current hook logic, because only the first closed period can carry non-zero close-volume.

Sizing and pool-safety:
- In `cases` mode, swap size is derived from the **missing delta** to the target period volume (not from a fixed large amount).
- Per-tx amounts are clamped to conservative bounds (defaults: `0.5..3.0` stable units per swap) and wallet-balance limits.
- This keeps deadband-crossing behavior while reducing risk of extreme pool reserve skew.

Wallet auto-rebalance:
- The simulator can automatically rebalance free wallet assets toward ~50/50 (stable/volatile by value).
- Default in current script: `disabled` (`AUTO_REBALANCE_ENABLED=0`) to avoid large maintenance swaps during mechanics-focused runs.
- If enabled, rebalance uses wrapped ETH flow and may consume part of free ETH above a native reserve floor.

Examples:
```bash
./test/scripts/simulate_fee_cycle.sh
./test/scripts/simulate_fee_cycle.sh --cases-runs 3
./test/scripts/simulate_fee_cycle.sh --duration-seconds 7200
./test/scripts/simulate_fee_cycle.sh --mode random --duration-seconds 3600
```
