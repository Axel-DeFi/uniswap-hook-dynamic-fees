// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";

/// @title VolumeDynamicFeeHook
/// @notice Single-pool Uniswap v4 hook that updates LP fees based on USD stable-coin volume.
/// @dev
/// - afterSwap-only updates (no beforeSwap override).
/// - Lazy fee updates: compute at period boundary when a swap arrives.
/// - One hook instance = one pool (no mapping keyed by PoolId).
/// - Persistent state fits into one 32-byte storage slot (bit packed).
///
/// Volume proxy:
/// - Measure only the stable token leg ("USD") and assume it is always worth $1.
/// - Convert to USD 1e6 (USD6) and multiply by 2 to approximate total notional.
///   (For an ETH/USD pool, the stable amount corresponds to the same USD value of the ETH leg.)
///
/// IMPORTANT:
/// - The pool must be created with LPFeeLibrary.DYNAMIC_FEE_FLAG in PoolKey.fee.
/// - This hook must be deployed via CREATE2 to an address with the required permission flags.
contract VolumeDynamicFeeHook is BaseHook {
    using BalanceDeltaLibrary for BalanceDelta;

    // -----------------------------------------------------------------------
    // Fee tiers (hundredths of a bip). Example: 3000 = 0.30%
    // -----------------------------------------------------------------------
    uint24[7] public constant FEE_TIERS = [uint24(95), 400, 900, 2500, 3000, 6000, 9000];
    uint8 public constant FEE_TIER_COUNT = 7;

    // -----------------------------------------------------------------------
    // Immutable configuration (no admin setters)
    // -----------------------------------------------------------------------
    Currency public immutable poolCurrency0;
    Currency public immutable poolCurrency1;
    int24 public immutable poolTickSpacing;
    Currency public immutable stableCurrency;

    bool internal immutable _stableIsCurrency0;

    // Scale stable token amount to USD6 (1e6)
    // If stableDecimals < 6: multiply by stableScale
    // If stableDecimals > 6: divide by stableScale
    bool internal immutable _scaleIsMul;
    uint64 internal immutable _stableScale;

    uint8 public immutable initialFeeIdx;
    uint8 public immutable floorIdx;
    uint8 public immutable capIdx;

    uint32 public immutable periodSeconds;
    uint8 public immutable emaPeriods; // EMA smoothing period count
    uint16 public immutable deadbandBps; // +/- bps around EMA to avoid micro-churn
    uint32 public immutable lullResetSeconds; // reset after prolonged inactivity

    // Guardian can pause/unpause the algorithm. No one can set arbitrary fees.
    address public immutable guardian;
    uint8 public immutable pauseFeeIdx;

    // -----------------------------------------------------------------------
    // Packed persistent state (ONE storage slot)
    // -----------------------------------------------------------------------
    //
    // Layout:
    // [  0.. 63] uint64  periodVolumeUsd6
    // [ 64..159] uint96  emaVolumeUsd6
    // [160..191] uint32  periodStart (unix seconds)
    // [192..199] uint8   feeIdx
    // [200..201] uint2   lastDir (0 none, 1 up, 2 down)
    // [202]      bool   paused
    // [203]      bool   pauseApplyPending
    // [204..255] unused
    //
    uint256 private _state;

    uint8 private constant DIR_NONE = 0;
    uint8 private constant DIR_UP = 1;
    uint8 private constant DIR_DOWN = 2;
    uint16 private constant MAX_LULL_PERIODS = 24;
    uint256 private constant PAUSED_BIT = 202;
    uint256 private constant PAUSE_APPLY_PENDING_BIT = 203;

    function isPaused() public view returns (bool) {
        return ((_state >> PAUSED_BIT) & 1) == 1;
    }

    function _setPaused(bool v) private {
        if (v) {
            _state |= (uint256(1) << PAUSED_BIT);
        } else {
            _state &= ~(uint256(1) << PAUSED_BIT);
        }

    }
    function isPauseApplyPending() public view returns (bool) {
        return ((_state >> PAUSE_APPLY_PENDING_BIT) & 1) == 1;
    }

    function _setPauseApplyPending(bool v) private {
        if (v) {
            _state |= (uint256(1) << PAUSE_APPLY_PENDING_BIT);
        } else {
            _state &= ~(uint256(1) << PAUSE_APPLY_PENDING_BIT);
        }
    }


    // -----------------------------------------------------------------------
    // Events (emitted only on fee changes / resets to reduce overhead)
    // -----------------------------------------------------------------------
    event FeeUpdated(uint24 newFee, uint8 newFeeIdx, uint64 closedVolumeUsd6, uint96 emaVolumeUsd6);
    event Paused(uint24 pauseFee, uint8 pauseFeeIdx);
    event Unpaused();
    event LullReset(uint24 newFee, uint8 newFeeIdx);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error InvalidPoolKey();
    error NotDynamicFeePool();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidFeeIndex();
    error InvalidConfig();
    error NotGuardian();

    constructor(
        IPoolManager _poolManager,
        // Pool binding
        Currency _poolCurrency0,
        Currency _poolCurrency1,
        int24 _poolTickSpacing,
        // Stable (USD proxy)
        Currency _stableCurrency,
        uint8 stableDecimals,
        // Fee regime
        uint8 _initialFeeIdx,
        uint8 _floorIdx,
        uint8 _capIdx,
        // Timing + smoothing
        uint32 _periodSeconds,
        uint8 _emaPeriods,
        uint16 _deadbandBps,
        uint32 _lullResetSeconds,
        address _guardian,
        uint8 _pauseFeeIdx
    ) BaseHook(_poolManager) {
        // Hook permission flags: afterInitialize + afterSwap only.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());

        if (Currency.unwrap(_poolCurrency0) >= Currency.unwrap(_poolCurrency1)) revert InvalidConfig();
        poolCurrency0 = _poolCurrency0;
        poolCurrency1 = _poolCurrency1;
        poolTickSpacing = _poolTickSpacing;

        if (_stableCurrency != _poolCurrency0 && _stableCurrency != _poolCurrency1) revert InvalidConfig();
        stableCurrency = _stableCurrency;
        _stableIsCurrency0 = (_stableCurrency == _poolCurrency0);

        if (_periodSeconds == 0) revert InvalidConfig();
        periodSeconds = _periodSeconds;

        if (_emaPeriods < 2) revert InvalidConfig(); // need at least 2 for meaningful smoothing
        emaPeriods = _emaPeriods;

        if (_deadbandBps > 5000) revert InvalidConfig(); // sanity: +/-50%
        deadbandBps = _deadbandBps;

        if (_lullResetSeconds < _periodSeconds) revert InvalidConfig(); // lull must be >= 1 period
        // Gas safety: we cap lullResetSeconds to avoid large catch-up loops on the next swap.
        // With the default PERIOD_SECONDS=300, MAX_LULL_PERIODS=24 allows up to ~2 hours of inactivity before a lull reset.
        if (_lullResetSeconds > uint32(uint256(_periodSeconds) * MAX_LULL_PERIODS)) revert InvalidConfig();
        lullResetSeconds = _lullResetSeconds;

        if (_guardian == address(0)) revert InvalidConfig();
        guardian = _guardian;
        if (_pauseFeeIdx >= FEE_TIER_COUNT) revert InvalidFeeIndex();
        pauseFeeIdx = _pauseFeeIdx;

        if (_floorIdx >= FEE_TIER_COUNT || _capIdx >= FEE_TIER_COUNT || _initialFeeIdx >= FEE_TIER_COUNT) {
            revert InvalidFeeIndex();
        }
        if (!(_floorIdx <= _initialFeeIdx && _initialFeeIdx <= _capIdx)) revert InvalidConfig();
        // pauseFeeIdx must be within the configured [floorIdx, capIdx] band.
        if (!(_floorIdx <= _pauseFeeIdx && _pauseFeeIdx <= _capIdx)) revert InvalidConfig();

        floorIdx = _floorIdx;
        capIdx = _capIdx;
        initialFeeIdx = _initialFeeIdx;

        if (stableDecimals > 18) revert InvalidConfig();

        // Precompute USD6 scaling from stable token decimals.
        // Common case: stableDecimals == 6 => scale=1, _scaleIsMul=true
        if (stableDecimals == 6) {
            _scaleIsMul = true;
            _stableScale = 1;
        } else if (stableDecimals < 6) {
            _scaleIsMul = true;
            _stableScale = uint64(10 ** (6 - stableDecimals));
        } else {
            _scaleIsMul = false;
            _stableScale = uint64(10 ** (stableDecimals - 6));
        }
    }

    // -----------------------------------------------------------------------
    // Hook permissions
    // -----------------------------------------------------------------------
    function getHookPermissions() public pure override returns (Hooks.Permissions memory perms) {
        perms.afterInitialize = true;
        perms.afterSwap = true;
    }

    // -----------------------------------------------------------------------
    // Callbacks
    // -----------------------------------------------------------------------

    /// @notice Initialize per-pool state and set an initial dynamic fee.
    /// @dev Called by PoolManager after pool initialization.
    
    function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        _validateKey(key);

        bool paused_ = isPaused();

        (uint64 _pv0, uint96 _ema0, uint32 periodStart, uint8 _fee0, uint8 _dir0, bool _paused0, bool _pending0) =
            _unpackState(_state);
        if (periodStart != 0) revert AlreadyInitialized();

        uint32 nowTs = _now32();

        // Initialize state even if paused (pause can be activated before pool init).
        uint8 feeIdx = paused_ ? pauseFeeIdx : initialFeeIdx;

        // Initialize packed state. If pause/unpause was requested before init, clear the pending flag here.
        _state = _packState(0, 0, nowTs, feeIdx, DIR_NONE, paused_, false);

        // Dynamic fee pools start with fee=0; set the initial (or paused) fee here.
        poolManager.updateDynamicLPFee(key, FEE_TIERS[feeIdx]);
        emit FeeUpdated(FEE_TIERS[feeIdx], feeIdx, 0, 0);

        return IHooks.afterInitialize.selector;
    }


    /// @notice Accumulate period volume and update fee lazily at period boundaries.
    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        _validateKey(key);

        
        if (isPaused()) {
            // Apply pause fee exactly once (PoolManager is unlocked in callbacks).
            if (isPauseApplyPending()) {
                poolManager.updateDynamicLPFee(key, FEE_TIERS[pauseFeeIdx]);
                _setPauseApplyPending(false);
                emit FeeUpdated(FEE_TIERS[pauseFeeIdx], pauseFeeIdx, 0, 0);
            }
            return (IHooks.afterSwap.selector, 0);
        }


        (uint64 periodVol, uint96 emaVol, uint32 periodStart, uint8 feeIdx, uint8 lastDir, bool _paused1, bool pauseApplyPending) =
            _unpackState(_state);


        // If unpause requested an initial fee application, do it once at the next callback.
        if (pauseApplyPending) {
            poolManager.updateDynamicLPFee(key, FEE_TIERS[feeIdx]);
            emit FeeUpdated(FEE_TIERS[feeIdx], feeIdx, 0, emaVol);
            pauseApplyPending = false;
        }

        if (periodStart == 0) revert NotInitialized();

        uint32 nowTs = _now32();
        uint32 elapsed = nowTs - periodStart;

        // Lull reset: if no swaps for a long time, snap back to initial fee and clear EMA/volume.
        
        // Lull reset: if no swaps for a long time, snap back to the initial fee and clear EMA/volume.
        if (elapsed >= lullResetSeconds) {
            uint8 oldFeeIdx = feeIdx;

            // Reset model and start a fresh period at nowTs.
            emaVol = 0;
            lastDir = DIR_NONE;
            feeIdx = initialFeeIdx;
            periodStart = nowTs;

            // Count this swap into the new period (windowing).
            periodVol = _addSwapVolumeUsd6(0, delta);

            _state = _packState(periodVol, emaVol, periodStart, feeIdx, lastDir, false, pauseApplyPending);

            // Apply fee only if it actually changes.
            if (feeIdx != oldFeeIdx) {
                poolManager.updateDynamicLPFee(key, FEE_TIERS[feeIdx]);
                emit FeeUpdated(FEE_TIERS[feeIdx], feeIdx, 0, 0);
            }

            emit LullReset(FEE_TIERS[feeIdx], feeIdx);

            return (IHooks.afterSwap.selector, 0);
        }


        // Close and roll the period if elapsed.
        if (elapsed >= periodSeconds) {
            // Catch-up for missed periods:
            // If multiple full periods elapsed since the last swap, we simulate each close in memory:
            // - period 0 closes with the accumulated periodVol
            // - subsequent missed periods close with 0 volume
            //
            // This keeps emaVol and feeIdx consistent even when swaps are sparse.
            // NOTE: periods is implicitly bounded because:
            // - this branch runs only when elapsed < lullResetSeconds
            // - lullResetSeconds is capped in the constructor (MAX_LULL_PERIODS)
            // - we batch the PoolManager update: at most one updateDynamicLPFee call for the final fee.
            uint32 periods = elapsed / periodSeconds; // >= 1
            uint64 closeVol0 = periodVol;

            uint8 oldFeeIdx = feeIdx;

            uint96 ema = emaVol;
            uint8 f = feeIdx;
            uint8 d = lastDir;

            for (uint32 i = 0; i < periods; i++) {
                uint64 v = (i == 0) ? closeVol0 : uint64(0);

                ema = _updateEma(ema, v);

                (uint8 nf, uint8 nd, bool changed) = _computeNextFeeIdx(f, d, v, ema);
                if (changed) {
                    f = nf;
                    d = nd;
                } else {
                    d = DIR_NONE;
                }
            }

            emaVol = ema;
            feeIdx = f;
            lastDir = d;

            if (feeIdx != oldFeeIdx) {
                poolManager.updateDynamicLPFee(key, FEE_TIERS[feeIdx]);
                emit FeeUpdated(FEE_TIERS[feeIdx], feeIdx, closeVol0, emaVol);
            }

            // Start a new period and count this swap into it (windowing).
            periodStart = nowTs;
            periodVol = 0;
        }


// Accumulate this swap's USD proxy volume into the current period.
        periodVol = _addSwapVolumeUsd6(periodVol, delta);

        _state = _packState(periodVol, emaVol, periodStart, feeIdx, lastDir, false, pauseApplyPending);
        return (IHooks.afterSwap.selector, 0);
    }

    // -----------------------------------------------------------------------
    // Views (debug/observability)
    // -----------------------------------------------------------------------

    function currentFeeBips() external view returns (uint24) {
        (uint64 _pv2, uint96 _ema2, uint32 periodStart, uint8 feeIdx, uint8 _dir2, bool _paused2, bool _pending2) = _unpackState(_state);
        if (periodStart == 0) revert NotInitialized();
        return FEE_TIERS[feeIdx];
    }

    
    // -----------------------------------------------------------------------
    // Guardian controls (no arbitrary fee setting)
    // -----------------------------------------------------------------------
    
    function pause() external {
        if (msg.sender != guardian) revert NotGuardian();
        if (isPaused()) return;

        bool alreadyInitialized;
        {
            (uint64 _pv3, uint96 _ema3, uint32 periodStart, uint8 _fee3, uint8 _dir3, bool _paused3, bool _pending3) = _unpackState(_state);
            alreadyInitialized = (periodStart != 0);
        }

        // Reset model state to avoid "sticky highs" and freeze updates.
        (uint64 periodVol, uint96 emaVol, uint32 periodStart, uint8 feeIdx, uint8 lastDir, bool _paused4, bool _pending4) = _unpackState(_state);
        periodVol = 0;
        emaVol = 0;
        // Do not block afterInitialize: keep periodStart=0 if the pool is not initialized yet.
        periodStart = alreadyInitialized ? _now32() : uint32(0);
        feeIdx = pauseFeeIdx;
        lastDir = DIR_NONE;

        _state = _packState(periodVol, emaVol, periodStart, feeIdx, lastDir, true, true);

        // PoolManager dynamic fee can only be updated safely during hook callbacks (PoolManager is unlocked there).
        // pauseApplyPending is stored in state; the next callback applies pauseFeeIdx.
        emit Paused(FEE_TIERS[pauseFeeIdx], pauseFeeIdx);
    }


    
    function unpause() external {
        if (msg.sender != guardian) revert NotGuardian();
        if (!isPaused()) return;

        bool alreadyInitialized;
        {
            (uint64 _pv3, uint96 _ema3, uint32 periodStart, uint8 _fee3, uint8 _dir3, bool _paused3, bool _pending3) = _unpackState(_state);
            alreadyInitialized = (periodStart != 0);
        }

        // Resume: reset the model and revert to the initial fee tier.
        (uint64 periodVol, uint96 emaVol, uint32 periodStart, uint8 feeIdx, uint8 lastDir, bool _paused4, bool _pending4) = _unpackState(_state);
        periodVol = 0;
        emaVol = 0;
        periodStart = alreadyInitialized ? _now32() : uint32(0);
        feeIdx = initialFeeIdx;
        lastDir = DIR_NONE;

        _state = _packState(periodVol, emaVol, periodStart, feeIdx, lastDir, false, true);
        // pauseApplyPending is stored in state; the next callback applies the initial fee.
        emit Unpaused();
    }


function unpackedState()
        external
        view
        returns (uint64 periodVolumeUsd6, uint96 emaVolumeUsd6, uint32 periodStart, uint8 feeIdx, uint8 lastDir)
    {
        (uint64 periodVolumeUsd6, uint96 emaVolumeUsd6, uint32 periodStart, uint8 feeIdx, uint8 lastDir, bool _paused5, bool _pending5) =
            _unpackState(_state);
        return (periodVolumeUsd6, emaVolumeUsd6, periodStart, feeIdx, lastDir);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _validateKey(PoolKey calldata key) internal view {
        if (key.currency0 != poolCurrency0 || key.currency1 != poolCurrency1 || key.tickSpacing != poolTickSpacing) {
            revert InvalidPoolKey();
        }
        // The pool must be configured for dynamic fees.
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert NotDynamicFeePool();
        // Ensure this hook is the pool's hook.
        if (address(key.hooks) != address(this)) revert InvalidPoolKey();
    }

    function _now32() internal view returns (uint32) {
        return uint32(block.timestamp);
    }

    function _addSwapVolumeUsd6(uint64 current, BalanceDelta delta) internal view returns (uint64) {
        int128 s = _stableIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 absStable = s < 0 ? uint256(-int256(s)) : uint256(uint128(s));

        // Convert stable amount to USD6, then multiply by 2 to approximate total notional.
        uint256 usd6 = _toUsd6(absStable);
        uint256 add = usd6 << 1;

        // Saturating add into uint64.
        uint256 sum = uint256(current) + add;
        if (sum > type(uint64).max) return type(uint64).max;
        return uint64(sum);
    }

    function _toUsd6(uint256 stableAmount) internal view returns (uint256) {
        if (_stableScale == 1) return stableAmount;
        if (_scaleIsMul) return stableAmount * _stableScale;
        return stableAmount / _stableScale;
    }

    function _updateEma(uint96 ema, uint64 closeVol) internal view returns (uint96) {
        if (ema == 0) {
            // Initialize EMA on the first close (including 0 if no volume ever happens).
            if (closeVol == 0) return 0;
            return uint96(closeVol);
        }

        uint256 n = uint256(emaPeriods);
        uint256 updated = (uint256(ema) * (n - 1) + uint256(closeVol)) / n;
        if (updated > type(uint96).max) return type(uint96).max;
        return uint96(updated);
    }

    function _computeNextFeeIdx(uint8 feeIdx, uint8 lastDir, uint64 closeVol, uint96 emaVol)
        internal
        view
        returns (uint8 newFeeIdx, uint8 newLastDir, bool changed)
    {
        newFeeIdx = feeIdx;
        newLastDir = lastDir;

        // If EMA isn't initialized yet (emaVol == 0), we don't move.
        if (emaVol == 0) {
            return (newFeeIdx, DIR_NONE, false);
        }

        // Deadband: ignore changes within +/- deadbandBps around EMA.
        // lower = ema * (10000 - db) / 10000
        // upper = ema * (10000 + db) / 10000
        uint256 emaU = uint256(emaVol);
        uint256 lower = (emaU * (10000 - uint256(deadbandBps))) / 10000;
        uint256 upper = (emaU * (10000 + uint256(deadbandBps))) / 10000;

        uint8 dir;
        if (uint256(closeVol) > upper) dir = DIR_UP;
        else if (uint256(closeVol) < lower) dir = DIR_DOWN;
        else dir = DIR_NONE;

        // Reversal lock: if direction flips, require one full period of confirmation.
        if (dir != DIR_NONE && newLastDir != DIR_NONE && dir != newLastDir) {
            return (newFeeIdx, DIR_NONE, false);
        }

        // At most one step per period.
        if (dir == DIR_UP) {
            if (newFeeIdx < capIdx) {
                newFeeIdx = newFeeIdx + 1;
                changed = true;
            }
            newLastDir = DIR_UP;
        } else if (dir == DIR_DOWN) {
            if (newFeeIdx > floorIdx) {
                newFeeIdx = newFeeIdx - 1;
                changed = true;
            }
            newLastDir = DIR_DOWN;
        } else {
            newLastDir = DIR_NONE;
        }
    }

    // -----------------------------------------------------------------------
    // Bit packing
    // -----------------------------------------------------------------------

    function _packState(
        uint64 periodVol,
        uint96 emaVol,
        uint32 periodStart,
        uint8 feeIdx,
        uint8 lastDir,
        bool paused,
        bool pauseApplyPending
    )
        internal
        pure
        returns (uint256 packed)
    {
        packed = uint256(periodVol);
        packed |= uint256(emaVol) << 64;
        packed |= uint256(periodStart) << 160;
        packed |= uint256(feeIdx) << 192;
        packed |= (uint256(lastDir) & 0x3) << 200;

        if (paused) packed |= uint256(1) << PAUSED_BIT;
        if (pauseApplyPending) packed |= uint256(1) << PAUSE_APPLY_PENDING_BIT;
    }

    function _unpackState(uint256 packed)
        internal
        pure
        returns (
            uint64 periodVol,
            uint96 emaVol,
            uint32 periodStart,
            uint8 feeIdx,
            uint8 lastDir,
            bool paused,
            bool pauseApplyPending
        )
    {
        periodVol = uint64(packed);
        emaVol = uint96(packed >> 64);
        periodStart = uint32(packed >> 160);
        feeIdx = uint8(packed >> 192);
        lastDir = uint8((packed >> 200) & 0x3);

        paused = ((packed >> PAUSED_BIT) & 1) == 1;
        pauseApplyPending = ((packed >> PAUSE_APPLY_PENDING_BIT) & 1) == 1;
    }
}