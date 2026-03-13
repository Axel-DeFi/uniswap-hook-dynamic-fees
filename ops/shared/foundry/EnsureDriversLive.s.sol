// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ConfigLoader} from "../lib/ConfigLoader.sol";
import {BudgetLib} from "../lib/BudgetLib.sol";
import {DriverValidationLib} from "../lib/DriverValidationLib.sol";
import {LoggingLib} from "../lib/LoggingLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";
import {LiveOpsBase} from "./LiveOpsBase.s.sol";

contract EnsureDriversLive is LiveOpsBase {
    function run() external {
        LoggingLib.phase(_phase("ensure-drivers"));

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        ConfigLoader.validateChainId(cfg.chainIdExpected);
        require(cfg.poolManager.code.length > 0, "POOL_MANAGER has no code");

        address liquidityDriver = vm.envOr("LIQUIDITY_DRIVER", address(0));
        address swapDriver = vm.envOr("SWAP_DRIVER", address(0));

        (bool liquidityOk, string memory liquidityReason) =
            DriverValidationLib.validateLiquidityDriver(liquidityDriver, cfg.poolManager);
        (bool swapOk, string memory swapReason) = DriverValidationLib.validateSwapDriver(swapDriver, cfg.poolManager);

        bool needLiquidityDriver = !liquidityOk;
        bool needSwapDriver = !swapOk;

        if (needLiquidityDriver || needSwapDriver) {
            if (needLiquidityDriver) LoggingLib.fail(liquidityReason);
            if (needSwapDriver) LoggingLib.fail(swapReason);

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

        DriverValidationLib.requireValidLiquidityDriver(liquidityDriver, cfg.poolManager);
        DriverValidationLib.requireValidSwapDriver(swapDriver, cfg.poolManager);

        string memory statePath = _driversStatePath();
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
