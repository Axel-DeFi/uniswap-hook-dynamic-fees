// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

import {CanonicalHookResolverLib} from "../../shared/lib/CanonicalHookResolverLib.sol";
import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {BudgetLib} from "../../shared/lib/BudgetLib.sol";
import {PoolStateLib} from "../../shared/lib/PoolStateLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract RunEmergencyChecksSepolia is Script {
    function run() external {
        LoggingLib.phase("sepolia.emergency");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        (cfg,) = CanonicalHookResolverLib.requireExistingCanonicalHook(cfg);

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
