// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {TokenValidationLib} from "../../shared/lib/TokenValidationLib.sol";
import {BudgetLib} from "../../shared/lib/BudgetLib.sol";
import {RangeSafetyLib} from "../../shared/lib/RangeSafetyLib.sol";
import {HookValidationLib} from "../../shared/lib/HookValidationLib.sol";
import {PoolStateLib} from "../../shared/lib/PoolStateLib.sol";
import {JsonReportLib} from "../../shared/lib/JsonReportLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract PreflightSepolia is Script {
    function run() external {
        LoggingLib.phase("sepolia.preflight");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        ConfigLoader.validateChainId(cfg.chainIdExpected);

        require(cfg.poolManager.code.length > 0, "POOL_MANAGER has no code");

        OpsTypes.TokenValidation memory tokenValidation = TokenValidationLib.validateTokens(cfg);
        OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        OpsTypes.RangeCheck memory range = RangeSafetyLib.validateRange(cfg);

        OpsTypes.HookValidation memory hookValidation;
        OpsTypes.PoolSnapshot memory snapshot;

        if (cfg.hookAddress != address(0)) {
            if (cfg.hookAddress.code.length == 0) {
                hookValidation.ok = false;
                hookValidation.reason = "stale HOOK_ADDRESS (no code)";
            } else {
                hookValidation = HookValidationLib.validateHook(cfg);
                snapshot = PoolStateLib.snapshotHook(cfg.hookAddress);
            }
        } else {
            hookValidation.ok = true;
            hookValidation.reason = "hook not set";
        }

        bool ok = tokenValidation.ok && budget.ok && range.ok && hookValidation.ok;

        string memory reportPath = vm.envOr(
            "OPS_SEPOLIA_PREFLIGHT_REPORT",
            string.concat(vm.projectRoot(), "/ops/sepolia/out/reports/preflight.sepolia.json")
        );

        JsonReportLib.writePreflightReport(
            reportPath,
            "sepolia-preflight",
            cfg,
            tokenValidation,
            budget,
            range,
            hookValidation,
            snapshot,
            ok
        );

        if (!ok) {
            LoggingLib.fail("preflight failed");
            revert("sepolia preflight failed");
        }

        LoggingLib.ok("preflight passed");
    }
}
