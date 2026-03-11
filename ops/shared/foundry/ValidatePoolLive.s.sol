// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {CanonicalHookResolverLib} from "../lib/CanonicalHookResolverLib.sol";
import {ConfigLoader} from "../lib/ConfigLoader.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {LoggingLib} from "../lib/LoggingLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";
import {LiveOpsBase} from "./LiveOpsBase.s.sol";

contract ValidatePoolLive is LiveOpsBase {
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

        LoggingLib.ok("live pool validation passed");
    }
}
