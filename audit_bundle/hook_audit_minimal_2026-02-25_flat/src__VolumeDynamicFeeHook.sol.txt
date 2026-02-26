// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @title VolumeDynamicFeeHook
/// @notice Single-pool Uniswap v4 hook that updates dynamic LP fees using stable-coin volume heuristics.
contract VolumeDynamicFeeHook is BaseHook {
    using BalanceDeltaLibrary for BalanceDelta;

    // -----------------------------------------------------------------------
    // Fee tiers (hundredths of a bip). Example: 3000 = 0.30%
    // -----------------------------------------------------------------------
    uint8 public constant FEE_TIER_COUNT = 7;

    error InvalidFeeIndex();

    /// @notice Packed fee tiers by index (hundredths of a bip).
    /// @dev Each fee is stored in 24 bits within PACKED_FEE_TIERS (little-endian by index).
    uint256 private constant PACKED_FEE_TIERS = uint256(95) | (uint256(400) << 24) | (uint256(900) << 48)
        | (uint256(2500) << 72) | (uint256(3000) << 96) | (uint256(6000) << 120) | (uint256(9000) << 144);

    function feeTiers(uint256 idx) public pure returns (uint24) {
        if (idx >= FEE_TIER_COUNT) revert InvalidFeeIndex();
        // Extract 24-bit lane.
        return uint24((PACKED_FEE_TIERS >> (idx * 24)) & 0xFFFFFF);
    }

    function _feeTier(uint8 idx) internal pure returns (uint24) {
        return feeTiers(uint256(idx));
    }

    // -----------------------------------------------------------------------
    // Immutable configuration
    // -----------------------------------------------------------------------
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    Currency public immutable poolCurrency0;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    Currency public immutable poolCurrency1;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    int24 public immutable poolTickSpacing;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    Currency public immutable stableCurrency;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    bool internal immutable _stableIsCurrency0;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    bool internal immutable _scaleIsMul;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint64 internal immutable _stableScale;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable initialFeeIdx;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable floorIdx;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable capIdx;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint32 public immutable periodSeconds;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable emaPeriods;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint16 public immutable deadbandBps;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint32 public immutable lullResetSeconds;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable guardian;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable pauseFeeIdx;

    // -----------------------------------------------------------------------
    // Packed state (ONE storage slot)
    // -----------------------------------------------------------------------
    uint256 private _state;

    uint8 private constant DIR_NONE = 0;
    uint8 private constant DIR_UP = 1;
    uint8 private constant DIR_DOWN = 2;

    uint16 private constant MAX_LULL_PERIODS = 24;
    uint8 private constant MAX_EMA_PERIODS = 64;
    // closeVol is tracked as 2 * abs(stableAmount) in USD6.
    // 2_000_000 equals $1 of period-close volume in current units.
    uint64 private constant DUST_CLOSE_VOL_USD6 = 2_000_000;

    uint256 private constant PAUSED_BIT = 202;

    // -----------------------------------------------------------------------
    // Events
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
    error InvalidConfig();
    error NotGuardian();

    constructor(
        IPoolManager _poolManager,
        Currency _poolCurrency0,
        Currency _poolCurrency1,
        int24 _poolTickSpacing,
        Currency _stableCurrency,
        uint8 stableDecimals,
        uint8 _initialFeeIdx,
        uint8 _floorIdx,
        uint8 _capIdx,
        uint32 _periodSeconds,
        uint8 _emaPeriods,
        uint16 _deadbandBps,
        uint32 _lullResetSeconds,
        address _guardian,
        uint8 _pauseFeeIdx
    ) BaseHook(_poolManager) {
        if (address(_poolManager) == address(0)) revert InvalidConfig();

        // enforce canonical ordering for determinism
        if (Currency.unwrap(_poolCurrency0) >= Currency.unwrap(_poolCurrency1)) revert InvalidConfig();

        poolCurrency0 = _poolCurrency0;
        poolCurrency1 = _poolCurrency1;
        poolTickSpacing = _poolTickSpacing;

        // Currency overloads `==` (not `!=`)
        if (!(_stableCurrency == _poolCurrency0) && !(_stableCurrency == _poolCurrency1)) {
            revert InvalidConfig();
        }
        stableCurrency = _stableCurrency;
        _stableIsCurrency0 = (_stableCurrency == _poolCurrency0);

        if (_periodSeconds == 0) revert InvalidConfig();
        periodSeconds = _periodSeconds;

        if (_emaPeriods < 2) revert InvalidConfig();
        if (_emaPeriods > MAX_EMA_PERIODS) revert InvalidConfig();
        emaPeriods = _emaPeriods;

        if (_deadbandBps > 5000) revert InvalidConfig();
        deadbandBps = _deadbandBps;

        if (_lullResetSeconds < _periodSeconds) revert InvalidConfig();
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
        if (!(_floorIdx <= _pauseFeeIdx && _pauseFeeIdx <= _capIdx)) revert InvalidConfig();

        floorIdx = _floorIdx;
        capIdx = _capIdx;
        initialFeeIdx = _initialFeeIdx;

        if (stableDecimals > 18) revert InvalidConfig();

        // Scale stableAmount (stableDecimals) to USD6.
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
    // Hook implementations (override INTERNAL hook functions)
    // -----------------------------------------------------------------------

    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        _validateKey(key);

        (,, uint32 periodStart,,,) = _unpackState(_state);
        if (periodStart != 0) revert AlreadyInitialized();

        bool paused_ = isPaused();
        uint32 nowTs = _now32();

        uint8 feeIdx = paused_ ? pauseFeeIdx : initialFeeIdx;

        _state = _packState(0, 0, nowTs, feeIdx, DIR_NONE, paused_);

        poolManager.updateDynamicLPFee(key, _feeTier(feeIdx));
        emit FeeUpdated(_feeTier(feeIdx), feeIdx, 0, 0);

        return IHooks.afterInitialize.selector;
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        _validateKey(key);

        if (isPaused()) {
            // Fee is applied immediately in pause()/unpause(); swaps while paused do not update state.
            return (IHooks.afterSwap.selector, 0);
        }

        (uint64 periodVol, uint96 emaVol, uint32 periodStart, uint8 feeIdx, uint8 lastDir, bool paused_) =
            _unpackState(_state);

        if (periodStart == 0) revert NotInitialized();

        uint32 nowTs = _now32();
        uint32 elapsed = nowTs - periodStart;

        if (elapsed >= lullResetSeconds) {
            uint8 oldFeeIdx = feeIdx;

            emaVol = 0;
            lastDir = DIR_NONE;
            feeIdx = initialFeeIdx;
            periodStart = nowTs;

            periodVol = _addSwapVolumeUsd6(0, delta);

            _state = _packState(periodVol, emaVol, periodStart, feeIdx, lastDir, paused_);

            if (feeIdx != oldFeeIdx) {
                poolManager.updateDynamicLPFee(key, _feeTier(feeIdx));
                emit FeeUpdated(_feeTier(feeIdx), feeIdx, 0, 0);
            }

            emit LullReset(_feeTier(feeIdx), feeIdx);
            return (IHooks.afterSwap.selector, 0);
        }

        if (elapsed >= periodSeconds) {
            uint32 periods = elapsed / periodSeconds;
            uint64 closeVol0 = periodVol;

            uint8 oldFeeIdx = feeIdx;

            uint96 ema = emaVol;
            uint8 f = feeIdx;
            uint8 d = lastDir;

            for (uint32 i = 0; i < periods; i++) {
                uint64 vRaw = (i == 0) ? closeVol0 : uint64(0);
                uint64 vEff = vRaw <= DUST_CLOSE_VOL_USD6 ? uint64(0) : vRaw;

                ema = _updateEma(ema, vEff);

                (uint8 nf, uint8 nd, bool changed) = _computeNextFeeIdx(f, d, vEff, ema);
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
                poolManager.updateDynamicLPFee(key, _feeTier(feeIdx));
                emit FeeUpdated(_feeTier(feeIdx), feeIdx, closeVol0, emaVol);
            }

            periodStart = nowTs;
            periodVol = 0;
        }

        periodVol = _addSwapVolumeUsd6(periodVol, delta);

        _state = _packState(periodVol, emaVol, periodStart, feeIdx, lastDir, paused_);
        return (IHooks.afterSwap.selector, 0);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function isPaused() public view returns (bool) {
        return ((_state >> PAUSED_BIT) & 1) == 1;
    }

    function currentFeeBips() external view returns (uint24) {
        (,, uint32 periodStart, uint8 feeIdx,,) = _unpackState(_state);
        if (periodStart == 0) revert NotInitialized();
        return _feeTier(feeIdx);
    }

    function unpackedState()
        external
        view
        returns (
            uint64 periodVolumeUsd6,
            uint96 emaVolumeUsd6,
            uint32 periodStart,
            uint8 feeIdx,
            uint8 lastDir
        )
    {
        (uint64 pv, uint96 ev, uint32 ps, uint8 fi, uint8 ld,) = _unpackState(_state);
        return (pv, ev, ps, fi, ld);
    }

    // -----------------------------------------------------------------------
    // Guardian controls
    // -----------------------------------------------------------------------

    function pause() external {
        if (msg.sender != guardian) revert NotGuardian();
        if (isPaused()) return;

        (uint64 periodVol, uint96 emaVol, uint32 periodStart, uint8 feeIdx, uint8 lastDir, bool paused_) =
            _unpackState(_state);
        bool initialized = periodStart != 0;

        // Reset state and force a conservative fee bucket.
        periodVol = 0;
        emaVol = 0;
        periodStart = initialized ? _now32() : uint32(0);
        feeIdx = pauseFeeIdx;
        lastDir = DIR_NONE;
        paused_ = true;

        _state = _packState(periodVol, emaVol, periodStart, feeIdx, lastDir, paused_);

        // Apply pause fee immediately for initialized pools.
        if (initialized) {
            poolManager.updateDynamicLPFee(_poolKey(), _feeTier(feeIdx));
            emit FeeUpdated(_feeTier(feeIdx), feeIdx, 0, 0);
        }

        emit Paused(_feeTier(pauseFeeIdx), pauseFeeIdx);
    }

    function unpause() external {
        if (msg.sender != guardian) revert NotGuardian();
        if (!isPaused()) return;

        (uint64 periodVol, uint96 emaVol, uint32 periodStart, uint8 feeIdx, uint8 lastDir, bool paused_) =
            _unpackState(_state);
        bool initialized = periodStart != 0;

        // Reset state and return to the initial fee bucket.
        periodVol = 0;
        emaVol = 0;
        periodStart = initialized ? _now32() : uint32(0);
        feeIdx = initialFeeIdx;
        lastDir = DIR_NONE;
        paused_ = false;

        _state = _packState(periodVol, emaVol, periodStart, feeIdx, lastDir, paused_);

        // Apply unpause fee immediately for initialized pools.
        if (initialized) {
            poolManager.updateDynamicLPFee(_poolKey(), _feeTier(feeIdx));
            emit FeeUpdated(_feeTier(feeIdx), feeIdx, 0, 0);
        }

        emit Unpaused();
    }

    function _poolKey() internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: poolCurrency0,
            currency1: poolCurrency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(address(this))
        });
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _validateKey(PoolKey calldata key) internal view {
        if (
            !(key.currency0 == poolCurrency0) || !(key.currency1 == poolCurrency1)
                || key.tickSpacing != poolTickSpacing
        ) {
            revert InvalidPoolKey();
        }
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert NotDynamicFeePool();
        if (address(key.hooks) != address(this)) revert InvalidPoolKey();
    }

    function _now32() internal view returns (uint32) {
        return uint32(block.timestamp);
    }

    function _addSwapVolumeUsd6(uint64 current, BalanceDelta delta) internal view returns (uint64) {
        int128 s = _stableIsCurrency0 ? delta.amount0() : delta.amount1();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 absStable = s < 0 ? uint256(-int256(s)) : uint256(uint128(s));

        uint256 usd6 = _toUsd6(absStable);

        // treat swap volume as 2 * stable-side abs delta (in + out)
        uint256 add = usd6 << 1;

        uint256 sum = uint256(current) + add;
        if (sum > type(uint64).max) return type(uint64).max;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(sum);
    }

    function _toUsd6(uint256 stableAmount) internal view returns (uint256) {
        if (_stableScale == 1) return stableAmount;
        if (_scaleIsMul) return stableAmount * _stableScale;
        return stableAmount / _stableScale;
    }

    function _updateEma(uint96 ema, uint64 closeVol) internal view returns (uint96) {
        if (ema == 0) {
            if (closeVol == 0) return 0;
            return uint96(closeVol);
        }

        uint256 n = uint256(emaPeriods);
        uint256 updated = (uint256(ema) * (n - 1) + uint256(closeVol)) / n;
        if (updated > type(uint96).max) return type(uint96).max;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(updated);
    }

    function _computeNextFeeIdx(uint8 feeIdx, uint8 lastDir, uint64 closeVol, uint96 emaVol)
        internal
        view
        returns (uint8 newFeeIdx, uint8 newLastDir, bool changed)
    {
        newFeeIdx = feeIdx;
        newLastDir = lastDir;

        if (emaVol == 0) {
            // Prevent fee stalling above floor in prolonged near-zero activity.
            if (closeVol == 0 && newFeeIdx > floorIdx) {
                return (newFeeIdx - 1, DIR_NONE, true);
            }
            return (newFeeIdx, DIR_NONE, false);
        }

        uint256 emaU = uint256(emaVol);
        uint256 lower = (emaU * (10000 - uint256(deadbandBps))) / 10000;
        uint256 upper = (emaU * (10000 + uint256(deadbandBps))) / 10000;

        uint8 dir;
        if (uint256(closeVol) > upper) dir = DIR_UP;
        else if (uint256(closeVol) < lower) dir = DIR_DOWN;
        else dir = DIR_NONE;

        // reversal lock: avoid immediate flip-flops across deadband
        if (dir != DIR_NONE && newLastDir != DIR_NONE && dir != newLastDir) {
            return (newFeeIdx, DIR_NONE, false);
        }

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
        bool paused
    ) internal pure returns (uint256 packed) {
        packed = uint256(periodVol);
        packed |= uint256(emaVol) << 64;
        packed |= uint256(periodStart) << 160;
        packed |= uint256(feeIdx) << 192;
        packed |= (uint256(lastDir) & 0x3) << 200;

        if (paused) packed |= uint256(1) << PAUSED_BIT;
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
            bool paused
        )
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        periodVol = uint64(packed);
        // forge-lint: disable-next-line(unsafe-typecast)
        emaVol = uint96(packed >> 64);
        // forge-lint: disable-next-line(unsafe-typecast)
        periodStart = uint32(packed >> 160);
        // forge-lint: disable-next-line(unsafe-typecast)
        feeIdx = uint8(packed >> 192);
        lastDir = uint8((packed >> 200) & 0x3);

        paused = ((packed >> PAUSED_BIT) & 1) == 1;
    }
}
