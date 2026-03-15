// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {GasMeasurementLib} from "../../shared/lib/GasMeasurementLib.sol";
import {GasMeasurementLocalBase} from "../../local/foundry/GasMeasurementLocalBase.sol";

contract MeasureGasLocalScenarioTest is Test, GasMeasurementLocalBase {
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

        _setUpMeasurementEnv();
    }

    function test_floorToCash_measurement_path_ends_in_cash() public {
        _runOperation(GasMeasurementLib.Operation.FloorToCash);
        _assertRegime(hook.REGIME_CASH());
    }

    function test_cashToExtreme_measurement_path_ends_in_extreme() public {
        _runOperation(GasMeasurementLib.Operation.CashToExtreme);
        _assertRegime(hook.REGIME_EXTREME());
    }

    function test_extremeToCash_measurement_path_ends_in_cash() public {
        _runOperation(GasMeasurementLib.Operation.ExtremeToCash);
        _assertRegime(hook.REGIME_CASH());
    }

    function test_cashToFloor_measurement_path_ends_in_floor() public {
        _runOperation(GasMeasurementLib.Operation.CashToFloor);
        _assertRegime(hook.REGIME_FLOOR());
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
