// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {ErrorLib} from "../../shared/lib/ErrorLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract DeploymentConfigHarness {
    function loadCoreConfig() external view returns (OpsTypes.CoreConfig memory cfg) {
        return ConfigLoader.loadCoreConfig();
    }

    function loadDeploymentConfig() external view returns (OpsTypes.DeploymentConfig memory cfg) {
        return ConfigLoader.loadDeploymentConfig(ConfigLoader.loadCoreConfig());
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
        _setBaseRuntimeEnv();
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
        assertEq(deployCfg.owner, address(0x1234));
        assertEq(deployCfg.floorFeePips, 400);
        assertEq(deployCfg.cashFeePips, 2_500);
        assertEq(deployCfg.extremeFeePips, 9_000);
        assertEq(deployCfg.periodSeconds, 300);
        assertEq(deployCfg.emaPeriods, 8);
        assertEq(deployCfg.lullResetSeconds, 3_600);
        assertEq(deployCfg.hookFeePercent, 1);
        assertEq(deployCfg.minCloseVolToCashUsd6, 1_000_000_000);
        assertEq(deployCfg.cashEnterTriggerBps, 18_500);
        assertEq(deployCfg.cashHoldPeriods, 4);
        assertEq(deployCfg.minCloseVolToExtremeUsd6, 4_000_000_000);
        assertEq(deployCfg.extremeEnterTriggerBps, 40_500);
        assertEq(deployCfg.upExtremeConfirmPeriods, 2);
        assertEq(deployCfg.extremeHoldPeriods, 4);
        assertEq(deployCfg.extremeExitTriggerBps, 12_500);
        assertEq(deployCfg.downExtremeConfirmPeriods, 2);
        assertEq(deployCfg.cashExitTriggerBps, 12_500);
        assertEq(deployCfg.downCashConfirmPeriods, 3);
        assertEq(deployCfg.emergencyFloorCloseVolUsd6, 600_000_000);
        assertEq(deployCfg.emergencyConfirmPeriods, 3);
    }

    function test_loadCoreConfig_live_inherits_deploy_snapshot_when_runtime_keys_are_omitted() public {
        _setBaseRuntimeEnv();
        vm.setEnv("POOL_MANAGER", "");
        vm.setEnv("VOLATILE", "");
        vm.setEnv("STABLE", "");
        vm.setEnv("STABLE_DECIMALS", "");
        vm.setEnv("TICK_SPACING", "");
        vm.setEnv("FLOOR_FEE_PERCENT", "");
        vm.setEnv("CASH_FEE_PERCENT", "");
        vm.setEnv("EXTREME_FEE_PERCENT", "");
        vm.setEnv("PERIOD_SECONDS", "");
        vm.setEnv("EMA_PERIODS", "");
        vm.setEnv("LULL_RESET_SECONDS", "");
        vm.setEnv("HOOK_FEE_PERCENT", "");
        vm.setEnv("MIN_VOLUME_TO_ENTER_CASH_USD", "");
        vm.setEnv("CASH_ENTER_TRIGGER_EMA_X", "");
        vm.setEnv("CASH_HOLD_PERIODS", "");
        vm.setEnv("MIN_VOLUME_TO_ENTER_EXTREME_USD", "");
        vm.setEnv("EXTREME_ENTER_TRIGGER_EMA_X", "");
        vm.setEnv("ENTER_EXTREME_CONFIRM_PERIODS", "");
        vm.setEnv("EXTREME_HOLD_PERIODS", "");
        vm.setEnv("EXTREME_EXIT_TRIGGER_EMA_X", "");
        vm.setEnv("EXIT_EXTREME_CONFIRM_PERIODS", "");
        vm.setEnv("CASH_EXIT_TRIGGER_EMA_X", "");
        vm.setEnv("EXIT_CASH_CONFIRM_PERIODS", "");
        vm.setEnv("EMERGENCY_FLOOR_TRIGGER_USD", "");
        vm.setEnv("EMERGENCY_CONFIRM_PERIODS", "");

        OpsTypes.CoreConfig memory runtimeCfg = harness.loadCoreConfig();

        assertEq(runtimeCfg.poolManager, address(0x000000000000000000000000000000000000aaaa));
        assertEq(runtimeCfg.volatileToken, address(0x0000000000000000000000000000000000007777));
        assertEq(runtimeCfg.stableToken, address(0x0000000000000000000000000000000000009999));
        assertEq(runtimeCfg.stableDecimals, 18);
        assertEq(runtimeCfg.tickSpacing, 60);
        assertEq(runtimeCfg.floorFeePips, 400);
        assertEq(runtimeCfg.cashFeePips, 2_500);
        assertEq(runtimeCfg.extremeFeePips, 9_000);
        assertEq(runtimeCfg.periodSeconds, 300);
        assertEq(runtimeCfg.emaPeriods, 8);
        assertEq(runtimeCfg.lullResetSeconds, 3_600);
        assertEq(runtimeCfg.hookFeePercent, 1);
        assertEq(runtimeCfg.minCloseVolToCashUsd6, 1_000_000_000);
        assertEq(runtimeCfg.cashEnterTriggerBps, 18_500);
        assertEq(runtimeCfg.cashHoldPeriods, 4);
        assertEq(runtimeCfg.minCloseVolToExtremeUsd6, 4_000_000_000);
        assertEq(runtimeCfg.extremeEnterTriggerBps, 40_500);
        assertEq(runtimeCfg.upExtremeConfirmPeriods, 2);
        assertEq(runtimeCfg.extremeHoldPeriods, 4);
        assertEq(runtimeCfg.extremeExitTriggerBps, 12_500);
        assertEq(runtimeCfg.downExtremeConfirmPeriods, 2);
        assertEq(runtimeCfg.cashExitTriggerBps, 12_500);
        assertEq(runtimeCfg.downCashConfirmPeriods, 3);
        assertEq(runtimeCfg.emergencyFloorCloseVolUsd6, 600_000_000);
        assertEq(runtimeCfg.emergencyConfirmPeriods, 3);
    }

    function test_requireDeploymentBindingConsistency_rejects_runtime_binding_drift() public view {
        OpsTypes.CoreConfig memory runtimeCfg;
        OpsTypes.DeploymentConfig memory deployCfg;

        runtimeCfg.poolManager = address(0x1111);
        deployCfg.poolManager = address(0xAAAA);

        (bool ok, bytes memory revertData) = address(harness)
            .staticcall(abi.encodeCall(harness.requireDeploymentBindingConsistency, (runtimeCfg, deployCfg)));

        assertFalse(ok);
        assertEq(
            revertData,
            abi.encodeWithSelector(
                ErrorLib.InvalidEnv.selector, "POOL_MANAGER", "must match DEPLOY_POOL_MANAGER"
            )
        );
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
        vm.setEnv("FLOOR_FEE_PERCENT", "0.05");
        vm.setEnv("CASH_FEE_PERCENT", "0.30");
        vm.setEnv("EXTREME_FEE_PERCENT", "0.95");
        vm.setEnv("PERIOD_SECONDS", "600");
        vm.setEnv("EMA_PERIODS", "16");
        vm.setEnv("LULL_RESET_SECONDS", "7200");
        vm.setEnv("HOOK_FEE_PERCENT", "3");
        vm.setEnv("MIN_COUNTED_SWAP_USD6", "4000000");
        vm.setEnv("MIN_VOLUME_TO_ENTER_CASH_USD", "1500");
        vm.setEnv("CASH_ENTER_TRIGGER_EMA_X", "2.02");
        vm.setEnv("CASH_HOLD_PERIODS", "5");
        vm.setEnv("MIN_VOLUME_TO_ENTER_EXTREME_USD", "4500");
        vm.setEnv("EXTREME_ENTER_TRIGGER_EMA_X", "4.32");
        vm.setEnv("ENTER_EXTREME_CONFIRM_PERIODS", "3");
        vm.setEnv("EXTREME_HOLD_PERIODS", "5");
        vm.setEnv("EXTREME_EXIT_TRIGGER_EMA_X", "1.28");
        vm.setEnv("EXIT_EXTREME_CONFIRM_PERIODS", "3");
        vm.setEnv("CASH_EXIT_TRIGGER_EMA_X", "1.28");
        vm.setEnv("EXIT_CASH_CONFIRM_PERIODS", "4");
        vm.setEnv("EMERGENCY_FLOOR_TRIGGER_USD", "700");
        vm.setEnv("EMERGENCY_CONFIRM_PERIODS", "4");

        vm.setEnv("DEPLOY_POOL_MANAGER", "0x000000000000000000000000000000000000AaAa");
        vm.setEnv("DEPLOY_VOLATILE", "0x0000000000000000000000000000000000007777");
        vm.setEnv("DEPLOY_STABLE", "0x0000000000000000000000000000000000009999");
        vm.setEnv("DEPLOY_STABLE_DECIMALS", "18");
        vm.setEnv("DEPLOY_TICK_SPACING", "60");
        vm.setEnv("DEPLOY_OWNER", "0x0000000000000000000000000000000000001234");
        vm.setEnv("DEPLOY_FLOOR_FEE_PERCENT", "0.04");
        vm.setEnv("DEPLOY_CASH_FEE_PERCENT", "0.25");
        vm.setEnv("DEPLOY_EXTREME_FEE_PERCENT", "0.9");
        vm.setEnv("DEPLOY_PERIOD_SECONDS", "300");
        vm.setEnv("DEPLOY_EMA_PERIODS", "8");
        vm.setEnv("DEPLOY_LULL_RESET_SECONDS", "3600");
        vm.setEnv("DEPLOY_HOOK_FEE_PERCENT", "1");
        vm.setEnv("DEPLOY_MIN_VOLUME_TO_ENTER_CASH_USD", "1000");
        vm.setEnv("DEPLOY_CASH_ENTER_TRIGGER_EMA_X", "1.85");
        vm.setEnv("DEPLOY_CASH_HOLD_PERIODS", "4");
        vm.setEnv("DEPLOY_MIN_VOLUME_TO_ENTER_EXTREME_USD", "4000");
        vm.setEnv("DEPLOY_EXTREME_ENTER_TRIGGER_EMA_X", "4.05");
        vm.setEnv("DEPLOY_ENTER_EXTREME_CONFIRM_PERIODS", "2");
        vm.setEnv("DEPLOY_EXTREME_HOLD_PERIODS", "4");
        vm.setEnv("DEPLOY_EXTREME_EXIT_TRIGGER_EMA_X", "1.25");
        vm.setEnv("DEPLOY_EXIT_EXTREME_CONFIRM_PERIODS", "2");
        vm.setEnv("DEPLOY_CASH_EXIT_TRIGGER_EMA_X", "1.25");
        vm.setEnv("DEPLOY_EXIT_CASH_CONFIRM_PERIODS", "3");
        vm.setEnv("DEPLOY_EMERGENCY_FLOOR_TRIGGER_USD", "600");
        vm.setEnv("DEPLOY_EMERGENCY_CONFIRM_PERIODS", "3");
    }
}
