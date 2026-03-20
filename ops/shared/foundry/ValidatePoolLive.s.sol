// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CanonicalHookResolverLib} from "../lib/CanonicalHookResolverLib.sol";
import {ConfigLoader} from "../lib/ConfigLoader.sol";
import {LoggingLib} from "../lib/LoggingLib.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";
import {LiveOpsBase} from "./LiveOpsBase.s.sol";

contract ValidatePoolLive is LiveOpsBase {
    using PoolIdLibrary for PoolKey;

    function run() external view {
        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        OpsTypes.DeploymentConfig memory deployCfg = ConfigLoader.loadDeploymentConfig(cfg);
        ConfigLoader.requireDeploymentBindingConsistency(cfg, deployCfg);
        (cfg,) = CanonicalHookResolverLib.requireExistingCanonicalHook(cfg, deployCfg);

        require(cfg.poolManager != address(0), "POOL_MANAGER missing");
        require(cfg.poolManager.code.length > 0, "POOL_MANAGER has no code");

        if (cfg.poolId != bytes32(0)) {
            bytes32 expectedPoolId = PoolId.unwrap(_poolKey(cfg).toId());
            require(cfg.poolId == expectedPoolId, "POOL_ID mismatch");
        }

        OpsTypes.PoolSnapshot memory snapshot = PoolStateLib.snapshotHook(cfg.hookAddress);
        require(snapshot.initialized, "hook state not initialized: pool may be missing init");

        LoggingLib.ok("live pool validation passed");
    }

    function _poolKey(OpsTypes.CoreConfig memory cfg) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(cfg.token0),
            currency1: Currency.wrap(cfg.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.hookAddress)
        });
    }
}
