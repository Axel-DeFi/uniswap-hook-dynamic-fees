// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {CanonicalHookResolverLib} from "../../shared/lib/CanonicalHookResolverLib.sol";
import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {PoolStateLib} from "../../shared/lib/PoolStateLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract ValidatePoolSepolia is Script {
    function run() external view {
        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        (cfg,) = CanonicalHookResolverLib.requireExistingCanonicalHook(cfg);

        require(cfg.poolManager != address(0), "POOL_MANAGER missing");
        require(cfg.poolManager.code.length > 0, "POOL_MANAGER has no code");

        if (cfg.poolAddress != address(0)) {
            require(cfg.poolAddress.code.length > 0, "POOL_ADDRESS has no code");
        }

        OpsTypes.PoolSnapshot memory snapshot = PoolStateLib.snapshotHook(cfg.hookAddress);
        require(snapshot.initialized, "hook state not initialized: pool may be missing init");

        LoggingLib.ok("sepolia pool validation passed");
    }
}
