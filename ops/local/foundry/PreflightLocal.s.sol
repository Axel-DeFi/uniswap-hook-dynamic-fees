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

contract PreflightLocal is Script {
    function run() external {
        LoggingLib.phase("local.preflight");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        ConfigLoader.validateChainId(cfg.chainIdExpected);

        string memory scenario = vm.envOr("OPS_SCENARIO", string("bootstrap"));
        bool bootstrapScenario = keccak256(bytes(scenario)) == keccak256(bytes("bootstrap"));
        bool hookConfigured = cfg.hookAddress != address(0);
        bool hookDeployed = hookConfigured && cfg.hookAddress.code.length > 0;
        bool bootstrapStage = _isBootstrapStage(bootstrapScenario, hookDeployed);

        OpsTypes.TokenValidation memory tokenValidation;
        OpsTypes.BudgetCheck memory budget;

        if (bootstrapStage) {
            tokenValidation.ok = true;
            tokenValidation.reason = "token checks deferred until bootstrap deploy";
            tokenValidation.stableDecimalsExpected = cfg.stableDecimals;

            budget.snapshot.ethWei = cfg.deployer.balance;
            budget.requiredEthWei = cfg.minEthBalanceWei + cfg.safetyBufferEthWei;
            budget.ok = budget.snapshot.ethWei >= budget.requiredEthWei;
            budget.reason = budget.ok ? "ok (bootstrap ETH-only budget gate)" : "insufficient ETH budget";
        } else {
            tokenValidation = TokenValidationLib.validateTokens(cfg);
            budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        }

        OpsTypes.RangeCheck memory range = RangeSafetyLib.validateRange(cfg);

        OpsTypes.HookValidation memory hookValidation;
        OpsTypes.PoolSnapshot memory snapshot;

        if (hookDeployed) {
            hookValidation = HookValidationLib.validateHook(cfg);
            snapshot = PoolStateLib.snapshotHook(cfg.hookAddress);
        } else if (bootstrapScenario) {
            hookValidation.ok = true;
            hookValidation.reason =
                hookConfigured ? "stale hook ignored in bootstrap stage" : "hook not set (bootstrap stage)";
        } else {
            hookValidation.ok = false;
            hookValidation.reason = hookConfigured ? "stale hook address (no code)" : "HOOK_ADDRESS missing";
        }

        bool ok = tokenValidation.ok && budget.ok && range.ok && hookValidation.ok;

        string memory reportPath = vm.envOr(
            "OPS_LOCAL_PREFLIGHT_REPORT",
            string.concat(vm.projectRoot(), "/ops/local/out/reports/preflight.local.json")
        );

        JsonReportLib.writePreflightReport(
            reportPath,
            "local-preflight",
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
            revert("local preflight failed");
        }

        LoggingLib.ok("preflight passed");
    }

    function _isBootstrapStage(bool bootstrapScenario, bool hookDeployed) private pure returns (bool) {
        return bootstrapScenario && !hookDeployed;
    }
}
