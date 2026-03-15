// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {GasMeasurementLib} from "../../shared/lib/GasMeasurementLib.sol";
import {GasMeasurementLocalBase} from "../../local/foundry/GasMeasurementLocalBase.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract MeasureGasLocalReportTest is Test, GasMeasurementLocalBase {
    uint256 internal constant OPERATION_COUNT = 12;

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
        cfg.minCountedSwapUsd6 = 4_000_000;
        cfg.minCloseVolToCashUsd6 = 1_000 * 1e6;
        cfg.cashEnterTriggerBps = 18_500;
        cfg.cashHoldPeriods = 4;
        cfg.minCloseVolToExtremeUsd6 = 4_000 * 1e6;
        cfg.extremeEnterTriggerBps = 40_500;
        cfg.upExtremeConfirmPeriods = 2;
        cfg.extremeHoldPeriods = 4;
        cfg.extremeExitTriggerBps = 12_500;
        cfg.downExtremeConfirmPeriods = 2;
        cfg.cashExitTriggerBps = 12_500;
        cfg.downCashConfirmPeriods = 3;
        cfg.emergencyFloorCloseVolUsd6 = 600 * 1e6;
        cfg.emergencyConfirmPeriods = 3;
    }

    function test_write_local_gas_samples() public {
        uint256 runs = vm.envOr("OPS_GAS_RUNS", uint256(5));
        string memory samplesPath = vm.envOr(
            "OPS_GAS_SAMPLES_PATH",
            string.concat(vm.projectRoot(), "/ops/local/out/reports/gas.samples.local.json")
        );

        string memory json = "[";
        bool first = true;

        for (uint256 opIndex = 0; opIndex < OPERATION_COUNT; ++opIndex) {
            GasMeasurementLib.Operation operation = GasMeasurementLib.Operation(opIndex);
            string memory label = GasMeasurementLib.label(operation);

            for (uint256 run = 1; run <= runs; ++run) {
                uint256 gasUsed = _measureOperation(operation);

                if (!first) {
                    json = string.concat(json, ",");
                }
                first = false;

                json = string.concat(
                    json,
                    "{",
                    '"network":"local",',
                    '"chainId":31337,',
                    '"operation":"',
                    label,
                    '",',
                    '"run":',
                    vm.toString(run),
                    ",",
                    '"txHash":"",',
                    '"gasUsed":',
                    vm.toString(gasUsed),
                    ",",
                    '"effectiveGasPriceWei":0',
                    "}"
                );
            }
        }

        json = string.concat(json, "]");
        vm.writeFile(samplesPath, json);
    }

    function _measureOperation(GasMeasurementLib.Operation operation) internal returns (uint256 gasUsed) {
        vm.pauseGasMetering();
        _setUpMeasurementEnv();

        bool ownerOp = operation == GasMeasurementLib.Operation.Pause
            || operation == GasMeasurementLib.Operation.Unpause
            || operation == GasMeasurementLib.Operation.EmergencyResetToFloor
            || operation == GasMeasurementLib.Operation.EmergencyResetToCash
            || operation == GasMeasurementLib.Operation.ClaimAllHookFees;

        if (ownerOp) {
            vm.startPrank(vm.addr(1));
        }

        vm.resumeGasMetering();
        uint256 gasBefore = gasleft();
        _runOperation(operation);
        gasUsed = gasBefore - gasleft();
        vm.pauseGasMetering();

        if (ownerOp) {
            vm.stopPrank();
        }
    }
}
