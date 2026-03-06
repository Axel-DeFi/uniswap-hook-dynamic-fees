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

/**
 * @dev VolumeDynamicFeeHook
 *      Adaptive LP-fee hook for a single Uniswap v4 pool.
 *      It tracks stable-side swap volume (USD6), updates an EMA on period close,
 *      and shifts fee tiers by regime with deadband/reversal safeguards.
 *
 *      Repository: https://github.com/Axel-DeFi/uniswap-hook-dynamic-fees
 *      (includes source code, documentation, and audit materials)
 */
/// @title VolumeDynamicFeeHook
/// @notice Single-pool Uniswap v4 hook that updates dynamic LP fees using stable-coin volume heuristics.
contract VolumeDynamicFeeHook is BaseHook {
    using BalanceDeltaLibrary for BalanceDelta;

    // -----------------------------------------------------------------------
    // Fee tiers (hundredths of a bip). Example: 3000 = 0.30%
    // -----------------------------------------------------------------------
    uint256 private constant MAX_FEE_TIER_COUNT = 16;

    struct ControllerConfig {
        uint64 minCloseVolToCashUsd6;
        uint64 minCloseVolToExtremeUsd6;
        uint64 emergencyFloorCloseVolUsd6;
        uint32 periodSeconds;
        uint32 lullResetSeconds;
        uint16 upRToCashBps;
        uint16 upRToExtremeBps;
        uint16 downRFromExtremeBps;
        uint16 downRFromCashBps;
        uint16 deadbandBps;
        uint16 creatorFeeBps;
        uint8 emaPeriods;
        uint8 cashHoldPeriods;
        uint8 upExtremeConfirmPeriods;
        uint8 extremeHoldPeriods;
        uint8 downExtremeConfirmPeriods;
        uint8 downCashConfirmPeriods;
        uint8 emergencyConfirmPeriods;
        uint8 floorIdx;
        uint8 cashIdx;
        uint8 extremeIdx;
        uint8 capIdx;
    }

    struct ControllerParams {
        uint64 minCloseVolToCashUsd6;
        uint16 upRToCashBps;
        uint8 cashHoldPeriods;
        uint64 minCloseVolToExtremeUsd6;
        uint16 upRToExtremeBps;
        uint8 upExtremeConfirmPeriods;
        uint8 extremeHoldPeriods;
        uint16 downRFromExtremeBps;
        uint8 downExtremeConfirmPeriods;
        uint16 downRFromCashBps;
        uint8 downCashConfirmPeriods;
        uint64 emergencyFloorCloseVolUsd6;
        uint8 emergencyConfirmPeriods;
    }

    error InvalidFeeIndex();
    uint16 public feeTierCount;
    uint24[] private _feeTiersByIdx;
    ControllerConfig private _config;
    address private _creator;
    address private _creatorFeeRecipient;
    uint16 public immutable creatorFeeLimitPercent;

    function feeTiers(uint256 idx) public view returns (uint24) {
        if (idx >= feeTierCount) revert InvalidFeeIndex();
        return _feeTiersByIdx[idx];
    }

    function _feeTier(uint8 idx) internal view returns (uint24) {
        return feeTiers(uint256(idx));
    }

    // -----------------------------------------------------------------------
    // Immutable configuration
    // -----------------------------------------------------------------------
    // -----------------------------------------------------------------------
    // Immutable pool binding
    // -----------------------------------------------------------------------
    Currency public immutable poolCurrency0;
    Currency public immutable poolCurrency1;
    int24 public immutable poolTickSpacing;
    Currency public immutable stableCurrency;

    bool internal immutable _stableIsCurrency0;
    bool internal immutable _scaleIsMul;
    uint64 internal immutable _stableScale;

    // -----------------------------------------------------------------------
    // Packed state (ONE storage slot)
    // -----------------------------------------------------------------------
    uint256 private _state;
    uint256 private _creatorFees0;
    uint256 private _creatorFees1;

    uint8 private constant DIR_NONE = 0;

    // Period-close reason codes (for PeriodClosed event).
    uint8 public constant REASON_NO_SWAPS = 7;
    uint8 public constant REASON_LULL_RESET = 8;
    uint8 public constant REASON_DEADBAND = 9;
    uint8 public constant REASON_EMA_BOOTSTRAP = 10;
    uint8 public constant REASON_JUMP_CASH = 11;
    uint8 public constant REASON_JUMP_EXTREME = 12;
    uint8 public constant REASON_DOWN_TO_CASH = 13;
    uint8 public constant REASON_DOWN_TO_FLOOR = 14;
    uint8 public constant REASON_HOLD = 15;
    uint8 public constant REASON_EMERGENCY_FLOOR = 16;
    uint8 public constant REASON_NO_CHANGE = 17;

    uint16 private constant MAX_LULL_PERIODS = 24;
    uint8 private constant MAX_EMA_PERIODS = 64;
    uint8 private constant MAX_HOLD_PERIODS = 31;
    uint8 private constant MAX_UP_EXTREME_STREAK = 3;
    uint8 private constant MAX_DOWN_STREAK = 7;
    uint8 private constant MAX_EMERGENCY_STREAK = 3;
    // closeVol is tracked as abs(stableAmount) in USD6.
    // 1_000_000 equals $1 of period-close volume.
    uint64 private constant DUST_CLOSE_VOL_USD6 = 1_000_000;
    uint256 private constant FEE_SCALE = 1_000_000;
    uint256 private constant BPS_SCALE = 10_000;
    uint256 private constant HOLD_REMAINING_SHIFT = 235;
    uint256 private constant UP_EXTREME_STREAK_SHIFT = 240;
    uint256 private constant DOWN_STREAK_SHIFT = 242;
    uint256 private constant EMERGENCY_STREAK_SHIFT = 245;

    uint256 private constant PAUSED_BIT = 234;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event FeeUpdated(uint24 newFee, uint8 newFeeIdx, uint64 closedVolumeUsd6, uint96 emaVolumeUsd6);
    event PeriodClosed(
        uint24 fromFee,
        uint8 fromFeeIdx,
        uint24 toFee,
        uint8 toFeeIdx,
        uint64 closedVolumeUsd6,
        uint96 emaVolumeUsd6,
        uint64 lpFeesUsd6,
        uint8 reasonCode
    );
    event Paused(uint24 fee, uint8 feeIdx);
    event Unpaused();
    event LullReset(uint24 newFee, uint8 newFeeIdx);
    event CreatorFeeAccrued(address indexed currency, uint256 amount, uint24 feeBips);
    event CreatorFeesClaimed(address indexed to, uint256 amount0, uint256 amount1);
    event CreatorFeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event RescueTransfer(address indexed currency, uint256 amount, address indexed recipient);
    event CreatorUpdated(address indexed previousCreator, address indexed newCreator);
    event FeeTiersUpdated(uint24[] tiers, uint8 floorIdx, uint8 cashIdx, uint8 extremeIdx, uint8 capIdx);
    event ControllerParamsUpdated(
        uint64 minCloseVolToCashUsd6,
        uint16 upRToCashBps,
        uint8 cashHoldPeriods,
        uint64 minCloseVolToExtremeUsd6,
        uint16 upRToExtremeBps,
        uint8 upExtremeConfirmPeriods,
        uint8 extremeHoldPeriods,
        uint16 downRFromExtremeBps,
        uint8 downExtremeConfirmPeriods,
        uint16 downRFromCashBps,
        uint8 downCashConfirmPeriods,
        uint64 emergencyFloorCloseVolUsd6,
        uint8 emergencyConfirmPeriods
    );
    event TimingParamsUpdated(
        uint32 periodSeconds, uint8 emaPeriods, uint32 lullResetSeconds, uint16 deadbandBps
    );
    event CreatorFeeConfigUpdated(address indexed creator, uint16 creatorFeeBps);
    event StateReset(uint8 feeIdx, uint64 periodStart, bool paused, uint8 reasonCode);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error InvalidPoolKey();
    error NotDynamicFeePool();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidConfig();
    error NotCreator();
    error InvalidRescueCurrency();
    error InvalidRecipient();
    error ClaimTooLarge();
    error CreatorFeeRecipientRequired();
    error CreatorFeeLimitExceeded(uint16 requestedBps, uint16 maxAllowedBps);
    error CreatorFeePercentLimitExceeded(uint16 requestedPercent, uint16 maxAllowedPercent);
    error TierNotFound();
    error InvalidTierBounds();
    error InvalidHoldPeriods();
    error InvalidConfirmPeriods();
    error RequiresPaused();
    error EthTransferFailed();

    uint8 private constant RESET_REASON_ADMIN_TIERS = 1;
    uint8 private constant RESET_REASON_ADMIN_TIMING = 2;
    uint8 private constant RESET_REASON_ADMIN_PAUSE = 3;
    uint8 private constant RESET_REASON_ADMIN_UNPAUSE = 4;
    uint8 private constant RESET_REASON_ADMIN_EMERGENCY = 5;

    constructor(
        IPoolManager _poolManager,
        Currency _poolCurrency0,
        Currency _poolCurrency1,
        int24 _poolTickSpacing,
        Currency _stableCurrency,
        uint8 stableDecimals,
        uint8 _floorIdx,
        uint8 _capIdx,
        uint24[] memory _feeTiers,
        uint32 _periodSeconds,
        uint8 _emaPeriods,
        uint16 _deadbandBps,
        uint32 _lullResetSeconds,
        address _creatorAddr,
        address _creatorFeeRecipientAddr,
        uint16 _creatorFeeLimitPercent,
        uint16 _creatorFeeBps,
        uint24 _cashTier,
        uint64 _minCloseVolToCashUsd6,
        uint16 _upRToCashBps,
        uint8 _cashHoldPeriods,
        uint24 _extremeTier,
        uint64 _minCloseVolToExtremeUsd6,
        uint16 _upRToExtremeBps,
        uint8 _upExtremeConfirmPeriods,
        uint8 _extremeHoldPeriods,
        uint16 _downRFromExtremeBps,
        uint8 _downExtremeConfirmPeriods,
        uint16 _downRFromCashBps,
        uint8 _downCashConfirmPeriods,
        uint64 _emergencyFloorCloseVolUsd6,
        uint8 _emergencyConfirmPeriods
    ) BaseHook(_poolManager) {
        if (address(_poolManager) == address(0)) revert InvalidConfig();
        if (_creatorFeeLimitPercent > 100) revert InvalidConfig();
        creatorFeeLimitPercent = _creatorFeeLimitPercent;

        // enforce canonical ordering for determinism
        if (Currency.unwrap(_poolCurrency0) >= Currency.unwrap(_poolCurrency1)) revert InvalidConfig();
        if (_poolTickSpacing <= 0) revert InvalidConfig();

        poolCurrency0 = _poolCurrency0;
        poolCurrency1 = _poolCurrency1;
        poolTickSpacing = _poolTickSpacing;

        // Currency overloads `==` (not `!=`)
        if (!(_stableCurrency == _poolCurrency0) && !(_stableCurrency == _poolCurrency1)) {
            revert InvalidConfig();
        }
        stableCurrency = _stableCurrency;
        _stableIsCurrency0 = (_stableCurrency == _poolCurrency0);

        _setTimingParamsInternal(_periodSeconds, _emaPeriods, _lullResetSeconds, _deadbandBps);
        _setCreatorInternal(_creatorAddr);
        _setCreatorFeeRecipientInternal(_creatorFeeRecipientAddr);
        _setCreatorFeeBpsInternal(_creatorFeeBps);

        uint8 cashTierIdx_ = _mustFindTierIdx(_feeTiers, _cashTier);
        uint8 extremeTierIdx_ = _mustFindTierIdx(_feeTiers, _extremeTier);
        _setFeeTiersAndRolesInternal(_feeTiers, _floorIdx, cashTierIdx_, extremeTierIdx_, _capIdx);

        ControllerParams memory p = ControllerParams({
            minCloseVolToCashUsd6: _minCloseVolToCashUsd6,
            upRToCashBps: _upRToCashBps,
            cashHoldPeriods: _cashHoldPeriods,
            minCloseVolToExtremeUsd6: _minCloseVolToExtremeUsd6,
            upRToExtremeBps: _upRToExtremeBps,
            upExtremeConfirmPeriods: _upExtremeConfirmPeriods,
            extremeHoldPeriods: _extremeHoldPeriods,
            downRFromExtremeBps: _downRFromExtremeBps,
            downExtremeConfirmPeriods: _downExtremeConfirmPeriods,
            downRFromCashBps: _downRFromCashBps,
            downCashConfirmPeriods: _downCashConfirmPeriods,
            emergencyFloorCloseVolUsd6: _emergencyFloorCloseVolUsd6,
            emergencyConfirmPeriods: _emergencyConfirmPeriods
        });
        _setControllerParamsInternal(p);

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

        emit CreatorUpdated(address(0), _creatorAddr);
        emit CreatorFeeRecipientUpdated(address(0), _creatorFeeRecipientAddr);
        emit CreatorFeeConfigUpdated(_creatorAddr, _creatorFeeBps);
        emit FeeTiersUpdated(_feeTiers, _floorIdx, cashTierIdx_, extremeTierIdx_, _capIdx);
        emit ControllerParamsUpdated(
            p.minCloseVolToCashUsd6,
            p.upRToCashBps,
            p.cashHoldPeriods,
            p.minCloseVolToExtremeUsd6,
            p.upRToExtremeBps,
            p.upExtremeConfirmPeriods,
            p.extremeHoldPeriods,
            p.downRFromExtremeBps,
            p.downExtremeConfirmPeriods,
            p.downRFromCashBps,
            p.downCashConfirmPeriods,
            p.emergencyFloorCloseVolUsd6,
            p.emergencyConfirmPeriods
        );
        emit TimingParamsUpdated(_periodSeconds, _emaPeriods, _lullResetSeconds, _deadbandBps);
    }

    modifier onlyCreator() {
        if (msg.sender != _creator) revert NotCreator();
        _;
    }

    modifier whenPaused() {
        if (!isPaused()) revert RequiresPaused();
        _;
    }

    function _setCreatorInternal(address newCreator) internal {
        if (newCreator == address(0)) revert InvalidConfig();
        _creator = newCreator;
    }

    function _setCreatorFeeRecipientInternal(address newRecipient) internal {
        if (newRecipient == address(0) && _config.creatorFeeBps > 0) revert CreatorFeeRecipientRequired();
        _creatorFeeRecipient = newRecipient;
    }

    function _setCreatorFeeBpsInternal(uint16 newCreatorFeeBps) internal {
        uint16 maxAllowedBps = _creatorFeeLimitBps();
        if (newCreatorFeeBps > maxAllowedBps) {
            revert CreatorFeeLimitExceeded(newCreatorFeeBps, maxAllowedBps);
        }
        if (newCreatorFeeBps > 0 && _creatorFeeRecipient == address(0)) revert CreatorFeeRecipientRequired();
        _config.creatorFeeBps = newCreatorFeeBps;
    }

    function _setCreatorFeeConfigInternal(address newCreator, uint16 newCreatorFeeBps) internal {
        _setCreatorInternal(newCreator);
        _setCreatorFeeBpsInternal(newCreatorFeeBps);
    }

    function _creatorFeeLimitBps() internal view returns (uint16) {
        return creatorFeeLimitPercent * 100;
    }

    function _setTimingParamsInternal(
        uint32 periodSeconds_,
        uint8 emaPeriods_,
        uint32 lullResetSeconds_,
        uint16 deadbandBps_
    ) internal {
        if (periodSeconds_ == 0) revert InvalidConfig();
        if (emaPeriods_ < 2 || emaPeriods_ > MAX_EMA_PERIODS) revert InvalidConfig();
        if (deadbandBps_ > 5000) revert InvalidConfig();
        if (lullResetSeconds_ < periodSeconds_) revert InvalidConfig();
        if (uint256(lullResetSeconds_) > uint256(periodSeconds_) * MAX_LULL_PERIODS) revert InvalidConfig();

        _config.periodSeconds = periodSeconds_;
        _config.emaPeriods = emaPeriods_;
        _config.lullResetSeconds = lullResetSeconds_;
        _config.deadbandBps = deadbandBps_;
    }

    function _setControllerParamsInternal(ControllerParams memory p) internal {
        if (p.cashHoldPeriods == 0 || p.cashHoldPeriods > MAX_HOLD_PERIODS) revert InvalidHoldPeriods();
        if (p.extremeHoldPeriods == 0 || p.extremeHoldPeriods > MAX_HOLD_PERIODS) {
            revert InvalidHoldPeriods();
        }
        if (p.upExtremeConfirmPeriods == 0 || p.upExtremeConfirmPeriods > MAX_UP_EXTREME_STREAK) {
            revert InvalidConfirmPeriods();
        }
        if (p.downExtremeConfirmPeriods == 0 || p.downExtremeConfirmPeriods > MAX_DOWN_STREAK) {
            revert InvalidConfirmPeriods();
        }
        if (p.downCashConfirmPeriods == 0 || p.downCashConfirmPeriods > MAX_DOWN_STREAK) {
            revert InvalidConfirmPeriods();
        }
        if (p.emergencyConfirmPeriods == 0 || p.emergencyConfirmPeriods > MAX_EMERGENCY_STREAK) {
            revert InvalidConfirmPeriods();
        }

        _config.minCloseVolToCashUsd6 = p.minCloseVolToCashUsd6;
        _config.upRToCashBps = p.upRToCashBps;
        _config.cashHoldPeriods = p.cashHoldPeriods;
        _config.minCloseVolToExtremeUsd6 = p.minCloseVolToExtremeUsd6;
        _config.upRToExtremeBps = p.upRToExtremeBps;
        _config.upExtremeConfirmPeriods = p.upExtremeConfirmPeriods;
        _config.extremeHoldPeriods = p.extremeHoldPeriods;
        _config.downRFromExtremeBps = p.downRFromExtremeBps;
        _config.downExtremeConfirmPeriods = p.downExtremeConfirmPeriods;
        _config.downRFromCashBps = p.downRFromCashBps;
        _config.downCashConfirmPeriods = p.downCashConfirmPeriods;
        _config.emergencyFloorCloseVolUsd6 = p.emergencyFloorCloseVolUsd6;
        _config.emergencyConfirmPeriods = p.emergencyConfirmPeriods;
    }

    function _mustFindTierIdx(uint24[] memory tiers, uint24 tier) internal pure returns (uint8 idx) {
        uint256 len = tiers.length;
        for (uint256 i = 0; i < len; ++i) {
            if (tiers[i] == tier) {
                // forge-lint: disable-next-line(unsafe-typecast)
                return uint8(i);
            }
        }
        revert TierNotFound();
    }

    function _setFeeTiersAndRolesInternal(
        uint24[] memory tiers,
        uint8 floorIdx_,
        uint8 cashIdx_,
        uint8 extremeIdx_,
        uint8 capIdx_
    ) internal {
        uint256 len = tiers.length;
        if (len == 0 || len > MAX_FEE_TIER_COUNT) revert InvalidConfig();
        if (
            len <= uint256(floorIdx_) || len <= uint256(cashIdx_) || len <= uint256(extremeIdx_)
                || len <= uint256(capIdx_)
        ) {
            revert InvalidFeeIndex();
        }
        if (floorIdx_ >= cashIdx_ || cashIdx_ >= extremeIdx_ || extremeIdx_ != capIdx_) {
            revert InvalidTierBounds();
        }

        delete _feeTiersByIdx;
        uint24 prevTier;
        for (uint256 i = 0; i < len; ++i) {
            uint24 tier = tiers[i];
            if (tier == 0 || tier > LPFeeLibrary.MAX_LP_FEE) revert InvalidConfig();
            if (i > 0 && tier <= prevTier) revert InvalidConfig();
            _feeTiersByIdx.push(tier);
            prevTier = tier;
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        feeTierCount = uint16(len);
        _config.floorIdx = floorIdx_;
        _config.cashIdx = cashIdx_;
        _config.extremeIdx = extremeIdx_;
        _config.capIdx = extremeIdx_;
    }

    function _resetStateToFloor(bool pausedValue, uint8 reasonCode) internal {
        (,, uint64 periodStart,,,,,,,) = _unpackState(_state);
        bool initialized = periodStart != 0;
        uint8 feeIdx = _config.floorIdx;
        uint64 nextPeriodStart = initialized ? _now64() : uint64(0);

        _state = _packState(0, 0, nextPeriodStart, feeIdx, DIR_NONE, pausedValue, 0, 0, 0, 0);

        if (initialized) {
            poolManager.updateDynamicLPFee(_poolKey(), _feeTier(feeIdx));
            emit FeeUpdated(_feeTier(feeIdx), feeIdx, 0, 0);
        }

        emit StateReset(feeIdx, nextPeriodStart, pausedValue, reasonCode);
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

        (,, uint64 periodStart,,,,,,,) = _unpackState(_state);
        if (periodStart != 0) revert AlreadyInitialized();

        uint64 nowTs = _now64();

        uint8 feeIdx = _config.floorIdx;

        _state = _packState(0, 0, nowTs, feeIdx, DIR_NONE, isPaused(), 0, 0, 0, 0);

        poolManager.updateDynamicLPFee(key, _feeTier(feeIdx));
        emit FeeUpdated(_feeTier(feeIdx), feeIdx, 0, 0);

        return IHooks.afterInitialize.selector;
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        _validateKey(key);

        if (isPaused()) {
            // Fee is applied immediately in pause()/unpause(); swaps while paused do not update state.
            return (IHooks.afterSwap.selector, 0);
        }

        (
            uint64 periodVol,
            uint96 emaVol,
            uint64 periodStart,
            uint8 feeIdx,
            uint8 lastDir,
            bool paused_,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak
        ) = _unpackState(_state);

        if (periodStart == 0) revert NotInitialized();

        uint24 appliedFeeBips = _feeTier(feeIdx);
        _accrueCreatorFeeAfterSwap(key, params, delta, appliedFeeBips);

        uint64 nowTs = _now64();
        uint64 elapsed = nowTs - periodStart;
        bool feeChanged;
        uint64 closeVolForEvent;

        if (elapsed >= _config.lullResetSeconds) {
            uint8 oldFeeIdx = feeIdx;

            emaVol = 0;
            lastDir = DIR_NONE;
            feeIdx = _config.floorIdx;
            periodStart = nowTs;
            holdRemaining = 0;
            upExtremeStreak = 0;
            downStreak = 0;
            emergencyStreak = 0;

            periodVol = _addSwapVolumeUsd6(0, delta);

            _state = _packState(
                periodVol,
                emaVol,
                periodStart,
                feeIdx,
                lastDir,
                paused_,
                holdRemaining,
                upExtremeStreak,
                downStreak,
                emergencyStreak
            );

            if (feeIdx != oldFeeIdx) {
                poolManager.updateDynamicLPFee(key, _feeTier(feeIdx));
                emit FeeUpdated(_feeTier(feeIdx), feeIdx, 0, 0);
            }

            emit PeriodClosed(
                _feeTier(oldFeeIdx), oldFeeIdx, _feeTier(feeIdx), feeIdx, 0, 0, 0, REASON_LULL_RESET
            );
            emit LullReset(_feeTier(feeIdx), feeIdx);
            return (IHooks.afterSwap.selector, 0);
        }

        if (elapsed >= _config.periodSeconds) {
            uint64 periods = elapsed / uint64(_config.periodSeconds);
            uint64 closeVol0 = periodVol;
            closeVolForEvent = closeVol0 <= DUST_CLOSE_VOL_USD6 ? uint64(0) : closeVol0;

            uint8 oldFeeIdx = feeIdx;

            uint96 ema = emaVol;
            uint8 f = feeIdx;
            uint8 hold = holdRemaining;
            uint8 upStreak = upExtremeStreak;
            uint8 down = downStreak;
            uint8 emergency = emergencyStreak;

            for (uint64 i = 0; i < periods; i++) {
                uint64 vRaw = (i == 0) ? closeVol0 : uint64(0);
                uint64 vEff = vRaw <= DUST_CLOSE_VOL_USD6 ? uint64(0) : vRaw;

                uint96 emaBefore = ema;
                ema = _updateEma(ema, vEff);
                bool bootstrapV2 = emaBefore == 0 && vEff > 0;

                uint8 fromFeeIdx = f;
                uint24 fromFee = _feeTier(fromFeeIdx);
                (uint8 nf, uint8 nh, uint8 nu, uint8 nd, uint8 ne,, uint8 reasonCode) =
                    _computeNextFeeIdxV2(f, vEff, ema, bootstrapV2, hold, upStreak, down, emergency);
                f = nf;
                hold = nh;
                upStreak = nu;
                down = nd;
                emergency = ne;

                emit PeriodClosed(
                    fromFee,
                    fromFeeIdx,
                    _feeTier(f),
                    f,
                    vEff,
                    ema,
                    _estimateLpFeesUsd6(vEff, fromFee),
                    reasonCode
                );
            }

            emaVol = ema;
            feeIdx = f;
            lastDir = DIR_NONE;
            holdRemaining = hold;
            upExtremeStreak = upStreak;
            downStreak = down;
            emergencyStreak = emergency;
            feeChanged = feeIdx != oldFeeIdx;

            uint256 nextPeriodStart = uint256(periodStart) + uint256(periods) * uint256(_config.periodSeconds);
            if (nextPeriodStart > uint256(nowTs)) {
                nextPeriodStart = nowTs;
            }
            if (nextPeriodStart > type(uint64).max) {
                periodStart = type(uint64).max;
            } else {
                // forge-lint: disable-next-line(unsafe-typecast)
                periodStart = uint64(nextPeriodStart);
            }
            periodVol = 0;
        }

        periodVol = _addSwapVolumeUsd6(periodVol, delta);

        _state = _packState(
            periodVol,
            emaVol,
            periodStart,
            feeIdx,
            lastDir,
            paused_,
            holdRemaining,
            upExtremeStreak,
            downStreak,
            emergencyStreak
        );

        if (feeChanged) {
            poolManager.updateDynamicLPFee(key, _feeTier(feeIdx));
            emit FeeUpdated(_feeTier(feeIdx), feeIdx, closeVolForEvent, emaVol);
        }
        return (IHooks.afterSwap.selector, 0);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function isPaused() public view returns (bool) {
        return ((_state >> PAUSED_BIT) & 1) == 1;
    }

    function currentFeeBips() external view returns (uint24) {
        (,, uint64 periodStart, uint8 feeIdx,,,,,,) = _unpackState(_state);
        if (periodStart == 0) revert NotInitialized();
        return _feeTier(feeIdx);
    }

    function unpackedState()
        external
        view
        returns (
            uint64 periodVolumeUsd6,
            uint96 emaVolumeUsd6,
            uint64 periodStart,
            uint8 feeIdx,
            uint8 lastDir
        )
    {
        (uint64 pv, uint96 ev, uint64 ps, uint8 fi, uint8 ld,,,,,) = _unpackState(_state);
        return (pv, ev, ps, fi, ld);
    }

    function floorIdx() public view returns (uint8) {
        return _config.floorIdx;
    }

    function cashIdx() public view returns (uint8) {
        return _config.cashIdx;
    }

    function extremeIdx() public view returns (uint8) {
        return _config.extremeIdx;
    }

    function capIdx() public view returns (uint8) {
        return _config.capIdx;
    }

    function minCloseVolToCashUsd6() public view returns (uint64) {
        return _config.minCloseVolToCashUsd6;
    }

    function upRToCashBps() public view returns (uint16) {
        return _config.upRToCashBps;
    }

    function cashHoldPeriods() public view returns (uint8) {
        return _config.cashHoldPeriods;
    }

    function minCloseVolToExtremeUsd6() public view returns (uint64) {
        return _config.minCloseVolToExtremeUsd6;
    }

    function upRToExtremeBps() public view returns (uint16) {
        return _config.upRToExtremeBps;
    }

    function upExtremeConfirmPeriods() public view returns (uint8) {
        return _config.upExtremeConfirmPeriods;
    }

    function extremeHoldPeriods() public view returns (uint8) {
        return _config.extremeHoldPeriods;
    }

    function downRFromExtremeBps() public view returns (uint16) {
        return _config.downRFromExtremeBps;
    }

    function downExtremeConfirmPeriods() public view returns (uint8) {
        return _config.downExtremeConfirmPeriods;
    }

    function downRFromCashBps() public view returns (uint16) {
        return _config.downRFromCashBps;
    }

    function downCashConfirmPeriods() public view returns (uint8) {
        return _config.downCashConfirmPeriods;
    }

    function emergencyFloorCloseVolUsd6() public view returns (uint64) {
        return _config.emergencyFloorCloseVolUsd6;
    }

    function emergencyConfirmPeriods() public view returns (uint8) {
        return _config.emergencyConfirmPeriods;
    }

    function periodSeconds() public view returns (uint32) {
        return _config.periodSeconds;
    }

    function emaPeriods() public view returns (uint8) {
        return _config.emaPeriods;
    }

    function deadbandBps() public view returns (uint16) {
        return _config.deadbandBps;
    }

    function lullResetSeconds() public view returns (uint32) {
        return _config.lullResetSeconds;
    }

    function creator() public view returns (address) {
        return _creator;
    }

    function creatorFeeRecipient() public view returns (address) {
        return _creatorFeeRecipient;
    }

    function creatorFeeBps() public view returns (uint16) {
        return _config.creatorFeeBps;
    }

    function getControllerParams() external view returns (ControllerParams memory p) {
        p = ControllerParams({
            minCloseVolToCashUsd6: _config.minCloseVolToCashUsd6,
            upRToCashBps: _config.upRToCashBps,
            cashHoldPeriods: _config.cashHoldPeriods,
            minCloseVolToExtremeUsd6: _config.minCloseVolToExtremeUsd6,
            upRToExtremeBps: _config.upRToExtremeBps,
            upExtremeConfirmPeriods: _config.upExtremeConfirmPeriods,
            extremeHoldPeriods: _config.extremeHoldPeriods,
            downRFromExtremeBps: _config.downRFromExtremeBps,
            downExtremeConfirmPeriods: _config.downExtremeConfirmPeriods,
            downRFromCashBps: _config.downRFromCashBps,
            downCashConfirmPeriods: _config.downCashConfirmPeriods,
            emergencyFloorCloseVolUsd6: _config.emergencyFloorCloseVolUsd6,
            emergencyConfirmPeriods: _config.emergencyConfirmPeriods
        });
    }

    function getFeeTiersAndRoles()
        external
        view
        returns (uint24[] memory tiers, uint8 floorIdx_, uint8 cashIdx_, uint8 extremeIdx_, uint8 capIdx_)
    {
        uint256 len = _feeTiersByIdx.length;
        tiers = new uint24[](len);
        for (uint256 i = 0; i < len; ++i) {
            tiers[i] = _feeTiersByIdx[i];
        }
        floorIdx_ = _config.floorIdx;
        cashIdx_ = _config.cashIdx;
        extremeIdx_ = _config.extremeIdx;
        capIdx_ = _config.capIdx;
    }

    function getStateDebug()
        external
        view
        returns (
            uint8 feeIdx,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak,
            uint64 periodStart,
            uint64 periodVol,
            uint96 emaVol,
            bool paused
        )
    {
        (
            periodVol,
            emaVol,
            periodStart,
            feeIdx,,
            paused,
            holdRemaining,
            upExtremeStreak,
            downStreak,
            emergencyStreak
        ) = _unpackState(_state);
    }

    function creatorFeesAccrued() external view returns (uint256 token0, uint256 token1) {
        return (_creatorFees0, _creatorFees1);
    }

    function claimCreatorFees(address to, uint256 amount0, uint256 amount1) external {
        if (msg.sender != _creator) revert NotCreator();
        if (to != _creatorFeeRecipient || to == address(0)) revert InvalidRecipient();
        if (amount0 > _creatorFees0 || amount1 > _creatorFees1) revert ClaimTooLarge();
        if (amount0 > 0) {
            _creatorFees0 -= amount0;
            poolCurrency0.transfer(to, amount0);
        }
        if (amount1 > 0) {
            _creatorFees1 -= amount1;
            poolCurrency1.transfer(to, amount1);
        }
        if (amount0 > 0 || amount1 > 0) {
            emit CreatorFeesClaimed(to, amount0, amount1);
        }
    }

    function claimAllCreatorFees() external {
        if (msg.sender != _creator) revert NotCreator();
        address to = _creatorFeeRecipient;
        if (to == address(0)) revert InvalidRecipient();
        uint256 amount0 = _creatorFees0;
        uint256 amount1 = _creatorFees1;
        if (amount0 > 0) {
            _creatorFees0 = 0;
            poolCurrency0.transfer(to, amount0);
        }
        if (amount1 > 0) {
            _creatorFees1 = 0;
            poolCurrency1.transfer(to, amount1);
        }
        if (amount0 > 0 || amount1 > 0) {
            emit CreatorFeesClaimed(to, amount0, amount1);
        }
    }

    function claimAllCreatorFees(address to) external {
        if (msg.sender != _creator) revert NotCreator();
        if (to != _creatorFeeRecipient || to == address(0)) revert InvalidRecipient();
        uint256 amount0 = _creatorFees0;
        uint256 amount1 = _creatorFees1;
        if (amount0 > 0) {
            _creatorFees0 = 0;
            poolCurrency0.transfer(to, amount0);
        }
        if (amount1 > 0) {
            _creatorFees1 = 0;
            poolCurrency1.transfer(to, amount1);
        }
        if (amount0 > 0 || amount1 > 0) {
            emit CreatorFeesClaimed(to, amount0, amount1);
        }
    }

    function rescueToken(Currency currency, uint256 amount) external {
        if (msg.sender != _creator) revert NotCreator();
        if (currency == poolCurrency0 || currency == poolCurrency1) revert InvalidRescueCurrency();

        currency.transfer(_creator, amount);
        emit RescueTransfer(Currency.unwrap(currency), amount, _creator);
    }

    function rescueETH(address to, uint256 amount) external onlyCreator {
        if (to == address(0)) revert InvalidRecipient();
        if (amount > address(this).balance) revert ClaimTooLarge();
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit RescueTransfer(address(0), amount, to);
    }

    // -----------------------------------------------------------------------
    // Admin controls
    // -----------------------------------------------------------------------

    function setCreatorFeeConfig(address newCreator, uint16 newCreatorFeeBps) external onlyCreator {
        address oldCreator = _creator;
        _setCreatorFeeConfigInternal(newCreator, newCreatorFeeBps);
        if (oldCreator != newCreator) {
            emit CreatorUpdated(oldCreator, newCreator);
        }
        emit CreatorFeeConfigUpdated(newCreator, newCreatorFeeBps);
    }

    function setCreatorFeePercent(uint16 newCreatorFeePercent) external onlyCreator {
        if (newCreatorFeePercent > creatorFeeLimitPercent) {
            revert CreatorFeePercentLimitExceeded(newCreatorFeePercent, creatorFeeLimitPercent);
        }
        uint16 newCreatorFeeBps = newCreatorFeePercent * 100;
        _setCreatorFeeBpsInternal(newCreatorFeeBps);
        emit CreatorFeeConfigUpdated(_creator, newCreatorFeeBps);
    }

    function setCreatorFeeRecipient(address newRecipient) external onlyCreator {
        address oldRecipient = _creatorFeeRecipient;
        _setCreatorFeeRecipientInternal(newRecipient);
        emit CreatorFeeRecipientUpdated(oldRecipient, newRecipient);
    }

    function setFeeTiersAndRoles(
        uint24[] calldata tiers,
        uint8 floorIdx_,
        uint8 cashIdx_,
        uint8 extremeIdx_,
        uint8 capIdx_
    ) external onlyCreator whenPaused {
        _setFeeTiersAndRolesInternal(tiers, floorIdx_, cashIdx_, extremeIdx_, capIdx_);
        emit FeeTiersUpdated(tiers, floorIdx_, cashIdx_, extremeIdx_, capIdx_);
        _resetStateToFloor(true, RESET_REASON_ADMIN_TIERS);
    }

    function setControllerParams(ControllerParams calldata p) external onlyCreator whenPaused {
        _setControllerParamsInternal(p);
        emit ControllerParamsUpdated(
            p.minCloseVolToCashUsd6,
            p.upRToCashBps,
            p.cashHoldPeriods,
            p.minCloseVolToExtremeUsd6,
            p.upRToExtremeBps,
            p.upExtremeConfirmPeriods,
            p.extremeHoldPeriods,
            p.downRFromExtremeBps,
            p.downExtremeConfirmPeriods,
            p.downRFromCashBps,
            p.downCashConfirmPeriods,
            p.emergencyFloorCloseVolUsd6,
            p.emergencyConfirmPeriods
        );
    }

    function setTimingParams(
        uint32 periodSeconds_,
        uint8 emaPeriods_,
        uint32 lullResetSeconds_,
        uint16 deadbandBps_
    ) external onlyCreator whenPaused {
        _setTimingParamsInternal(periodSeconds_, emaPeriods_, lullResetSeconds_, deadbandBps_);
        emit TimingParamsUpdated(periodSeconds_, emaPeriods_, lullResetSeconds_, deadbandBps_);
        _resetStateToFloor(true, RESET_REASON_ADMIN_TIMING);
    }

    function pause() external onlyCreator {
        if (isPaused()) return;
        _resetStateToFloor(true, RESET_REASON_ADMIN_PAUSE);
        emit Paused(_feeTier(_config.floorIdx), _config.floorIdx);
    }

    function unpause() external onlyCreator {
        if (!isPaused()) return;
        _resetStateToFloor(false, RESET_REASON_ADMIN_UNPAUSE);
        emit Unpaused();
    }

    function emergencyResetStateToFloor() external onlyCreator whenPaused {
        _resetStateToFloor(true, RESET_REASON_ADMIN_EMERGENCY);
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

    receive() external payable {}

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

    function _now64() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _addSwapVolumeUsd6(uint64 current, BalanceDelta delta) internal view returns (uint64) {
        int128 s = _stableIsCurrency0 ? delta.amount0() : delta.amount1();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 absStable = s < 0 ? uint256(-int256(s)) : uint256(uint128(s));

        uint256 usd6 = _toUsd6(absStable);

        // treat swap volume as one-sided stable notional
        uint256 add = usd6;

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

        uint256 n = uint256(_config.emaPeriods);
        uint256 updated = (uint256(ema) * (n - 1) + uint256(closeVol)) / n;
        if (updated > type(uint96).max) return type(uint96).max;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(updated);
    }

    function _estimateLpFeesUsd6(uint64 closeVol, uint24 feeBips) internal pure returns (uint64) {
        uint256 fees = (uint256(closeVol) * uint256(feeBips)) / 1_000_000;
        if (fees > type(uint64).max) return type(uint64).max;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(fees);
    }

    function _computeCreatorFee(uint256 amountIn, uint24 feeBips) internal view returns (uint256) {
        uint256 lpFeeAmount = (amountIn * uint256(feeBips)) / FEE_SCALE;
        return (lpFeeAmount * uint256(_config.creatorFeeBps)) / BPS_SCALE;
    }

    function _accrueCreatorFeeAfterSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint24 feeBips
    ) internal {
        if (_config.creatorFeeBps == 0) return;

        int128 amountInSigned = params.zeroForOne ? delta.amount0() : delta.amount1();
        uint256 amountIn =
            amountInSigned < 0 ? uint256(-int256(amountInSigned)) : uint256(uint128(amountInSigned));
        if (amountIn == 0) return;

        uint256 creatorCut = _computeCreatorFee(amountIn, feeBips);
        if (creatorCut == 0) return;

        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        poolManager.take(inputCurrency, address(this), creatorCut);
        if (inputCurrency == poolCurrency0) {
            _creatorFees0 += creatorCut;
        } else {
            _creatorFees1 += creatorCut;
        }
        emit CreatorFeeAccrued(Currency.unwrap(inputCurrency), creatorCut, feeBips);
    }

    // Backward-compatible internal surface for existing test harnesses.
    function _computeNextFeeIdx(uint8 feeIdx, uint8, uint64 closeVol, uint96 emaVol)
        internal
        view
        returns (uint8 newFeeIdx, uint8 newLastDir, bool changed, uint8 reasonCode)
    {
        (newFeeIdx,,,,, changed, reasonCode) =
            _computeNextFeeIdxV2(feeIdx, closeVol, emaVol, false, 0, 0, 0, 0);
        newLastDir = DIR_NONE;
    }

    function _computeNextFeeIdxV2(
        uint8 feeIdx,
        uint64 closeVol,
        uint96 emaVol,
        bool bootstrapV2,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    )
        internal
        view
        returns (
            uint8 newFeeIdx,
            uint8 newHoldRemaining,
            uint8 newUpExtremeStreak,
            uint8 newDownStreak,
            uint8 newEmergencyStreak,
            bool changed,
            uint8 reasonCode
        )
    {
        newFeeIdx = feeIdx;
        newHoldRemaining = holdRemaining;
        newUpExtremeStreak = upExtremeStreak;
        newDownStreak = downStreak;
        newEmergencyStreak = emergencyStreak;
        reasonCode = closeVol == 0 ? REASON_NO_SWAPS : REASON_NO_CHANGE;

        // Rule 1: hold counter always decays first.
        if (newHoldRemaining > 0) {
            unchecked {
                newHoldRemaining -= 1;
            }
        }

        // Rule 2: emergency floor guard runs before all transitions.
        if (closeVol < _config.emergencyFloorCloseVolUsd6) {
            newEmergencyStreak = _incrementStreak(newEmergencyStreak, MAX_EMERGENCY_STREAK);
        } else {
            newEmergencyStreak = 0;
        }
        if (newEmergencyStreak >= _config.emergencyConfirmPeriods && newFeeIdx != _config.floorIdx) {
            newFeeIdx = _config.floorIdx;
            newHoldRemaining = 0;
            newUpExtremeStreak = 0;
            newDownStreak = 0;
            newEmergencyStreak = 0;
            return (
                newFeeIdx,
                newHoldRemaining,
                newUpExtremeStreak,
                newDownStreak,
                newEmergencyStreak,
                true,
                REASON_EMERGENCY_FLOOR
            );
        }

        uint256 rBps = emaVol == 0 ? 0 : (uint256(closeVol) * BPS_SCALE) / uint256(emaVol);
        uint256 deadband = uint256(_config.deadbandBps);
        bool deadbandBlocked;

        // Rule 3a: floor -> cash fast jump.
        if (newFeeIdx == _config.floorIdx) {
            bool upCashRaw = rBps >= uint256(_config.upRToCashBps);
            bool upCashPass = rBps >= uint256(_config.upRToCashBps) + deadband;
            bool canJumpCash =
                !bootstrapV2 && emaVol != 0 && closeVol >= _config.minCloseVolToCashUsd6 && upCashPass;
            if (
                !bootstrapV2 && emaVol != 0 && closeVol >= _config.minCloseVolToCashUsd6 && upCashRaw
                    && !upCashPass && newFeeIdx != _config.cashIdx
            ) {
                deadbandBlocked = true;
            }
            if (canJumpCash && newFeeIdx != _config.cashIdx) {
                newFeeIdx = _config.cashIdx;
                newHoldRemaining = _config.cashHoldPeriods;
                newUpExtremeStreak = 0;
                newDownStreak = 0;
                newEmergencyStreak = 0;
                return (
                    newFeeIdx,
                    newHoldRemaining,
                    newUpExtremeStreak,
                    newDownStreak,
                    newEmergencyStreak,
                    true,
                    REASON_JUMP_CASH
                );
            }
        }

        // Rule 3b: cash -> extreme jump after consecutive confirmations.
        if (newFeeIdx == _config.cashIdx) {
            bool upExtremeRaw =
                closeVol >= _config.minCloseVolToExtremeUsd6 && rBps >= uint256(_config.upRToExtremeBps);
            bool upExtremePass = closeVol >= _config.minCloseVolToExtremeUsd6
                && rBps >= uint256(_config.upRToExtremeBps) + deadband;
            if (upExtremePass) {
                newUpExtremeStreak = _incrementStreak(newUpExtremeStreak, MAX_UP_EXTREME_STREAK);
            } else {
                if (
                    upExtremeRaw
                        && _incrementStreak(newUpExtremeStreak, MAX_UP_EXTREME_STREAK)
                            >= _config.upExtremeConfirmPeriods && !bootstrapV2
                        && newFeeIdx != _config.extremeIdx
                ) {
                    deadbandBlocked = true;
                }
                newUpExtremeStreak = 0;
            }
            if (
                !bootstrapV2 && newUpExtremeStreak >= _config.upExtremeConfirmPeriods
                    && newFeeIdx != _config.extremeIdx
            ) {
                newFeeIdx = _config.extremeIdx;
                newHoldRemaining = _config.extremeHoldPeriods;
                newUpExtremeStreak = 0;
                newDownStreak = 0;
                newEmergencyStreak = 0;
                return (
                    newFeeIdx,
                    newHoldRemaining,
                    newUpExtremeStreak,
                    newDownStreak,
                    newEmergencyStreak,
                    true,
                    REASON_JUMP_EXTREME
                );
            }
        } else {
            newUpExtremeStreak = 0;
        }

        // Rule 4: down transitions are blocked while hold is active.
        if (newHoldRemaining > 0) {
            newDownStreak = 0;
            return (
                newFeeIdx,
                newHoldRemaining,
                newUpExtremeStreak,
                newDownStreak,
                newEmergencyStreak,
                false,
                REASON_HOLD
            );
        }

        if (newFeeIdx == _config.extremeIdx) {
            uint256 downExtremeThreshold = uint256(_config.downRFromExtremeBps);
            uint256 downExtremePassThreshold =
                downExtremeThreshold > deadband ? downExtremeThreshold - deadband : 0;
            bool downExtremeRaw = rBps <= downExtremeThreshold;
            bool downExtremePass = rBps <= downExtremePassThreshold;
            if (downExtremePass) {
                newDownStreak = _incrementStreak(newDownStreak, MAX_DOWN_STREAK);
            } else {
                if (
                    downExtremeRaw
                        && _incrementStreak(newDownStreak, MAX_DOWN_STREAK)
                            >= _config.downExtremeConfirmPeriods && newFeeIdx != _config.cashIdx
                ) {
                    deadbandBlocked = true;
                }
                newDownStreak = 0;
            }
            if (newDownStreak >= _config.downExtremeConfirmPeriods) {
                newDownStreak = 0;
                if (newFeeIdx != _config.cashIdx) {
                    newFeeIdx = _config.cashIdx;
                    return (
                        newFeeIdx,
                        newHoldRemaining,
                        newUpExtremeStreak,
                        newDownStreak,
                        newEmergencyStreak,
                        true,
                        REASON_DOWN_TO_CASH
                    );
                }
            }
        } else if (newFeeIdx == _config.cashIdx) {
            uint256 downCashThreshold = uint256(_config.downRFromCashBps);
            uint256 downCashPassThreshold = downCashThreshold > deadband ? downCashThreshold - deadband : 0;
            bool downCashRaw = rBps <= downCashThreshold;
            bool downCashPass = rBps <= downCashPassThreshold;
            if (downCashPass) {
                newDownStreak = _incrementStreak(newDownStreak, MAX_DOWN_STREAK);
            } else {
                if (
                    downCashRaw
                        && _incrementStreak(newDownStreak, MAX_DOWN_STREAK) >= _config.downCashConfirmPeriods
                        && newFeeIdx != _config.floorIdx
                ) {
                    deadbandBlocked = true;
                }
                newDownStreak = 0;
            }
            if (newDownStreak >= _config.downCashConfirmPeriods) {
                newDownStreak = 0;
                if (newFeeIdx != _config.floorIdx) {
                    newFeeIdx = _config.floorIdx;
                    return (
                        newFeeIdx,
                        newHoldRemaining,
                        newUpExtremeStreak,
                        newDownStreak,
                        newEmergencyStreak,
                        true,
                        REASON_DOWN_TO_FLOOR
                    );
                }
            }
        } else {
            newDownStreak = 0;
        }

        if (deadbandBlocked) {
            reasonCode = REASON_DEADBAND;
        }
        if (bootstrapV2) {
            reasonCode = REASON_EMA_BOOTSTRAP;
        }
    }

    function _incrementStreak(uint8 current, uint8 maxValue) internal pure returns (uint8) {
        return current < maxValue ? current + 1 : maxValue;
    }

    // -----------------------------------------------------------------------
    // Bit packing
    // -----------------------------------------------------------------------

    function _packState(
        uint64 periodVol,
        uint96 emaVol,
        uint64 periodStart,
        uint8 feeIdx,
        uint8 lastDir,
        bool paused,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) internal pure returns (uint256 packed) {
        packed = uint256(periodVol);
        packed |= uint256(emaVol) << 64;
        packed |= uint256(periodStart) << 160;
        packed |= uint256(feeIdx) << 224;
        packed |= (uint256(lastDir) & 0x3) << 232;
        packed |= (uint256(holdRemaining) & 0x1F) << HOLD_REMAINING_SHIFT;
        packed |= (uint256(upExtremeStreak) & 0x3) << UP_EXTREME_STREAK_SHIFT;
        packed |= (uint256(downStreak) & 0x7) << DOWN_STREAK_SHIFT;
        packed |= (uint256(emergencyStreak) & 0x3) << EMERGENCY_STREAK_SHIFT;

        if (paused) packed |= uint256(1) << PAUSED_BIT;
    }

    function _unpackState(uint256 packed)
        internal
        pure
        returns (
            uint64 periodVol,
            uint96 emaVol,
            uint64 periodStart,
            uint8 feeIdx,
            uint8 lastDir,
            bool paused,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak
        )
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        periodVol = uint64(packed);
        // forge-lint: disable-next-line(unsafe-typecast)
        emaVol = uint96(packed >> 64);
        // forge-lint: disable-next-line(unsafe-typecast)
        periodStart = uint64(packed >> 160);
        // forge-lint: disable-next-line(unsafe-typecast)
        feeIdx = uint8(packed >> 224);
        lastDir = uint8((packed >> 232) & 0x3);

        paused = ((packed >> PAUSED_BIT) & 1) == 1;
        holdRemaining = uint8((packed >> HOLD_REMAINING_SHIFT) & 0x1F);
        upExtremeStreak = uint8((packed >> UP_EXTREME_STREAK_SHIFT) & 0x3);
        downStreak = uint8((packed >> DOWN_STREAK_SHIFT) & 0x7);
        emergencyStreak = uint8((packed >> EMERGENCY_STREAK_SHIFT) & 0x3);
    }
}
