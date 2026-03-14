// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @title VolumeDynamicFeeHook
/// @notice Single-pool Uniswap v4 hook that manages dynamic LP fees.
/// @notice Source code, documentation, and audit reports live at https://github.com/Axel-DeFi/uniswap-hook-dynamic-fees.
/// @dev NatSpec in this file is the source of truth for operations docs.
contract VolumeDynamicFeeHook is BaseHook, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    /// @notice Fixed-point scale used by Uniswap LP fee tiers (1e6 = 100%).
    uint256 private constant FEE_SCALE = 1_000_000;

    /// @notice Basis-point scale used for percentage math.
    uint256 private constant BPS_SCALE = 10_000;

    /// @notice Scaler used for EMA precision. Stored EMA units are USD6 * EMA_SCALE.
    uint256 private constant EMA_SCALE = 1_000_000;

    /// @notice Hard maximum for HookFee share as a percent of LP fee.
    uint16 public constant MAX_HOOK_FEE_PERCENT = 10;

    /// @notice Maximum single settlement amount accepted by PoolManager burn/take accounting.
    uint256 private constant MAX_POOLMANAGER_SETTLEMENT_AMOUNT = uint256(uint128(type(int128).max));

    /// @notice Delay for HookFee percent changes.
    uint64 public constant HOOK_FEE_PERCENT_CHANGE_DELAY = 48 hours;

    /// @notice Default minimum swap notional counted into period volume telemetry.
    uint64 public constant DEFAULT_MIN_COUNTED_SWAP_USD6 = 4_000_000;

    /// @notice Minimum allowed counted-swap threshold (USD6).
    uint64 public constant MIN_MIN_COUNTED_SWAP_USD6 = 1_000_000;

    /// @notice Maximum allowed counted-swap threshold (USD6).
    uint64 public constant MAX_MIN_COUNTED_SWAP_USD6 = 10_000_000;

    uint16 private constant MAX_LULL_PERIODS = 24;
    uint8 private constant MAX_EMA_PERIODS = 64;
    uint8 private constant MAX_HOLD_PERIODS = 31;
    uint8 private constant MAX_UP_EXTREME_STREAK = 3;
    uint8 private constant MAX_DOWN_STREAK = 7;
    uint8 private constant MAX_EMERGENCY_STREAK = 3;

    uint8 public constant REGIME_FLOOR = 0;
    uint8 public constant REGIME_CASH = 1;
    uint8 public constant REGIME_EXTREME = 2;

    // Period-close reason codes.
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

    // Packed-state layout.
    uint256 private constant PAUSED_BIT = 232;
    uint256 private constant HOLD_REMAINING_SHIFT = 233;
    uint256 private constant UP_EXTREME_STREAK_SHIFT = 238;
    uint256 private constant DOWN_STREAK_SHIFT = 240;
    uint256 private constant EMERGENCY_STREAK_SHIFT = 243;

    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    struct HookFeeClaimUnlockData {
        address recipient;
        uint256 amount0;
        uint256 amount1;
    }

    /// @notice Mutable controller and fee configuration.
    struct ControllerConfig {
        uint24 floorFee;
        uint24 cashFee;
        uint24 extremeFee;
        uint64 minCloseVolToCashUsd6;
        uint64 minCloseVolToExtremeUsd6;
        uint64 emergencyFloorCloseVolUsd6;
        uint64 minCountedSwapUsd6;
        uint32 periodSeconds;
        uint32 lullResetSeconds;
        uint16 upRToCashBps;
        uint16 upRToExtremeBps;
        uint16 downRFromExtremeBps;
        uint16 downRFromCashBps;
        uint16 deadbandBps;
        uint16 hookFeePercent;
        uint8 emaPeriods;
        uint8 cashHoldPeriods;
        uint8 upExtremeConfirmPeriods;
        uint8 extremeHoldPeriods;
        uint8 downExtremeConfirmPeriods;
        uint8 downCashConfirmPeriods;
        uint8 emergencyConfirmPeriods;
    }

    /// @notice Runtime state-machine parameters exposed as a grouped API.
    struct ControllerParams {
        uint64 minCloseVolToCashUsd6;
        uint16 upRToCashBps;
        // Configured hold length N; effective fully protected periods are N - 1 (N = 1 gives zero extra hold protection).
        uint8 cashHoldPeriods;
        uint64 minCloseVolToExtremeUsd6;
        uint16 upRToExtremeBps;
        uint8 upExtremeConfirmPeriods;
        // Same semantics as cash hold: configured N gives N - 1 fully protected periods.
        uint8 extremeHoldPeriods;
        uint16 downRFromExtremeBps;
        uint8 downExtremeConfirmPeriods;
        uint16 downRFromCashBps;
        uint8 downCashConfirmPeriods;
        uint64 emergencyFloorCloseVolUsd6;
        uint8 emergencyConfirmPeriods;
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when active LP fee tier changes.
    event FeeUpdated(uint24 newFee, uint8 newFeeIdx, uint64 closedVolumeUsd6, uint96 emaVolumeUsd6Scaled);

    /// @notice Emitted for each period-close transition.
    event PeriodClosed(
        uint24 fromFee,
        uint8 fromFeeIdx,
        uint24 toFee,
        uint8 toFeeIdx,
        uint64 closedVolumeUsd6,
        uint96 emaVolumeUsd6Scaled,
        uint64 approxLpFeesUsd6,
        uint8 reasonCode
    );

    /// @notice Emitted when the controller is paused in freeze mode.
    event Paused(uint24 fee, uint8 feeIdx);

    /// @notice Emitted when the controller is resumed from freeze mode.
    event Unpaused(uint24 fee, uint8 feeIdx);

    /// @notice Emitted when lull reset triggers due to inactivity.
    event LullReset(uint24 newFee, uint8 newFeeIdx);

    /// @notice Emitted when HookFee is accrued from a swap.
    event HookFeeAccrued(
        address indexed currency, uint256 amount, uint24 appliedLpFeeBips, uint16 hookFeePercent
    );

    /// @notice Emitted when accrued HookFees are claimed.
    event HookFeesClaimed(address indexed to, uint256 amount0, uint256 amount1);

    /// @notice Emitted when owner changes.
    event OwnerUpdated(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when owner transfer is proposed.
    event OwnerTransferStarted(address indexed currentOwner, address indexed pendingOwner);

    /// @notice Emitted when pending owner transfer is cancelled.
    event OwnerTransferCancelled(address indexed cancelledPendingOwner);

    /// @notice Emitted when pending owner accepts ownership.
    event OwnerTransferAccepted(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when explicit regime fees are updated.
    event RegimeFeesUpdated(uint24 floorFee, uint24 cashFee, uint24 extremeFee);

    /// @notice Emitted when core controller thresholds/confirm params are updated.
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

    /// @notice Emitted when timing and smoothing params are updated.
    event TimingParamsUpdated(
        uint32 periodSeconds, uint8 emaPeriods, uint32 lullResetSeconds, uint16 deadbandBps
    );

    /// @notice Emitted when a HookFee percent change is scheduled through timelock.
    event HookFeePercentChangeScheduled(uint16 newHookFeePercent, uint64 executeAfter);

    /// @notice Emitted when scheduled HookFee percent change is cancelled.
    event HookFeePercentChangeCancelled(uint16 cancelledHookFeePercent);

    /// @notice Emitted when HookFee percent is executed and applied.
    event HookFeePercentChanged(uint16 oldHookFeePercent, uint16 newHookFeePercent);

    /// @notice Emitted when min counted swap threshold update is scheduled.
    event MinCountedSwapUsd6ChangeScheduled(uint64 newMinCountedSwapUsd6);

    /// @notice Emitted when scheduled min counted swap threshold update is cancelled.
    event MinCountedSwapUsd6ChangeCancelled(uint64 cancelledMinCountedSwapUsd6);

    /// @notice Emitted when min counted swap threshold is applied.
    event MinCountedSwapUsd6Changed(uint64 oldMinCountedSwapUsd6, uint64 newMinCountedSwapUsd6);

    /// @notice Emitted when paused emergency reset sets controller to floor regime.
    event EmergencyResetToFloorApplied(uint8 feeIdx, uint64 periodStart, uint96 emaVolumeUsd6Scaled);

    /// @notice Emitted when paused emergency reset sets controller to cash regime.
    event EmergencyResetToCashApplied(uint8 feeIdx, uint64 periodStart, uint96 emaVolumeUsd6Scaled);

    /// @notice Emitted when non-pool assets or ETH are rescued.
    event RescueTransfer(address indexed currency, uint256 amount, address indexed recipient);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error InvalidPoolKey();
    error NotDynamicFeePool();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidConfig();
    error InvalidStableDecimals(uint8 stableDecimals);
    error InvalidHoldPeriods();
    error InvalidConfirmPeriods();
    error RequiresPaused();

    error NotOwner();
    error InvalidOwner();
    error PendingOwnerExists();
    error NoPendingOwnerTransfer();
    error NotPendingOwner();

    error InvalidRescueCurrency();
    error InvalidRecipient();
    error ClaimTooLarge();
    error EthTransferFailed();
    error EthReceiveRejected();
    error HookFeePercentLimitExceeded(uint16 requestedPercent, uint16 maxAllowedPercent);
    error PendingHookFeePercentChangeExists();
    error NoPendingHookFeePercentChange();
    error HookFeePercentChangeNotReady(uint64 executeAfter);

    error InvalidMinCountedSwapUsd6();
    error PendingMinCountedSwapUsd6ChangeExists();
    error NoPendingMinCountedSwapUsd6Change();

    error InvalidUnlockData();

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    ControllerConfig private _config;

    address private _owner;
    address private _pendingOwner;

    bool private _hasPendingHookFeePercentChange;
    uint16 private _pendingHookFeePercent;
    uint64 private _pendingHookFeePercentExecuteAfter;

    bool private _hasPendingMinCountedSwapUsd6Change;
    uint64 private _pendingMinCountedSwapUsd6;

    // Packed controller state.
    uint256 private _state;

    // HookFee accrual balances by pool currency order.
    uint256 private _hookFees0;
    uint256 private _hookFees1;

    // -----------------------------------------------------------------------
    // Immutable pool binding
    // -----------------------------------------------------------------------

    /// @notice Bound pool currency0.
    Currency public immutable poolCurrency0;

    /// @notice Bound pool currency1.
    Currency public immutable poolCurrency1;

    /// @notice Bound pool tick spacing.
    int24 public immutable poolTickSpacing;

    /// @notice Stable-side token used for USD6 volume telemetry.
    Currency public immutable stableCurrency;

    /// @notice Configured decimals mode for stable-side telemetry scaling.
    uint8 public immutable stableDecimals;

    bool internal immutable _stableIsCurrency0;
    uint64 internal immutable _stableScale;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @notice Deploys and configures a single-pool dynamic-fee hook.
    /// @param _poolManager Uniswap v4 PoolManager.
    /// @param _poolCurrency0 Pool currency0 (must be address-sorted and lower than currency1).
    /// @param _poolCurrency1 Pool currency1.
    /// @param _poolTickSpacing Pool tick spacing.
    /// @param _stableCurrency Stable-side token used for volume telemetry.
    /// @param stableDecimals_ Stable token decimals; only `6` or `18` are accepted.
    /// @param _floorFee Floor LP fee in hundredths of a bip.
    /// @param _cashFee Cash LP fee in hundredths of a bip.
    /// @param _extremeFee Extreme LP fee in hundredths of a bip.
    /// @param _periodSeconds Period length in seconds.
    /// @param _emaPeriods EMA denominator.
    /// @param _deadbandBps Deadband threshold in bps.
    /// @param _lullResetSeconds Lull-reset inactivity threshold in seconds. Must be strictly greater than `_periodSeconds`.
    /// @param ownerAddr Initial owner address.
    /// @param hookFeePercent_ Initial HookFee percent of LP fee.
    /// @param _minCloseVolToCashUsd6 Minimum close volume for floor->cash transition.
    /// @param _upRToCashBps Ratio threshold for floor->cash transition.
    /// @param _cashHoldPeriods Configured cash hold length `N` (effective fully protected periods are `N - 1`; `N = 1` gives zero extra hold protection).
    /// @param _minCloseVolToExtremeUsd6 Minimum close volume for cash->extreme transition.
    /// @param _upRToExtremeBps Ratio threshold for cash->extreme transition.
    /// @param _upExtremeConfirmPeriods Confirmation periods for cash->extreme transition.
    /// @param _extremeHoldPeriods Hold periods after entering extreme.
    /// @param _downRFromExtremeBps Ratio threshold for extreme->cash transition.
    /// @param _downExtremeConfirmPeriods Confirmation periods for extreme->cash transition.
    /// @param _downRFromCashBps Ratio threshold for cash->floor transition.
    /// @param _downCashConfirmPeriods Confirmation periods for cash->floor transition.
    /// @param _emergencyFloorCloseVolUsd6 Emergency floor trigger threshold (`> 0` and strictly below `_minCloseVolToCashUsd6`).
    /// @param _emergencyConfirmPeriods Consecutive confirmations for emergency floor trigger.
    constructor(
        IPoolManager _poolManager,
        Currency _poolCurrency0,
        Currency _poolCurrency1,
        int24 _poolTickSpacing,
        Currency _stableCurrency,
        uint8 stableDecimals_,
        uint24 _floorFee,
        uint24 _cashFee,
        uint24 _extremeFee,
        uint32 _periodSeconds,
        uint8 _emaPeriods,
        uint16 _deadbandBps,
        uint32 _lullResetSeconds,
        address ownerAddr,
        uint16 hookFeePercent_,
        uint64 _minCloseVolToCashUsd6,
        uint16 _upRToCashBps,
        uint8 _cashHoldPeriods,
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

        // Enforce canonical pool token ordering.
        if (Currency.unwrap(_poolCurrency0) >= Currency.unwrap(_poolCurrency1)) revert InvalidConfig();
        if (_poolTickSpacing <= 0) revert InvalidConfig();

        poolCurrency0 = _poolCurrency0;
        poolCurrency1 = _poolCurrency1;
        poolTickSpacing = _poolTickSpacing;

        if (!(_stableCurrency == _poolCurrency0) && !(_stableCurrency == _poolCurrency1)) {
            revert InvalidConfig();
        }
        stableCurrency = _stableCurrency;
        _stableIsCurrency0 = (_stableCurrency == _poolCurrency0);

        if (stableDecimals_ != 6 && stableDecimals_ != 18) {
            revert InvalidStableDecimals(stableDecimals_);
        }
        stableDecimals = stableDecimals_;

        if (stableDecimals_ == 6) _stableScale = 1;
        else _stableScale = 1_000_000_000_000;

        _setTimingParamsInternal(_periodSeconds, _emaPeriods, _lullResetSeconds, _deadbandBps);
        _setOwnerInternal(ownerAddr);
        _setHookFeePercentInternal(hookFeePercent_);
        _setRegimeFeesInternal(_floorFee, _cashFee, _extremeFee);

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

        _config.minCountedSwapUsd6 = DEFAULT_MIN_COUNTED_SWAP_USD6;

        emit OwnerUpdated(address(0), ownerAddr);
        emit HookFeePercentChanged(0, hookFeePercent_);
        emit RegimeFeesUpdated(_floorFee, _cashFee, _extremeFee);
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
        emit MinCountedSwapUsd6Changed(0, DEFAULT_MIN_COUNTED_SWAP_USD6);
    }

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    modifier whenPaused() {
        if (!isPaused()) revert RequiresPaused();
        _;
    }

    // -----------------------------------------------------------------------
    // Hook permissions
    // -----------------------------------------------------------------------

    /// @notice Declares required callback permissions for address flag mining.
    /// @return perms Hook permission flags expected from deployed hook address.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory perms) {
        perms.afterInitialize = true;
        perms.afterSwap = true;
        perms.afterSwapReturnDelta = true;
    }

    // -----------------------------------------------------------------------
    // Hook implementations
    // -----------------------------------------------------------------------

    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        _validateKey(key);

        (,, uint64 periodStart,,,,,,) = _unpackState(_state);
        if (periodStart != 0) revert AlreadyInitialized();

        uint64 nowTs = _now64();
        uint8 feeIdx = REGIME_FLOOR;

        _state = _packState(0, 0, nowTs, feeIdx, isPaused(), 0, 0, 0, 0);

        poolManager.updateDynamicLPFee(key, _regimeFee(feeIdx));
        emit FeeUpdated(_regimeFee(feeIdx), feeIdx, 0, 0);

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

        (
            uint64 periodVol,
            uint96 emaVolScaled,
            uint64 periodStart,
            uint8 feeIdx,
            bool paused_,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak
        ) = _unpackState(_state);

        if (periodStart == 0) revert NotInitialized();

        uint24 appliedFeeBips = _regimeFee(feeIdx);
        int128 hookFeeDelta = _accrueHookFeeAfterSwap(key, params, delta, appliedFeeBips);

        if (paused_) {
            return (IHooks.afterSwap.selector, hookFeeDelta);
        }

        uint64 nowTs = _now64();
        uint64 elapsed = nowTs - periodStart;
        bool feeChanged;
        uint64 closeVolForEvent;

        if (elapsed >= _config.lullResetSeconds) {
            uint8 oldFeeIdx = feeIdx;

            emaVolScaled = 0;
            feeIdx = REGIME_FLOOR;
            periodStart = nowTs;
            holdRemaining = 0;
            upExtremeStreak = 0;
            downStreak = 0;
            emergencyStreak = 0;

            _activatePendingMinCountedSwapUsd6();
            periodVol = _addSwapVolumeUsd6(0, delta);

            _state = _packState(
                periodVol,
                emaVolScaled,
                periodStart,
                feeIdx,
                paused_,
                holdRemaining,
                upExtremeStreak,
                downStreak,
                emergencyStreak
            );

            uint24 oldFee = _regimeFee(oldFeeIdx);
            uint24 newFee = _regimeFee(feeIdx);
            if (feeIdx != oldFeeIdx) {
                poolManager.updateDynamicLPFee(key, newFee);
                emit FeeUpdated(newFee, feeIdx, 0, 0);
            }

            emit PeriodClosed(oldFee, oldFeeIdx, newFee, feeIdx, 0, 0, 0, REASON_LULL_RESET);
            emit LullReset(newFee, feeIdx);
            return (IHooks.afterSwap.selector, hookFeeDelta);
        }

        if (elapsed >= _config.periodSeconds) {
            uint64 periods = elapsed / uint64(_config.periodSeconds);
            uint64 closeVol0 = periodVol;
            closeVolForEvent = closeVol0;

            uint8 oldFeeIdx = feeIdx;

            uint96 ema = emaVolScaled;
            uint8 f = feeIdx;
            uint8 hold = holdRemaining;
            uint8 upStreak = upExtremeStreak;
            uint8 down = downStreak;
            uint8 emergency = emergencyStreak;

            for (uint64 i = 0; i < periods; ++i) {
                uint64 closeVol = i == 0 ? closeVol0 : uint64(0);

                uint96 emaBefore = ema;
                ema = _updateEmaScaled(ema, closeVol);
                bool bootstrapV2 = emaBefore == 0 && closeVol > 0;

                uint8 fromFeeIdx = f;
                uint24 fromFee = _regimeFee(fromFeeIdx);
                (uint8 nf, uint8 nh, uint8 nu, uint8 nd, uint8 ne, uint8 reasonCode) =
                    _computeNextRegimeV2(f, closeVol, ema, bootstrapV2, hold, upStreak, down, emergency);
                f = nf;
                hold = nh;
                upStreak = nu;
                down = nd;
                emergency = ne;

                emit PeriodClosed(
                    fromFee,
                    fromFeeIdx,
                    _regimeFee(f),
                    f,
                    closeVol,
                    ema,
                    _estimateApproxLpFeesUsd6(closeVol, fromFee),
                    reasonCode
                );
            }

            emaVolScaled = ema;
            feeIdx = f;
            holdRemaining = hold;
            upExtremeStreak = upStreak;
            downStreak = down;
            emergencyStreak = emergency;
            feeChanged = feeIdx != oldFeeIdx;

            periodStart = periodStart + periods * uint64(_config.periodSeconds);

            periodVol = 0;
            _activatePendingMinCountedSwapUsd6();
        }

        periodVol = _addSwapVolumeUsd6(periodVol, delta);

        _state = _packState(
            periodVol,
            emaVolScaled,
            periodStart,
            feeIdx,
            paused_,
            holdRemaining,
            upExtremeStreak,
            downStreak,
            emergencyStreak
        );

        if (feeChanged) {
            uint24 activeFee = _regimeFee(feeIdx);
            poolManager.updateDynamicLPFee(key, activeFee);
            emit FeeUpdated(activeFee, feeIdx, closeVolForEvent, emaVolScaled);
        }

        return (IHooks.afterSwap.selector, hookFeeDelta);
    }

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    /// @notice Returns whether controller is paused.
    /// @dev Paused mode freezes regulator transitions only; swaps and HookFee accrual remain active.
    function isPaused() public view returns (bool) {
        return ((_state >> PAUSED_BIT) & 1) == 1;
    }

    /// @notice Returns currently active LP fee tier.
    function currentFeeBips() external view returns (uint24) {
        (,, uint64 periodStart, uint8 feeIdx,,,,,) = _unpackState(_state);
        if (periodStart == 0) revert NotInitialized();
        return _regimeFee(feeIdx);
    }

    /// @notice Returns packed runtime fields used by offchain telemetry.
    /// @return periodVolumeUsd6 Counted stable-side period volume in USD6.
    /// @return emaVolumeUsd6Scaled Scaled EMA in USD6 * 1e6.
    /// @return periodStart Current period start timestamp.
    /// @return feeIdx Active regime id (`0` floor, `1` cash, `2` extreme).
    function unpackedState()
        external
        view
        returns (uint64 periodVolumeUsd6, uint96 emaVolumeUsd6Scaled, uint64 periodStart, uint8 feeIdx)
    {
        (periodVolumeUsd6, emaVolumeUsd6Scaled, periodStart, feeIdx,,,,,) = _unpackState(_state);
    }

    /// @notice Returns currently active regime id (`0` floor, `1` cash, `2` extreme).
    function currentRegime() public view returns (uint8 regime) {
        (,, uint64 periodStart, uint8 feeIdx,,,,,) = _unpackState(_state);
        if (periodStart == 0) revert NotInitialized();
        regime = feeIdx;
    }

    /// @notice Returns floor LP fee.
    function floorFee() public view returns (uint24) {
        return _config.floorFee;
    }

    /// @notice Returns cash LP fee.
    function cashFee() public view returns (uint24) {
        return _config.cashFee;
    }

    /// @notice Returns extreme LP fee.
    function extremeFee() public view returns (uint24) {
        return _config.extremeFee;
    }

    /// @notice Returns threshold for floor->cash transition.
    function minCloseVolToCashUsd6() public view returns (uint64) {
        return _config.minCloseVolToCashUsd6;
    }

    /// @notice Returns ratio threshold for floor->cash transition.
    function upRToCashBps() public view returns (uint16) {
        return _config.upRToCashBps;
    }

    /// @notice Returns configured cash hold length `N` after entering cash regime.
    /// @dev Effective fully protected hold periods are `N - 1` because hold is decremented at period-close start.
    function cashHoldPeriods() public view returns (uint8) {
        return _config.cashHoldPeriods;
    }

    /// @notice Returns threshold for cash->extreme transition.
    function minCloseVolToExtremeUsd6() public view returns (uint64) {
        return _config.minCloseVolToExtremeUsd6;
    }

    /// @notice Returns ratio threshold for cash->extreme transition.
    function upRToExtremeBps() public view returns (uint16) {
        return _config.upRToExtremeBps;
    }

    /// @notice Returns confirmation periods for cash->extreme transition.
    function upExtremeConfirmPeriods() public view returns (uint8) {
        return _config.upExtremeConfirmPeriods;
    }

    /// @notice Returns hold periods after entering extreme regime.
    function extremeHoldPeriods() public view returns (uint8) {
        return _config.extremeHoldPeriods;
    }

    /// @notice Returns ratio threshold for extreme->cash transition.
    function downRFromExtremeBps() public view returns (uint16) {
        return _config.downRFromExtremeBps;
    }

    /// @notice Returns confirmation periods for extreme->cash transition.
    function downExtremeConfirmPeriods() public view returns (uint8) {
        return _config.downExtremeConfirmPeriods;
    }

    /// @notice Returns ratio threshold for cash->floor transition.
    function downRFromCashBps() public view returns (uint16) {
        return _config.downRFromCashBps;
    }

    /// @notice Returns confirmation periods for cash->floor transition.
    function downCashConfirmPeriods() public view returns (uint8) {
        return _config.downCashConfirmPeriods;
    }

    /// @notice Returns emergency floor volume threshold.
    function emergencyFloorCloseVolUsd6() public view returns (uint64) {
        return _config.emergencyFloorCloseVolUsd6;
    }

    /// @notice Returns emergency floor confirmation periods.
    function emergencyConfirmPeriods() public view returns (uint8) {
        return _config.emergencyConfirmPeriods;
    }

    /// @notice Returns period duration in seconds.
    function periodSeconds() public view returns (uint32) {
        return _config.periodSeconds;
    }

    /// @notice Returns EMA denominator.
    function emaPeriods() public view returns (uint8) {
        return _config.emaPeriods;
    }

    /// @notice Returns deadband threshold in bps.
    function deadbandBps() public view returns (uint16) {
        return _config.deadbandBps;
    }

    /// @notice Returns lull reset threshold in seconds.
    /// @dev This value is always strictly greater than `periodSeconds`.
    function lullResetSeconds() public view returns (uint32) {
        return _config.lullResetSeconds;
    }

    /// @notice Returns current owner address.
    function owner() public view returns (address) {
        return _owner;
    }

    /// @notice Returns pending owner address.
    function pendingOwner() public view returns (address) {
        return _pendingOwner;
    }

    /// @notice Returns current HookFee percent of LP fee.
    function hookFeePercent() public view returns (uint16) {
        return _config.hookFeePercent;
    }

    /// @notice Returns minimum swap notional counted into period volume telemetry.
    function minCountedSwapUsd6() public view returns (uint64) {
        return _config.minCountedSwapUsd6;
    }

    /// @notice Returns pending HookFee percent timelock data.
    function pendingHookFeePercentChange()
        external
        view
        returns (bool exists, uint16 nextValue, uint64 executeAfter)
    {
        return (_hasPendingHookFeePercentChange, _pendingHookFeePercent, _pendingHookFeePercentExecuteAfter);
    }

    /// @notice Returns pending min-counted-swap threshold update.
    /// @dev This update path is intentionally timelock-free and activates on next period boundary only.
    function pendingMinCountedSwapUsd6Change() external view returns (bool exists, uint64 nextValue) {
        return (_hasPendingMinCountedSwapUsd6Change, _pendingMinCountedSwapUsd6);
    }

    /// @notice Returns grouped controller transition params.
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

    /// @notice Returns explicit regime fees.
    function getRegimeFees() external view returns (uint24 floorFee_, uint24 cashFee_, uint24 extremeFee_) {
        floorFee_ = _config.floorFee;
        cashFee_ = _config.cashFee;
        extremeFee_ = _config.extremeFee;
    }

    /// @notice Returns detailed packed state counters for debugging and monitoring.
    /// @dev `downStreak` is context-dependent and must be interpreted together with current `feeIdx`:
    /// when `feeIdx==REGIME_CASH` it tracks cash->floor confirmations, and when `feeIdx==REGIME_EXTREME` it tracks
    /// extreme->cash confirmations.
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
            uint96 emaVolScaled,
            bool paused
        )
    {
        (
            periodVol,
            emaVolScaled,
            periodStart,
            feeIdx,
            paused,
            holdRemaining,
            upExtremeStreak,
            downStreak,
            emergencyStreak
        ) = _unpackState(_state);
    }

    /// @notice Returns accrued HookFee balances by pool currency order.
    function hookFeesAccrued() external view returns (uint256 token0, uint256 token1) {
        return (_hookFees0, _hookFees1);
    }

    // -----------------------------------------------------------------------
    // Admin and owner controls
    // -----------------------------------------------------------------------

    /// @notice Proposes a new owner address. Acceptance must be performed by pending owner.
    /// @dev Rejects zero address and current owner to avoid self-pending-owner traps.
    function proposeNewOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0) || newOwner == _owner) revert InvalidOwner();
        if (_pendingOwner != address(0)) revert PendingOwnerExists();
        _pendingOwner = newOwner;
        emit OwnerTransferStarted(_owner, newOwner);
    }

    /// @notice Cancels currently pending owner transfer.
    function cancelOwnerTransfer() external onlyOwner {
        address pending = _pendingOwner;
        if (pending == address(0)) revert NoPendingOwnerTransfer();
        _pendingOwner = address(0);
        emit OwnerTransferCancelled(pending);
    }

    /// @notice Accepts owner role by pending owner.
    function acceptOwner() external {
        address pending = _pendingOwner;
        if (msg.sender != pending) revert NotPendingOwner();

        address oldOwner = _owner;
        _pendingOwner = address(0);
        _owner = pending;

        emit OwnerTransferAccepted(oldOwner, pending);
        emit OwnerUpdated(oldOwner, pending);
    }

    /// @notice Schedules HookFee percent change through 48h timelock.
    function scheduleHookFeePercentChange(uint16 newHookFeePercent) external onlyOwner {
        if (_hasPendingHookFeePercentChange) revert PendingHookFeePercentChangeExists();
        _validateHookFeePercent(newHookFeePercent);

        uint64 executeAfter = _now64() + HOOK_FEE_PERCENT_CHANGE_DELAY;
        _hasPendingHookFeePercentChange = true;
        _pendingHookFeePercent = newHookFeePercent;
        _pendingHookFeePercentExecuteAfter = executeAfter;

        emit HookFeePercentChangeScheduled(newHookFeePercent, executeAfter);
    }

    /// @notice Cancels scheduled HookFee percent change.
    function cancelHookFeePercentChange() external onlyOwner {
        if (!_hasPendingHookFeePercentChange) revert NoPendingHookFeePercentChange();

        uint16 cancelled = _pendingHookFeePercent;
        _hasPendingHookFeePercentChange = false;
        _pendingHookFeePercent = 0;
        _pendingHookFeePercentExecuteAfter = 0;

        emit HookFeePercentChangeCancelled(cancelled);
    }

    /// @notice Executes scheduled HookFee percent change after timelock delay.
    function executeHookFeePercentChange() external onlyOwner {
        if (!_hasPendingHookFeePercentChange) revert NoPendingHookFeePercentChange();

        uint64 executeAfter = _pendingHookFeePercentExecuteAfter;
        if (_now64() < executeAfter) revert HookFeePercentChangeNotReady(executeAfter);

        uint16 oldValue = _config.hookFeePercent;
        uint16 newValue = _pendingHookFeePercent;

        _hasPendingHookFeePercentChange = false;
        _pendingHookFeePercent = 0;
        _pendingHookFeePercentExecuteAfter = 0;

        _setHookFeePercentInternal(newValue);
        emit HookFeePercentChanged(oldValue, newValue);
    }

    /// @notice Schedules a new minimum counted swap threshold.
    /// @dev Allowed range is `[1e6, 10e6]` in USD6 units.
    /// @dev New value is applied only at the next period boundary in `afterSwap`.
    /// @dev This path intentionally has no timelock; operations should use offchain recalibration discipline.
    function scheduleMinCountedSwapUsd6Change(uint64 newMinCountedSwapUsd6) external onlyOwner {
        if (_hasPendingMinCountedSwapUsd6Change) revert PendingMinCountedSwapUsd6ChangeExists();
        _validateMinCountedSwapUsd6(newMinCountedSwapUsd6);

        _hasPendingMinCountedSwapUsd6Change = true;
        _pendingMinCountedSwapUsd6 = newMinCountedSwapUsd6;

        emit MinCountedSwapUsd6ChangeScheduled(newMinCountedSwapUsd6);
    }

    /// @notice Cancels scheduled minimum counted swap threshold.
    function cancelMinCountedSwapUsd6Change() external onlyOwner {
        if (!_hasPendingMinCountedSwapUsd6Change) revert NoPendingMinCountedSwapUsd6Change();

        uint64 cancelled = _pendingMinCountedSwapUsd6;
        _hasPendingMinCountedSwapUsd6Change = false;
        _pendingMinCountedSwapUsd6 = 0;

        emit MinCountedSwapUsd6ChangeCancelled(cancelled);
    }

    /// @notice Updates explicit regime fees while paused.
    /// @dev Preserves EMA, always clears hold/streak counters, and starts a fresh open period.
    /// @dev Active regime id is preserved; if the active regime fee changes, LP fee is updated immediately.
    function setRegimeFees(uint24 floorFee_, uint24 cashFee_, uint24 extremeFee_)
        external
        onlyOwner
        whenPaused
    {
        (, uint96 emaVolScaled, uint64 periodStart, uint8 feeIdx, bool paused_,,,,) = _unpackState(_state);
        uint24 oldActiveFee = _regimeFee(feeIdx);

        _setRegimeFeesInternal(floorFee_, cashFee_, extremeFee_);
        emit RegimeFeesUpdated(floorFee_, cashFee_, extremeFee_);

        if (periodStart == 0) return;

        uint64 nextPeriodStart = _now64();
        _state = _packState(0, emaVolScaled, nextPeriodStart, feeIdx, paused_, 0, 0, 0, 0);

        uint24 newActiveFee = _regimeFee(feeIdx);
        if (newActiveFee != oldActiveFee) {
            poolManager.updateDynamicLPFee(_poolKey(), newActiveFee);
            emit FeeUpdated(newActiveFee, feeIdx, 0, emaVolScaled);
        }
    }

    /// @notice Updates controller transition parameters while paused.
    /// @dev Hold counters are decremented at the start of each closed period, so configured hold `N` yields `N - 1`
    /// fully protected periods (`N = 1` means zero extra hold protection).
    /// @dev Preserves active regime id and EMA, clears hold/streak counters, and starts a fresh open period.
    function setControllerParams(ControllerParams calldata p) external onlyOwner whenPaused {
        (, uint96 emaVolScaled, uint64 periodStart, uint8 feeIdx, bool paused_,,,,) = _unpackState(_state);

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

        if (periodStart == 0) return;

        _state = _packState(0, emaVolScaled, _now64(), feeIdx, paused_, 0, 0, 0, 0);
    }

    /// @notice Updates timing and smoothing parameters while paused.
    /// @dev Requires `lullResetSeconds_ > periodSeconds_`; equality is rejected.
    /// @dev Time-scale updates (`periodSeconds` or `emaPeriods`) perform a safe reset:
    /// floor regime, zero EMA/counters, fresh open period, and immediate LP fee sync when active tier changes.
    /// @dev Non-time-scale updates (only `lullResetSeconds` and/or `deadbandBps`) preserve regime and EMA/counters,
    /// and only restart a fresh open period.
    function setTimingParams(
        uint32 periodSeconds_,
        uint8 emaPeriods_,
        uint32 lullResetSeconds_,
        uint16 deadbandBps_
    ) external onlyOwner whenPaused {
        (
            ,
            uint96 emaVolScaled,
            uint64 periodStart,
            uint8 feeIdx,
            bool paused_,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak
        ) = _unpackState(_state);

        bool timeScaleChanged = periodSeconds_ != _config.periodSeconds || emaPeriods_ != _config.emaPeriods;
        uint24 oldActiveFee = _regimeFee(feeIdx);

        _setTimingParamsInternal(periodSeconds_, emaPeriods_, lullResetSeconds_, deadbandBps_);
        emit TimingParamsUpdated(periodSeconds_, emaPeriods_, lullResetSeconds_, deadbandBps_);

        if (periodStart == 0) return;

        if (timeScaleChanged) {
            feeIdx = REGIME_FLOOR;
            emaVolScaled = 0;
            holdRemaining = 0;
            upExtremeStreak = 0;
            downStreak = 0;
            emergencyStreak = 0;
        }

        _state = _packState(
            0,
            emaVolScaled,
            _now64(),
            feeIdx,
            paused_,
            holdRemaining,
            upExtremeStreak,
            downStreak,
            emergencyStreak
        );

        if (timeScaleChanged) {
            uint24 newActiveFee = _regimeFee(feeIdx);
            if (newActiveFee != oldActiveFee) {
                poolManager.updateDynamicLPFee(_poolKey(), newActiveFee);
                emit FeeUpdated(newActiveFee, feeIdx, 0, emaVolScaled);
            }
        }
    }

    /// @notice Enters paused freeze mode.
    /// @dev Keeps feeIdx, EMA and streak counters unchanged. Clears only open-period volume and restarts period clock.
    /// @dev Freezes regulator transitions at the last active LP fee tier.
    /// @dev Does not disable swaps and does not disable HookFee accrual/claim accounting.
    function pause() external onlyOwner {
        if (isPaused()) return;

        (
            ,
            uint96 emaVolScaled,
            uint64 periodStart,
            uint8 feeIdx,,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak
        ) = _unpackState(_state);

        uint64 nextPeriodStart = periodStart == 0 ? uint64(0) : _now64();
        _state = _packState(
            0,
            emaVolScaled,
            nextPeriodStart,
            feeIdx,
            true,
            holdRemaining,
            upExtremeStreak,
            downStreak,
            emergencyStreak
        );

        emit Paused(_regimeFee(feeIdx), feeIdx);
    }

    /// @notice Exits paused freeze mode.
    /// @dev Continues from the same fee regime and counters, with a fresh open period.
    /// @dev LP fee tier stays at the frozen value until normal transitions run after unpause.
    /// @dev Resuming does not retroactively alter HookFee accrual that happened while paused.
    function unpause() external onlyOwner {
        if (!isPaused()) return;

        (
            ,
            uint96 emaVolScaled,
            uint64 periodStart,
            uint8 feeIdx,,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak
        ) = _unpackState(_state);

        uint64 nextPeriodStart = periodStart == 0 ? uint64(0) : _now64();
        _state = _packState(
            0,
            emaVolScaled,
            nextPeriodStart,
            feeIdx,
            false,
            holdRemaining,
            upExtremeStreak,
            downStreak,
            emergencyStreak
        );

        emit Unpaused(_regimeFee(feeIdx), feeIdx);
    }

    /// @notice Emergency reset while paused to floor regime.
    /// @dev Clears EMA/counters (`emaVolumeUsd6Scaled`, hold/streak counters) and restarts open period state.
    /// @dev If the target fee index already matches current index, fee state still resets but no `FeeUpdated` is emitted.
    function emergencyResetToFloor() external onlyOwner whenPaused {
        _emergencyReset(REGIME_FLOOR, true);
    }

    /// @notice Emergency reset while paused to cash regime.
    /// @dev Clears EMA/counters (`emaVolumeUsd6Scaled`, hold/streak counters) and restarts open period state.
    /// @dev If the target fee index already matches current index, fee state still resets but no `FeeUpdated` is emitted.
    function emergencyResetToCash() external onlyOwner whenPaused {
        _emergencyReset(REGIME_CASH, false);
    }

    /// @notice Claims selected amounts of accrued HookFees.
    /// @dev `to` must equal current `owner()`.
    /// @dev Uses PoolManager accounting withdrawal flow (`unlock` -> `burn` -> `take`) to transfer funds to recipient.
    function claimHookFees(address to, uint256 amount0, uint256 amount1) external onlyOwner {
        _claimHookFeesInternal(to, amount0, amount1);
    }

    /// @notice Claims all accrued HookFees to current `owner()`.
    /// @dev Uses PoolManager accounting withdrawal flow (`unlock` -> `burn` -> `take`) to transfer funds to recipient.
    function claimAllHookFees() external onlyOwner {
        _claimHookFeesInternal(_owner, _hookFees0, _hookFees1);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Restricted to PoolManager and used only for HookFee claim settlement.
    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        HookFeeClaimUnlockData memory claimData = abi.decode(data, (HookFeeClaimUnlockData));
        if (claimData.recipient == address(0)) revert InvalidUnlockData();
        _withdrawHookFeeViaPoolManagerAccounting(claimData.recipient, claimData.amount0, claimData.amount1);
        return "";
    }

    /// @notice Rescues non-pool ERC20 balance from the hook contract.
    function rescueToken(Currency currency, uint256 amount) external onlyOwner {
        if (currency == poolCurrency0 || currency == poolCurrency1) revert InvalidRescueCurrency();

        currency.transfer(_owner, amount);
        emit RescueTransfer(Currency.unwrap(currency), amount, _owner);
    }

    /// @notice Rescues ETH balance from the hook contract to owner.
    function rescueETH(uint256 amount) external onlyOwner {
        if (amount > address(this).balance) revert ClaimTooLarge();

        (bool ok,) = payable(_owner).call{value: amount}("");
        if (!ok) revert EthTransferFailed();

        emit RescueTransfer(address(0), amount, _owner);
    }

    /// @notice Rejects direct ETH transfers.
    receive() external payable {
        revert EthReceiveRejected();
    }

    // -----------------------------------------------------------------------
    // Internal configuration helpers
    // -----------------------------------------------------------------------

    function _setOwnerInternal(address newOwner) internal {
        if (newOwner == address(0)) revert InvalidOwner();
        _owner = newOwner;
    }

    function _validateHookFeePercent(uint16 newHookFeePercent) internal pure {
        if (newHookFeePercent > MAX_HOOK_FEE_PERCENT) {
            revert HookFeePercentLimitExceeded(newHookFeePercent, MAX_HOOK_FEE_PERCENT);
        }
    }

    function _setHookFeePercentInternal(uint16 newHookFeePercent) internal {
        _validateHookFeePercent(newHookFeePercent);
        _config.hookFeePercent = newHookFeePercent;
    }

    /// @notice Validates telemetry dust-threshold bounds.
    /// @dev Allowed range is `[1e6, 10e6]` in USD6 units.
    function _validateMinCountedSwapUsd6(uint64 newMinCountedSwapUsd6) internal pure {
        if (
            newMinCountedSwapUsd6 < MIN_MIN_COUNTED_SWAP_USD6
                || newMinCountedSwapUsd6 > MAX_MIN_COUNTED_SWAP_USD6
        ) {
            revert InvalidMinCountedSwapUsd6();
        }
    }

    function _setTimingParamsInternal(
        uint32 periodSeconds_,
        uint8 emaPeriods_,
        uint32 lullResetSeconds_,
        uint16 deadbandBps_
    ) internal {
        if (periodSeconds_ == 0) revert InvalidConfig();
        if (emaPeriods_ < 2 || emaPeriods_ > MAX_EMA_PERIODS) revert InvalidConfig();
        if (deadbandBps_ > 5_000) revert InvalidConfig();
        if (lullResetSeconds_ <= periodSeconds_) revert InvalidConfig();
        if (uint256(lullResetSeconds_) > uint256(periodSeconds_) * MAX_LULL_PERIODS) revert InvalidConfig();
        if (_config.downRFromExtremeBps != 0 && _config.downRFromCashBps != 0) {
            _validateDeadbandVsDownThresholds(
                deadbandBps_, _config.downRFromExtremeBps, _config.downRFromCashBps
            );
        }

        _config.periodSeconds = periodSeconds_;
        _config.emaPeriods = emaPeriods_;
        _config.lullResetSeconds = lullResetSeconds_;
        _config.deadbandBps = deadbandBps_;
    }

    function _validateDeadbandVsDownThresholds(
        uint16 deadbandBps_,
        uint16 downRFromExtremeBps_,
        uint16 downRFromCashBps_
    ) internal pure {
        if (deadbandBps_ >= downRFromExtremeBps_ || deadbandBps_ >= downRFromCashBps_) {
            revert InvalidConfig();
        }
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
        // Emergency floor threshold at zero would force permanent trigger semantics.
        if (p.emergencyFloorCloseVolUsd6 == 0) revert InvalidConfig();
        // Cross-parameter consistency guards.
        if (p.emergencyFloorCloseVolUsd6 >= p.minCloseVolToCashUsd6) revert InvalidConfig();
        if (p.minCloseVolToCashUsd6 > p.minCloseVolToExtremeUsd6) revert InvalidConfig();
        if (p.upRToCashBps > p.upRToExtremeBps) revert InvalidConfig();
        if (p.downRFromCashBps < p.downRFromExtremeBps) revert InvalidConfig();
        _validateDeadbandVsDownThresholds(_config.deadbandBps, p.downRFromExtremeBps, p.downRFromCashBps);

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

    function _setRegimeFeesInternal(uint24 floorFee_, uint24 cashFee_, uint24 extremeFee_) internal {
        if (
            floorFee_ == 0 || floorFee_ >= cashFee_ || cashFee_ >= extremeFee_
                || extremeFee_ > LPFeeLibrary.MAX_LP_FEE
        ) {
            revert InvalidConfig();
        }
        _config.floorFee = floorFee_;
        _config.cashFee = cashFee_;
        _config.extremeFee = extremeFee_;
    }

    function _emergencyReset(uint8 targetFeeIdx, bool toFloor) internal {
        (,, uint64 periodStart, uint8 oldFeeIdx, bool paused_,,,,) = _unpackState(_state);

        if (periodStart == 0) revert NotInitialized();

        uint64 nowTs = _now64();
        _state = _packState(0, 0, nowTs, targetFeeIdx, paused_, 0, 0, 0, 0);

        if (oldFeeIdx != targetFeeIdx) {
            uint24 targetFee = _regimeFee(targetFeeIdx);
            poolManager.updateDynamicLPFee(_poolKey(), targetFee);
            emit FeeUpdated(targetFee, targetFeeIdx, 0, 0);
        }

        if (toFloor) {
            emit EmergencyResetToFloorApplied(targetFeeIdx, nowTs, 0);
        } else {
            emit EmergencyResetToCashApplied(targetFeeIdx, nowTs, 0);
        }
    }

    /// @notice Activates pending telemetry threshold update.
    /// @dev Called only on period rollover so threshold never changes mid-period.
    function _activatePendingMinCountedSwapUsd6() internal {
        if (!_hasPendingMinCountedSwapUsd6Change) return;

        uint64 oldValue = _config.minCountedSwapUsd6;
        uint64 newValue = _pendingMinCountedSwapUsd6;

        _hasPendingMinCountedSwapUsd6Change = false;
        _pendingMinCountedSwapUsd6 = 0;

        _config.minCountedSwapUsd6 = newValue;
        emit MinCountedSwapUsd6Changed(oldValue, newValue);
    }

    /// @notice Executes HookFee claim through PoolManager unlock callback flow.
    /// @dev Internal accounting is reduced before unlock; whole operation reverts atomically on failure.
    function _claimHookFeesInternal(address to, uint256 amount0, uint256 amount1) internal {
        if (to != _owner) revert InvalidRecipient();
        if (amount0 > _hookFees0 || amount1 > _hookFees1) revert ClaimTooLarge();
        if (amount0 == 0 && amount1 == 0) return;

        _hookFees0 -= amount0;
        _hookFees1 -= amount1;

        poolManager.unlock(
            abi.encode(HookFeeClaimUnlockData({recipient: to, amount0: amount0, amount1: amount1}))
        );
        emit HookFeesClaimed(to, amount0, amount1);
    }

    /// @notice Converts hook ERC6909 claims into ERC20/native payouts and sends funds to recipient.
    /// @dev Burn creates positive PoolManager delta for this hook; take withdraws the same amount to `to`.
    function _withdrawHookFeeViaPoolManagerAccounting(address to, uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) {
            _withdrawCurrencyClaim(poolCurrency0, to, amount0);
        }
        if (amount1 > 0) {
            _withdrawCurrencyClaim(poolCurrency1, to, amount1);
        }
    }

    function _withdrawCurrencyClaim(Currency currency, address to, uint256 amount) internal {
        while (amount > 0) {
            uint256 chunk = amount > MAX_POOLMANAGER_SETTLEMENT_AMOUNT ? MAX_POOLMANAGER_SETTLEMENT_AMOUNT : amount;
            poolManager.burn(address(this), currency.toId(), chunk);
            poolManager.take(currency, to, chunk);
            unchecked {
                amount -= chunk;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Internal hook helpers
    // -----------------------------------------------------------------------

    function _poolKey() internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: poolCurrency0,
            currency1: poolCurrency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(address(this))
        });
    }

    function _validateKey(PoolKey calldata key) internal view {
        if (
            !(key.currency0 == poolCurrency0) || !(key.currency1 == poolCurrency1)
                || key.tickSpacing != poolTickSpacing
        ) {
            revert InvalidPoolKey();
        }
        // Require exact dynamic-fee marker for the bound pool key.
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert NotDynamicFeePool();
        if (address(key.hooks) != address(this)) revert InvalidPoolKey();
    }

    function _now64() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _regimeFee(uint8 idx) internal view returns (uint24) {
        if (idx == REGIME_FLOOR) return _config.floorFee;
        if (idx == REGIME_CASH) return _config.cashFee;
        if (idx == REGIME_EXTREME) return _config.extremeFee;
        revert InvalidConfig();
    }

    /// @notice Accrues per-swap HookFee from an approximate LP-fee estimate.
    /// @dev Estimation uses the unspecified side selected by the current exact-input/exact-output execution path.
    /// @dev Small systematic deviations between exact-input and exact-output paths are expected by design.
    function _accrueHookFeeAfterSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint24 appliedFeeBips
    ) internal returns (int128 hookFeeDelta) {
        uint16 hookFeePct = _config.hookFeePercent;
        if (hookFeePct == 0) return 0;

        bool specifiedTokenIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency unspecifiedCurrency = specifiedTokenIs0 ? key.currency1 : key.currency0;
        int128 unspecifiedAmountSigned = specifiedTokenIs0 ? delta.amount1() : delta.amount0();

        uint256 absUnspecified = unspecifiedAmountSigned < 0
            ? uint256(-int256(unspecifiedAmountSigned))
            : uint256(uint128(unspecifiedAmountSigned));
        if (absUnspecified == 0) return 0;

        uint256 lpFeeAmount = (absUnspecified * uint256(appliedFeeBips)) / FEE_SCALE;
        uint256 hookFeeAmount = (lpFeeAmount * uint256(hookFeePct)) / 100;
        if (hookFeeAmount == 0) return 0;

        if (hookFeeAmount > uint256(uint128(type(int128).max))) {
            hookFeeAmount = uint256(uint128(type(int128).max));
        }

        if (unspecifiedCurrency == poolCurrency0) {
            _hookFees0 += hookFeeAmount;
        } else {
            _hookFees1 += hookFeeAmount;
        }

        // Persist claimable balance in PoolManager ERC6909 accounting during the same unlocked swap context.
        poolManager.mint(address(this), unspecifiedCurrency.toId(), hookFeeAmount);

        emit HookFeeAccrued(Currency.unwrap(unspecifiedCurrency), hookFeeAmount, appliedFeeBips, hookFeePct);

        return int128(uint128(hookFeeAmount));
    }

    function _addSwapVolumeUsd6(uint64 current, BalanceDelta delta) internal view returns (uint64) {
        int128 stableAmount = _stableIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 absStable = stableAmount < 0 ? uint256(-int256(stableAmount)) : uint256(uint128(stableAmount));

        uint256 usd6 = _toUsd6(absStable);
        if (usd6 < _config.minCountedSwapUsd6) {
            return current;
        }

        uint256 sum = uint256(current) + usd6;
        if (sum > type(uint64).max) return type(uint64).max;
        return uint64(sum);
    }

    function _toUsd6(uint256 stableAmount) internal view returns (uint256) {
        if (_stableScale == 1) return stableAmount;
        return stableAmount / _stableScale;
    }

    function _updateEmaScaled(uint96 emaScaled, uint64 closeVol) internal view returns (uint96) {
        if (emaScaled == 0) {
            if (closeVol == 0) return 0;
            uint256 seeded = uint256(closeVol) * EMA_SCALE;
            if (seeded > type(uint96).max) return type(uint96).max;
            return uint96(seeded);
        }

        uint256 n = uint256(_config.emaPeriods);
        uint256 updated = (uint256(emaScaled) * (n - 1) + uint256(closeVol) * EMA_SCALE) / n;
        if (updated > type(uint96).max) return type(uint96).max;
        return uint96(updated);
    }

    function _estimateApproxLpFeesUsd6(uint64 closeVol, uint24 feeBips) internal pure returns (uint64) {
        uint256 fees = (uint256(closeVol) * uint256(feeBips)) / FEE_SCALE;
        if (fees > type(uint64).max) return type(uint64).max;
        return uint64(fees);
    }

    function _incrementStreak(uint8 current, uint8 maxValue) internal pure returns (uint8) {
        return current < maxValue ? current + 1 : maxValue;
    }

    /// @notice Computes the next LP-fee regime and transition counters for a closed period.
    /// @dev Hold is decremented at period-close start, so configured hold `N` yields `N - 1` fully protected periods.
    /// @dev The automatic emergency floor trigger is evaluated before hold protection and can reset to `FLOOR`
    /// @dev even when `holdRemaining > 0` once `emergencyConfirmPeriods` consecutive closes stay below
    /// @dev `emergencyFloorCloseVolUsd6`.
    function _computeNextRegimeV2(
        uint8 feeIdx,
        uint64 closeVol,
        uint96 emaVolScaled,
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
            uint8 reasonCode
        )
    {
        newFeeIdx = feeIdx;
        newHoldRemaining = holdRemaining;
        newUpExtremeStreak = upExtremeStreak;
        newDownStreak = downStreak;
        newEmergencyStreak = emergencyStreak;
        reasonCode = closeVol == 0 ? REASON_NO_SWAPS : REASON_NO_CHANGE;

        // Hold counter is decremented before protection check; configured hold N gives N - 1 fully protected periods.
        if (newHoldRemaining > 0) {
            unchecked {
                newHoldRemaining -= 1;
            }
        }

        if (closeVol < _config.emergencyFloorCloseVolUsd6) {
            newEmergencyStreak = _incrementStreak(newEmergencyStreak, MAX_EMERGENCY_STREAK);
        } else {
            newEmergencyStreak = 0;
        }
        if (newEmergencyStreak >= _config.emergencyConfirmPeriods && newFeeIdx != REGIME_FLOOR) {
            newFeeIdx = REGIME_FLOOR;
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
                REASON_EMERGENCY_FLOOR
            );
        }

        uint256 rBps =
            emaVolScaled == 0 ? 0 : (uint256(closeVol) * EMA_SCALE * BPS_SCALE) / uint256(emaVolScaled);
        uint256 deadband = uint256(_config.deadbandBps);
        bool deadbandBlocked;

        if (newFeeIdx == REGIME_FLOOR) {
            uint256 cashThreshold = uint256(_config.upRToCashBps);
            bool upCashRaw = rBps >= cashThreshold;
            bool upCashPass = rBps >= cashThreshold + deadband;
            bool canJumpCash =
                !bootstrapV2 && emaVolScaled != 0 && closeVol >= _config.minCloseVolToCashUsd6 && upCashPass;
            if (
                !bootstrapV2 && emaVolScaled != 0 && closeVol >= _config.minCloseVolToCashUsd6 && upCashRaw
                    && !upCashPass
            ) {
                deadbandBlocked = true;
            }
            if (canJumpCash && newFeeIdx != REGIME_CASH) {
                newFeeIdx = REGIME_CASH;
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
                    REASON_JUMP_CASH
                );
            }
        }

        if (newFeeIdx == REGIME_CASH) {
            uint256 extremeThreshold = uint256(_config.upRToExtremeBps);
            bool upExtremeRaw =
                closeVol >= _config.minCloseVolToExtremeUsd6 && rBps >= extremeThreshold;
            bool upExtremePass = closeVol >= _config.minCloseVolToExtremeUsd6
                && rBps >= extremeThreshold + deadband;
            if (upExtremePass) {
                newUpExtremeStreak = _incrementStreak(newUpExtremeStreak, MAX_UP_EXTREME_STREAK);
            } else {
                if (
                    upExtremeRaw
                        && _incrementStreak(newUpExtremeStreak, MAX_UP_EXTREME_STREAK)
                            >= _config.upExtremeConfirmPeriods && !bootstrapV2 && newFeeIdx != REGIME_EXTREME
                ) {
                    deadbandBlocked = true;
                }
                newUpExtremeStreak = 0;
            }
            if (
                !bootstrapV2 && newUpExtremeStreak >= _config.upExtremeConfirmPeriods
                    && newFeeIdx != REGIME_EXTREME
            ) {
                newFeeIdx = REGIME_EXTREME;
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
                    REASON_JUMP_EXTREME
                );
            }
        } else {
            newUpExtremeStreak = 0;
        }

        if (newHoldRemaining > 0) {
            newDownStreak = 0;
            return
                (
                    newFeeIdx,
                    newHoldRemaining,
                    newUpExtremeStreak,
                    newDownStreak,
                    newEmergencyStreak,
                    REASON_HOLD
                );
        }

        if (newFeeIdx == REGIME_EXTREME) {
            uint256 downExtremeThreshold = uint256(_config.downRFromExtremeBps);
            uint256 downExtremePassThreshold = downExtremeThreshold - deadband;
            bool downExtremeRaw = rBps <= downExtremeThreshold;
            bool downExtremePass = rBps <= downExtremePassThreshold;
            if (downExtremePass) {
                newDownStreak = _incrementStreak(newDownStreak, MAX_DOWN_STREAK);
            } else {
                if (
                    downExtremeRaw
                        && _incrementStreak(newDownStreak, MAX_DOWN_STREAK)
                            >= _config.downExtremeConfirmPeriods && newFeeIdx != REGIME_CASH
                ) {
                    deadbandBlocked = true;
                }
                newDownStreak = 0;
            }
            if (newDownStreak >= _config.downExtremeConfirmPeriods) {
                newDownStreak = 0;
                if (newFeeIdx != REGIME_CASH) {
                    newFeeIdx = REGIME_CASH;
                    return (
                        newFeeIdx,
                        newHoldRemaining,
                        newUpExtremeStreak,
                        newDownStreak,
                        newEmergencyStreak,
                        REASON_DOWN_TO_CASH
                    );
                }
            }
        } else if (newFeeIdx == REGIME_CASH) {
            uint256 downCashThreshold = uint256(_config.downRFromCashBps);
            uint256 downCashPassThreshold = downCashThreshold - deadband;
            bool downCashRaw = rBps <= downCashThreshold;
            bool downCashPass = rBps <= downCashPassThreshold;
            if (downCashPass) {
                newDownStreak = _incrementStreak(newDownStreak, MAX_DOWN_STREAK);
            } else {
                if (
                    downCashRaw
                        && _incrementStreak(newDownStreak, MAX_DOWN_STREAK) >= _config.downCashConfirmPeriods
                        && newFeeIdx != REGIME_FLOOR
                ) {
                    deadbandBlocked = true;
                }
                newDownStreak = 0;
            }
            if (newDownStreak >= _config.downCashConfirmPeriods) {
                newDownStreak = 0;
                if (newFeeIdx != REGIME_FLOOR) {
                    newFeeIdx = REGIME_FLOOR;
                    return (
                        newFeeIdx,
                        newHoldRemaining,
                        newUpExtremeStreak,
                        newDownStreak,
                        newEmergencyStreak,
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

    // -----------------------------------------------------------------------
    // Bit packing
    // -----------------------------------------------------------------------

    function _packState(
        uint64 periodVol,
        uint96 emaVolScaled,
        uint64 periodStart,
        uint8 feeIdx,
        bool paused,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) internal pure returns (uint256 packed) {
        packed = uint256(periodVol);
        packed |= uint256(emaVolScaled) << 64;
        packed |= uint256(periodStart) << 160;
        packed |= uint256(feeIdx) << 224;
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
            uint96 emaVolScaled,
            uint64 periodStart,
            uint8 feeIdx,
            bool paused,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak
        )
    {
        periodVol = uint64(packed);
        emaVolScaled = uint96(packed >> 64);
        periodStart = uint64(packed >> 160);
        feeIdx = uint8(packed >> 224);

        paused = ((packed >> PAUSED_BIT) & 1) == 1;
        holdRemaining = uint8((packed >> HOLD_REMAINING_SHIFT) & 0x1F);
        upExtremeStreak = uint8((packed >> UP_EXTREME_STREAK_SHIFT) & 0x3);
        downStreak = uint8((packed >> DOWN_STREAK_SHIFT) & 0x7);
        emergencyStreak = uint8((packed >> EMERGENCY_STREAK_SHIFT) & 0x3);
    }
}
