# Test scripts

This directory is reserved for **test-only** scripts (local Anvil helpers, fuzz harness runners, etc.).
Production/ops scripts live in `/scripts`.

Current long-run live traffic simulator:
- `./test/scripts/simulate_fee_cycle.sh`

`simulate_fee_cycle.sh` modes:
- `--mode cases` (default): deterministic suite for hook behavior coverage.
- `--mode random`: long-running random traffic with anti-drift protection.

`cases` mode flow (high-level):
- Ramped `UP` volume that crosses deadband upper threshold and pushes fee toward cap.
- Cap clamp probes.
- Ramped `DOWN` volume that crosses deadband lower threshold and pushes fee toward floor.
- Floor clamp probes.
- Reversal lock probe (opposite direction after directional memory).
- Deadband no-change probe.
- Lull reset probe (`lullReset + 3s` wait, then trigger swap).

`cases` mode accounting:
- Case completion is strict per current run cycle: a scenario is counted only when observed in its expected stage.
- Early/accidental observations outside the current stage do not complete the scenario checklist.
- Start stage is chosen adaptively from current on-chain `feeIdx` (closest edge first), then the script drives through the full checklist.

Run control:
- `--cases-runs <N>`: run deterministic suite `N` times.
- `--duration-seconds <N>`: stop by wall-clock time (`0` = unlimited).
- Stop condition is whichever comes first (`cases-runs` or `duration`).

Important timing note:
- In `cases` mode, one full run always includes the lull-reset wait (`HOOK_LULL_RESET_SECONDS + 3`), so minimal runtime of a full run is bounded by that pause plus tx confirmation time.

Sizing and pool-safety:
- In `cases` mode, swap size is derived from the **missing delta** to the target period volume (not from a fixed large amount).
- Per-tx amounts are clamped to conservative bounds (small-dollar range by default) and wallet-balance limits.
- This keeps deadband-crossing behavior while reducing risk of extreme pool reserve skew.

Wallet auto-rebalance:
- The simulator can automatically rebalance free wallet assets toward ~50/50 (stable/volatile by value).
- Rebalance uses wrapped ETH flow and may consume up to 80% of currently available ETH above a native reserve floor.
- Rebalance is triggered on low token balances (or balance-related swap failures), with an attempt interval guard to avoid excessive maintenance tx.

Examples:
```bash
./test/scripts/simulate_fee_cycle.sh --chain sepolia --mode cases --broadcast
./test/scripts/simulate_fee_cycle.sh --chain sepolia --mode cases --cases-runs 3 --broadcast
./test/scripts/simulate_fee_cycle.sh --chain sepolia --mode cases --duration-seconds 7200 --broadcast
./test/scripts/simulate_fee_cycle.sh --chain sepolia --mode random --duration-seconds 3600 --broadcast
```
