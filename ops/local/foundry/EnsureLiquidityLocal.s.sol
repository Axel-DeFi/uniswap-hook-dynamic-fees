// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {BudgetLib} from "../../shared/lib/BudgetLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract EnsureLiquidityLocal is Script {
    function run() external {
        LoggingLib.phase("local.ensure-liquidity");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        address deployer = cfg.deployer;

        uint256 needStable = cfg.minStableBalanceRaw + cfg.liquidityBudgetStableRaw + cfg.swapBudgetStableRaw;
        uint256 needVolatile =
            cfg.minVolatileBalanceRaw + cfg.liquidityBudgetVolatileRaw + cfg.swapBudgetVolatileRaw;

        OpsTypes.BalanceSnapshot memory before = BudgetLib.snapshot(cfg, deployer);

        vm.startBroadcast(pk);
        if (cfg.stableToken != address(0) && before.stableRaw < needStable) {
            IMintable(cfg.stableToken).mint(deployer, needStable - before.stableRaw);
        }
        if (cfg.volatileToken != address(0) && before.volatileRaw < needVolatile) {
            IMintable(cfg.volatileToken).mint(deployer, needVolatile - before.volatileRaw);
        }
        vm.stopBroadcast();

        OpsTypes.BudgetCheck memory check = BudgetLib.checkBeforeBroadcast(cfg, deployer);
        require(check.ok, check.reason);

        LoggingLib.ok("liquidity balances ensured");
    }
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}
