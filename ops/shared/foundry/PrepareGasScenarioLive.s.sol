// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {CanonicalHookResolverLib} from "../lib/CanonicalHookResolverLib.sol";
import {ConfigLoader} from "../lib/ConfigLoader.sol";
import {BudgetLib} from "../lib/BudgetLib.sol";
import {DriverValidationLib} from "../lib/DriverValidationLib.sol";
import {LoggingLib} from "../lib/LoggingLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";
import {LiveOpsBase} from "./LiveOpsBase.s.sol";

contract PrepareGasScenarioLive is LiveOpsBase {
    function run() external {
        LoggingLib.phase(_phase("gas-prepare"));

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        OpsTypes.DeploymentConfig memory deployCfg = ConfigLoader.loadDeploymentConfig(cfg);
        ConfigLoader.requireDeploymentBindingConsistency(cfg, deployCfg);
        (cfg,) = CanonicalHookResolverLib.requireExistingCanonicalHook(cfg, deployCfg);

        OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        require(budget.ok, budget.reason);

        address driver = vm.envOr("SWAP_DRIVER", address(0));
        DriverValidationLib.requireValidSwapDriver(driver, cfg.poolManager);

        VolumeDynamicFeeHook hook = VolumeDynamicFeeHook(payable(cfg.hookAddress));
        uint32 gasPeriodSeconds = uint32(vm.envOr("OPS_GAS_PERIOD_SECONDS", uint256(1)));
        uint32 gasLullResetSeconds = uint32(vm.envOr("OPS_GAS_LULL_RESET_SECONDS", uint256(2)));
        require(gasLullResetSeconds > gasPeriodSeconds, "OPS_GAS_LULL_RESET_SECONDS must exceed OPS_GAS_PERIOD_SECONDS");

        string memory snapshotPath = vm.envOr(
            "OPS_GAS_TIMING_SNAPSHOT",
            string.concat(_networkDir(), "/out/state/gas.", _network(), ".timing.json")
        );

        bool wasPaused = hook.isPaused();
        string memory snapshotJson = string.concat(
            "{",
            '"periodSeconds":', vm.toString(hook.periodSeconds()), ",",
            '"emaPeriods":', vm.toString(hook.emaPeriods()), ",",
            '"lullResetSeconds":', vm.toString(hook.lullResetSeconds()), ",",
            '"deadbandBps":', vm.toString(hook.deadbandBps()), ",",
            '"wasPaused":', wasPaused ? "true" : "false",
            "}"
        );
        vm.writeFile(snapshotPath, snapshotJson);

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        vm.startBroadcast(pk);
        if (!wasPaused) {
            hook.pause();
        }
        hook.setTimingParams(gasPeriodSeconds, hook.emaPeriods(), gasLullResetSeconds, hook.deadbandBps());
        hook.emergencyResetToFloor();
        if (cfg.stableToken != address(0)) {
            IERC20Minimal(cfg.stableToken).approve(driver, type(uint256).max);
        }
        hook.unpause();
        vm.stopBroadcast();

        LoggingLib.ok("gas scenario prepared");
    }
}
