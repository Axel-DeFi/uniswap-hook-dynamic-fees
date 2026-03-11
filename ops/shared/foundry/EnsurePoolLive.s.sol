// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {CanonicalHookResolverLib} from "../lib/CanonicalHookResolverLib.sol";
import {ConfigLoader} from "../lib/ConfigLoader.sol";
import {BudgetLib} from "../lib/BudgetLib.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {LoggingLib} from "../lib/LoggingLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";
import {EnvLib} from "../lib/EnvLib.sol";
import {LiveOpsBase} from "./LiveOpsBase.s.sol";

contract EnsurePoolLive is LiveOpsBase {
    function run() external {
        LoggingLib.phase(_phase("ensure-pool"));

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        OpsTypes.DeploymentConfig memory deployCfg = ConfigLoader.loadDeploymentConfig(cfg);
        (cfg,) = CanonicalHookResolverLib.requireExistingCanonicalHook(cfg, deployCfg);

        OpsTypes.PoolSnapshot memory snapshot = PoolStateLib.snapshotHook(cfg.hookAddress);
        if (snapshot.initialized) {
            LoggingLib.ok("pool already initialized");
            return;
        }

        OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        require(budget.ok, budget.reason);

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        uint256 sqrtPriceRaw = EnvLib.requireUint("INIT_SQRT_PRICE_X96");
        require(sqrtPriceRaw <= type(uint160).max, "INIT_SQRT_PRICE_X96 out of uint160 range");
        uint160 sqrtPriceX96 = uint160(sqrtPriceRaw);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(cfg.token0),
            currency1: Currency.wrap(cfg.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.hookAddress)
        });

        vm.startBroadcast(pk);
        IPoolManager(cfg.poolManager).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        LoggingLib.ok("pool initialize tx sent");
    }
}
