# Deep Technical + Economic Audit Prompt for `VolumeDynamicFeeHook`

You are a senior smart-contract security auditor and DeFi mechanism designer.
Your task is to perform a deep, adversarial audit of this hook implementation, covering both:
1) technical/security correctness, and
2) economic/game-theoretic behavior.

Language requirement:
- The full audit result must be written in Russian.

## Scope (audit only these files)
- `src/VolumeDynamicFeeHook.sol`
- `docs/SPEC.md`
- `docs/FAQ.md`
- `README.md`
- `scripts/README.md`
- `config/_hook.template.conf`

## Context and design intent (critical to reduce false positives)
Treat the following as intentional design choices, not automatic vulnerabilities:

1. No external oracle/TWAP integration by design.
   - Reason: reduce dependency risk, revert/liveness risk, and attack surface.
   - Stable token side is used as USD proxy.
   - Depeg risk is accepted operationally (monitoring + guardian pause), not solved on-chain.

2. No dedicated anti-volume-manipulation filter by design.
   - Reason: attacker-driven volume generally increases paid fees and can be economically self-penalizing.
   - This can be acceptable for LP-centric revenue objectives.
   - Only flag this as a real issue if you prove a net-profitable adversarial strategy under realistic assumptions (fees, slippage, liquidity depth, gas).

3. Fee updates are afterSwap-only and lazy.
   - No beforeSwap fee override path.
   - No manual admin fee setter.
   - One-step-per-period logic is intentional for stability and predictability.

4. Guardian pause/unpause semantics are immediate for initialized pools.
   - No deferred `apply_pending_pause` mechanism by design.
   - It is known that guardian role should be assigned to a multisig wallet in production.

5. Single-pool deployment model is intentional.
   - One hook instance is bound to one pool key.
   - No multi-pool state mapping.

6. Tick spacing is standardized to 10 in active configs (template reflects deployment intent).

## What to evaluate

### A. Technical/security audit
- Constructor/config validation completeness and bypass possibilities.
- Pool key validation correctness and isolation guarantees.
- Access control (`guardian`) and privilege boundaries.
- State machine safety: initialize, active, paused, lull reset, unpause transitions.
- Correctness of packed storage layout and bit operations.
- Numeric edge cases:
  - scaling (`stableDecimals` to USD6),
  - saturation behavior (`uint64`/`uint96` limits),
  - timestamp/elapsed computations,
  - signed delta absolute conversion.
- External call surfaces and interaction risks (`PoolManager.updateDynamicLPFee`).
- Reentrancy/griefing/DoS considerations.
- Event integrity vs actual state transitions.
- Any mismatch between implementation and `docs/SPEC.md`.

### B. Economic/mechanism audit
- Fee-response behavior under normal, bursty, and low-liquidity regimes.
- Deadband + reversal lock impact on oscillation, lag, and responsiveness.
- Cap/floor behavior and long-run fee drift characteristics.
- Lull reset implications for inactive markets.
- Adversarial strategy analysis:
  - wash-volume style manipulation,
  - griefing via tiny swaps,
  - boundary-timing manipulation at period rollover,
  - liquidity-fragmentation effects.
- For each candidate attack, estimate expected PnL qualitatively or quantitatively (if enough data), including fee + gas + slippage.

## False-positive control policy
- Do not report an issue as a vulnerability if it is clearly an intentional trade-off listed above.
- Instead classify it as `Accepted design trade-off` and explain:
  - why it is acceptable in this design,
  - under which market conditions it may become unacceptable.
- If you still classify as vulnerability, provide clear exploit assumptions and why accepted rationale fails.

## Required output format
Return findings in a single concise table with these columns:
- `ID`
- `Severity` (`Critical/High/Medium/Low/Info`)
- `Domain` (`Technical` or `Economic`)
- `Location` (file + exact line(s))
- `Finding`
- `Impact`
- `Exploit Preconditions`
- `Evidence / Reproduction idea`
- `Recommendation`
- `Classification` (`Vulnerability` / `Accepted design trade-off` / `Observation`)
- `Confidence` (`High/Medium/Low`)

After the table, provide:
1) `Top 3 priorities` (short bullet list),
2) `Suggested additional tests` (targeted, implementation-specific),
3) `Final conclusion` (5-10 lines max): production readiness assessment and key residual risks.

## Strict requirements
- No generic advice without code linkage.
- Every non-trivial claim must reference exact code location(s).
- Separate clearly:
  - exploitable bugs,
  - accepted trade-offs,
  - operational recommendations.
