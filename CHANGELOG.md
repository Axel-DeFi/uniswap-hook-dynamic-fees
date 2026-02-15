# CHANGELOG

## 2026-02-14

### Updated fee model
- Switched from `score = volumeUSD * fee` to a **volume-regime** model:
  - Maintain `emaVolume` (EMA of period volume).
  - Adjust fee based on deviation of `volumeUSD` from `emaVolume`.
- Enforced **max one step per period** (`maxStep = 1`).

### Updated fee buckets
- New fixed buckets (feeUnits):
  - `[95, 400, 900, 2500, 3000, 6000, 9000]`

### Explicit cap behavior
- Added `capIdx` (immutable) and documented it prominently.
- Default `capIdx` is the index of `3000` (0.30%), but it is configurable at deploy time.

### Inactivity handling
- Added `lullResetSeconds` (immutable). On the first swap after a long lull, the hook resets
  `feeIdx` to `initialFeeIdx` and clears `emaVolume` to re-learn quickly.

### License
- Set license to Apache-2.0.

## 2026-02-15

### Catch-up for missed periods
- Implemented an exact **fast-forward** mechanism when multiple full periods elapse between swaps (within the lull corridor).
- Simulates `k = floor(elapsed / PERIOD_SECONDS)` closes in memory:
  - first close uses the accumulated `volumeUSD`
  - remaining closes use `0` volume
- Correctly simulates `lastDir` (reversal-lock) inside the loop.
- Batches writes: at most **one** `updateDynamicLPFee` call for the final `feeIdx`.

