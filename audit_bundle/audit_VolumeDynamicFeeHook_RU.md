# VolumeDynamicFeeHook — Audit Bundle Update (Polishing Patch)

Документ обновлён: 10 марта 2026.

## Scope

Патч покрывает только согласованный объём после свежего аудита:
- misconfiguration trap: `lullResetSeconds == periodSeconds`;
- defensive guard для ownership flow: запрет `proposeNewOwner(currentOwner)`;
- документирование by-design семантик:
  - effective hold: `cashHoldPeriods = N` даёт `N - 1` fully protected periods;
  - HookFee approximation (exact-input / exact-output);
  - pause mode behavior.

Вне scope и сознательно не менялось:
- H-01 / timelock для `setHookFeeRecipient(...)`;
- экономика HookFee;
- широкая переработка fee-tier state machine;
- storage layout / `_state` packing.

## Code Hardening

### 1) Misconfiguration trap fix (`lullResetSeconds > periodSeconds`)

Изменено в `src/VolumeDynamicFeeHook.sol`:
- в `_setTimingParamsInternal(...)` проверка ужесточена до strict inequality:
  - было: `lullResetSeconds_ < periodSeconds_`;
  - стало: `lullResetSeconds_ <= periodSeconds_` (revert `InvalidConfig()`).

Результат:
- конфигурация `lullResetSeconds == periodSeconds` теперь запрещена;
- исключён режим, где ветка lull-reset может постоянно перехватывать period-close и удерживать контроллер на floor.

### 2) Ownership defensive guard (`proposeNewOwner(currentOwner)`)

Изменено в `src/VolumeDynamicFeeHook.sol`:
- в `proposeNewOwner(address newOwner)` добавлен запрет self-pending-owner:
  - `if (newOwner == address(0) || newOwner == _owner) revert InvalidOwner();`

Результат:
- владелец больше не может создать self-pending-owner trap;
- двухшаговая модель transfer ownership сохранена без изменений.

## Documented-By-Design Semantics

### 3) Hold semantics (`N - 1`)

Зафиксировано в NatSpec + docs:
- hold counter уменьшается в начале каждого closed period;
- из-за порядка выполнения `cashHoldPeriods = N` даёт `N - 1` fully protected periods;
- `cashHoldPeriods = 1` даёт нулевую effective hold protection.

### 4) HookFee approximation (exact-input / exact-output)

Зафиксировано в NatSpec + docs:
- HookFee считается по approximate LP-fee estimate;
- estimate привязан к unspecified side текущего execution path;
- небольшое систематическое расхождение между exact-input и exact-output является ожидаемым by design;
- значение подходит для текущей protocol fee logic, но не является accounting-grade replica LP fee.

### 5) Pause semantics

Зафиксировано в NatSpec + docs:
- `pause()` замораживает regulator transitions и фиксирует active LP fee tier;
- swaps не отключаются;
- HookFee accrual продолжает работать в paused mode;
- emergency reset функции доступны только в paused mode.

## Tests (Added / Updated)

### Added

- `ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol`
  - `test_setTimingParams_reverts_when_lullReset_equals_period`
  - `test_owner_transfer_rejects_propose_current_owner`
  - `test_cashHoldPeriods_one_results_in_zero_effective_hold_protection`
  - `test_hookFee_approximation_exactInput_vs_exactOutput_paths`

- `ops/tests/unit/VolumeDynamicFeeHook.ConfigAndEdges.t.sol`
  - `test_constructor_reverts_when_lullReset_equals_period`

### Updated

- `ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol`
  - `test_pause_unpause_freeze_resume_semantics`
    - дополнительно фиксирует, что в paused mode не происходят state-machine transitions (`feeIdx`/`periodStart` freeze, `updateDynamicLPFee` не вызывается), при этом HookFee accrual остаётся активным.

## Documentation Changes

Обновлено и синхронизировано с реализацией:
- `src/VolumeDynamicFeeHook.sol` (NatSpec);
- `docs/SPEC.md`;
- `README.md`;
- `docs/FAQ.md`.

Ключевые уточнения в документации:
- strict timing guard: `lullResetSeconds > periodSeconds`;
- self-pending-owner reject;
- hold semantics `N - 1`;
- HookFee approximation semantics;
- pause mode behavior.

## Validation (Local)

Подтверждённые команды:
- `forge build` — **ok**;
- `forge test --offline --match-path 'ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol'` — **19 passed, 0 failed**;
- `forge test --offline --match-path 'ops/tests/unit/VolumeDynamicFeeHook.ConfigAndEdges.t.sol'` — **18 passed, 0 failed**;
- `forge test --offline --match-path 'ops/tests/integration/VolumeDynamicFeeHook.ClaimAccounting.t.sol'` — **4 passed, 0 failed**.

## Residual / Accepted Risks (Unchanged)

- `setHookFeeRecipient(...)` остаётся immediate (без timelock) как ранее принятый governance/key risk.
- Этот риск не закрывался в данном patch set по согласованному scope.

## Conclusion

Патч минимальный и production-oriented: добавлены только необходимые guardrails и документирование by-design семантик без изменения экономики HookFee и без расширения governance-механик. Изменения подтверждены целевыми unit/integration regressions и согласованы между кодом, тестами и документацией.
