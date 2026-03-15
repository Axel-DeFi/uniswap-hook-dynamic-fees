// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {ErrorLib} from "../../shared/lib/ErrorLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract DeploymentConfigHarness {
    function loadDeploymentConfig() external view returns (OpsTypes.DeploymentConfig memory cfg) {
        OpsTypes.CoreConfig memory runtimeCfg = ConfigLoader.loadCoreConfig();
        return ConfigLoader.loadDeploymentConfig(runtimeCfg);
    }

    function requireDeploymentBindingConsistency(
        OpsTypes.CoreConfig memory runtimeCfg,
        OpsTypes.DeploymentConfig memory deployCfg
    ) external pure {
        ConfigLoader.requireDeploymentBindingConsistency(runtimeCfg, deployCfg);
    }
}

contract ConfigLoaderDeploymentSnapshotTest is Test {
    DeploymentConfigHarness internal harness;

    function setUp() public {
        harness = new DeploymentConfigHarness();
    }

    function test_loadDeploymentConfig_live_uses_frozen_deploy_snapshot() public {
        _setBaseRuntimeEnv();
        OpsTypes.DeploymentConfig memory deployCfg = harness.loadDeploymentConfig();

        assertEq(deployCfg.poolManager, address(0x000000000000000000000000000000000000aaaa));
        assertEq(deployCfg.token0, address(0x0000000000000000000000000000000000007777));
        assertEq(deployCfg.token1, address(0x0000000000000000000000000000000000009999));
        assertEq(deployCfg.tickSpacing, 60);
        assertEq(deployCfg.stableToken, address(0x0000000000000000000000000000000000009999));
        assertEq(deployCfg.stableDecimals, 18);
        assertEq(deployCfg.owner, address(0xBEEF));
        assertEq(deployCfg.floorFeePips, 400);
        assertEq(deployCfg.cashFeePips, 2_500);
        assertEq(deployCfg.extremeFeePips, 9_000);
        assertEq(deployCfg.periodSeconds, 300);
        assertEq(deployCfg.emaPeriods, 8);
        assertEq(deployCfg.deadbandBps, 500);
        assertEq(deployCfg.lullResetSeconds, 3_600);
        assertEq(deployCfg.hookFeePercent, 1);
        assertEq(deployCfg.minCloseVolToCashUsd6, 1_000_000_000);
        assertEq(deployCfg.upRToCashBps, 18_000);
        assertEq(deployCfg.cashHoldPeriods, 4);
        assertEq(deployCfg.minCloseVolToExtremeUsd6, 4_000_000_000);
        assertEq(deployCfg.upRToExtremeBps, 40_000);
        assertEq(deployCfg.upExtremeConfirmPeriods, 2);
        assertEq(deployCfg.extremeHoldPeriods, 4);
        assertEq(deployCfg.downRFromExtremeBps, 13_000);
        assertEq(deployCfg.downExtremeConfirmPeriods, 2);
        assertEq(deployCfg.downRFromCashBps, 13_000);
        assertEq(deployCfg.downCashConfirmPeriods, 3);
        assertEq(deployCfg.emergencyFloorCloseVolUsd6, 600_000_000);
        assertEq(deployCfg.emergencyConfirmPeriods, 3);
    }

    function test_loadDeploymentConfig_live_rejects_zero_deploy_owner() public {
        _setBaseRuntimeEnv();
        vm.setEnv("DEPLOY_OWNER", "0x0000000000000000000000000000000000000000");
        vm.expectRevert(abi.encodeWithSelector(ErrorLib.InvalidEnv.selector, "DEPLOY_OWNER", "zero address"));
        harness.loadDeploymentConfig();
        vm.setEnv("DEPLOY_OWNER", "0x000000000000000000000000000000000000beef");
    }

    function test_requireDeploymentBindingConsistency_rejects_runtime_binding_drift() public {
        _setBaseRuntimeEnv();
        OpsTypes.CoreConfig memory runtimeCfg = ConfigLoader.loadCoreConfig();
        OpsTypes.DeploymentConfig memory deployCfg = harness.loadDeploymentConfig();

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorLib.InvalidEnv.selector, "POOL_MANAGER", "must match DEPLOY_POOL_MANAGER"
            )
        );
        harness.requireDeploymentBindingConsistency(runtimeCfg, deployCfg);
    }

    function _setBaseRuntimeEnv() internal {
        vm.setEnv("OPS_RUNTIME", "live");
        vm.setEnv("RPC_URL", "http://127.0.0.1:8545");
        vm.setEnv("CHAIN_ID_EXPECTED", "31337");
        vm.setEnv("POOL_MANAGER", "0x0000000000000000000000000000000000001111");
        vm.setEnv("VOLATILE", "0x0000000000000000000000000000000000002222");
        vm.setEnv("STABLE", "0x0000000000000000000000000000000000003333");
        vm.setEnv("STABLE_DECIMALS", "6");
        vm.setEnv("TICK_SPACING", "10");
        vm.setEnv("OWNER", "0x0000000000000000000000000000000000004444");
        vm.setEnv("FLOOR_FEE_PIPS", "500");
        vm.setEnv("CASH_FEE_PIPS", "3000");
        vm.setEnv("EXTREME_FEE_PIPS", "9500");
        vm.setEnv("PERIOD_SECONDS", "600");
        vm.setEnv("EMA_PERIODS", "16");
        vm.setEnv("DEADBAND_PERCENT", "12");
        vm.setEnv("LULL_RESET_SECONDS", "7200");
        vm.setEnv("HOOK_FEE_PERCENT", "3");
        vm.setEnv("MIN_COUNTED_SWAP_USD6", "4000000");
        vm.setEnv("MIN_VOLUME_TO_ENTER_CASH_USD", "1500");
        vm.setEnv("CASH_ENTER_EMA_PERCENT", "190");
        vm.setEnv("CASH_HOLD_PERIODS", "5");
        vm.setEnv("MIN_VOLUME_TO_ENTER_EXTREME_USD", "4500");
        vm.setEnv("EXTREME_ENTER_EMA_PERCENT", "420");
        vm.setEnv("ENTER_EXTREME_CONFIRM_PERIODS", "3");
        vm.setEnv("EXTREME_HOLD_PERIODS", "5");
        vm.setEnv("EXTREME_EXIT_EMA_PERCENT", "140");
        vm.setEnv("EXIT_EXTREME_CONFIRM_PERIODS", "3");
        vm.setEnv("CASH_EXIT_EMA_PERCENT", "140");
        vm.setEnv("EXIT_CASH_CONFIRM_PERIODS", "4");
        vm.setEnv("EMERGENCY_FLOOR_TRIGGER_USD", "700");
        vm.setEnv("EMERGENCY_CONFIRM_PERIODS", "4");

        vm.setEnv("DEPLOY_POOL_MANAGER", "0x000000000000000000000000000000000000AaAa");
        vm.setEnv("DEPLOY_VOLATILE", "0x0000000000000000000000000000000000007777");
        vm.setEnv("DEPLOY_STABLE", "0x0000000000000000000000000000000000009999");
        vm.setEnv("DEPLOY_STABLE_DECIMALS", "18");
        vm.setEnv("DEPLOY_TICK_SPACING", "60");
        vm.setEnv("DEPLOY_OWNER", "0x0000000000000000000000000000000000000001");
        vm.setEnv("DEPLOY_OWNER", "0x000000000000000000000000000000000000beef");
        vm.setEnv("DEPLOY_FLOOR_FEE_PIPS", "400");
        vm.setEnv("DEPLOY_CASH_FEE_PIPS", "2500");
        vm.setEnv("DEPLOY_EXTREME_FEE_PIPS", "9000");
        vm.setEnv("DEPLOY_PERIOD_SECONDS", "300");
        vm.setEnv("DEPLOY_EMA_PERIODS", "8");
        vm.setEnv("DEPLOY_DEADBAND_PERCENT", "5");
        vm.setEnv("DEPLOY_LULL_RESET_SECONDS", "3600");
        vm.setEnv("DEPLOY_HOOK_FEE_PERCENT", "1");
        vm.setEnv("DEPLOY_MIN_VOLUME_TO_ENTER_CASH_USD", "1000");
        vm.setEnv("DEPLOY_CASH_ENTER_EMA_PERCENT", "180");
        vm.setEnv("DEPLOY_CASH_HOLD_PERIODS", "4");
        vm.setEnv("DEPLOY_MIN_VOLUME_TO_ENTER_EXTREME_USD", "4000");
        vm.setEnv("DEPLOY_EXTREME_ENTER_EMA_PERCENT", "400");
        vm.setEnv("DEPLOY_ENTER_EXTREME_CONFIRM_PERIODS", "2");
        vm.setEnv("DEPLOY_EXTREME_HOLD_PERIODS", "4");
        vm.setEnv("DEPLOY_EXTREME_EXIT_EMA_PERCENT", "130");
        vm.setEnv("DEPLOY_EXIT_EXTREME_CONFIRM_PERIODS", "2");
        vm.setEnv("DEPLOY_CASH_EXIT_EMA_PERCENT", "130");
        vm.setEnv("DEPLOY_EXIT_CASH_CONFIRM_PERIODS", "3");
        vm.setEnv("DEPLOY_EMERGENCY_FLOOR_TRIGGER_USD", "600");
        vm.setEnv("DEPLOY_EMERGENCY_CONFIRM_PERIODS", "3");
    }
}
