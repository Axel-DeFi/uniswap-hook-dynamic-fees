// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {GasMeasurementLib} from "../../shared/lib/GasMeasurementLib.sol";
import {GasMeasurementLocalBase} from "../../local/foundry/GasMeasurementLocalBase.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract MeasureGasLocalScenarioTest is Test, GasMeasurementLocalBase {
    function setUp() public {
        _setUpMeasurementEnv();
    }

    function _loadMeasurementConfig() internal pure override returns (OpsTypes.CoreConfig memory cfg) {
        cfg.runtime = OpsTypes.Runtime.Local;
        cfg.privateKey = 1;
        cfg.tickSpacing = 10;
        cfg.stableDecimals = 6;
        cfg.floorFeePips = 400;
        cfg.cashFeePips = 2_500;
        cfg.extremeFeePips = 9_000;
        cfg.periodSeconds = 60;
        cfg.emaPeriods = 8;
        cfg.lullResetSeconds = 600;
        cfg.hookFeePercent = 10;
        cfg.minCountedSwapVolume = 4_000_000;
        cfg.floorToCashMinCloseVolume = 1_000 * 1e6;
        cfg.floorToCashMinFlowBps = 18_500;
        cfg.cashHoldPeriods = 4;
        cfg.cashToExtremeMinCloseVolume = 4_000 * 1e6;
        cfg.cashToExtremeMinFlowBps = 40_500;
        cfg.cashToExtremeConfirmPeriods = 2;
        cfg.extremeHoldPeriods = 4;
        cfg.extremeToCashMaxFlowBps = 12_500;
        cfg.extremeToCashConfirmPeriods = 2;
        cfg.cashToFloorMaxFlowBps = 12_500;
        cfg.cashToFloorConfirmPeriods = 3;
        cfg.emergencyToFloorMaxCloseVolume = 600 * 1e6;
        cfg.emergencyToFloorConfirmPeriods = 3;
    }

    function test_floorToCash_measurement_path_ends_in_cash() public {
        _runOperation(GasMeasurementLib.Operation.FloorToCash);
        _assertMode(hook.MODE_CASH());
    }

    function test_cashToExtreme_measurement_path_ends_in_extreme() public {
        _runOperation(GasMeasurementLib.Operation.CashToExtreme);
        _assertMode(hook.MODE_EXTREME());
    }

    function test_extremeToCash_measurement_path_ends_in_cash() public {
        _runOperation(GasMeasurementLib.Operation.ExtremeToCash);
        _assertMode(hook.MODE_CASH());
    }

    function test_cashToFloor_measurement_path_ends_in_floor() public {
        _runOperation(GasMeasurementLib.Operation.CashToFloor);
        _assertMode(hook.MODE_FLOOR());
    }

    function test_claimAllHookFees_measurement_path_clears_accrued_balances() public {
        vm.startPrank(vm.addr(1));
        _runOperation(GasMeasurementLib.Operation.ClaimAllHookFees);
        vm.stopPrank();
        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        assertEq(fees0, 0);
        assertEq(fees1, 0);
    }
}
