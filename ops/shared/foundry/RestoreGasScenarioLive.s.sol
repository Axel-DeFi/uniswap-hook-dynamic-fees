// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {CanonicalHookResolverLib} from "../lib/CanonicalHookResolverLib.sol";
import {ConfigLoader} from "../lib/ConfigLoader.sol";
import {BudgetLib} from "../lib/BudgetLib.sol";
import {LoggingLib} from "../lib/LoggingLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";
import {LiveOpsBase} from "./LiveOpsBase.s.sol";

contract RestoreGasScenarioLive is LiveOpsBase {
    function run() external {
        LoggingLib.phase(_phase("gas-restore"));

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        OpsTypes.DeploymentConfig memory deployCfg = ConfigLoader.loadDeploymentConfig(cfg);
        ConfigLoader.requireDeploymentBindingConsistency(cfg, deployCfg);
        (cfg,) = CanonicalHookResolverLib.requireExistingCanonicalHook(cfg, deployCfg);

        OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        require(budget.ok, budget.reason);

        string memory snapshotPath = vm.envOr(
            "OPS_GAS_TIMING_SNAPSHOT",
            string.concat(_networkDir(), "/out/state/gas.", _network(), ".timing.json")
        );
        string memory snapshot = vm.readFile(snapshotPath);

        uint32 originalPeriodSeconds = abi.decode(vm.parseJson(snapshot, ".periodSeconds"), (uint32));
        uint8 originalEmaPeriods = abi.decode(vm.parseJson(snapshot, ".emaPeriods"), (uint8));
        uint32 originalLullResetSeconds = abi.decode(vm.parseJson(snapshot, ".lullResetSeconds"), (uint32));
        uint16 originalDeadbandBps = abi.decode(vm.parseJson(snapshot, ".deadbandBps"), (uint16));
        bool wasPaused = abi.decode(vm.parseJson(snapshot, ".wasPaused"), (bool));

        VolumeDynamicFeeHook hook = VolumeDynamicFeeHook(payable(cfg.hookAddress));
        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        vm.startBroadcast(pk);
        if (!hook.isPaused()) {
            hook.pause();
        }
        hook.setTimingParams(originalPeriodSeconds, originalEmaPeriods, originalLullResetSeconds, originalDeadbandBps);
        if (!wasPaused) {
            hook.unpause();
        }
        vm.stopBroadcast();

        LoggingLib.ok("gas scenario restored");
    }
}
