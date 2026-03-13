// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {PoolStateLib} from "../../shared/lib/PoolStateLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract RunEmergencyChecksLocal is Script {
    function run() external {
        LoggingLib.phase("local.emergency");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        require(cfg.hookAddress != address(0) && cfg.hookAddress.code.length > 0, "HOOK_ADDRESS missing");

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
