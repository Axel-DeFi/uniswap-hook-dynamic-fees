// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "../../tests/mocks/MockPoolManager.sol";
import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {GasMeasurementLib} from "../../shared/lib/GasMeasurementLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract VolumeDynamicFeeHookGasLocalHarness is VolumeDynamicFeeHook {
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
        uint64 _minCloseVolToCashUsd6,
        uint16 _cashEnterTriggerBps,
        uint8 _cashHoldPeriods,
        uint64 _minCloseVolToExtremeUsd6,
        uint16 _extremeEnterTriggerBps,
        uint8 _upExtremeConfirmPeriods,
        uint8 _extremeHoldPeriods,
        uint16 _extremeExitTriggerBps,
        uint8 _downExtremeConfirmPeriods,
        uint16 _cashExitTriggerBps,
        uint8 _downCashConfirmPeriods,
        uint64 _emergencyFloorCloseVolUsd6,
        uint8 _emergencyConfirmPeriods
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
            _minCloseVolToCashUsd6,
            _cashEnterTriggerBps,
            _cashHoldPeriods,
            _minCloseVolToExtremeUsd6,
            _extremeEnterTriggerBps,
            _upExtremeConfirmPeriods,
            _extremeHoldPeriods,
            _extremeExitTriggerBps,
            _downExtremeConfirmPeriods,
            _cashExitTriggerBps,
            _downCashConfirmPeriods,
            _emergencyFloorCloseVolUsd6,
            _emergencyConfirmPeriods
        )
    {}

    function validateHookAddress(BaseHook) internal pure override {}
}

abstract contract GasMeasurementLocalBase is CommonBase {
    address internal constant TOKEN0 = address(0x0000000000000000000000000000000000001111);
    address internal constant TOKEN1 = address(0x0000000000000000000000000000000000002222);

    MockPoolManager internal manager;
    VolumeDynamicFeeHookGasLocalHarness internal hook;
    PoolKey internal key;
    OpsTypes.CoreConfig internal cfg;

    function _setUpMeasurementEnv() internal {
        cfg = _loadMeasurementConfig();
        address ownerAddr = cfg.privateKey != 0 ? vm.addr(cfg.privateKey) : cfg.owner;
        manager = new MockPoolManager();
        hook = new VolumeDynamicFeeHookGasLocalHarness(
            IPoolManager(address(manager)),
            Currency.wrap(TOKEN0),
            Currency.wrap(TOKEN1),
            cfg.tickSpacing,
            Currency.wrap(TOKEN0),
            cfg.stableDecimals,
            cfg.floorFeePips,
            cfg.cashFeePips,
            cfg.extremeFeePips,
            cfg.periodSeconds,
            cfg.emaPeriods,
            cfg.lullResetSeconds,
            ownerAddr,
            cfg.hookFeePercent,
            cfg.minCloseVolToCashUsd6,
            cfg.cashEnterTriggerBps,
            cfg.cashHoldPeriods,
            cfg.minCloseVolToExtremeUsd6,
            cfg.extremeEnterTriggerBps,
            cfg.upExtremeConfirmPeriods,
            cfg.extremeHoldPeriods,
            cfg.extremeExitTriggerBps,
            cfg.downExtremeConfirmPeriods,
            cfg.cashExitTriggerBps,
            cfg.downCashConfirmPeriods,
            cfg.emergencyFloorCloseVolUsd6,
            cfg.emergencyConfirmPeriods
        );

        key = PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(address(hook))
        });

        manager.callAfterInitialize(hook, key);
    }

    function _loadMeasurementConfig() internal view virtual returns (OpsTypes.CoreConfig memory) {
        return ConfigLoader.loadCoreConfig();
    }

    function _runOperation(GasMeasurementLib.Operation op) internal {
        if (op == GasMeasurementLib.Operation.NormalSwap) {
            _measureNormalSwap();
            return;
        }
        if (op == GasMeasurementLib.Operation.PeriodClose) {
            _measurePeriodClose();
            return;
        }
        if (op == GasMeasurementLib.Operation.FloorToCash) {
            _measureFloorToCash();
            return;
        }
        if (op == GasMeasurementLib.Operation.CashToExtreme) {
            _measureCashToExtreme();
            return;
        }
        if (op == GasMeasurementLib.Operation.ExtremeToCash) {
            _measureExtremeToCash();
            return;
        }
        if (op == GasMeasurementLib.Operation.CashToFloor) {
            _measureCashToFloor();
            return;
        }
        if (op == GasMeasurementLib.Operation.LullReset) {
            _measureLullReset();
            return;
        }
        if (op == GasMeasurementLib.Operation.Pause) {
            hook.pause();
            return;
        }
        if (op == GasMeasurementLib.Operation.Unpause) {
            hook.pause();
            hook.unpause();
            return;
        }
        if (op == GasMeasurementLib.Operation.EmergencyResetToFloor) {
            _moveToCash();
            hook.pause();
            hook.emergencyResetToFloor();
            return;
        }
        if (op == GasMeasurementLib.Operation.EmergencyResetToCash) {
            hook.pause();
            hook.emergencyResetToCash();
            return;
        }

        _measureClaimAllHookFees();
    }

    function _measureNormalSwap() internal {
        _swapStable(_seedStableRaw());
    }

    function _measurePeriodClose() internal {
        _swapStable(_seedStableRaw());
        _warpPeriod();
        _swapStable(_minCountedStableRaw());
    }

    function _measureFloorToCash() internal {
        _primeFloorToCash();
        _completeFloorToCash(_minCountedUsd6());
    }

    function _measureCashToExtreme() internal {
        _primeCashToExtreme();
        _completeCashToExtreme(_minCountedUsd6());
    }

    function _measureExtremeToCash() internal {
        _primeExtremeToCash();
        _warpPeriod();
        _swapStable(_minCountedStableRaw());
        _assertRegime(hook.REGIME_CASH());
    }

    function _measureCashToFloor() internal {
        _primeCashToFloor();
        _warpPeriod();
        _swapStable(_minCountedStableRaw());
        _assertRegime(hook.REGIME_FLOOR());
    }

    function _measureLullReset() internal {
        _moveToCash();
        vm.warp(block.timestamp + uint256(cfg.lullResetSeconds) + 1);
        _swapStable(_minCountedStableRaw());
        _assertRegime(hook.REGIME_FLOOR());
    }

    function _measureClaimAllHookFees() internal {
        _swapStable(_seedStableRaw());
        hook.claimAllHookFees();
    }

    function _moveToCash() internal {
        _primeFloorToCash();
        _completeFloorToCash(_minCountedUsd6());
    }

    function _primeFloorToCash() internal {
        uint64 seedUsd6 = _seedUsd6();
        _swapStable(GasMeasurementLib.usd6ToStableRaw(seedUsd6, cfg.stableDecimals));

        uint16 passThreshold = cfg.cashEnterTriggerBps;
        uint64 cashUsd6 = _chooseNextUpOpenPeriodUsd6(passThreshold, cfg.minCloseVolToCashUsd6);
        _warpPeriod();
        _swapStable(GasMeasurementLib.usd6ToStableRaw(cashUsd6, cfg.stableDecimals));
        _assertRegime(hook.REGIME_FLOOR());
    }

    function _completeFloorToCash(uint64 nextOpenUsd6) internal {
        _warpPeriod();
        _swapStable(GasMeasurementLib.usd6ToStableRaw(nextOpenUsd6, cfg.stableDecimals));
        _assertRegime(hook.REGIME_CASH());
    }

    function _primeCashToExtreme() internal {
        uint16 passThreshold = cfg.extremeEnterTriggerBps;
        _primeFloorToCash();
        _completeFloorToCash(_chooseNextUpOpenPeriodUsd6(passThreshold, cfg.minCloseVolToExtremeUsd6));

        _warpPeriod();
        _swapStable(
            GasMeasurementLib.usd6ToStableRaw(
                _chooseNextUpOpenPeriodUsd6(passThreshold, cfg.minCloseVolToExtremeUsd6), cfg.stableDecimals
            )
        );
        _assertRegime(hook.REGIME_CASH());
    }

    function _completeCashToExtreme(uint64 nextOpenUsd6) internal {
        _warpPeriod();
        _swapStable(GasMeasurementLib.usd6ToStableRaw(nextOpenUsd6, cfg.stableDecimals));
        _assertRegime(hook.REGIME_EXTREME());
    }

    function _primeExtremeToCash() internal {
        uint16 downPassThreshold = cfg.extremeExitTriggerBps;
        _primeCashToExtreme();
        _completeCashToExtreme(_chooseNextDownOpenPeriodUsd6(downPassThreshold));

        for (uint256 i = 0; i < uint256(cfg.extremeHoldPeriods); ++i) {
            uint64 nextDownUsd6 = _chooseNextDownOpenPeriodUsd6(downPassThreshold);
            _warpPeriod();
            _swapStable(GasMeasurementLib.usd6ToStableRaw(nextDownUsd6, cfg.stableDecimals));
            _assertRegime(hook.REGIME_EXTREME());
        }
    }

    function _primeCashToFloor() internal {
        uint16 downPassThreshold = cfg.cashExitTriggerBps;
        _primeExtremeToCash();

        _warpPeriod();
        _swapStable(
            GasMeasurementLib.usd6ToStableRaw(_chooseNextDownOpenPeriodUsd6(downPassThreshold), cfg.stableDecimals)
        );
        _assertRegime(hook.REGIME_CASH());

        for (uint256 i = 0; i + 1 < uint256(cfg.downCashConfirmPeriods); ++i) {
            uint64 nextDownUsd6 = _chooseNextDownOpenPeriodUsd6(downPassThreshold);
            _warpPeriod();
            _swapStable(GasMeasurementLib.usd6ToStableRaw(nextDownUsd6, cfg.stableDecimals));
            _assertRegime(hook.REGIME_CASH());
        }
    }

    function _swapStable(uint256 amountStableRaw) internal {
        require(amountStableRaw <= uint256(type(uint128).max >> 1), "stable amount too large");

        int128 stableAmount = int128(uint128(amountStableRaw));
        uint256 otherRaw = amountStableRaw > 10 ? (amountStableRaw * 9) / 10 : amountStableRaw;
        require(otherRaw <= uint256(type(uint128).max >> 1), "other amount too large");
        int128 otherAmount = int128(uint128(otherRaw));

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountStableRaw), sqrtPriceLimitX96: 0});
        BalanceDelta delta = toBalanceDelta(-stableAmount, otherAmount);
        manager.callAfterSwapWithParams(hook, key, params, delta);
    }

    function _warpPeriod() internal {
        vm.warp(block.timestamp + uint256(cfg.periodSeconds));
    }

    function _assertRegime(uint8 expected) internal view {
        (,,, uint8 feeIdx) = hook.unpackedState();
        require(feeIdx == expected, "unexpected regime");
    }

    function _seedUsd6() internal view returns (uint64) {
        uint64 floor = cfg.minCloseVolToCashUsd6;
        uint64 minCounted = uint64(cfg.minCountedSwapUsd6);
        return floor > minCounted ? floor : minCounted;
    }

    function _minCountedUsd6() internal view returns (uint64) {
        return uint64(cfg.minCountedSwapUsd6);
    }

    function _seedStableRaw() internal view returns (uint256) {
        return GasMeasurementLib.usd6ToStableRaw(_seedUsd6(), cfg.stableDecimals);
    }

    function _minCountedStableRaw() internal view returns (uint256) {
        return GasMeasurementLib.usd6ToStableRaw(_minCountedUsd6(), cfg.stableDecimals);
    }

    function _chooseNextUpOpenPeriodUsd6(uint16 passThresholdBps, uint64 minCloseVolUsd6)
        internal
        view
        returns (uint64 nextOpenUsd6)
    {
        (uint64 periodVol, uint96 emaScaled) = _periodVolAndEma();
        uint96 emaAfterClose = GasMeasurementLib.updateEmaScaled(emaScaled, periodVol, cfg.emaPeriods);
        nextOpenUsd6 =
            GasMeasurementLib.minUpPassCloseVolUsd6(emaAfterClose, cfg.emaPeriods, passThresholdBps, minCloseVolUsd6);
    }

    function _chooseNextDownOpenPeriodUsd6(uint16 passThresholdBps) internal view returns (uint64 nextOpenUsd6) {
        (uint64 periodVol, uint96 emaScaled) = _periodVolAndEma();
        uint96 emaAfterClose = GasMeasurementLib.updateEmaScaled(emaScaled, periodVol, cfg.emaPeriods);
        nextOpenUsd6 = GasMeasurementLib.chooseDownPassCloseVolUsd6(
            emaAfterClose,
            cfg.emaPeriods,
            passThresholdBps,
            uint64(cfg.minCountedSwapUsd6),
            cfg.emergencyFloorCloseVolUsd6
        );
    }

    function _periodVolAndEma() internal view returns (uint64 periodVol, uint96 emaScaled) {
        (periodVol, emaScaled,,) = hook.unpackedState();
    }
}
