# VolumeDynamicFeeHook v2 — Audit Bundle Update

Документ обновлён: 10 марта 2026.

## Scope

Патч покрывает только согласованный объём:
- исправления аудиторских замечаний: **Н-04, Н-05, Н-06, Н-09**;
- обновление default dust threshold: **`minCountedSwapUsd6 = 4e6`**;
- актуализацию audit bundle по фактическому покрытию локальных и Sepolia-проверок.

Пункты вне scope этого патча:
- **Н-01 не изменялся**;
- timelock для `setHookFeeRecipient(...)` не добавлялся;
- `_computeNextFeeIdxV2` не переписывался;
- бизнес-логика вне перечисленных фиксов не расширялась.

## Fixed Findings

### Н-04 — non-role `feeIdx` после `setFeeTiersAndRoles(...)`

Исправлено в `src/VolumeDynamicFeeHook.sol`:
- после `_findTierIdx(...)` добавлена явная проверка, что найденный индекс является одной из ролей (`floorIdx` / `cashIdx` / `extremeIdx`);
- если индекс найден, но не role-index, `nextFeeIdx` принудительно переводится в `floorIdx`;
- одновременно сбрасываются `holdRemaining`, `upExtremeStreak`, `downStreak`, `emergencyStreak`.

Результат: инвариант "active fee index всегда role-index" соблюдается после перестройки tiers/roles.

### Н-05 — floor-режим не должен сохранять hold/streak baggage

Исправлено в `src/VolumeDynamicFeeHook.sol`:
- после вычисления финального `nextFeeIdx` добавлено правило: если `nextFeeIdx == floorIdx`, то `holdRemaining` и все streak counters принудительно обнуляются.

Результат: floor-режим всегда стартует в чистом состоянии, независимо от того, был ли старый tier найден.

### Н-06 — активация pending threshold в ветке lull reset

Исправлено в `_afterSwap(...)` (`src/VolumeDynamicFeeHook.sol`):
- `_activatePendingMinCountedSwapUsd6()` вызывается в ветке `elapsed >= lullResetSeconds`;
- вызов расположен **до** `periodVol = _addSwapVolumeUsd6(0, delta)`.

Результат: первый swap нового периода после lull reset учитывается уже с новым threshold.

### Н-09 — единый source of truth для количества tiers

Исправлено в `src/VolumeDynamicFeeHook.sol`:
- удалён storage-поле `uint16 public feeTierCount`;
- добавлен ABI-совместимый getter:
  - `function feeTierCount() public view returns (uint16)`
  - возвращает `uint16(_feeTiersByIdx.length)`;
- bounds check в `feeTiers(uint256 idx)` переведён на `_feeTiersByIdx.length`;
- `_setFeeTiersAndRolesInternal(...)` больше не пишет отдельный cached count.

Результат: устранён риск рассинхронизации двух источников истины.

## Dust Threshold Update

Default значение обновлено до **`4_000_000` (`4e6`, USD6)**:
- `src/VolumeDynamicFeeHook.sol` (`DEFAULT_MIN_COUNTED_SWAP_USD6`);
- тесты (`ops/tests/unit`, `ops/tests/integration`);
- документация: `README.md`, `docs/SPEC.md`, `docs/FAQ.md`, `ops/local/RUNBOOK.md`, `ops/sepolia/RUNBOOK.md`;
- оффчейн replay-утилита: `scripts/analyze_threshold_replay_v4.py` (baseline default).

## Testing Scope

### Local / Mock Coverage

Подтверждённые запуски в этом патче:
- `forge build` — **ok**;
- `forge test --offline --match-path 'ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol'` — **15 passed, 0 failed**;
- `forge test --offline --match-path 'ops/tests/unit/VolumeDynamicFeeHook.ConfigAndEdges.t.sol'` — **17 passed, 0 failed**;
- `forge test --offline --match-path 'ops/tests/integration/VolumeDynamicFeeHook.ClaimAccounting.t.sol'` — **4 passed, 0 failed**;
- `forge test --offline --match-path 'ops/tests/fuzz/VolumeDynamicFeeHook.Fuzz.t.sol'` — **2 passed, 0 failed**.

Добавлены/обновлены регрессии:
- Н-04: found tier at non-role index => forced floor reset + counters reset;
- Н-05: floor role after re-tiering => no hold/streak carry-over;
- Н-06: pending threshold activation order on lull reset;
- Н-09: `feeTierCount()` getter and `feeTiers(idx)` bounds;
- default dust threshold == `4e6`.

### Sepolia Validation

В репозитории присутствуют конкретные Sepolia-артефакты:
- `ops/sepolia/out/reports/preflight.sepolia.json`
- `ops/sepolia/out/reports/full.sepolia.json`
- `ops/sepolia/out/state/inspect.sepolia.json`
- `ops/sepolia/out/state/sepolia.addresses.json`
- `ops/sepolia/out/state/sepolia.drivers.json`

Что подтверждается этими артефактами:
- preflight прошёл на chainId `11155111` (`ok: true`, expected=actual);
- зафиксированы конкретные адреса `poolManager`, `hookAddress`, helper drivers;
- в state/report snapshot hook инициализирован, не paused, и наблюдаемая fee-режим/state телеметрия читаются с Sepolia deployment.

Чем это отличается от purely local Mock coverage:
- local/mock тесты проверяют детерминированную логику и инварианты в изолированной среде;
- Sepolia-артефакты подтверждают работу operational pipeline (`preflight/inspect/full`) и корректность on-chain wiring/адресов на публичном testnet.

### Remaining Gaps / Limitations

- В рамках этого патча Sepolia-сценарии не запускались повторно из CI/sandbox; использованы существующие артефакты из репозитория.
- Артефакты в `ops/sepolia/out/*` — snapshot-подтверждение состояния и опер-проверок, но не полный e2e coverage всех edge-cases.
- Полный `ops/tests/invariant/VolumeDynamicFeeHook.Invariant.t.sol` в этой среде не завершён за практичное время; фикс-пункты Н-04/05/06/09 закрыты unit/integration/fuzz регрессиями выше.

## Conclusion

Патч адресует **Н-04, Н-05, Н-06, Н-09** точечно и без расширения бизнес-логики вне согласованного объёма. Default dust threshold синхронизирован на **`4e6`** в коде, тестах и документации, а audit bundle теперь явно разделяет локальное и Sepolia-покрытие с проверяемыми артефактами и честно обозначенными ограничениями.
