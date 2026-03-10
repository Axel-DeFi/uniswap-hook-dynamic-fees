// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {BudgetLib} from "../../shared/lib/BudgetLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract EnsureDriversSepolia is Script {
    function run() external {
        LoggingLib.phase("sepolia.ensure-drivers");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        ConfigLoader.validateChainId(cfg.chainIdExpected);
        require(cfg.poolManager.code.length > 0, "POOL_MANAGER has no code");

        address liquidityDriver = vm.envOr("LIQUIDITY_DRIVER", address(0));
        address swapDriver = vm.envOr("SWAP_DRIVER", address(0));

        bool needLiquidityDriver = liquidityDriver == address(0) || liquidityDriver.code.length == 0;
        bool needSwapDriver = swapDriver == address(0) || swapDriver.code.length == 0;

        if (needLiquidityDriver || needSwapDriver) {
            OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
            require(budget.ok, budget.reason);

            uint256 pk = cfg.privateKey;
            require(pk != 0, "PRIVATE_KEY missing");

            vm.startBroadcast(pk);
            if (needLiquidityDriver) {
                liquidityDriver = address(new PoolModifyLiquidityTest(IPoolManager(cfg.poolManager)));
            }
            if (needSwapDriver) {
                swapDriver = address(new PoolSwapTest(IPoolManager(cfg.poolManager)));
            }
            vm.stopBroadcast();
        }

        require(liquidityDriver.code.length > 0, "LIQUIDITY_DRIVER deploy/reuse failed");
        require(swapDriver.code.length > 0, "SWAP_DRIVER deploy/reuse failed");

        string memory statePath = vm.envOr(
            "OPS_SEPOLIA_DRIVERS_STATE_PATH",
            string.concat(vm.projectRoot(), "/ops/sepolia/out/state/sepolia.drivers.json")
        );
        vm.writeFile(
            statePath,
            string.concat(
                "{",
                _kv("liquidityDriver", vm.toString(liquidityDriver)),
                ",",
                _kv("swapDriver", vm.toString(swapDriver)),
                "}"
            )
        );

        LoggingLib.infoAddress("liquidityDriver", liquidityDriver);
        LoggingLib.infoAddress("swapDriver", swapDriver);
        LoggingLib.ok("drivers ready");
    }

    function _kv(string memory key, string memory value) private pure returns (string memory) {
        return string.concat('"', key, '":"', value, '"');
    }
}
