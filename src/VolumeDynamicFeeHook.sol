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
import {
    BeforeSwapDelta,
    toBeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

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
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    // -----------------------------------------------------------------------
    // Fee tiers (hundredths of a bip). Example: 3000 = 0.30%
    // -----------------------------------------------------------------------
    uint256 private constant MAX_FEE_TIER_COUNT = 255;

    error InvalidFeeIndex();
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint16 public immutable feeTierCount;
    uint24[] private _feeTiersByIdx;

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
    uint8 public immutable floorIdx;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable capIdx;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable cashIdx;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable extremeIdx;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint64 public immutable minCloseVolToCashUsd6;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint16 public immutable upRToCashBps;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable cashHoldPeriods;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint64 public immutable minCloseVolToExtremeUsd6;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint16 public immutable upRToExtremeBps;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable upExtremeConfirmPeriods;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable extremeHoldPeriods;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint16 public immutable downRFromExtremeBps;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable downExtremeConfirmPeriods;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint16 public immutable downRFromCashBps;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable downCashConfirmPeriods;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint64 public immutable emergencyFloorCloseVolUsd6;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 public immutable emergencyConfirmPeriods;

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
    address public immutable creator;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint16 public immutable creatorFeeBps;

    // -----------------------------------------------------------------------
    // Packed state (ONE storage slot)
    // -----------------------------------------------------------------------
    uint256 private _state;
    uint256 private _creatorFees0;
    uint256 private _creatorFees1;

    uint8 private constant DIR_NONE = 0;

    // Period-close reason codes (for PeriodClosed event).
    uint8 public constant REASON_FEE_UP = 1;
    uint8 public constant REASON_FEE_DOWN = 2;
    uint8 public constant REASON_REVERSAL_LOCK = 3;
    uint8 public constant REASON_CAP = 4;
    uint8 public constant REASON_FLOOR = 5;
    uint8 public constant REASON_ZERO_EMA_DECAY = 6;
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
    uint8 public constant REASON_BOOTSTRAP_V2 = 17;

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
    event RescueTransfer(address indexed currency, uint256 amount, address indexed recipient);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error InvalidPoolKey();
    error NotDynamicFeePool();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidConfig();
    error NotGuardian();
    error NotCreator();
    error InvalidRescueCurrency();
    error InvalidRecipient();
    error ClaimTooLarge();
    error TierNotFound();
    error InvalidTierBounds();
    error InvalidHoldPeriods();
    error InvalidConfirmPeriods();

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
        address _guardian,
        address _creator,
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

        if (_periodSeconds == 0) revert InvalidConfig();
        periodSeconds = _periodSeconds;

        if (_emaPeriods < 2) revert InvalidConfig();
        if (_emaPeriods > MAX_EMA_PERIODS) revert InvalidConfig();
        emaPeriods = _emaPeriods;

        if (_deadbandBps > 5000) revert InvalidConfig();
        deadbandBps = _deadbandBps;

        if (_lullResetSeconds < _periodSeconds) revert InvalidConfig();
        if (uint256(_lullResetSeconds) > uint256(_periodSeconds) * MAX_LULL_PERIODS) revert InvalidConfig();
        lullResetSeconds = _lullResetSeconds;

        if (_guardian == address(0)) revert InvalidConfig();
        guardian = _guardian;
        if (_creator == address(0)) revert InvalidConfig();
        creator = _creator;

        if (_creatorFeeBps > 10_000) revert InvalidConfig();
        creatorFeeBps = _creatorFeeBps;

        uint256 tierCount = _feeTiers.length;
        if (tierCount == 0 || tierCount > MAX_FEE_TIER_COUNT) revert InvalidConfig();
        if (tierCount <= uint256(_floorIdx) || tierCount <= uint256(_capIdx)) {
            revert InvalidFeeIndex();
        }
        if (_floorIdx > _capIdx) revert InvalidConfig();
        feeTierCount = uint16(tierCount);

        uint24 prevTier;
        uint8 cashTierIdx_;
        uint8 extremeTierIdx_;
        bool cashTierFound;
        bool extremeTierFound;
        for (uint256 i = 0; i < tierCount; ++i) {
            uint24 tier = _feeTiers[i];
            if (tier == 0) revert InvalidConfig();
            if (i > 0 && tier <= prevTier) revert InvalidConfig();
            _feeTiersByIdx.push(tier);
            if (tier == _cashTier) {
                // forge-lint: disable-next-line(unsafe-typecast)
                cashTierIdx_ = uint8(i);
                cashTierFound = true;
            }
            if (tier == _extremeTier) {
                // forge-lint: disable-next-line(unsafe-typecast)
                extremeTierIdx_ = uint8(i);
                extremeTierFound = true;
            }
            prevTier = tier;
        }
        if (!cashTierFound || !extremeTierFound) revert TierNotFound();

        if (_floorIdx > cashTierIdx_ || cashTierIdx_ > extremeTierIdx_ || extremeTierIdx_ > _capIdx) {
            revert InvalidTierBounds();
        }

        if (_cashHoldPeriods == 0 || _cashHoldPeriods > MAX_HOLD_PERIODS) revert InvalidHoldPeriods();
        if (_extremeHoldPeriods == 0 || _extremeHoldPeriods > MAX_HOLD_PERIODS) revert InvalidHoldPeriods();
        if (_upExtremeConfirmPeriods == 0 || _upExtremeConfirmPeriods > MAX_UP_EXTREME_STREAK) {
            revert InvalidConfirmPeriods();
        }
        if (_downExtremeConfirmPeriods == 0 || _downExtremeConfirmPeriods > MAX_DOWN_STREAK) {
            revert InvalidConfirmPeriods();
        }
        if (_downCashConfirmPeriods == 0 || _downCashConfirmPeriods > MAX_DOWN_STREAK) {
            revert InvalidConfirmPeriods();
        }
        if (_emergencyConfirmPeriods == 0 || _emergencyConfirmPeriods > MAX_EMERGENCY_STREAK) {
            revert InvalidConfirmPeriods();
        }

        floorIdx = _floorIdx;
        capIdx = _capIdx;
        cashIdx = cashTierIdx_;
        extremeIdx = extremeTierIdx_;
        minCloseVolToCashUsd6 = _minCloseVolToCashUsd6;
        upRToCashBps = _upRToCashBps;
        cashHoldPeriods = _cashHoldPeriods;
        minCloseVolToExtremeUsd6 = _minCloseVolToExtremeUsd6;
        upRToExtremeBps = _upRToExtremeBps;
        upExtremeConfirmPeriods = _upExtremeConfirmPeriods;
        extremeHoldPeriods = _extremeHoldPeriods;
        downRFromExtremeBps = _downRFromExtremeBps;
        downExtremeConfirmPeriods = _downExtremeConfirmPeriods;
        downRFromCashBps = _downRFromCashBps;
        downCashConfirmPeriods = _downCashConfirmPeriods;
        emergencyFloorCloseVolUsd6 = _emergencyFloorCloseVolUsd6;
        emergencyConfirmPeriods = _emergencyConfirmPeriods;

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
        perms.beforeSwap = true;
        perms.beforeSwapReturnDelta = true;
        perms.afterSwap = true;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validateKey(key);
        if (isPaused() || creatorFeeBps == 0 || params.amountSpecified >= 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (,, uint64 periodStart, uint8 feeIdx,,,,,,) = _unpackState(_state);
        if (periodStart == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 creatorCut = _computeCreatorFee(amountIn, _feeTier(feeIdx));
        if (creatorCut == 0 || creatorCut >= amountIn) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 maxSpecifiedDelta = uint256(type(uint128).max >> 1);
        if (creatorCut > maxSpecifiedDelta) {
            creatorCut = maxSpecifiedDelta;
        }

        Currency specifiedCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        poolManager.take(specifiedCurrency, address(this), creatorCut);
        if (specifiedCurrency == poolCurrency0) {
            _creatorFees0 += creatorCut;
        } else {
            _creatorFees1 += creatorCut;
        }
        emit CreatorFeeAccrued(Currency.unwrap(specifiedCurrency), creatorCut, _feeTier(feeIdx));

        int128 specifiedDelta = int128(uint128(creatorCut));
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, 0), 0);
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

        uint8 feeIdx = floorIdx;

        _state = _packState(0, 0, nowTs, feeIdx, DIR_NONE, isPaused(), 0, 0, 0, 0);

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

        uint64 nowTs = _now64();
        uint64 elapsed = nowTs - periodStart;
        bool feeChanged;
        uint64 closeVolForEvent;

        if (elapsed >= lullResetSeconds) {
            uint8 oldFeeIdx = feeIdx;

            emaVol = 0;
            lastDir = DIR_NONE;
            feeIdx = floorIdx;
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

        if (elapsed >= periodSeconds) {
            uint64 periods = elapsed / uint64(periodSeconds);
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

            periodStart = nowTs;
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

    function creatorFeesAccrued() external view returns (uint256 token0, uint256 token1) {
        return (_creatorFees0, _creatorFees1);
    }

    function claimCreatorFees(address to, uint256 amount0, uint256 amount1) external {
        if (msg.sender != creator) revert NotCreator();
        if (to == address(0)) revert InvalidRecipient();
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

    function claimAllCreatorFees(address to) external {
        if (msg.sender != creator) revert NotCreator();
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

    function rescueToken(Currency currency, uint256 amount) external {
        if (msg.sender != guardian) revert NotGuardian();
        if (currency == poolCurrency0 || currency == poolCurrency1) revert InvalidRescueCurrency();

        currency.transfer(creator, amount);
        emit RescueTransfer(Currency.unwrap(currency), amount, creator);
    }

    // -----------------------------------------------------------------------
    // Guardian controls
    // -----------------------------------------------------------------------

    function pause() external {
        if (msg.sender != guardian) revert NotGuardian();
        if (isPaused()) return;

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
        bool initialized = periodStart != 0;

        // Reset state and force floor fee bucket.
        periodVol = 0;
        emaVol = 0;
        periodStart = initialized ? _now64() : uint64(0);
        feeIdx = floorIdx;
        lastDir = DIR_NONE;
        paused_ = true;
        holdRemaining = 0;
        upExtremeStreak = 0;
        downStreak = 0;
        emergencyStreak = 0;

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

        // Apply floor fee immediately for initialized pools.
        if (initialized) {
            poolManager.updateDynamicLPFee(_poolKey(), _feeTier(feeIdx));
            emit FeeUpdated(_feeTier(feeIdx), feeIdx, 0, 0);
        }

        emit Paused(_feeTier(floorIdx), floorIdx);
    }

    function unpause() external {
        if (msg.sender != guardian) revert NotGuardian();
        if (!isPaused()) return;

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
        bool initialized = periodStart != 0;

        // Reset state and return to floor fee bucket.
        periodVol = 0;
        emaVol = 0;
        periodStart = initialized ? _now64() : uint64(0);
        feeIdx = floorIdx;
        lastDir = DIR_NONE;
        paused_ = false;
        holdRemaining = 0;
        upExtremeStreak = 0;
        downStreak = 0;
        emergencyStreak = 0;

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

        // Apply floor fee immediately for initialized pools.
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

        uint256 n = uint256(emaPeriods);
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
        return (lpFeeAmount * uint256(creatorFeeBps)) / BPS_SCALE;
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
        reasonCode = closeVol == 0 ? REASON_NO_SWAPS : REASON_DEADBAND;

        // Rule 1: hold counter always decays first.
        if (newHoldRemaining > 0) {
            unchecked {
                newHoldRemaining -= 1;
            }
        }

        // Rule 2: emergency floor guard runs before all transitions.
        if (closeVol < emergencyFloorCloseVolUsd6) {
            newEmergencyStreak = _incrementStreak(newEmergencyStreak, MAX_EMERGENCY_STREAK);
        } else {
            newEmergencyStreak = 0;
        }
        if (newEmergencyStreak >= emergencyConfirmPeriods && newFeeIdx != floorIdx) {
            newFeeIdx = floorIdx;
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

        // Rule 3a: floor -> cash fast jump.
        if (newFeeIdx == floorIdx) {
            bool canJumpCash = !bootstrapV2 && emaVol != 0 && closeVol >= minCloseVolToCashUsd6
                && rBps >= uint256(upRToCashBps);
            if (canJumpCash && newFeeIdx != cashIdx) {
                newFeeIdx = cashIdx;
                newHoldRemaining = cashHoldPeriods;
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
        if (newFeeIdx == cashIdx) {
            if (closeVol >= minCloseVolToExtremeUsd6 && rBps >= uint256(upRToExtremeBps)) {
                newUpExtremeStreak = _incrementStreak(newUpExtremeStreak, MAX_UP_EXTREME_STREAK);
            } else {
                newUpExtremeStreak = 0;
            }
            if (!bootstrapV2 && newUpExtremeStreak >= upExtremeConfirmPeriods && newFeeIdx != extremeIdx) {
                newFeeIdx = extremeIdx;
                newHoldRemaining = extremeHoldPeriods;
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

        if (newFeeIdx == extremeIdx) {
            if (rBps <= uint256(downRFromExtremeBps)) {
                newDownStreak = _incrementStreak(newDownStreak, MAX_DOWN_STREAK);
            } else {
                newDownStreak = 0;
            }
            if (newDownStreak >= downExtremeConfirmPeriods) {
                newDownStreak = 0;
                if (newFeeIdx != cashIdx) {
                    newFeeIdx = cashIdx;
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
        } else if (newFeeIdx == cashIdx) {
            if (rBps <= uint256(downRFromCashBps)) {
                newDownStreak = _incrementStreak(newDownStreak, MAX_DOWN_STREAK);
            } else {
                newDownStreak = 0;
            }
            if (newDownStreak >= downCashConfirmPeriods) {
                newDownStreak = 0;
                if (newFeeIdx != floorIdx) {
                    newFeeIdx = floorIdx;
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

        if (bootstrapV2) {
            reasonCode = REASON_BOOTSTRAP_V2;
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
