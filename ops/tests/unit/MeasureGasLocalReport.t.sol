// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {GasMeasurementLib} from "../../shared/lib/GasMeasurementLib.sol";
import {GasMeasurementLocalBase} from "../../local/foundry/GasMeasurementLocalBase.sol";

contract MeasureGasLocalReportTest is Test, GasMeasurementLocalBase {
    uint256 internal constant OPERATION_COUNT = 12;

    function setUp() public {
        vm.setEnv("OPS_RUNTIME", "local");
        vm.setEnv("PRIVATE_KEY", "1");
        vm.setEnv("POOL_MANAGER", "0x0000000000000000000000000000000000000001");
        vm.setEnv("VOLATILE", "0x0000000000000000000000000000000000000002");
        vm.setEnv("STABLE", "0x0000000000000000000000000000000000000003");
        vm.setEnv("STABLE_DECIMALS", "6");
        vm.setEnv("TICK_SPACING", "10");
        vm.setEnv("OWNER", "0x000000000000000000000000000000000000BEEF");
        vm.setEnv("FLOOR_FEE_PIPS", "400");
        vm.setEnv("CASH_FEE_PIPS", "2500");
        vm.setEnv("EXTREME_FEE_PIPS", "9000");
        vm.setEnv("PERIOD_SECONDS", "60");
        vm.setEnv("EMA_PERIODS", "8");
        vm.setEnv("DEADBAND_PERCENT", "5");
        vm.setEnv("LULL_RESET_SECONDS", "600");
        vm.setEnv("HOOK_FEE_PERCENT", "10");
        vm.setEnv("MIN_COUNTED_SWAP_USD6", "4000000");
        vm.setEnv("MIN_VOLUME_TO_ENTER_CASH_USD", "1000");
        vm.setEnv("CASH_ENTER_EMA_PERCENT", "180");
        vm.setEnv("CASH_HOLD_PERIODS", "4");
        vm.setEnv("MIN_VOLUME_TO_ENTER_EXTREME_USD", "4000");
        vm.setEnv("EXTREME_ENTER_EMA_PERCENT", "400");
        vm.setEnv("ENTER_EXTREME_CONFIRM_PERIODS", "2");
        vm.setEnv("EXTREME_HOLD_PERIODS", "4");
        vm.setEnv("EXTREME_EXIT_EMA_PERCENT", "130");
        vm.setEnv("EXIT_EXTREME_CONFIRM_PERIODS", "2");
        vm.setEnv("CASH_EXIT_EMA_PERCENT", "130");
        vm.setEnv("EXIT_CASH_CONFIRM_PERIODS", "3");
        vm.setEnv("EMERGENCY_FLOOR_TRIGGER_USD", "600");
        vm.setEnv("EMERGENCY_CONFIRM_PERIODS", "3");
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
