// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

import {CanonicalHookResolverLib} from "../lib/CanonicalHookResolverLib.sol";
import {ConfigLoader} from "../lib/ConfigLoader.sol";
import {BudgetLib} from "../lib/BudgetLib.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {LoggingLib} from "../lib/LoggingLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";
import {LiveOpsBase} from "./LiveOpsBase.s.sol";

contract RunEmergencyChecksLive is LiveOpsBase {
    function run() external {
        LoggingLib.phase(_phase("emergency"));

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        OpsTypes.DeploymentConfig memory deployCfg = ConfigLoader.loadDeploymentConfig(cfg);
        ConfigLoader.requireDeploymentBindingConsistency(cfg, deployCfg);
        (cfg,) = CanonicalHookResolverLib.requireExistingCanonicalHook(cfg, deployCfg);

        OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        require(budget.ok, budget.reason);

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        VolumeDynamicFeeHook hook = VolumeDynamicFeeHook(payable(cfg.hookAddress));

        vm.startBroadcast(pk);
        if (!hook.isPaused()) {
            hook.pause();
        }
        hook.emergencyResetToFloor();
        hook.unpause();
        vm.stopBroadcast();

        OpsTypes.PoolSnapshot memory snapshot = PoolStateLib.snapshotHook(cfg.hookAddress);
        require(!snapshot.paused, "hook must end unpaused");
        // Explicit three-regime model guarantees FLOOR=0.
        require(snapshot.feeIdx == 0, "fee idx must be floor after emergency reset");

        LoggingLib.ok("emergency checks complete");
    }
}
