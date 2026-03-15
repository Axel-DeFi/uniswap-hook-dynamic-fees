// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {CanonicalHookResolverLib} from "../lib/CanonicalHookResolverLib.sol";
import {ConfigLoader} from "../lib/ConfigLoader.sol";
import {BudgetLib} from "../lib/BudgetLib.sol";
import {DriverValidationLib} from "../lib/DriverValidationLib.sol";
import {LoggingLib} from "../lib/LoggingLib.sol";
import {GasMeasurementLib} from "../lib/GasMeasurementLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";
import {LiveOpsBase} from "./LiveOpsBase.s.sol";

interface ISwapDriver {
    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    function swap(
        PoolKey memory key,
        SwapParams memory params,
        TestSettings memory testSettings,
        bytes memory hookData
    ) external payable;
}

contract MeasureGasLive is LiveOpsBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    OpsTypes.CoreConfig internal cfg;
    VolumeDynamicFeeHook internal hook;
    PoolKey internal key;
    address internal driver;

    function run() external {
        LoggingLib.phase(_phase("gas-measure"));

        string memory rawOperation = vm.envString("OPS_GAS_OPERATION");
        GasMeasurementLib.Operation operation = GasMeasurementLib.parseOperation(rawOperation);

        cfg = ConfigLoader.loadCoreConfig();
        OpsTypes.DeploymentConfig memory deployCfg = ConfigLoader.loadDeploymentConfig(cfg);
        ConfigLoader.requireDeploymentBindingConsistency(cfg, deployCfg);
        (cfg,) = CanonicalHookResolverLib.requireExistingCanonicalHook(cfg, deployCfg);

        OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        require(budget.ok, budget.reason);

        hook = VolumeDynamicFeeHook(payable(cfg.hookAddress));
        key = PoolKey({
            currency0: Currency.wrap(cfg.token0),
            currency1: Currency.wrap(cfg.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.hookAddress)
        });

        driver = vm.envOr("SWAP_DRIVER", address(0));
        DriverValidationLib.requireValidSwapDriver(driver, cfg.poolManager);

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        vm.startBroadcast(pk);
        _runOperation(operation);
        vm.stopBroadcast();
    }

    function _runOperation(GasMeasurementLib.Operation operation) internal {
        if (operation == GasMeasurementLib.Operation.Pause) {
            _resetToFloorUnpaused();
            hook.pause();
            return;
        }
        if (operation == GasMeasurementLib.Operation.Unpause) {
            _resetToFloorUnpaused();
            hook.pause();
            hook.unpause();
            return;
        }
        if (operation == GasMeasurementLib.Operation.EmergencyResetToFloor) {
            _moveToCash();
            hook.pause();
            hook.emergencyResetToFloor();
            return;
        }
        if (operation == GasMeasurementLib.Operation.EmergencyResetToCash) {
            _resetToFloorUnpaused();
            hook.pause();
            hook.emergencyResetToCash();
            return;
        }
        if (operation == GasMeasurementLib.Operation.ClaimAllHookFees) {
            _resetToFloorUnpaused();
            _swapStableUsd6(_seedUsd6());
            hook.claimAllHookFees();
            return;
        }
        if (operation == GasMeasurementLib.Operation.NormalSwap) {
            _resetToFloorUnpaused();
            _swapStableUsd6(_seedUsd6());
            return;
        }
        if (operation == GasMeasurementLib.Operation.PeriodClose) {
            _resetToFloorUnpaused();
            _swapStableUsd6(_seedUsd6());
            _swapStableUsd6(_minCountedUsd6());
            return;
        }
        if (operation == GasMeasurementLib.Operation.FloorToCash) {
            _resetToFloorUnpaused();
            _primeFloorToCash();
            _completeFloorToCash(_minCountedUsd6());
            return;
        }
        if (operation == GasMeasurementLib.Operation.CashToExtreme) {
            _resetToFloorUnpaused();
            _primeCashToExtreme();
            _completeCashToExtreme(_minCountedUsd6());
            return;
        }
        if (operation == GasMeasurementLib.Operation.ExtremeToCash) {
            _resetToFloorUnpaused();
            _primeExtremeToCash();
            _swapStableUsd6(_minCountedUsd6());
            _assertRegime(hook.REGIME_CASH());
            return;
        }
        if (operation == GasMeasurementLib.Operation.CashToFloor) {
            _resetToFloorUnpaused();
            _primeCashToFloor();
            _swapStableUsd6(_minCountedUsd6());
            _assertRegime(hook.REGIME_FLOOR());
            return;
        }

        _resetToFloorUnpaused();
        _swapStableUsd6(_seedUsd6());
        _swapStableUsd6(_minCountedUsd6());
        _assertRegime(hook.REGIME_FLOOR());
    }

    function _resetToFloorUnpaused() internal {
        if (!hook.isPaused()) {
            hook.pause();
        }
        hook.emergencyResetToFloor();
        hook.unpause();
        _assertRegime(hook.REGIME_FLOOR());
    }

    function _moveToCash() internal {
        _primeFloorToCash();
        _completeFloorToCash(_minCountedUsd6());
    }

    function _primeFloorToCash() internal {
        _swapStableUsd6(_seedUsd6());
        _swapStableUsd6(_chooseNextUpOpenPeriodUsd6(hook.cashEnterTriggerBps(), hook.minCloseVolToCashUsd6()));
        _assertRegime(hook.REGIME_FLOOR());
    }

    function _completeFloorToCash(uint64 nextOpenUsd6) internal {
        _swapStableUsd6(nextOpenUsd6);
        _assertRegime(hook.REGIME_CASH());
    }

    function _primeCashToExtreme() internal {
        uint16 passThreshold = hook.extremeEnterTriggerBps();
        _primeFloorToCash();
        _completeFloorToCash(_chooseNextUpOpenPeriodUsd6(passThreshold, hook.minCloseVolToExtremeUsd6()));
        _swapStableUsd6(_chooseNextUpOpenPeriodUsd6(passThreshold, hook.minCloseVolToExtremeUsd6()));
        _assertRegime(hook.REGIME_CASH());
    }

    function _completeCashToExtreme(uint64 nextOpenUsd6) internal {
        _swapStableUsd6(nextOpenUsd6);
        _assertRegime(hook.REGIME_EXTREME());
    }

    function _primeExtremeToCash() internal {
        uint16 downPassThreshold = hook.extremeExitTriggerBps();
        _primeCashToExtreme();
        _completeCashToExtreme(_chooseNextDownOpenPeriodUsd6(downPassThreshold));

        for (uint256 i = 0; i < uint256(hook.extremeHoldPeriods()); ++i) {
            _swapStableUsd6(_chooseNextDownOpenPeriodUsd6(downPassThreshold));
            _assertRegime(hook.REGIME_EXTREME());
        }
    }

    function _primeCashToFloor() internal {
        uint16 downPassThreshold = hook.cashExitTriggerBps();
        _primeExtremeToCash();

        _swapStableUsd6(_chooseNextDownOpenPeriodUsd6(downPassThreshold));
        _assertRegime(hook.REGIME_CASH());

        for (uint256 i = 0; i + 1 < uint256(hook.downCashConfirmPeriods()); ++i) {
            _swapStableUsd6(_chooseNextDownOpenPeriodUsd6(downPassThreshold));
            _assertRegime(hook.REGIME_CASH());
        }
    }

    function _chooseNextUpOpenPeriodUsd6(uint16 passThresholdBps, uint64 minCloseVolUsd6)
        internal
        view
        returns (uint64 nextOpenUsd6)
    {
        (uint64 periodVol, uint96 emaScaled,,) = hook.unpackedState();
        uint96 emaAfterClose = GasMeasurementLib.updateEmaScaled(emaScaled, periodVol, hook.emaPeriods());
        nextOpenUsd6 = GasMeasurementLib.minUpPassCloseVolUsd6(
            emaAfterClose, hook.emaPeriods(), passThresholdBps, minCloseVolUsd6
        );
    }

    function _chooseNextDownOpenPeriodUsd6(uint16 passThresholdBps) internal view returns (uint64 nextOpenUsd6) {
        (uint64 periodVol, uint96 emaScaled,,) = hook.unpackedState();
        uint96 emaAfterClose = GasMeasurementLib.updateEmaScaled(emaScaled, periodVol, hook.emaPeriods());
        nextOpenUsd6 = GasMeasurementLib.chooseDownPassCloseVolUsd6(
            emaAfterClose,
            hook.emaPeriods(),
            passThresholdBps,
            hook.minCountedSwapUsd6(),
            hook.emergencyFloorCloseVolUsd6()
        );
    }

    function _swapStableUsd6(uint64 amountUsd6) internal {
        uint256 amountRaw = GasMeasurementLib.usd6ToStableRaw(amountUsd6, cfg.stableDecimals);
        _swapStableRaw(amountRaw);
    }

    function _swapStableRaw(uint256 amountStableRaw) internal {
        require(amountStableRaw > 0, "stable swap amount is zero");

        IPoolManager manager = IPoolManager(cfg.poolManager);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());

        bool stableZeroForOne = cfg.stableToken == cfg.token0;
        require(_directionAllowed(stableZeroForOne, sqrtPriceX96), "stable swap direction unavailable");

        SwapParams memory params = SwapParams({
            zeroForOne: stableZeroForOne,
            amountSpecified: -int256(amountStableRaw),
            sqrtPriceLimitX96: stableZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        uint256 value = cfg.stableToken == address(0) ? amountStableRaw : 0;
        ISwapDriver(driver).swap{value: value}(key, params, ISwapDriver.TestSettings(false, false), "");
    }

    function _directionAllowed(bool zeroForOne, uint160 sqrtPriceX96) internal pure returns (bool) {
        if (zeroForOne) {
            return sqrtPriceX96 > TickMath.MIN_SQRT_PRICE + 1;
        }
        return sqrtPriceX96 < TickMath.MAX_SQRT_PRICE - 1;
    }

    function _assertRegime(uint8 expected) internal view {
        (,,, uint8 feeIdx) = hook.unpackedState();
        require(feeIdx == expected, "unexpected regime");
    }

    function _seedUsd6() internal view returns (uint64) {
        uint64 floor = hook.minCloseVolToCashUsd6();
        uint64 minCounted = hook.minCountedSwapUsd6();
        return floor > minCounted ? floor : minCounted;
    }

    function _minCountedUsd6() internal view returns (uint64) {
        return hook.minCountedSwapUsd6();
    }
}
