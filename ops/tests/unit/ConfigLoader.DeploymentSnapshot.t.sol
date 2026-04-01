// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {ErrorLib} from "../../shared/lib/ErrorLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract DeploymentConfigHarness {
    function loadCoreConfig() external view returns (OpsTypes.CoreConfig memory cfg) {
        return ConfigLoader.loadCoreConfig();
    }

    function loadCorePoolId() external view returns (bytes32) {
        return ConfigLoader.loadCoreConfig().poolId;
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
    address internal constant RUNTIME_STABLE = address(0x0000000000000000000000000000000000003333);
    address internal constant DEPLOY_STABLE = address(0x0000000000000000000000000000000000009999);
    bytes32 internal constant RUNTIME_POOL_ID =
        hex"111122223333444455556666777788889999aaaabbbbccccddddeeeeffff0000";
    string internal constant RUNTIME_POOL_ID_RAW =
        "0x111122223333444455556666777788889999aaaabbbbccccddddeeeeffff0000";

    DeploymentConfigHarness internal harness;

    function setUp() public {
        harness = new DeploymentConfigHarness();
        MockERC20 runtimeStableImpl = new MockERC20("Runtime Stable", "RSTB", 6);
        MockERC20 deployStableImpl = new MockERC20("Deploy Stable", "DSTB", 18);
        vm.etch(RUNTIME_STABLE, address(runtimeStableImpl).code);
        vm.etch(DEPLOY_STABLE, address(deployStableImpl).code);
    }

    function test_loadDeploymentConfig_live_uses_frozen_deploy_snapshot() public {
        _setBaseRuntimeEnv();
        OpsTypes.DeploymentConfig memory deployCfg = harness.loadDeploymentConfig();

        assertEq(deployCfg.poolManager, address(0x000000000000000000000000000000000000aaaa));
        assertEq(deployCfg.token0, address(0x0000000000000000000000000000000000007777));
        assertEq(deployCfg.token1, address(0x0000000000000000000000000000000000009999));
        assertEq(deployCfg.tickSpacing, 60);
        assertEq(deployCfg.stableToken, DEPLOY_STABLE);
        assertEq(deployCfg.stableDecimals, 18);
        assertEq(deployCfg.owner, address(0x1234));
        assertEq(deployCfg.floorFeePips, 400);
        assertEq(deployCfg.cashFeePips, 2_500);
        assertEq(deployCfg.extremeFeePips, 9_000);
        assertEq(deployCfg.periodSeconds, 300);
        assertEq(deployCfg.emaPeriods, 8);
        assertEq(deployCfg.lullResetSeconds, 3_600);
        assertEq(deployCfg.hookFeePercent, 1);
        assertEq(deployCfg.floorToCashMinCloseVolume, 1_000_000_000);
        assertEq(deployCfg.floorToCashMinFlowBps, 18_500);
        assertEq(deployCfg.cashHoldPeriods, 4);
        assertEq(deployCfg.cashToExtremeMinCloseVolume, 4_000_000_000);
        assertEq(deployCfg.cashToExtremeMinFlowBps, 40_500);
        assertEq(deployCfg.cashToExtremeConfirmPeriods, 2);
        assertEq(deployCfg.extremeHoldPeriods, 4);
        assertEq(deployCfg.extremeToCashMaxFlowBps, 12_500);
        assertEq(deployCfg.extremeToCashConfirmPeriods, 2);
        assertEq(deployCfg.cashToFloorMaxFlowBps, 12_500);
        assertEq(deployCfg.cashToFloorConfirmPeriods, 3);
        assertEq(deployCfg.emergencyToFloorMaxCloseVolume, 600_000_000);
        assertEq(deployCfg.emergencyToFloorConfirmPeriods, 3);
    }

    function test_loadCoreConfig_live_uses_runtime_bindings_when_present() public {
        _setBaseRuntimeEnv();

        OpsTypes.CoreConfig memory runtimeCfg = harness.loadCoreConfig();

        assertEq(runtimeCfg.poolManager, address(0x0000000000000000000000000000000000001111));
        assertEq(runtimeCfg.poolId, RUNTIME_POOL_ID);
        assertEq(runtimeCfg.volatileToken, address(0x0000000000000000000000000000000000002222));
        assertEq(runtimeCfg.stableToken, RUNTIME_STABLE);
        assertEq(runtimeCfg.stableDecimals, 6);
        assertEq(runtimeCfg.tickSpacing, 10);
        assertEq(runtimeCfg.floorFeePips, 500);
        assertEq(runtimeCfg.cashFeePips, 3_000);
        assertEq(runtimeCfg.extremeFeePips, 9_500);
        assertEq(runtimeCfg.periodSeconds, 600);
        assertEq(runtimeCfg.emaPeriods, 16);
        assertEq(runtimeCfg.lullResetSeconds, 7_200);
        assertEq(runtimeCfg.hookFeePercent, 3);
        assertEq(runtimeCfg.floorToCashMinCloseVolume, 1_500_000_000);
        assertEq(runtimeCfg.floorToCashMinFlowBps, 20_200);
        assertEq(runtimeCfg.cashHoldPeriods, 5);
        assertEq(runtimeCfg.cashToExtremeMinCloseVolume, 4_500_000_000);
        assertEq(runtimeCfg.cashToExtremeMinFlowBps, 43_200);
        assertEq(runtimeCfg.cashToExtremeConfirmPeriods, 3);
        assertEq(runtimeCfg.extremeHoldPeriods, 5);
        assertEq(runtimeCfg.extremeToCashMaxFlowBps, 12_800);
        assertEq(runtimeCfg.extremeToCashConfirmPeriods, 3);
        assertEq(runtimeCfg.cashToFloorMaxFlowBps, 12_800);
        assertEq(runtimeCfg.cashToFloorConfirmPeriods, 4);
        assertEq(runtimeCfg.emergencyToFloorMaxCloseVolume, 700_000_000);
        assertEq(runtimeCfg.emergencyToFloorConfirmPeriods, 4);
    }

    function test_loadCoreConfig_live_reads_pool_id_as_bytes32() public {
        _setBaseRuntimeEnv();

        assertEq(harness.loadCorePoolId(), RUNTIME_POOL_ID);
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
        _setBaseCommonEnv();
        vm.setEnv("OPS_RUNTIME", "live");
        vm.setEnv("POOL_MANAGER", "0x0000000000000000000000000000000000001111");
        vm.setEnv("POOL_ID", RUNTIME_POOL_ID_RAW);
        vm.setEnv("VOLATILE", "0x0000000000000000000000000000000000002222");
        vm.setEnv("STABLE", vm.toString(RUNTIME_STABLE));
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
        vm.setEnv("MIN_COUNTED_SWAP_VOLUME", "4000000");
        vm.setEnv("FLOOR_TO_CASH_MIN_CLOSE_VOLUME", "1500000000");
        vm.setEnv("FLOOR_TO_CASH_MIN_FLOW_EMA_X", "2.02");
        vm.setEnv("CASH_HOLD_PERIODS", "5");
        vm.setEnv("CASH_TO_EXTREME_MIN_CLOSE_VOLUME", "4500000000");
        vm.setEnv("CASH_TO_EXTREME_MIN_FLOW_EMA_X", "4.32");
        vm.setEnv("CASH_TO_EXTREME_CONFIRM_PERIODS", "3");
        vm.setEnv("EXTREME_HOLD_PERIODS", "5");
        vm.setEnv("EXTREME_TO_CASH_MAX_FLOW_EMA_X", "1.28");
        vm.setEnv("EXTREME_TO_CASH_CONFIRM_PERIODS", "3");
        vm.setEnv("CASH_TO_FLOOR_MAX_FLOW_EMA_X", "1.28");
        vm.setEnv("CASH_TO_FLOOR_CONFIRM_PERIODS", "4");
        vm.setEnv("EMERGENCY_TO_FLOOR_MAX_CLOSE_VOLUME", "700000000");
        vm.setEnv("EMERGENCY_TO_FLOOR_CONFIRM_PERIODS", "4");

        _setBaseDeployEnv();
    }

    function _setBaseCommonEnv() internal {
        vm.setEnv("OPS_RUNTIME", "live");
        vm.setEnv("RPC_URL", "http://127.0.0.1:8545");
        vm.setEnv("CHAIN_ID_EXPECTED", "31337");
    }

    function _setBaseDeployEnv() internal {
        vm.setEnv("DEPLOY_POOL_MANAGER", "0x000000000000000000000000000000000000AaAa");
        vm.setEnv("DEPLOY_VOLATILE", "0x0000000000000000000000000000000000007777");
        vm.setEnv("DEPLOY_STABLE", vm.toString(DEPLOY_STABLE));
        vm.setEnv("DEPLOY_TICK_SPACING", "60");
        vm.setEnv("DEPLOY_OWNER", "0x0000000000000000000000000000000000001234");
        vm.setEnv("DEPLOY_FLOOR_FEE_PERCENT", "0.04");
        vm.setEnv("DEPLOY_CASH_FEE_PERCENT", "0.25");
        vm.setEnv("DEPLOY_EXTREME_FEE_PERCENT", "0.9");
        vm.setEnv("DEPLOY_PERIOD_SECONDS", "300");
        vm.setEnv("DEPLOY_EMA_PERIODS", "8");
        vm.setEnv("DEPLOY_LULL_RESET_SECONDS", "3600");
        vm.setEnv("DEPLOY_HOOK_FEE_PERCENT", "1");
        vm.setEnv("DEPLOY_FLOOR_TO_CASH_MIN_CLOSE_VOLUME", "1000000000");
        vm.setEnv("DEPLOY_FLOOR_TO_CASH_MIN_FLOW_EMA_X", "1.85");
        vm.setEnv("DEPLOY_CASH_HOLD_PERIODS", "4");
        vm.setEnv("DEPLOY_CASH_TO_EXTREME_MIN_CLOSE_VOLUME", "4000000000");
        vm.setEnv("DEPLOY_CASH_TO_EXTREME_MIN_FLOW_EMA_X", "4.05");
        vm.setEnv("DEPLOY_CASH_TO_EXTREME_CONFIRM_PERIODS", "2");
        vm.setEnv("DEPLOY_EXTREME_HOLD_PERIODS", "4");
        vm.setEnv("DEPLOY_EXTREME_TO_CASH_MAX_FLOW_EMA_X", "1.25");
        vm.setEnv("DEPLOY_EXTREME_TO_CASH_CONFIRM_PERIODS", "2");
        vm.setEnv("DEPLOY_CASH_TO_FLOOR_MAX_FLOW_EMA_X", "1.25");
        vm.setEnv("DEPLOY_CASH_TO_FLOOR_CONFIRM_PERIODS", "3");
        vm.setEnv("DEPLOY_EMERGENCY_TO_FLOOR_MAX_CLOSE_VOLUME", "600000000");
        vm.setEnv("DEPLOY_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS", "3");
    }
}
