// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "../utils/VolumeDynamicFeeHookV2DeployHelper.sol";

contract VolumeDynamicFeeHookAdminHarness is VolumeDynamicFeeHook {
    constructor(
        IPoolManager _poolManager,
        Currency _poolCurrency0,
        Currency _poolCurrency1,
        int24 _poolTickSpacing,
        Currency _stableCurrency,
        uint8 stableDecimals,
        uint24 _floorFee,
        uint24 _cashFee,
        uint24 _extremeFee,
        uint32 _periodSeconds,
        uint8 _emaPeriods,
        uint32 _lullResetSeconds,
        address ownerAddr,
        uint16 hookFeePercent,
        uint64 _floorToCashMinCloseVolume,
        uint16 _floorToCashMinFlowBps,
        uint8 _cashHoldPeriods,
        uint64 _cashToExtremeMinCloseVolume,
        uint16 _cashToExtremeMinFlowBps,
        uint8 _cashToExtremeConfirmPeriods,
        uint8 _extremeHoldPeriods,
        uint16 _extremeToCashMaxFlowBps,
        uint8 _extremeToCashConfirmPeriods,
        uint16 _cashToFloorMaxFlowBps,
        uint8 _cashToFloorConfirmPeriods,
        uint64 _emergencyToFloorMaxCloseVolume,
        uint8 _emergencyToFloorConfirmPeriods
    )
        VolumeDynamicFeeHook(
            _poolManager,
            _poolCurrency0,
            _poolCurrency1,
            _poolTickSpacing,
            _stableCurrency,
            stableDecimals,
            _floorFee,
            _cashFee,
            _extremeFee,
            _periodSeconds,
            _emaPeriods,
            _lullResetSeconds,
            ownerAddr,
            hookFeePercent,
            _floorToCashMinCloseVolume,
            _floorToCashMinFlowBps,
            _cashHoldPeriods,
            _cashToExtremeMinCloseVolume,
            _cashToExtremeMinFlowBps,
            _cashToExtremeConfirmPeriods,
            _extremeHoldPeriods,
            _extremeToCashMaxFlowBps,
            _extremeToCashConfirmPeriods,
            _cashToFloorMaxFlowBps,
            _cashToFloorConfirmPeriods,
            _emergencyToFloorMaxCloseVolume,
            _emergencyToFloorConfirmPeriods
        )
    {}

    function validateHookAddress(BaseHook) internal pure override {}

    function packStateHarness(
        uint64 periodVol,
        uint96 emaVolScaled,
        uint64 periodStart,
        uint8 feeIdx,
        bool paused,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) external pure returns (uint256) {
        return _packState(
            periodVol,
            emaVolScaled,
            periodStart,
            feeIdx,
            paused,
            holdRemaining,
            upExtremeStreak,
            downStreak,
            emergencyStreak
        );
    }

    function unpackStateHarness(uint256 packed)
        external
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
        return _unpackState(packed);
    }

    function packControllerTransitionCountersHarness(
        bool paused,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) external pure returns (uint16) {
        return _packControllerTransitionCounters(
            paused, holdRemaining, upExtremeStreak, downStreak, emergencyStreak
        );
    }
}

contract VolumeDynamicFeeHookAdminTest is Test, VolumeDynamicFeeHookV2DeployHelper {
    MockPoolManager internal manager;
    VolumeDynamicFeeHookAdminHarness internal hook;
    PoolKey internal key;

    address internal constant TOKEN0 = address(0x0000000000000000000000000000000000001111);
    address internal constant TOKEN1 = address(0x0000000000000000000000000000000000002222);

    address internal owner = address(this);
    address internal outsider = address(0xCAFE);
    address internal nextOwner = address(0xBEEF);

    uint32 internal constant PERIOD_SECONDS = 300;
    uint8 internal constant EMA_PERIODS = 8;
    uint32 internal constant LULL_RESET_SECONDS = 3600;
    uint64 internal constant USD6 = 1e6;
    uint64 internal constant LOW_NON_EMERGENCY_CLOSEVOL_USD6 = 150 * USD6;
    uint64 internal constant LOW_EMERGENCY_CLOSEVOL_USD6 = 50 * USD6;
    uint64 internal constant SEED_CLOSEVOL_USD6 = 10_000 * USD6;
    uint64 internal constant CASH_JUMP_CLOSEVOL_USD6 = 25_000 * USD6;
    uint64 internal constant EXTREME_STREAK1_CLOSEVOL_USD6 = 100_000 * USD6;
    uint64 internal constant EXTREME_STREAK2_CLOSEVOL_USD6 = 200_000 * USD6;
    uint256 internal constant EMA_SCALE = 1e6;
    uint8 internal constant MAX_EMA_PERIODS = 128;
    uint8 internal constant MAX_HOLD_PERIODS = 15;
    uint8 internal constant MAX_UP_EXTREME_CONFIRM_PERIODS = 7;
    uint8 internal constant MAX_DOWN_CONFIRM_PERIODS = 15;
    uint8 internal constant MAX_EMERGENCY_STREAK_LIMIT = 15;

    uint8 internal constant TRACE_COUNTER_HOLD_SHIFT = 1;
    uint8 internal constant TRACE_COUNTER_UP_EXTREME_SHIFT = 5;
    uint8 internal constant TRACE_COUNTER_DOWN_SHIFT = 8;
    uint8 internal constant TRACE_COUNTER_EMERGENCY_SHIFT = 12;
    uint256 internal constant PAUSED_BIT = 232;
    uint256 internal constant HOLD_REMAINING_SHIFT = 233;
    uint256 internal constant UP_EXTREME_STREAK_SHIFT = 237;
    uint256 internal constant DOWN_STREAK_SHIFT = 240;
    uint256 internal constant EMERGENCY_STREAK_SHIFT = 244;

    uint16 internal constant TRACE_FLAG_BOOTSTRAP_V2 = 0x0001;
    uint16 internal constant TRACE_FLAG_HOLD_WAS_ACTIVE = 0x0004;
    uint16 internal constant TRACE_FLAG_EMERGENCY_TRIGGERED = 0x0008;
    uint16 internal constant TRACE_FLAG_CASH_ENTER_TRIGGER = 0x0010;
    uint16 internal constant TRACE_FLAG_EXTREME_ENTER_TRIGGER = 0x0020;
    uint16 internal constant TRACE_FLAG_EXTREME_EXIT_TRIGGER = 0x0040;
    uint16 internal constant TRACE_FLAG_CASH_EXIT_TRIGGER = 0x0080;

    bytes32 internal constant CONTROLLER_TRANSITION_TRACE_TOPIC = keccak256(
        "ControllerTransitionTrace(uint64,uint24,uint8,uint24,uint8,uint64,uint96,uint96,uint64,uint16,uint16,uint16,uint8)"
    );
    bytes32 internal constant PERIOD_CLOSED_TOPIC =
        keccak256("PeriodClosed(uint24,uint8,uint24,uint8,uint64,uint96,uint64,uint8)");
    bytes32 internal constant FEE_UPDATED_TOPIC = keccak256("FeeUpdated(uint24,uint8,uint64,uint96)");
    bytes32 internal constant LULL_RESET_TOPIC = keccak256("LullReset(uint24,uint8)");

    struct ControllerTransitionTraceLog {
        uint64 periodStart;
        uint24 fromFee;
        uint8 fromFeeIdx;
        uint24 toFee;
        uint8 toFeeIdx;
        uint64 closeVolumeUsd6;
        uint96 emaBeforeUsd6Scaled;
        uint96 emaAfterUsd6Scaled;
        uint64 approxLpFeesUsd6;
        uint16 decisionFlags;
        uint16 countersBefore;
        uint16 countersAfter;
        uint8 reasonCode;
    }

    struct PeriodClosedLog {
        uint24 fromFee;
        uint8 fromFeeIdx;
        uint24 toFee;
        uint8 toFeeIdx;
        uint64 closedVolumeUsd6;
        uint96 emaVolumeUsd6Scaled;
        uint64 approxLpFeesUsd6;
        uint8 reasonCode;
    }

    struct FeeUpdatedLog {
        uint24 newFee;
        uint8 newFeeIdx;
        uint64 closedVolumeUsd6;
        uint96 emaVolumeUsd6Scaled;
    }

    struct SwapEventCapture {
        uint256 traceCount;
        uint256 periodClosedCount;
        uint256 feeUpdatedCount;
        uint256 lullResetCount;
        ControllerTransitionTraceLog lastTrace;
        PeriodClosedLog lastPeriodClosed;
        FeeUpdatedLog lastFeeUpdated;
    }

    function setUp() public {
        manager = new MockPoolManager();

        hook = _deployHarness(
            V2_DEFAULT_FLOOR_FEE,
            V2_DEFAULT_CASH_FEE,
            V2_DEFAULT_EXTREME_FEE,
            owner,
            V2_INITIAL_HOOK_FEE_PERCENT,
            6
        );
        key = _poolKey(address(hook));

        manager.callAfterInitialize(hook, key);
    }

    function _poolKey(address hookAddr) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(hookAddr)
        });
    }

    function _deployHarness(
        uint24 floorFee_,
        uint24 cashFee_,
        uint24 extremeFee_,
        address owner_,
        uint16 hookFeePercent_,
        uint8 stableDecimals
    ) internal returns (VolumeDynamicFeeHookAdminHarness h) {
        h = new VolumeDynamicFeeHookAdminHarness(
            IPoolManager(address(manager)),
            Currency.wrap(TOKEN0),
            Currency.wrap(TOKEN1),
            10,
            Currency.wrap(TOKEN0),
            stableDecimals,
            floorFee_,
            cashFee_,
            extremeFee_,
            PERIOD_SECONDS,
            EMA_PERIODS,
            LULL_RESET_SECONDS,
            owner_,
            hookFeePercent_,
            V2_FLOOR_TO_CASH_MIN_CLOSE_VOLUME,
            V2_FLOOR_TO_CASH_MIN_FLOW_BPS,
            V2_CASH_HOLD_PERIODS,
            V2_CASH_TO_EXTREME_MIN_CLOSE_VOLUME,
            V2_CASH_TO_EXTREME_MIN_FLOW_BPS,
            V2_CASH_TO_EXTREME_CONFIRM_PERIODS,
            V2_EXTREME_HOLD_PERIODS,
            V2_EXTREME_TO_CASH_MAX_FLOW_BPS,
            V2_EXTREME_TO_CASH_CONFIRM_PERIODS,
            V2_CASH_TO_FLOOR_MAX_FLOW_BPS,
            V2_CASH_TO_FLOOR_CONFIRM_PERIODS,
            V2_EMERGENCY_TO_FLOOR_MAX_CLOSE_VOLUME,
            V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS
        );
    }

    function _swap(bool zeroForOne, int256 amountSpecified, int128 amount0, int128 amount1) internal {
        SwapParams memory params =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0});
        BalanceDelta delta = toBalanceDelta(amount0, amount1);
        manager.callAfterSwapWithParams(hook, key, params, delta);
    }

    function _swapFor(
        VolumeDynamicFeeHookAdminHarness targetHook,
        PoolKey memory targetKey,
        bool zeroForOne,
        int256 amountSpecified,
        int128 amount0,
        int128 amount1
    ) internal {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(amount0, amount1);
        manager.callAfterSwapWithParams(targetHook, targetKey, params, delta);
    }

    function _moveToCashModeWithHold() internal {
        _swap(true, -1, -1_000_000_000, 900_000_000);
        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        _swap(true, -1, -2_300_000_000, 2_070_000_000);
        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (uint8 feeIdx, uint8 holdRemaining,,,,,,,) = hook.getStateDebug();
        assertEq(feeIdx, hook.MODE_CASH(), "precondition: active tier must be cash");
        assertGt(holdRemaining, 0, "precondition: cash hold must be active");
    }

    function _moveToCashWithPendingUpExtremeStreak() internal {
        _moveToCashModeWithHold();

        _swap(true, -1, -10_000_000_000, 9_000_000_000);
        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (uint8 feeIdx,, uint8 upExtremeStreak,,,,,,) = hook.getStateDebug();
        assertEq(feeIdx, hook.MODE_CASH(), "precondition: active tier must stay cash");
        assertEq(upExtremeStreak, 1, "precondition: one pending up streak expected");
    }

    function _defaultControllerParams()
        internal
        pure
        returns (VolumeDynamicFeeHook.ControllerParams memory p)
    {
        p = VolumeDynamicFeeHook.ControllerParams({
            floorToCashMinCloseVolume: V2_FLOOR_TO_CASH_MIN_CLOSE_VOLUME,
            floorToCashMinFlowBps: V2_FLOOR_TO_CASH_MIN_FLOW_BPS,
            cashHoldPeriods: V2_CASH_HOLD_PERIODS,
            cashToExtremeMinCloseVolume: V2_CASH_TO_EXTREME_MIN_CLOSE_VOLUME,
            cashToExtremeMinFlowBps: V2_CASH_TO_EXTREME_MIN_FLOW_BPS,
            cashToExtremeConfirmPeriods: V2_CASH_TO_EXTREME_CONFIRM_PERIODS,
            extremeHoldPeriods: V2_EXTREME_HOLD_PERIODS,
            extremeToCashMaxFlowBps: V2_EXTREME_TO_CASH_MAX_FLOW_BPS,
            extremeToCashConfirmPeriods: V2_EXTREME_TO_CASH_CONFIRM_PERIODS,
            cashToFloorMaxFlowBps: V2_CASH_TO_FLOOR_MAX_FLOW_BPS,
            cashToFloorConfirmPeriods: V2_CASH_TO_FLOOR_CONFIRM_PERIODS,
            emergencyToFloorMaxCloseVolume: V2_EMERGENCY_TO_FLOOR_MAX_CLOSE_VOLUME,
            emergencyToFloorConfirmPeriods: V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS
        });
    }

    function _asInt128(uint64 value) internal pure returns (int128) {
        return int128(int256(uint256(value)));
    }

    function _countedSwap(uint64 closeVolUsd6) internal {
        _swap(true, -1, -_asInt128(closeVolUsd6), 0);
    }

    function _closeCurrentPeriod() internal {
        _swap(true, -1, 0, 0);
    }

    function _closePeriodWithCountedVolume(uint64 closeVolUsd6) internal {
        _countedSwap(closeVolUsd6);
        _advanceOnePeriod();
        _closeCurrentPeriod();
    }

    function _advanceOnePeriod() internal {
        vm.warp(block.timestamp + PERIOD_SECONDS);
    }

    function _currentPeriodStart() internal view returns (uint64 periodStart_) {
        (,, periodStart_,) = hook.unpackedState();
    }

    function _captureCountedSwap(uint64 closeVolUsd6) internal returns (SwapEventCapture memory capture) {
        vm.recordLogs();
        _countedSwap(closeVolUsd6);
        capture = _decodeSwapEventCapture(vm.getRecordedLogs());
    }

    function _captureZeroSwap() internal returns (SwapEventCapture memory capture) {
        vm.recordLogs();
        _closeCurrentPeriod();
        capture = _decodeSwapEventCapture(vm.getRecordedLogs());
    }

    function _decodeSwapEventCapture(Vm.Log[] memory entries)
        internal
        pure
        returns (SwapEventCapture memory capture)
    {
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length == 0) continue;

            bytes32 topic0 = entries[i].topics[0];
            if (topic0 == CONTROLLER_TRANSITION_TRACE_TOPIC) {
                capture.traceCount += 1;
                (
                    uint64 periodStart_,
                    uint24 fromFee_,
                    uint8 fromFeeIdx_,
                    uint24 toFee_,
                    uint8 toFeeIdx_,
                    uint64 closeVolumeUsd6_,
                    uint96 emaBeforeUsd6Scaled_,
                    uint96 emaAfterUsd6Scaled_,
                    uint64 approxLpFeesUsd6_,
                    uint16 decisionFlags_,
                    uint16 countersBefore_,
                    uint16 countersAfter_,
                    uint8 reasonCode_
                ) = abi.decode(
                    entries[i].data,
                    (
                        uint64,
                        uint24,
                        uint8,
                        uint24,
                        uint8,
                        uint64,
                        uint96,
                        uint96,
                        uint64,
                        uint16,
                        uint16,
                        uint16,
                        uint8
                    )
                );
                capture.lastTrace = ControllerTransitionTraceLog({
                    periodStart: periodStart_,
                    fromFee: fromFee_,
                    fromFeeIdx: fromFeeIdx_,
                    toFee: toFee_,
                    toFeeIdx: toFeeIdx_,
                    closeVolumeUsd6: closeVolumeUsd6_,
                    emaBeforeUsd6Scaled: emaBeforeUsd6Scaled_,
                    emaAfterUsd6Scaled: emaAfterUsd6Scaled_,
                    approxLpFeesUsd6: approxLpFeesUsd6_,
                    decisionFlags: decisionFlags_,
                    countersBefore: countersBefore_,
                    countersAfter: countersAfter_,
                    reasonCode: reasonCode_
                });
                continue;
            }

            if (topic0 == PERIOD_CLOSED_TOPIC) {
                capture.periodClosedCount += 1;
                (
                    uint24 fromFee_,
                    uint8 fromFeeIdx_,
                    uint24 toFee_,
                    uint8 toFeeIdx_,
                    uint64 closedVolumeUsd6_,
                    uint96 emaVolumeUsd6Scaled_,
                    uint64 approxLpFeesUsd6_,
                    uint8 reasonCode_
                ) = abi.decode(entries[i].data, (uint24, uint8, uint24, uint8, uint64, uint96, uint64, uint8));
                capture.lastPeriodClosed = PeriodClosedLog({
                    fromFee: fromFee_,
                    fromFeeIdx: fromFeeIdx_,
                    toFee: toFee_,
                    toFeeIdx: toFeeIdx_,
                    closedVolumeUsd6: closedVolumeUsd6_,
                    emaVolumeUsd6Scaled: emaVolumeUsd6Scaled_,
                    approxLpFeesUsd6: approxLpFeesUsd6_,
                    reasonCode: reasonCode_
                });
                continue;
            }

            if (topic0 == FEE_UPDATED_TOPIC) {
                capture.feeUpdatedCount += 1;
                (uint24 newFee_, uint8 newFeeIdx_, uint64 closedVolumeUsd6_, uint96 emaVolumeUsd6Scaled_) =
                    abi.decode(entries[i].data, (uint24, uint8, uint64, uint96));
                capture.lastFeeUpdated = FeeUpdatedLog({
                    newFee: newFee_,
                    newFeeIdx: newFeeIdx_,
                    closedVolumeUsd6: closedVolumeUsd6_,
                    emaVolumeUsd6Scaled: emaVolumeUsd6Scaled_
                });
                continue;
            }

            if (topic0 == LULL_RESET_TOPIC) {
                capture.lullResetCount += 1;
            }
        }
    }

    function _expectedUpdatedEma(uint96 emaBefore, uint64 closeVolUsd6) internal pure returns (uint96) {
        if (emaBefore == 0) {
            if (closeVolUsd6 == 0) return 0;
            return uint96(uint256(closeVolUsd6) * EMA_SCALE);
        }

        return
            uint96((uint256(emaBefore) * (EMA_PERIODS - 1) + uint256(closeVolUsd6) * EMA_SCALE) / EMA_PERIODS);
    }

    function _expectedApproxLpFees(uint64 closeVolUsd6, uint24 feeBips) internal pure returns (uint64) {
        return uint64((uint256(closeVolUsd6) * uint256(feeBips)) / EMA_SCALE);
    }

    function _packTraceCounters(
        bool paused,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) internal pure returns (uint16 counters) {
        if (paused) counters |= 1;
        counters |= uint16(holdRemaining) << TRACE_COUNTER_HOLD_SHIFT;
        counters |= uint16(upExtremeStreak) << TRACE_COUNTER_UP_EXTREME_SHIFT;
        counters |= uint16(downStreak) << TRACE_COUNTER_DOWN_SHIFT;
        counters |= uint16(emergencyStreak) << TRACE_COUNTER_EMERGENCY_SHIFT;
    }

    function test_packState_supports_new_maximum_counter_values_without_truncation() public view {
        uint256 packed = hook.packStateHarness(
            11,
            22,
            33,
            hook.MODE_EXTREME(),
            true,
            MAX_HOLD_PERIODS,
            MAX_UP_EXTREME_CONFIRM_PERIODS,
            MAX_DOWN_CONFIRM_PERIODS,
            MAX_EMERGENCY_STREAK_LIMIT
        );

        assertEq((packed >> PAUSED_BIT) & 1, 1, "paused bit must stay at bit 232");
        assertEq((packed >> HOLD_REMAINING_SHIFT) & 0x0F, MAX_HOLD_PERIODS, "hold must use 4 bits");
        assertEq(
            (packed >> UP_EXTREME_STREAK_SHIFT) & 0x07,
            MAX_UP_EXTREME_CONFIRM_PERIODS,
            "up streak must use 3 bits"
        );
        assertEq((packed >> DOWN_STREAK_SHIFT) & 0x0F, MAX_DOWN_CONFIRM_PERIODS, "down streak must use 4 bits");
        assertEq(
            (packed >> EMERGENCY_STREAK_SHIFT) & 0x0F,
            MAX_EMERGENCY_STREAK_LIMIT,
            "emergency streak must use 4 bits"
        );
        assertEq(packed >> 248, 0, "packed counters must still fit inside the existing single state slot");

        (
            uint64 periodVol,
            uint96 emaVolScaled,
            uint64 periodStart,
            uint8 feeIdx,
            bool paused,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak
        ) = hook.unpackStateHarness(packed);

        assertEq(periodVol, 11);
        assertEq(emaVolScaled, 22);
        assertEq(periodStart, 33);
        assertEq(feeIdx, hook.MODE_EXTREME());
        assertTrue(paused);
        assertEq(holdRemaining, MAX_HOLD_PERIODS);
        assertEq(upExtremeStreak, MAX_UP_EXTREME_CONFIRM_PERIODS);
        assertEq(downStreak, MAX_DOWN_CONFIRM_PERIODS);
        assertEq(emergencyStreak, MAX_EMERGENCY_STREAK_LIMIT);
    }

    function test_packControllerTransitionCounters_supports_new_maximum_values_without_truncation() public view {
        uint16 counters = hook.packControllerTransitionCountersHarness(
            true,
            MAX_HOLD_PERIODS,
            MAX_UP_EXTREME_CONFIRM_PERIODS,
            MAX_DOWN_CONFIRM_PERIODS,
            MAX_EMERGENCY_STREAK_LIMIT
        );

        assertEq(counters & 1, 1, "paused flag must stay at bit 0");
        assertEq((counters >> TRACE_COUNTER_HOLD_SHIFT) & 0x0F, MAX_HOLD_PERIODS, "hold must use 4 bits");
        assertEq(
            (counters >> TRACE_COUNTER_UP_EXTREME_SHIFT) & 0x07,
            MAX_UP_EXTREME_CONFIRM_PERIODS,
            "up streak must use 3 bits"
        );
        assertEq(
            (counters >> TRACE_COUNTER_DOWN_SHIFT) & 0x0F,
            MAX_DOWN_CONFIRM_PERIODS,
            "down streak must use 4 bits"
        );
        assertEq(
            (counters >> TRACE_COUNTER_EMERGENCY_SHIFT) & 0x0F,
            MAX_EMERGENCY_STREAK_LIMIT,
            "emergency streak must use 4 bits"
        );
        assertEq(
            counters,
            uint16(
                1
                    | (uint16(MAX_HOLD_PERIODS) << TRACE_COUNTER_HOLD_SHIFT)
                    | (uint16(MAX_UP_EXTREME_CONFIRM_PERIODS) << TRACE_COUNTER_UP_EXTREME_SHIFT)
                    | (uint16(MAX_DOWN_CONFIRM_PERIODS) << TRACE_COUNTER_DOWN_SHIFT)
                    | (uint16(MAX_EMERGENCY_STREAK_LIMIT) << TRACE_COUNTER_EMERGENCY_SHIFT)
            ),
            "trace counters must still fit inside uint16"
        );
    }

    function _seedFloorEma() internal returns (uint96 emaSeed) {
        _countedSwap(SEED_CLOSEVOL_USD6);
        _advanceOnePeriod();
        _closeCurrentPeriod();
        emaSeed = _expectedUpdatedEma(0, SEED_CLOSEVOL_USD6);
    }

    function _enterCashMode() internal returns (uint96 emaCash) {
        uint96 emaSeed = _seedFloorEma();
        _countedSwap(CASH_JUMP_CLOSEVOL_USD6);
        _advanceOnePeriod();
        _closeCurrentPeriod();

        emaCash = _expectedUpdatedEma(emaSeed, CASH_JUMP_CLOSEVOL_USD6);

        (uint8 feeIdx, uint8 holdRemaining,,,,,,,) = hook.getStateDebug();
        assertEq(feeIdx, hook.MODE_CASH(), "precondition: active tier must be cash");
        assertEq(holdRemaining, hook.cashHoldPeriods(), "precondition: cash hold must be freshly set");
    }

    function test_controllerTransitionTrace_normal_close_without_transition() public {
        SwapEventCapture memory openCapture = _captureCountedSwap(SEED_CLOSEVOL_USD6);
        assertEq(openCapture.traceCount, 0, "trace must not emit on open-period swaps");
        assertEq(openCapture.periodClosedCount, 0, "PeriodClosed must not emit on open-period swaps");
        assertEq(openCapture.feeUpdatedCount, 0, "FeeUpdated must not emit on open-period swaps");
        assertEq(openCapture.lullResetCount, 0, "LullReset must not emit on open-period swaps");

        _advanceOnePeriod();
        _closeCurrentPeriod();

        uint96 emaBefore = _expectedUpdatedEma(0, SEED_CLOSEVOL_USD6);
        _countedSwap(SEED_CLOSEVOL_USD6);
        uint64 closedPeriodStart = _currentPeriodStart();

        _advanceOnePeriod();
        SwapEventCapture memory capture = _captureZeroSwap();

        uint96 emaAfter = _expectedUpdatedEma(emaBefore, SEED_CLOSEVOL_USD6);
        uint64 approxLpFees = _expectedApproxLpFees(SEED_CLOSEVOL_USD6, hook.floorFee());

        assertEq(capture.traceCount, 1, "trace must emit once on period close");
        assertEq(capture.periodClosedCount, 1, "PeriodClosed must still emit");
        assertEq(capture.feeUpdatedCount, 0, "FeeUpdated must not emit without transition");
        assertEq(capture.lullResetCount, 0, "LullReset must not emit on normal close");

        assertEq(capture.lastTrace.periodStart, closedPeriodStart);
        assertEq(capture.lastTrace.fromFee, hook.floorFee());
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_FLOOR());
        assertEq(capture.lastTrace.toFee, hook.floorFee());
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_FLOOR());
        assertEq(capture.lastTrace.closeVolumeUsd6, SEED_CLOSEVOL_USD6);
        assertEq(capture.lastTrace.emaBeforeUsd6Scaled, emaBefore);
        assertEq(capture.lastTrace.emaAfterUsd6Scaled, emaAfter);
        assertEq(capture.lastTrace.approxLpFeesUsd6, approxLpFees);
        assertEq(capture.lastTrace.decisionFlags, 0);
        assertEq(capture.lastTrace.countersBefore, _packTraceCounters(false, 0, 0, 0, 0));
        assertEq(capture.lastTrace.countersAfter, _packTraceCounters(false, 0, 0, 0, 0));
        assertEq(capture.lastTrace.reasonCode, hook.REASON_NO_CHANGE());

        assertEq(capture.lastPeriodClosed.fromFee, hook.floorFee());
        assertEq(capture.lastPeriodClosed.fromFeeIdx, hook.MODE_FLOOR());
        assertEq(capture.lastPeriodClosed.toFee, hook.floorFee());
        assertEq(capture.lastPeriodClosed.toFeeIdx, hook.MODE_FLOOR());
        assertEq(capture.lastPeriodClosed.closedVolumeUsd6, SEED_CLOSEVOL_USD6);
        assertEq(capture.lastPeriodClosed.emaVolumeUsd6Scaled, emaAfter);
        assertEq(capture.lastPeriodClosed.approxLpFeesUsd6, approxLpFees);
        assertEq(capture.lastPeriodClosed.reasonCode, hook.REASON_NO_CHANGE());

        assertEq(hook.currentMode(), hook.MODE_FLOOR(), "fee mode must stay floor");
        assertEq(manager.lastFee(), hook.floorFee(), "active fee must stay floor");
    }

    function test_controllerTransitionTrace_floor_to_cash() public {
        uint96 emaBefore = _seedFloorEma();
        _countedSwap(CASH_JUMP_CLOSEVOL_USD6);
        uint64 closedPeriodStart = _currentPeriodStart();

        _advanceOnePeriod();
        SwapEventCapture memory capture = _captureZeroSwap();

        uint96 emaAfter = _expectedUpdatedEma(emaBefore, CASH_JUMP_CLOSEVOL_USD6);
        uint64 approxLpFees = _expectedApproxLpFees(CASH_JUMP_CLOSEVOL_USD6, hook.floorFee());

        assertEq(capture.traceCount, 1, "trace must emit once on jump to cash");
        assertEq(capture.periodClosedCount, 1, "PeriodClosed must still emit");
        assertEq(capture.feeUpdatedCount, 1, "FeeUpdated must still emit on transition");
        assertEq(capture.lullResetCount, 0, "LullReset must not emit on normal close");

        assertEq(capture.lastTrace.periodStart, closedPeriodStart);
        assertEq(capture.lastTrace.fromFee, hook.floorFee());
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_FLOOR());
        assertEq(capture.lastTrace.toFee, hook.cashFee());
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_CASH());
        assertEq(capture.lastTrace.closeVolumeUsd6, CASH_JUMP_CLOSEVOL_USD6);
        assertEq(capture.lastTrace.emaBeforeUsd6Scaled, emaBefore);
        assertEq(capture.lastTrace.emaAfterUsd6Scaled, emaAfter);
        assertEq(capture.lastTrace.approxLpFeesUsd6, approxLpFees);
        assertEq(capture.lastTrace.decisionFlags, TRACE_FLAG_CASH_ENTER_TRIGGER);
        assertEq(capture.lastTrace.countersBefore, _packTraceCounters(false, 0, 0, 0, 0));
        assertEq(capture.lastTrace.countersAfter, _packTraceCounters(false, hook.cashHoldPeriods(), 0, 0, 0));
        assertEq(capture.lastTrace.reasonCode, hook.REASON_JUMP_CASH());

        assertEq(capture.lastPeriodClosed.fromFee, hook.floorFee());
        assertEq(capture.lastPeriodClosed.toFee, hook.cashFee());
        assertEq(capture.lastPeriodClosed.closedVolumeUsd6, CASH_JUMP_CLOSEVOL_USD6);
        assertEq(capture.lastPeriodClosed.emaVolumeUsd6Scaled, emaAfter);
        assertEq(capture.lastPeriodClosed.approxLpFeesUsd6, approxLpFees);
        assertEq(capture.lastPeriodClosed.reasonCode, hook.REASON_JUMP_CASH());

        assertEq(capture.lastFeeUpdated.newFee, hook.cashFee());
        assertEq(capture.lastFeeUpdated.newFeeIdx, hook.MODE_CASH());
        assertEq(capture.lastFeeUpdated.closedVolumeUsd6, CASH_JUMP_CLOSEVOL_USD6);
        assertEq(capture.lastFeeUpdated.emaVolumeUsd6Scaled, emaAfter);

        assertEq(hook.currentMode(), hook.MODE_CASH(), "fee mode must jump to cash");
        assertEq(manager.lastFee(), hook.cashFee(), "active fee must update to cash");
    }

    function test_controllerTransitionTrace_cash_to_extreme() public {
        uint96 emaCash = _enterCashMode();

        _countedSwap(EXTREME_STREAK1_CLOSEVOL_USD6);
        _advanceOnePeriod();
        _closeCurrentPeriod();

        uint96 emaBefore = _expectedUpdatedEma(emaCash, EXTREME_STREAK1_CLOSEVOL_USD6);
        _countedSwap(EXTREME_STREAK2_CLOSEVOL_USD6);
        uint64 closedPeriodStart = _currentPeriodStart();

        _advanceOnePeriod();
        SwapEventCapture memory capture = _captureZeroSwap();

        uint96 emaAfter = _expectedUpdatedEma(emaBefore, EXTREME_STREAK2_CLOSEVOL_USD6);
        uint64 approxLpFees = _expectedApproxLpFees(EXTREME_STREAK2_CLOSEVOL_USD6, hook.cashFee());

        assertEq(capture.traceCount, 1, "trace must emit once on jump to extreme");
        assertEq(capture.periodClosedCount, 1, "PeriodClosed must still emit");
        assertEq(capture.feeUpdatedCount, 1, "FeeUpdated must still emit on transition");
        assertEq(capture.lullResetCount, 0, "LullReset must not emit on normal close");

        assertEq(capture.lastTrace.periodStart, closedPeriodStart);
        assertEq(capture.lastTrace.fromFee, hook.cashFee());
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_CASH());
        assertEq(capture.lastTrace.toFee, hook.extremeFee());
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_EXTREME());
        assertEq(capture.lastTrace.closeVolumeUsd6, EXTREME_STREAK2_CLOSEVOL_USD6);
        assertEq(capture.lastTrace.emaBeforeUsd6Scaled, emaBefore);
        assertEq(capture.lastTrace.emaAfterUsd6Scaled, emaAfter);
        assertEq(capture.lastTrace.approxLpFeesUsd6, approxLpFees);
        assertEq(capture.lastTrace.decisionFlags, TRACE_FLAG_HOLD_WAS_ACTIVE | TRACE_FLAG_EXTREME_ENTER_TRIGGER);
        assertEq(capture.lastTrace.countersBefore, _packTraceCounters(false, 1, 1, 0, 0));
        assertEq(
            capture.lastTrace.countersAfter, _packTraceCounters(false, hook.extremeHoldPeriods(), 0, 0, 0)
        );
        assertEq(capture.lastTrace.reasonCode, hook.REASON_JUMP_EXTREME());

        assertEq(capture.lastPeriodClosed.fromFee, hook.cashFee());
        assertEq(capture.lastPeriodClosed.toFee, hook.extremeFee());
        assertEq(capture.lastPeriodClosed.closedVolumeUsd6, EXTREME_STREAK2_CLOSEVOL_USD6);
        assertEq(capture.lastPeriodClosed.emaVolumeUsd6Scaled, emaAfter);
        assertEq(capture.lastPeriodClosed.approxLpFeesUsd6, approxLpFees);
        assertEq(capture.lastPeriodClosed.reasonCode, hook.REASON_JUMP_EXTREME());

        assertEq(capture.lastFeeUpdated.newFee, hook.extremeFee());
        assertEq(capture.lastFeeUpdated.newFeeIdx, hook.MODE_EXTREME());
        assertEq(capture.lastFeeUpdated.closedVolumeUsd6, EXTREME_STREAK2_CLOSEVOL_USD6);
        assertEq(capture.lastFeeUpdated.emaVolumeUsd6Scaled, emaAfter);

        assertEq(hook.currentMode(), hook.MODE_EXTREME(), "fee mode must jump to extreme");
        assertEq(manager.lastFee(), hook.extremeFee(), "active fee must update to extreme");
    }

    function test_controllerTransitionTrace_hold_blocked_close() public {
        uint96 emaBefore = _enterCashMode();
        uint64 closedPeriodStart = _currentPeriodStart();

        _advanceOnePeriod();
        SwapEventCapture memory capture = _captureZeroSwap();

        uint96 emaAfter = _expectedUpdatedEma(emaBefore, 0);

        assertEq(capture.traceCount, 1, "trace must emit once on hold-blocked close");
        assertEq(capture.periodClosedCount, 1, "PeriodClosed must still emit");
        assertEq(capture.feeUpdatedCount, 0, "FeeUpdated must not emit when hold keeps cash");
        assertEq(capture.lullResetCount, 0, "LullReset must not emit on normal close");

        assertEq(capture.lastTrace.periodStart, closedPeriodStart);
        assertEq(capture.lastTrace.fromFee, hook.cashFee());
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_CASH());
        assertEq(capture.lastTrace.toFee, hook.cashFee());
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_CASH());
        assertEq(capture.lastTrace.closeVolumeUsd6, 0);
        assertEq(capture.lastTrace.emaBeforeUsd6Scaled, emaBefore);
        assertEq(capture.lastTrace.emaAfterUsd6Scaled, emaAfter);
        assertEq(capture.lastTrace.approxLpFeesUsd6, 0);
        assertEq(capture.lastTrace.decisionFlags, TRACE_FLAG_HOLD_WAS_ACTIVE | TRACE_FLAG_CASH_EXIT_TRIGGER);
        assertEq(capture.lastTrace.countersBefore, _packTraceCounters(false, hook.cashHoldPeriods(), 0, 0, 0));
        assertEq(capture.lastTrace.countersAfter, _packTraceCounters(false, 1, 0, 0, 1));
        assertEq(capture.lastTrace.reasonCode, hook.REASON_HOLD());

        assertEq(capture.lastPeriodClosed.fromFee, hook.cashFee());
        assertEq(capture.lastPeriodClosed.toFee, hook.cashFee());
        assertEq(capture.lastPeriodClosed.closedVolumeUsd6, 0);
        assertEq(capture.lastPeriodClosed.emaVolumeUsd6Scaled, emaAfter);
        assertEq(capture.lastPeriodClosed.approxLpFeesUsd6, 0);
        assertEq(capture.lastPeriodClosed.reasonCode, hook.REASON_HOLD());

        assertEq(hook.currentMode(), hook.MODE_CASH(), "fee mode must stay cash under hold");
        assertEq(manager.lastFee(), hook.cashFee(), "active fee must stay cash");
    }

    function test_controllerTransitionTrace_emergency_floor_transition() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.cashToFloorConfirmPeriods = MAX_DOWN_CONFIRM_PERIODS;
        hook.setControllerParams(p);
        hook.unpause();

        uint96 emaBefore = _enterCashMode();

        for (uint256 i = 1; i < V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS; ++i) {
            _advanceOnePeriod();
            _closeCurrentPeriod();
            emaBefore = _expectedUpdatedEma(emaBefore, 0);
        }

        uint64 closedPeriodStart = _currentPeriodStart();

        _advanceOnePeriod();
        SwapEventCapture memory capture = _captureZeroSwap();

        uint96 emaAfter = _expectedUpdatedEma(emaBefore, 0);

        assertEq(capture.traceCount, 1, "trace must emit once on emergency floor transition");
        assertEq(capture.periodClosedCount, 1, "PeriodClosed must still emit");
        assertEq(capture.feeUpdatedCount, 1, "FeeUpdated must still emit on emergency floor");
        assertEq(capture.lullResetCount, 0, "LullReset must not emit on normal close");

        assertEq(capture.lastTrace.periodStart, closedPeriodStart);
        assertEq(capture.lastTrace.fromFee, hook.cashFee());
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_CASH());
        assertEq(capture.lastTrace.toFee, hook.floorFee());
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_FLOOR());
        assertEq(capture.lastTrace.closeVolumeUsd6, 0);
        assertEq(capture.lastTrace.emaBeforeUsd6Scaled, emaBefore);
        assertEq(capture.lastTrace.emaAfterUsd6Scaled, emaAfter);
        assertEq(capture.lastTrace.approxLpFeesUsd6, 0);
        assertEq(capture.lastTrace.decisionFlags, TRACE_FLAG_EMERGENCY_TRIGGERED);
        assertEq(capture.lastTrace.countersBefore, _packTraceCounters(false, 0, 0, 4, 5));
        assertEq(capture.lastTrace.countersAfter, _packTraceCounters(false, 0, 0, 0, 0));
        assertEq(capture.lastTrace.reasonCode, hook.REASON_EMERGENCY_FLOOR());

        assertEq(capture.lastPeriodClosed.fromFee, hook.cashFee());
        assertEq(capture.lastPeriodClosed.toFee, hook.floorFee());
        assertEq(capture.lastPeriodClosed.closedVolumeUsd6, 0);
        assertEq(capture.lastPeriodClosed.emaVolumeUsd6Scaled, emaAfter);
        assertEq(capture.lastPeriodClosed.approxLpFeesUsd6, 0);
        assertEq(capture.lastPeriodClosed.reasonCode, hook.REASON_EMERGENCY_FLOOR());

        assertEq(capture.lastFeeUpdated.newFee, hook.floorFee());
        assertEq(capture.lastFeeUpdated.newFeeIdx, hook.MODE_FLOOR());
        assertEq(capture.lastFeeUpdated.closedVolumeUsd6, 0);
        assertEq(capture.lastFeeUpdated.emaVolumeUsd6Scaled, emaAfter);

        assertEq(hook.currentMode(), hook.MODE_FLOOR(), "fee mode must reset to floor");
        assertEq(manager.lastFee(), hook.floorFee(), "active fee must update to floor");
    }

    function test_controllerTransitionTrace_catchUp_emergency_floor_triggers_mid_loop() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.extremeToCashConfirmPeriods = MAX_DOWN_CONFIRM_PERIODS;
        p.cashToFloorConfirmPeriods = MAX_DOWN_CONFIRM_PERIODS;
        hook.setControllerParams(p);
        hook.unpause();

        _enterCashMode();

        _countedSwap(EXTREME_STREAK1_CLOSEVOL_USD6);
        _advanceOnePeriod();
        _closeCurrentPeriod();

        _countedSwap(EXTREME_STREAK2_CLOSEVOL_USD6);
        _advanceOnePeriod();
        _closeCurrentPeriod();

        (uint8 feeIdxBeforeCatchUp, uint8 holdBeforeCatchUp,,,, uint64 periodStartBeforeCatchUp,,,) =
            hook.getStateDebug();
        assertEq(feeIdxBeforeCatchUp, hook.MODE_EXTREME(), "precondition: active tier must be extreme");
        assertEq(
            holdBeforeCatchUp,
            hook.extremeHoldPeriods(),
            "precondition: extreme hold must be freshly set before catch-up"
        );

        vm.warp(block.timestamp + PERIOD_SECONDS * V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS);
        vm.recordLogs();
        _closeCurrentPeriod();
        SwapEventCapture memory capture = _decodeSwapEventCapture(vm.getRecordedLogs());

        assertEq(
            capture.traceCount,
            V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS,
            "catch-up should emit one trace per closed overdue period"
        );
        assertEq(
            capture.periodClosedCount,
            V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS,
            "catch-up should emit PeriodClosed for each overdue period"
        );
        assertEq(capture.feeUpdatedCount, 1, "emergency floor should sync LP fee once after catch-up");
        assertEq(capture.lullResetCount, 0, "catch-up below lull reset must not emit LullReset");

        assertEq(
            capture.lastTrace.periodStart,
            periodStartBeforeCatchUp + uint64(PERIOD_SECONDS * (V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS - 1))
        );
        assertEq(capture.lastTrace.fromFee, hook.extremeFee());
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_EXTREME());
        assertEq(capture.lastTrace.toFee, hook.floorFee());
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_FLOOR());
        assertEq(capture.lastTrace.closeVolumeUsd6, 0);
        assertEq(capture.lastTrace.approxLpFeesUsd6, 0);
        assertEq(capture.lastTrace.decisionFlags, TRACE_FLAG_EMERGENCY_TRIGGERED);
        assertEq(capture.lastTrace.countersBefore, _packTraceCounters(false, 0, 0, 4, 5));
        assertEq(capture.lastTrace.countersAfter, _packTraceCounters(false, 0, 0, 0, 0));
        assertEq(capture.lastTrace.reasonCode, hook.REASON_EMERGENCY_FLOOR());

        assertEq(capture.lastPeriodClosed.fromFee, hook.extremeFee());
        assertEq(capture.lastPeriodClosed.toFee, hook.floorFee());
        assertEq(capture.lastPeriodClosed.closedVolumeUsd6, 0);
        assertEq(capture.lastPeriodClosed.approxLpFeesUsd6, 0);
        assertEq(capture.lastPeriodClosed.reasonCode, hook.REASON_EMERGENCY_FLOOR());

        (
            uint8 feeIdxAfterCatchUp,
            uint8 holdAfterCatchUp,
            uint8 upAfterCatchUp,
            uint8 downAfterCatchUp,
            uint8 emergencyAfterCatchUp,
            uint64 periodStartAfterCatchUp,,,
        ) = hook.getStateDebug();
        assertEq(feeIdxAfterCatchUp, hook.MODE_FLOOR(), "emergency floor should win inside catch-up loop");
        assertEq(holdAfterCatchUp, 0, "hold must be cleared after emergency floor reset");
        assertEq(upAfterCatchUp, 0, "up streak must reset after emergency floor");
        assertEq(downAfterCatchUp, 0, "down streak must reset after emergency floor");
        assertEq(emergencyAfterCatchUp, 0, "emergency streak must reset after trigger");
        assertEq(
            periodStartAfterCatchUp,
            periodStartBeforeCatchUp + uint64(PERIOD_SECONDS * V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS),
            "periodStart must advance by the number of overdue closes"
        );
        assertEq(
            manager.lastFee(), hook.floorFee(), "active LP fee must end at floor after emergency catch-up"
        );
    }

    function test_controllerTransitionTrace_lull_reset() public {
        uint96 emaBefore = _enterCashMode();
        uint64 closedPeriodStart = _currentPeriodStart();

        vm.warp(block.timestamp + LULL_RESET_SECONDS);
        SwapEventCapture memory capture = _captureZeroSwap();

        assertEq(capture.traceCount, 1, "trace must emit once on lull reset");
        assertEq(capture.periodClosedCount, 1, "PeriodClosed must still emit");
        assertEq(capture.feeUpdatedCount, 1, "FeeUpdated must still emit on lull fee reset");
        assertEq(capture.lullResetCount, 1, "LullReset must still emit");

        assertEq(capture.lastTrace.periodStart, closedPeriodStart);
        assertEq(capture.lastTrace.fromFee, hook.cashFee());
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_CASH());
        assertEq(capture.lastTrace.toFee, hook.floorFee());
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_FLOOR());
        assertEq(capture.lastTrace.closeVolumeUsd6, 0);
        assertEq(capture.lastTrace.emaBeforeUsd6Scaled, emaBefore);
        assertEq(capture.lastTrace.emaAfterUsd6Scaled, 0);
        assertEq(capture.lastTrace.approxLpFeesUsd6, 0);
        assertEq(capture.lastTrace.decisionFlags, 0);
        assertEq(capture.lastTrace.countersBefore, _packTraceCounters(false, hook.cashHoldPeriods(), 0, 0, 0));
        assertEq(capture.lastTrace.countersAfter, _packTraceCounters(false, 0, 0, 0, 0));
        assertEq(capture.lastTrace.reasonCode, hook.REASON_LULL_RESET());

        assertEq(capture.lastPeriodClosed.fromFee, hook.cashFee());
        assertEq(capture.lastPeriodClosed.toFee, hook.floorFee());
        assertEq(capture.lastPeriodClosed.closedVolumeUsd6, 0);
        assertEq(capture.lastPeriodClosed.emaVolumeUsd6Scaled, 0);
        assertEq(capture.lastPeriodClosed.approxLpFeesUsd6, 0);
        assertEq(capture.lastPeriodClosed.reasonCode, hook.REASON_LULL_RESET());

        assertEq(capture.lastFeeUpdated.newFee, hook.floorFee());
        assertEq(capture.lastFeeUpdated.newFeeIdx, hook.MODE_FLOOR());
        assertEq(capture.lastFeeUpdated.closedVolumeUsd6, 0);
        assertEq(capture.lastFeeUpdated.emaVolumeUsd6Scaled, 0);

        assertEq(hook.currentMode(), hook.MODE_FLOOR(), "fee mode must reset to floor on lull");
        assertEq(manager.lastFee(), hook.floorFee(), "active fee must update to floor");
    }

    function test_hookFee_is_returned_via_afterSwap_delta_path() public {
        hook.scheduleHookFeePercentChange(10);
        vm.warp(block.timestamp + 48 hours);
        hook.executeHookFeePercentChange();

        // unspecified currency for exact-input zeroForOne is token1 (delta.amount1)
        _swap(true, -1, -1_000_000_000, 900_000_000);

        // 900_000_000 * 400 / 1e6 = 360_000 LP fee; hook fee 10% => 36_000
        assertEq(manager.lastAfterSwapSelector(), IHooks.afterSwap.selector);
        assertEq(manager.lastAfterSwapDelta(), int128(36_000));
        assertEq(manager.takeCount(), 0, "poolManager.take must not be used in HookFee path");
        assertEq(manager.mintCount(), 1, "poolManager.mint must capture hook claim balance");

        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        assertEq(fees0, 0);
        assertEq(fees1, 36_000);
    }

    function test_hookFee_approximation_exactInput_vs_exactOutput_paths() public {
        // Exact-input: unspecified side is token1 in zeroForOne flow.
        _swap(true, -90_000_000, -100_000_000, 90_000_000);

        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        uint256 exactInputAccrual = fees1;
        assertEq(fees0, 0);
        assertGt(exactInputAccrual, 0, "exact-input path should accrue non-zero HookFee");

        // Exact-output: unspecified side is token0 in zeroForOne flow.
        _swap(true, 90_000_000, -100_000_000, 90_000_000);

        (fees0, fees1) = hook.hookFeesAccrued();
        uint256 exactOutputAccrual = fees0;
        assertGt(exactOutputAccrual, 0, "exact-output path should accrue non-zero HookFee");
        assertEq(fees1, exactInputAccrual, "exact-input token1 accrual should not be overwritten");
        assertGt(
            exactOutputAccrual,
            exactInputAccrual,
            "exact-output path can deviate because approximation uses unspecified-side amount"
        );
    }

    function test_hookFee_cap_enforced_at_10_percent() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                VolumeDynamicFeeHook.HookFeePercentLimitExceeded.selector, uint16(11), uint16(10)
            )
        );
        hook.scheduleHookFeePercentChange(11);
    }

    function test_timelock_schedule_cancel_execute() public {
        hook.scheduleHookFeePercentChange(4);

        (bool exists, uint16 nextValue, uint64 executeAfter) = hook.pendingHookFeePercentChange();
        assertTrue(exists);
        assertEq(nextValue, 4);
        assertEq(executeAfter, uint64(block.timestamp) + 48 hours);

        vm.expectRevert(
            abi.encodeWithSelector(VolumeDynamicFeeHook.HookFeePercentChangeNotReady.selector, executeAfter)
        );
        hook.executeHookFeePercentChange();

        hook.cancelHookFeePercentChange();
        (exists,,) = hook.pendingHookFeePercentChange();
        assertFalse(exists);

        hook.scheduleHookFeePercentChange(5);
        vm.warp(block.timestamp + 48 hours);
        hook.executeHookFeePercentChange();
        assertEq(hook.hookFeePercent(), 5);
    }

    function test_claimHookFees_reverts_when_to_is_not_current_owner() public {
        _swap(true, -1, -10_000_000, 9_000_000);
        (, uint256 fees1) = hook.hookFeesAccrued();
        assertGt(fees1, 0, "precondition: accrued fees must exist");

        vm.expectRevert(VolumeDynamicFeeHook.InvalidRecipient.selector);
        hook.claimHookFees(outsider, 0, fees1);
    }

    function test_claimAllHookFees_chunks_settlement_when_accrual_exceeds_poolManager_int128_limit() public {
        uint24 nearMaxFloorFee = 999_998;
        VolumeDynamicFeeHookAdminHarness largeClaimHook =
            _deployHarness(nearMaxFloorFee, nearMaxFloorFee + 1, 1_000_000, owner, 10, 6);
        PoolKey memory largeClaimKey = _poolKey(address(largeClaimHook));
        manager.callAfterInitialize(largeClaimHook, largeClaimKey);

        for (uint256 i = 0; i < 11; ++i) {
            _swapFor(largeClaimHook, largeClaimKey, true, -1, -1, type(int128).max);
        }

        uint256 poolManagerLimit = uint256(uint128(type(int128).max));
        (, uint256 fees1) = largeClaimHook.hookFeesAccrued();
        assertGt(fees1, poolManagerLimit, "precondition: accrued HookFee must exceed single-settlement limit");

        largeClaimHook.claimAllHookFees();

        (uint256 fees0After, uint256 fees1After) = largeClaimHook.hookFeesAccrued();
        assertEq(fees0After, 0);
        assertEq(fees1After, 0);
        assertEq(manager.unlockCount(), 1, "claim should still use a single unlock call");
        assertEq(manager.burnCount(), 2, "oversized accrual must be burned in multiple chunks");
        assertEq(manager.takeCount(), 2, "oversized accrual must be taken in multiple chunks");
    }

    function test_claimAllHookFees_after_owner_transfer_uses_new_owner_without_manual_sync() public {
        _swap(true, -1, -10_000_000, 9_000_000);
        (, uint256 feesBeforeTransfer) = hook.hookFeesAccrued();
        assertGt(feesBeforeTransfer, 0, "precondition: accrued fees must exist");

        hook.proposeNewOwner(nextOwner);
        vm.prank(nextOwner);
        hook.acceptOwner();

        vm.expectRevert(VolumeDynamicFeeHook.NotOwner.selector);
        hook.claimAllHookFees();

        uint256 takeCountBefore = manager.takeCount();
        vm.prank(nextOwner);
        hook.claimAllHookFees();

        (, uint256 feesAfterClaim) = hook.hookFeesAccrued();
        assertEq(feesAfterClaim, 0, "new owner must be able to claim pre-transfer accrual");
        assertEq(manager.takeCount(), takeCountBefore + 1, "claim payout must target current owner");
    }

    function test_owner_transfer_propose_cancel_accept_flow() public {
        vm.prank(outsider);
        vm.expectRevert(VolumeDynamicFeeHook.NotOwner.selector);
        hook.proposeNewOwner(nextOwner);

        hook.proposeNewOwner(nextOwner);
        assertEq(hook.pendingOwner(), nextOwner);

        vm.prank(outsider);
        vm.expectRevert(VolumeDynamicFeeHook.NotPendingOwner.selector);
        hook.acceptOwner();

        hook.cancelOwnerTransfer();
        assertEq(hook.pendingOwner(), address(0));

        hook.proposeNewOwner(nextOwner);
        vm.prank(nextOwner);
        hook.acceptOwner();

        assertEq(hook.owner(), nextOwner);
        assertEq(hook.pendingOwner(), address(0));
    }

    function test_owner_transfer_rejects_propose_current_owner() public {
        vm.expectRevert(VolumeDynamicFeeHook.InvalidOwner.selector);
        hook.proposeNewOwner(owner);
    }

    function test_setTimingParams_reverts_when_lullReset_equals_period() public {
        hook.pause();

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        hook.setTimingParams(PERIOD_SECONDS, EMA_PERIODS, PERIOD_SECONDS);
    }

    function test_setTimingParams_lull_only_keeps_mode_ema_and_counters() public {
        _moveToCashWithPendingUpExtremeStreak();
        hook.pause();

        (
            uint8 feeIdxBefore,
            uint8 holdBefore,
            uint8 upBefore,
            uint8 downBefore,
            uint8 emergencyBefore,
            uint64 periodStartBefore,,
            uint96 emaBefore,
        ) = hook.getStateDebug();
        uint256 updatesBefore = manager.updateCount();

        uint32 newLullReset = LULL_RESET_SECONDS + PERIOD_SECONDS;
        hook.setTimingParams(PERIOD_SECONDS, EMA_PERIODS, newLullReset);

        (
            uint8 feeIdxAfter,
            uint8 holdAfter,
            uint8 upAfter,
            uint8 downAfter,
            uint8 emergencyAfter,
            uint64 periodStartAfter,
            uint64 periodVolAfter,
            uint96 emaAfter,
        ) = hook.getStateDebug();

        assertEq(feeIdxAfter, feeIdxBefore);
        assertEq(holdAfter, holdBefore);
        assertEq(upAfter, upBefore);
        assertEq(downAfter, downBefore);
        assertEq(emergencyAfter, emergencyBefore);
        assertEq(emaAfter, emaBefore);
        assertEq(periodVolAfter, 0);
        assertGe(periodStartAfter, periodStartBefore);
        assertEq(manager.updateCount(), updatesBefore, "no immediate LP fee update expected");
        assertEq(hook.lullResetSeconds(), newLullReset);
    }

    function test_setTimingParams_period_change_resets_to_floor_and_clears_state() public {
        _moveToCashWithPendingUpExtremeStreak();
        hook.pause();

        (uint8 feeIdxBefore,,,,, uint64 periodStartBefore,, uint96 emaBefore,) = hook.getStateDebug();
        assertEq(feeIdxBefore, hook.MODE_CASH(), "precondition: must be in cash before reset");
        assertGt(emaBefore, 0, "precondition: EMA must be seeded");

        uint256 updatesBefore = manager.updateCount();
        uint32 newPeriod = PERIOD_SECONDS + 15;
        uint32 newLullReset = newPeriod + 30;
        hook.setTimingParams(newPeriod, EMA_PERIODS, newLullReset);

        (
            uint8 feeIdxAfter,
            uint8 holdAfter,
            uint8 upAfter,
            uint8 downAfter,
            uint8 emergencyAfter,
            uint64 periodStartAfter,
            uint64 periodVolAfter,
            uint96 emaAfter,
            bool pausedAfter
        ) = hook.getStateDebug();

        assertEq(feeIdxAfter, hook.MODE_FLOOR());
        assertEq(holdAfter, 0);
        assertEq(upAfter, 0);
        assertEq(downAfter, 0);
        assertEq(emergencyAfter, 0);
        assertEq(periodVolAfter, 0);
        assertEq(emaAfter, 0);
        assertGe(periodStartAfter, periodStartBefore);
        assertTrue(pausedAfter, "pause flag must remain set");
        assertEq(manager.updateCount(), updatesBefore + 1, "fee update expected when active tier changes");
        assertEq(manager.lastFee(), hook.floorFee(), "active LP fee must switch to floor");
        assertEq(hook.periodSeconds(), newPeriod);
        assertEq(hook.lullResetSeconds(), newLullReset);
    }

    function test_setTimingParams_emaPeriods_change_resets_to_floor_and_clears_state() public {
        _moveToCashWithPendingUpExtremeStreak();
        hook.pause();

        (uint8 feeIdxBefore,,,,,,,,) = hook.getStateDebug();
        assertEq(feeIdxBefore, hook.MODE_CASH(), "precondition: must be in cash before reset");

        uint256 updatesBefore = manager.updateCount();
        uint8 newEmaPeriods = EMA_PERIODS + 1;
        hook.setTimingParams(PERIOD_SECONDS, newEmaPeriods, LULL_RESET_SECONDS);

        (
            uint8 feeIdxAfter,
            uint8 holdAfter,
            uint8 upAfter,
            uint8 downAfter,
            uint8 emergencyAfter,,
            uint64 periodVolAfter,
            uint96 emaAfter,
            bool pausedAfter
        ) = hook.getStateDebug();

        assertEq(feeIdxAfter, hook.MODE_FLOOR());
        assertEq(holdAfter, 0);
        assertEq(upAfter, 0);
        assertEq(downAfter, 0);
        assertEq(emergencyAfter, 0);
        assertEq(periodVolAfter, 0);
        assertEq(emaAfter, 0);
        assertTrue(pausedAfter, "pause flag must remain set");
        assertEq(manager.updateCount(), updatesBefore + 1, "fee update expected when active tier changes");
        assertEq(manager.lastFee(), hook.floorFee(), "active LP fee must switch to floor");
        assertEq(hook.emaPeriods(), newEmaPeriods);

        hook.unpause();
        assertFalse(hook.isPaused(), "unpause should still work after timing reset");
    }

    function test_setTimingParams_accepts_emaPeriods_above_previous_limit_and_up_to_128() public {
        hook.pause();

        hook.setTimingParams(PERIOD_SECONDS, 65, LULL_RESET_SECONDS);
        assertEq(hook.emaPeriods(), 65);

        hook.setTimingParams(PERIOD_SECONDS, 96, LULL_RESET_SECONDS);
        assertEq(hook.emaPeriods(), 96);

        hook.setTimingParams(PERIOD_SECONDS, MAX_EMA_PERIODS, LULL_RESET_SECONDS);
        assertEq(hook.emaPeriods(), MAX_EMA_PERIODS);
    }

    function test_setTimingParams_reverts_when_emaPeriods_exceeds_128() public {
        hook.pause();

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        hook.setTimingParams(PERIOD_SECONDS, uint8(MAX_EMA_PERIODS + 1), LULL_RESET_SECONDS);
    }

    function test_setControllerParams_reverts_when_cash_volume_threshold_exceeds_extreme_threshold() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.floorToCashMinCloseVolume = p.cashToExtremeMinCloseVolume + 1;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        hook.setControllerParams(p);
    }

    function test_setControllerParams_reverts_when_cash_up_ratio_exceeds_extreme_up_ratio() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.floorToCashMinFlowBps = p.cashToExtremeMinFlowBps + 1;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        hook.setControllerParams(p);
    }

    function test_setControllerParams_reverts_when_cash_down_ratio_is_below_extreme_down_ratio() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.cashToFloorMaxFlowBps = p.extremeToCashMaxFlowBps - 1;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        hook.setControllerParams(p);
    }

    function test_setControllerParams_reverts_when_emergency_floor_threshold_is_zero() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.emergencyToFloorMaxCloseVolume = 0;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        hook.setControllerParams(p);
    }

    function test_setControllerParams_reverts_when_emergency_floor_not_below_cash_threshold() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.emergencyToFloorMaxCloseVolume = p.floorToCashMinCloseVolume;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        hook.setControllerParams(p);
    }

    function test_setControllerParams_accepts_when_emergency_floor_is_strictly_below_cash_threshold() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.emergencyToFloorMaxCloseVolume = p.floorToCashMinCloseVolume - 1;

        hook.setControllerParams(p);
        assertEq(hook.emergencyToFloorMaxCloseVolume(), p.emergencyToFloorMaxCloseVolume);
    }

    function test_setControllerParams_accepts_new_maximum_supported_ranges() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.cashHoldPeriods = MAX_HOLD_PERIODS;
        p.extremeHoldPeriods = MAX_HOLD_PERIODS;
        p.cashToExtremeConfirmPeriods = MAX_UP_EXTREME_CONFIRM_PERIODS;
        p.extremeToCashConfirmPeriods = MAX_DOWN_CONFIRM_PERIODS;
        p.cashToFloorConfirmPeriods = MAX_DOWN_CONFIRM_PERIODS;
        p.emergencyToFloorConfirmPeriods = MAX_EMERGENCY_STREAK_LIMIT;

        hook.setControllerParams(p);

        VolumeDynamicFeeHook.ControllerParams memory updated = hook.getControllerParams();
        assertEq(updated.cashHoldPeriods, MAX_HOLD_PERIODS);
        assertEq(updated.extremeHoldPeriods, MAX_HOLD_PERIODS);
        assertEq(updated.cashToExtremeConfirmPeriods, MAX_UP_EXTREME_CONFIRM_PERIODS);
        assertEq(updated.extremeToCashConfirmPeriods, MAX_DOWN_CONFIRM_PERIODS);
        assertEq(updated.cashToFloorConfirmPeriods, MAX_DOWN_CONFIRM_PERIODS);
        assertEq(updated.emergencyToFloorConfirmPeriods, MAX_EMERGENCY_STREAK_LIMIT);
    }

    function test_setControllerParams_reverts_when_ranges_exceed_new_maximums() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.cashHoldPeriods = uint8(MAX_HOLD_PERIODS + 1);
        vm.expectRevert(VolumeDynamicFeeHook.InvalidHoldPeriods.selector);
        hook.setControllerParams(p);

        p = _defaultControllerParams();
        p.extremeHoldPeriods = uint8(MAX_HOLD_PERIODS + 1);
        vm.expectRevert(VolumeDynamicFeeHook.InvalidHoldPeriods.selector);
        hook.setControllerParams(p);

        p = _defaultControllerParams();
        p.cashToExtremeConfirmPeriods = uint8(MAX_UP_EXTREME_CONFIRM_PERIODS + 1);
        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfirmPeriods.selector);
        hook.setControllerParams(p);

        p = _defaultControllerParams();
        p.extremeToCashConfirmPeriods = uint8(MAX_DOWN_CONFIRM_PERIODS + 1);
        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfirmPeriods.selector);
        hook.setControllerParams(p);

        p = _defaultControllerParams();
        p.cashToFloorConfirmPeriods = uint8(MAX_DOWN_CONFIRM_PERIODS + 1);
        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfirmPeriods.selector);
        hook.setControllerParams(p);

        p = _defaultControllerParams();
        p.emergencyToFloorConfirmPeriods = uint8(MAX_EMERGENCY_STREAK_LIMIT + 1);
        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfirmPeriods.selector);
        hook.setControllerParams(p);
    }

    function test_setControllerParams_preserves_mode_and_ema_but_clears_counters() public {
        _moveToCashWithPendingUpExtremeStreak();
        hook.pause();

        (
            uint8 feeIdxBefore,
            uint8 holdBefore,
            uint8 upBefore,
            uint8 downBefore,
            uint8 emergencyBefore,
            uint64 periodStartBefore,,
            uint96 emaBefore,
        ) = hook.getStateDebug();
        assertEq(feeIdxBefore, hook.MODE_CASH());
        assertGt(holdBefore, 0, "precondition: hold must be active");
        assertGt(upBefore, 0, "precondition: up streak must be active");

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.floorToCashMinCloseVolume = p.floorToCashMinCloseVolume + 1;
        p.cashToExtremeMinCloseVolume = p.cashToExtremeMinCloseVolume + 1;
        hook.setControllerParams(p);

        (
            uint8 feeIdxAfter,
            uint8 holdAfter,
            uint8 upAfter,
            uint8 downAfter,
            uint8 emergencyAfter,
            uint64 periodStartAfter,
            uint64 periodVolAfter,
            uint96 emaAfter,
            bool pausedAfter
        ) = hook.getStateDebug();
        downBefore;
        emergencyBefore;
        assertEq(feeIdxAfter, feeIdxBefore, "mode must be preserved");
        assertEq(emaAfter, emaBefore, "EMA must be preserved");
        assertEq(holdAfter, 0, "hold counter must reset");
        assertEq(upAfter, 0, "up streak must reset");
        assertEq(downAfter, 0, "down streak must reset");
        assertEq(emergencyAfter, 0, "emergency streak must reset");
        assertEq(periodVolAfter, 0, "fresh open period must start from zero volume");
        assertGe(periodStartAfter, periodStartBefore, "open period start must restart");
        assertTrue(pausedAfter, "pause flag must remain true");
    }

    function test_setControllerParams_clears_stale_up_streak_before_unpause() public {
        _moveToCashWithPendingUpExtremeStreak();
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.floorToCashMinCloseVolume = p.floorToCashMinCloseVolume + 1;
        p.cashToExtremeMinCloseVolume = p.cashToExtremeMinCloseVolume + 1;
        hook.setControllerParams(p);
        hook.unpause();

        _swap(true, -1, -10_000_000_000, 9_000_000_000);
        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (uint8 feeIdxAfter,,,,,,,,) = hook.getStateDebug();
        assertEq(
            feeIdxAfter, hook.MODE_CASH(), "stale up streak must not trigger immediate jump to extreme"
        );
    }

    function testFuzz_setControllerParams_rejects_emergency_floor_not_below_cash_threshold(uint64 minCloseVolToCash)
        public
    {
        hook.pause();

        uint64 minCash = uint64(bound(minCloseVolToCash, 1, type(uint64).max));
        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.floorToCashMinCloseVolume = minCash;
        p.cashToExtremeMinCloseVolume = minCash;
        p.emergencyToFloorMaxCloseVolume = minCash;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        hook.setControllerParams(p);
    }

    function testFuzz_setTimingParams_time_scale_change_performs_safe_reset(uint32 periodSeed, uint8 emaSeed)
        public
    {
        _moveToCashModeWithHold();
        hook.pause();

        uint32 newPeriod = uint32(bound(periodSeed, 1, 7200));
        uint8 newEma = uint8(bound(emaSeed, 2, MAX_EMA_PERIODS));
        if (newPeriod == PERIOD_SECONDS && newEma == EMA_PERIODS) {
            if (newEma < MAX_EMA_PERIODS) newEma += 1;
            else newPeriod += 1;
        }
        uint32 newLull = newPeriod + 1;

        hook.setTimingParams(newPeriod, newEma, newLull);

        (
            uint8 feeIdxAfter,
            uint8 holdAfter,
            uint8 upAfter,
            uint8 downAfter,
            uint8 emergencyAfter,,
            uint64 periodVolAfter,
            uint96 emaAfter,
        ) = hook.getStateDebug();

        assertEq(feeIdxAfter, hook.MODE_FLOOR());
        assertEq(holdAfter, 0);
        assertEq(upAfter, 0);
        assertEq(downAfter, 0);
        assertEq(emergencyAfter, 0);
        assertEq(periodVolAfter, 0);
        assertEq(emaAfter, 0);
    }

    function test_cashHoldPeriods_one_results_in_zero_effective_hold_protection() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = VolumeDynamicFeeHook.ControllerParams({
            floorToCashMinCloseVolume: V2_FLOOR_TO_CASH_MIN_CLOSE_VOLUME,
            floorToCashMinFlowBps: V2_FLOOR_TO_CASH_MIN_FLOW_BPS,
            cashHoldPeriods: 1,
            cashToExtremeMinCloseVolume: V2_CASH_TO_EXTREME_MIN_CLOSE_VOLUME,
            cashToExtremeMinFlowBps: V2_CASH_TO_EXTREME_MIN_FLOW_BPS,
            cashToExtremeConfirmPeriods: V2_CASH_TO_EXTREME_CONFIRM_PERIODS,
            extremeHoldPeriods: V2_EXTREME_HOLD_PERIODS,
            extremeToCashMaxFlowBps: V2_EXTREME_TO_CASH_MAX_FLOW_BPS,
            extremeToCashConfirmPeriods: V2_EXTREME_TO_CASH_CONFIRM_PERIODS,
            cashToFloorMaxFlowBps: V2_CASH_TO_FLOOR_MAX_FLOW_BPS,
            cashToFloorConfirmPeriods: 1,
            emergencyToFloorMaxCloseVolume: V2_EMERGENCY_TO_FLOOR_MAX_CLOSE_VOLUME,
            emergencyToFloorConfirmPeriods: V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS
        });
        hook.setControllerParams(p);
        hook.unpause();

        _moveToCashModeWithHold();
        (uint8 feeIdxAfterJump, uint8 holdAfterJump,,,,,,,) = hook.getStateDebug();
        assertEq(feeIdxAfterJump, hook.MODE_CASH(), "precondition: active tier must be cash");
        assertEq(holdAfterJump, 1, "configured hold must initialize to one");

        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (uint8 feeIdxAfterNextClose, uint8 holdAfterNextClose,,,,,,,) = hook.getStateDebug();
        assertEq(
            feeIdxAfterNextClose,
            hook.MODE_FLOOR(),
            "cashHoldPeriods=1 should not provide an extra fully protected period"
        );
        assertEq(holdAfterNextClose, 0, "hold must be consumed at the next close");
    }

    function test_emergencyFloor_positive_threshold_still_triggers_transition_to_floor() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.emergencyToFloorMaxCloseVolume = 1;
        p.emergencyToFloorConfirmPeriods = 1;
        hook.setControllerParams(p);
        hook.unpause();

        _moveToCashModeWithHold();

        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (uint8 feeIdx,,,,,,,,) = hook.getStateDebug();
        assertEq(feeIdx, hook.MODE_FLOOR(), "emergency floor should trigger from cash on low close volume");
    }

    function test_default_cash_profile_ordinary_descent_requires_four_weak_closes() public {
        _moveToCashModeWithHold();

        for (uint256 i = 1; i <= 3; ++i) {
            _closePeriodWithCountedVolume(LOW_NON_EMERGENCY_CLOSEVOL_USD6);

            (uint8 feeIdx, uint8 holdRemaining,, uint8 downStreak, uint8 emergencyStreak,,,,) = hook.getStateDebug();
            assertEq(feeIdx, hook.MODE_CASH(), "cash must stay active before the 4th weak close");
            assertEq(emergencyStreak, 0, "ordinary weak closes must not tick the emergency path");

            if (i == 1) {
                assertEq(holdRemaining, 1, "first weak close must only consume hold");
                assertEq(downStreak, 0, "ordinary down streak must stay blocked during hold");
            } else if (i == 2) {
                assertEq(holdRemaining, 0, "second weak close must finish hold");
                assertEq(downStreak, 1, "ordinary down streak starts after hold is gone");
            } else {
                assertEq(downStreak, 2, "third weak close must still be one short of cash->floor descent");
            }
        }

        _closePeriodWithCountedVolume(LOW_NON_EMERGENCY_CLOSEVOL_USD6);
        (uint8 feeIdxAfter,,,,,,,,) = hook.getStateDebug();
        assertEq(
            feeIdxAfter,
            hook.MODE_FLOOR(),
            "cashHoldPeriods=2 and cashToFloorConfirmPeriods=3 must first allow descent on weak close #4"
        );
    }

    function test_emergency_path_counts_during_hold_and_triggers_on_sixth_weak_close_when_ordinary_path_is_delayed()
        public
    {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.cashToFloorConfirmPeriods = MAX_DOWN_CONFIRM_PERIODS;
        hook.setControllerParams(p);
        hook.unpause();

        _moveToCashModeWithHold();

        for (uint256 i = 1; i < V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS; ++i) {
            _closePeriodWithCountedVolume(LOW_EMERGENCY_CLOSEVOL_USD6);

            (uint8 feeIdx, uint8 holdRemaining,, uint8 downStreak, uint8 emergencyStreak,,,,) = hook.getStateDebug();
            assertEq(
                feeIdx,
                hook.MODE_CASH(),
                "emergency must not trigger before weak close #6 when the ordinary path is delayed"
            );
            assertEq(emergencyStreak, i, "emergency streak must keep accumulating on every weak close");

            if (i == 1) {
                assertEq(holdRemaining, 1, "first weak close must still leave one hold period");
                assertEq(downStreak, 0, "ordinary down streak stays blocked while hold is active");
            } else if (i == 2) {
                assertEq(holdRemaining, 0, "second weak close must finish hold consumption");
                assertEq(downStreak, 1, "ordinary down streak must start once hold is gone");
            } else {
                assertEq(downStreak, uint8(i - 1), "ordinary down streak must keep counting after hold");
            }
        }

        _closePeriodWithCountedVolume(LOW_EMERGENCY_CLOSEVOL_USD6);
        (uint8 feeIdxAfter,,,,,,,,) = hook.getStateDebug();
        assertEq(
            feeIdxAfter,
            hook.MODE_FLOOR(),
            "emergencyToFloorConfirmPeriods=6 must first allow emergency descent on weak close #6 once the ordinary path is delayed"
        );
    }

    function test_default_extreme_profile_ordinary_descent_requires_three_weak_closes() public {
        _enterCashMode();
        _closePeriodWithCountedVolume(EXTREME_STREAK1_CLOSEVOL_USD6);
        _closePeriodWithCountedVolume(EXTREME_STREAK2_CLOSEVOL_USD6);

        (uint8 feeIdxAfterJump, uint8 holdAfterJump,,,,,,,) = hook.getStateDebug();
        assertEq(feeIdxAfterJump, hook.MODE_EXTREME(), "precondition: controller must enter extreme mode");
        assertEq(holdAfterJump, hook.extremeHoldPeriods(), "precondition: extreme hold must be freshly set");

        for (uint256 i = 1; i <= 2; ++i) {
            _closePeriodWithCountedVolume(LOW_NON_EMERGENCY_CLOSEVOL_USD6);

            (uint8 feeIdx, uint8 holdRemaining,, uint8 downStreak, uint8 emergencyStreak,,,,) = hook.getStateDebug();
            assertEq(feeIdx, hook.MODE_EXTREME(), "extreme must stay active before the 3rd weak close");
            assertEq(emergencyStreak, 0, "ordinary weak closes must not tick emergency");

            if (i == 1) {
                assertEq(holdRemaining, 1, "first weak close must only consume extreme hold");
                assertEq(downStreak, 0, "ordinary down streak must stay blocked during hold");
            } else {
                assertEq(holdRemaining, 0, "second weak close must finish extreme hold");
                assertEq(downStreak, 1, "ordinary down streak starts after hold is gone");
            }
        }

        _closePeriodWithCountedVolume(LOW_NON_EMERGENCY_CLOSEVOL_USD6);
        (uint8 feeIdxAfter,,,,,,,,) = hook.getStateDebug();
        assertEq(
            feeIdxAfter,
            hook.MODE_CASH(),
            "extremeHoldPeriods=2 and extremeToCashConfirmPeriods=2 must first allow descent on weak close #3"
        );
    }

    function test_cashToExtremeConfirmPeriods_upper_bound_requires_full_7_close_streak() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.floorToCashMinFlowBps = 1;
        p.cashToExtremeMinFlowBps = 1;
        p.cashToExtremeConfirmPeriods = MAX_UP_EXTREME_CONFIRM_PERIODS;
        hook.setControllerParams(p);
        hook.unpause();

        _enterCashMode();

        for (uint256 i = 1; i < MAX_UP_EXTREME_CONFIRM_PERIODS; ++i) {
            _closePeriodWithCountedVolume(EXTREME_STREAK2_CLOSEVOL_USD6);

            (uint8 feeIdxDuringStreak,, uint8 upExtremeStreak,,,,,,) = hook.getStateDebug();
            assertEq(
                feeIdxDuringStreak, hook.MODE_CASH(), "cash must not jump to extreme before the 7th qualifying close"
            );
            assertEq(upExtremeStreak, uint8(i), "up streak must accumulate up to the new 3-bit maximum");
        }

        _closePeriodWithCountedVolume(EXTREME_STREAK2_CLOSEVOL_USD6);

        (uint8 feeIdxAfterJump, uint8 holdRemaining,,,,,,,) = hook.getStateDebug();
        assertEq(feeIdxAfterJump, hook.MODE_EXTREME(), "cash must jump to extreme on the 7th qualifying close");
        assertEq(holdRemaining, hook.extremeHoldPeriods(), "extreme hold must initialize without truncation");
    }

    function test_cashToFloorConfirmPeriods_upper_bound_requires_full_15_close_streak() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.cashHoldPeriods = 1;
        p.cashToFloorConfirmPeriods = MAX_DOWN_CONFIRM_PERIODS;
        p.emergencyToFloorMaxCloseVolume = 1;
        hook.setControllerParams(p);
        hook.unpause();

        _enterCashMode();

        for (uint256 i = 1; i < MAX_DOWN_CONFIRM_PERIODS; ++i) {
            _closePeriodWithCountedVolume(LOW_NON_EMERGENCY_CLOSEVOL_USD6);

            (uint8 feeIdxDuringStreak,,, uint8 downStreak,,,,,) = hook.getStateDebug();
            assertEq(
                feeIdxDuringStreak, hook.MODE_CASH(), "cash must remain active until the 15th downward confirmation"
            );
            assertEq(downStreak, uint8(i), "down streak must accumulate up to 14 without truncation");
        }

        _closePeriodWithCountedVolume(LOW_NON_EMERGENCY_CLOSEVOL_USD6);

        (uint8 feeIdxAfterDrop,,, uint8 downStreakAfterDrop, uint8 emergencyStreak,,,,) = hook.getStateDebug();
        assertEq(feeIdxAfterDrop, hook.MODE_FLOOR(), "cash must fall to floor on the 15th downward confirmation");
        assertEq(downStreakAfterDrop, 0, "down streak must reset after the transition");
        assertEq(emergencyStreak, 0, "emergency path must stay inactive in the non-emergency scenario");
    }

    function test_extremeToCashConfirmPeriods_upper_bound_requires_full_15_close_streak() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.cashToExtremeConfirmPeriods = 1;
        p.extremeHoldPeriods = 1;
        p.extremeToCashConfirmPeriods = MAX_DOWN_CONFIRM_PERIODS;
        p.emergencyToFloorMaxCloseVolume = 1;
        hook.setControllerParams(p);
        hook.unpause();

        _enterCashMode();
        _closePeriodWithCountedVolume(EXTREME_STREAK2_CLOSEVOL_USD6);

        (uint8 feeIdxAfterJump, uint8 holdAfterJump,,,,,,,) = hook.getStateDebug();
        assertEq(feeIdxAfterJump, hook.MODE_EXTREME(), "precondition: controller must enter extreme mode");
        assertEq(holdAfterJump, 1, "precondition: extreme hold must initialize to one");

        for (uint256 i = 1; i < MAX_DOWN_CONFIRM_PERIODS; ++i) {
            _closePeriodWithCountedVolume(LOW_NON_EMERGENCY_CLOSEVOL_USD6);

            (uint8 feeIdxDuringStreak,,, uint8 downStreak,,,,,) = hook.getStateDebug();
            assertEq(
                feeIdxDuringStreak,
                hook.MODE_EXTREME(),
                "extreme must remain active until the 15th downward confirmation"
            );
            assertEq(downStreak, uint8(i), "down streak must accumulate up to 14 without truncation");
        }

        _closePeriodWithCountedVolume(LOW_NON_EMERGENCY_CLOSEVOL_USD6);

        (uint8 feeIdxAfterDrop,,, uint8 downStreakAfterDrop, uint8 emergencyStreak,,,,) = hook.getStateDebug();
        assertEq(
            feeIdxAfterDrop, hook.MODE_CASH(), "extreme must fall back to cash on the 15th downward confirmation"
        );
        assertEq(downStreakAfterDrop, 0, "down streak must reset after the transition");
        assertEq(emergencyStreak, 0, "emergency path must stay inactive in the non-emergency scenario");
    }

    function test_emergencyToFloorConfirmPeriods_upper_bound_requires_full_15_close_streak() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.cashHoldPeriods = 1;
        p.cashToFloorConfirmPeriods = MAX_DOWN_CONFIRM_PERIODS;
        p.emergencyToFloorConfirmPeriods = MAX_EMERGENCY_STREAK_LIMIT;
        hook.setControllerParams(p);
        hook.unpause();

        _enterCashMode();

        for (uint256 i = 1; i < MAX_EMERGENCY_STREAK_LIMIT; ++i) {
            _advanceOnePeriod();
            _closeCurrentPeriod();

            (uint8 feeIdxDuringStreak,,, uint8 downStreak, uint8 emergencyStreak,,,,) = hook.getStateDebug();
            assertEq(
                feeIdxDuringStreak, hook.MODE_CASH(), "emergency floor must not trigger before the 15th low close"
            );
            assertEq(downStreak, uint8(i), "down streak must keep counting alongside the emergency streak");
            assertEq(emergencyStreak, uint8(i), "emergency streak must accumulate up to 14 without truncation");
        }

        _advanceOnePeriod();
        SwapEventCapture memory capture = _captureZeroSwap();

        assertEq(capture.lastTrace.reasonCode, hook.REASON_EMERGENCY_FLOOR());
        assertEq(
            capture.lastTrace.decisionFlags & TRACE_FLAG_EMERGENCY_TRIGGERED,
            TRACE_FLAG_EMERGENCY_TRIGGERED,
            "emergency path must win once the 15th low close arrives"
        );

        (uint8 feeIdxAfterDrop,,,,,,,,) = hook.getStateDebug();
        assertEq(feeIdxAfterDrop, hook.MODE_FLOOR(), "emergency floor must trigger exactly on the 15th low close");
    }

    function test_pause_unpause_freeze_resume_semantics() public {
        _swap(true, -1, -10_000_000, 9_000_000);
        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (
            uint8 feeIdxBefore,
            uint8 holdBefore,
            uint8 upBefore,
            uint8 downBefore,
            uint8 emergencyBefore,
            uint64 periodStartBefore,,
            uint96 emaBefore,
        ) = hook.getStateDebug();

        uint256 updateCountBeforePause = manager.updateCount();
        hook.pause();
        assertTrue(hook.isPaused());

        (
            uint8 feeIdxPaused,
            uint8 holdPaused,
            uint8 upPaused,
            uint8 downPaused,
            uint8 emergencyPaused,
            uint64 periodStartPaused,
            uint64 periodVolPaused,
            uint96 emaPaused,
        ) = hook.getStateDebug();

        assertEq(feeIdxPaused, feeIdxBefore);
        assertEq(holdPaused, holdBefore);
        assertEq(upPaused, upBefore);
        assertEq(downPaused, downBefore);
        assertEq(emergencyPaused, emergencyBefore);
        assertEq(emaPaused, emaBefore);
        assertEq(periodVolPaused, 0);
        assertGe(periodStartPaused, periodStartBefore);

        (uint256 fees0BeforePausedSwap, uint256 fees1BeforePausedSwap) = hook.hookFeesAccrued();
        uint256 mintCountBeforePausedSwap = manager.mintCount();
        _swap(true, -1, -6_000_000, 5_700_000);
        assertEq(manager.lastAfterSwapDelta(), 0, "HookFee must not be charged while paused");
        assertEq(manager.mintCount(), mintCountBeforePausedSwap, "paused swaps must not mint claim balances");

        (uint256 fees0AfterPausedSwap, uint256 fees1AfterPausedSwap) = hook.hookFeesAccrued();
        assertEq(fees0AfterPausedSwap, fees0BeforePausedSwap);
        assertEq(fees1AfterPausedSwap, fees1BeforePausedSwap);

        (
            uint8 feeIdxAfterSwapWhilePaused,,,,,
            uint64 periodStartAfterSwapWhilePaused,
            uint64 periodVolAfterSwapWhilePaused,,
        ) = hook.getStateDebug();
        assertEq(feeIdxAfterSwapWhilePaused, feeIdxBefore);
        assertEq(periodStartAfterSwapWhilePaused, periodStartPaused);
        assertEq(periodVolAfterSwapWhilePaused, 0);
        assertEq(
            manager.updateCount(), updateCountBeforePause, "paused swaps must not trigger fee tier updates"
        );

        hook.unpause();
        assertFalse(hook.isPaused());

        _swap(true, -1, -6_000_000, 5_700_000);
        (,,,,,, uint64 periodVolAfterUnpause,,) = hook.getStateDebug();
        assertEq(periodVolAfterUnpause, 6_000_000);
    }

    function test_emergency_resets_require_paused_and_apply_semantics() public {
        vm.expectRevert(VolumeDynamicFeeHook.RequiresPaused.selector);
        hook.emergencyResetToFloor();

        hook.pause();
        hook.emergencyResetToCash();

        (
            uint8 feeIdx,
            uint8 hold,
            uint8 up,
            uint8 down,
            uint8 emergency,
            uint64 periodStart,
            uint64 periodVol,
            uint96 ema,
            bool paused
        ) = hook.getStateDebug();

        assertEq(feeIdx, hook.MODE_CASH());
        assertEq(hold, 0);
        assertEq(up, 0);
        assertEq(down, 0);
        assertEq(emergency, 0);
        assertEq(periodVol, 0);
        assertEq(ema, 0);
        assertTrue(paused);
        assertEq(periodStart, uint64(block.timestamp));

        hook.emergencyResetToFloor();
        (feeIdx,,,,,, periodVol, ema, paused) = hook.getStateDebug();
        assertEq(feeIdx, hook.MODE_FLOOR());
        assertEq(periodVol, 0);
        assertEq(ema, 0);
        assertTrue(paused);
    }

    function test_setModeFees_pausedMaintenance_preservesEma_resetsCounters_andKeepsMode() public {
        _moveToCashModeWithHold();

        (
            uint8 modeBefore,
            uint8 holdBefore,
            uint8 upBefore,
            uint8 downBefore,
            uint8 emergencyBefore,
            uint64 periodStartBefore,
            uint64 periodVolBefore,
            uint96 emaBefore,
            bool pausedBefore
        ) = hook.getStateDebug();
        upBefore;
        downBefore;
        emergencyBefore;
        periodVolBefore;
        pausedBefore;
        assertEq(modeBefore, hook.MODE_CASH());
        assertGt(holdBefore, 0);

        _swap(true, -1, -10_000_000, 9_500_000);
        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (, emaBefore,,) = hook.unpackedState();
        assertGt(emaBefore, 0, "precondition: EMA should be seeded");

        hook.pause();
        uint256 updatesBefore = manager.updateCount();
        hook.setModeFees(400, 3000, 9000);

        (
            uint8 modeAfter,
            uint8 holdAfter,
            uint8 upAfter,
            uint8 downAfter,
            uint8 emergencyAfter,
            uint64 periodStartAfter,
            uint64 periodVolAfter,
            uint96 emaAfter,
            bool pausedAfter
        ) = hook.getStateDebug();
        periodVolAfter;
        pausedAfter;
        assertEq(modeAfter, hook.MODE_CASH(), "active mode must stay cash");
        assertEq(holdAfter, 0, "hold must reset");
        assertEq(upAfter, 0, "up streak must reset");
        assertEq(downAfter, 0, "down streak must reset");
        assertEq(emergencyAfter, 0, "emergency streak must reset");
        assertEq(emaAfter, emaBefore, "EMA must be preserved");
        assertGe(periodStartAfter, periodStartBefore, "open period must restart");
        assertEq(manager.updateCount(), updatesBefore + 1, "active fee change must be applied immediately");
        assertEq(manager.lastFee(), 3000);
    }

    function test_setModeFees_rejects_invalid_fee_order() public {
        hook.pause();

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        hook.setModeFees(0, 2500, 9000);

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        hook.setModeFees(400, 400, 9000);

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        hook.setModeFees(400, 9000, 2500);
    }

    function test_getModeFees_returns_explicit_triplet() public view {
        (uint24 floorFee_, uint24 cashFee_, uint24 extremeFee_) = hook.getModeFees();
        assertEq(floorFee_, 400);
        assertEq(cashFee_, 2500);
        assertEq(extremeFee_, 9000);
    }

    function test_minCountedSwapVolume_filters_only_telemetry_and_applies_next_period() public {
        assertEq(hook.minCountedSwapVolume(), 4_000_000);

        _swap(true, -1, -1_000_000, 900_000);
        (uint64 periodVol,,,) = hook.unpackedState();
        assertEq(periodVol, 0, "dust swap must not be counted");
        assertEq(manager.lastAfterSwapDelta() > 0, true, "dust swap still pays HookFee");

        _swap(true, -1, -6_000_000, 5_700_000);
        (periodVol,,,) = hook.unpackedState();
        assertEq(periodVol, 6_000_000);

        hook.scheduleMinCountedSwapVolumeChange(10_000_000);
        _swap(true, -1, -6_000_000, 5_700_000);
        (periodVol,,,) = hook.unpackedState();
        assertEq(periodVol, 12_000_000, "new threshold must not apply mid-period");

        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);
        assertEq(hook.minCountedSwapVolume(), 10_000_000);

        _swap(true, -1, -6_000_000, 5_700_000);
        (periodVol,,,) = hook.unpackedState();
        assertEq(periodVol, 0, "new threshold must apply after next period boundary");
    }

    function test_period_close_catch_up_keeps_periodStart_aligned_and_not_future() public {
        (,, uint64 periodStartBefore,) = hook.unpackedState();
        uint64 elapsed = uint64(PERIOD_SECONDS * 5 + 17);
        vm.warp(uint256(periodStartBefore) + elapsed);

        _swap(true, -1, 0, 0);

        (,, uint64 periodStartAfter,) = hook.unpackedState();
        assertEq(periodStartAfter, periodStartBefore + uint64(PERIOD_SECONDS * 5));
        assertLe(periodStartAfter, uint64(block.timestamp));
    }

    function test_periodVol_saturates_at_uint64_max_under_extreme_volume() public {
        _swap(true, -1, -type(int128).max, 0);

        (uint64 periodVol,,,) = hook.unpackedState();
        assertEq(periodVol, type(uint64).max);
    }

    function test_scaledEma_updates_with_precision() public {
        _swap(true, -1, -10_000_000, 9_500_000);
        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (, uint96 ema1,,) = hook.unpackedState();
        uint96 expected1 = uint96(10_000_000 * 1_000_000);
        assertEq(ema1, expected1);

        _swap(true, -1, -20_000_000, 19_000_000);
        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (, uint96 ema2,,) = hook.unpackedState();
        uint96 expected2 =
            uint96((uint256(expected1) * (EMA_PERIODS - 1) + uint256(20_000_000) * 1_000_000) / EMA_PERIODS);
        assertEq(ema2, expected2);
    }

    function test_stable_decimals_only_6_or_18() public {
        VolumeDynamicFeeHookAdminHarness h6 =
            _deployHarness(V2_DEFAULT_FLOOR_FEE, V2_DEFAULT_CASH_FEE, V2_DEFAULT_EXTREME_FEE, owner, 1, 6);
        assertEq(h6.MODE_FLOOR(), 0);

        VolumeDynamicFeeHookAdminHarness h18 =
            _deployHarness(V2_DEFAULT_FLOOR_FEE, V2_DEFAULT_CASH_FEE, V2_DEFAULT_EXTREME_FEE, owner, 1, 18);
        assertEq(h18.MODE_FLOOR(), 0);

        vm.expectRevert(abi.encodeWithSelector(VolumeDynamicFeeHook.InvalidStableDecimals.selector, uint8(8)));
        _deployHarness(V2_DEFAULT_FLOOR_FEE, V2_DEFAULT_CASH_FEE, V2_DEFAULT_EXTREME_FEE, owner, 1, 8);
    }

    function test_stable_decimals_18_converts_to_usd6_by_division() public {
        VolumeDynamicFeeHookAdminHarness h18 =
            _deployHarness(V2_DEFAULT_FLOOR_FEE, V2_DEFAULT_CASH_FEE, V2_DEFAULT_EXTREME_FEE, owner, 1, 18);
        PoolKey memory key18 = _poolKey(address(h18));
        manager.callAfterInitialize(h18, key18);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        BalanceDelta delta = toBalanceDelta(-int128(6e18), int128(57e17));
        manager.callAfterSwapWithParams(h18, key18, params, delta);

        (uint64 periodVol,,,) = h18.unpackedState();
        assertEq(periodVol, 6_000_000, "18-dec stable amount must be converted to USD6 with division path");
    }

    function test_receive_reverts() public {
        vm.deal(outsider, 1 ether);

        vm.prank(outsider);
        vm.expectRevert(VolumeDynamicFeeHook.EthReceiveRejected.selector);
        (bool ok,) = address(hook).call{value: 1}("");
        ok;
    }

    function test_claimHookFees_and_pause_admin_unpause_integration() public {
        _swap(true, -1, -10_000_000, 9_500_000);
        (uint256 b0, uint256 b1) = hook.hookFeesAccrued();
        assertEq(b0 + b1 > 0, true);

        hook.claimAllHookFees();
        assertEq(manager.unlockCount(), 1, "claim must go through poolManager.unlock");
        assertEq(manager.burnCount() > 0, true, "claim must burn poolManager claim balances");
        assertEq(manager.takeCount() > 0, true, "claim must take from poolManager accounting");
        (b0, b1) = hook.hookFeesAccrued();
        assertEq(b0, 0);
        assertEq(b1, 0);

        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = VolumeDynamicFeeHook.ControllerParams({
            floorToCashMinCloseVolume: V2_FLOOR_TO_CASH_MIN_CLOSE_VOLUME + 1,
            floorToCashMinFlowBps: V2_FLOOR_TO_CASH_MIN_FLOW_BPS,
            cashHoldPeriods: V2_CASH_HOLD_PERIODS,
            cashToExtremeMinCloseVolume: V2_CASH_TO_EXTREME_MIN_CLOSE_VOLUME,
            cashToExtremeMinFlowBps: V2_CASH_TO_EXTREME_MIN_FLOW_BPS,
            cashToExtremeConfirmPeriods: V2_CASH_TO_EXTREME_CONFIRM_PERIODS,
            extremeHoldPeriods: V2_EXTREME_HOLD_PERIODS,
            extremeToCashMaxFlowBps: V2_EXTREME_TO_CASH_MAX_FLOW_BPS,
            extremeToCashConfirmPeriods: V2_EXTREME_TO_CASH_CONFIRM_PERIODS,
            cashToFloorMaxFlowBps: V2_CASH_TO_FLOOR_MAX_FLOW_BPS,
            cashToFloorConfirmPeriods: V2_CASH_TO_FLOOR_CONFIRM_PERIODS,
            emergencyToFloorMaxCloseVolume: V2_EMERGENCY_TO_FLOOR_MAX_CLOSE_VOLUME,
            emergencyToFloorConfirmPeriods: V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS
        });
        hook.setControllerParams(p);
        hook.setTimingParams(PERIOD_SECONDS, EMA_PERIODS, LULL_RESET_SECONDS);

        hook.unpause();
        assertFalse(hook.isPaused());

        _swap(true, -1, -6_000_000, 5_700_000);
        (uint64 pv,,,) = hook.unpackedState();
        assertEq(pv, 6_000_000);
    }
}
