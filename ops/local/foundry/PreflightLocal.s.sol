// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {TokenValidationLib} from "../../shared/lib/TokenValidationLib.sol";
import {BudgetLib} from "../../shared/lib/BudgetLib.sol";
import {RangeSafetyLib} from "../../shared/lib/RangeSafetyLib.sol";
import {HookValidationLib} from "../../shared/lib/HookValidationLib.sol";
import {NativeRecipientValidationLib} from "../../shared/lib/NativeRecipientValidationLib.sol";
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

        if (hookValidation.ok) {
            address payoutRecipient;
            address payoutSender;

            if (hookDeployed) {
                payoutRecipient = VolumeDynamicFeeHook(payable(cfg.hookAddress)).owner();
                payoutSender = cfg.hookAddress;
            } else {
                payoutRecipient = vm.envOr("OWNER", cfg.deployer);
                payoutSender = payoutRecipient;
            }

            (bool nativeRecipientOk, string memory nativeRecipientReason) = NativeRecipientValidationLib.validatePayoutRecipientForNativePool(
                cfg.token0, cfg.token1, payoutRecipient, payoutSender
            );
            if (!nativeRecipientOk) {
                hookValidation.ok = false;
                hookValidation.reason = nativeRecipientReason;
            }
        }

        if (hookValidation.ok) {
            bool hookIsDeployed = cfg.hookAddress != address(0) && cfg.hookAddress.code.length > 0;

            uint64 minCloseVolToCashUsd6;
            uint64 emergencyFloorCloseVolUsd6;
            uint8 cashHoldPeriods;
            uint8 extremeHoldPeriods;

            if (hookIsDeployed) {
                VolumeDynamicFeeHook h = VolumeDynamicFeeHook(payable(cfg.hookAddress));
                minCloseVolToCashUsd6 = h.minCloseVolToCashUsd6();
                emergencyFloorCloseVolUsd6 = h.emergencyFloorCloseVolUsd6();
                cashHoldPeriods = h.cashHoldPeriods();
                extremeHoldPeriods = h.extremeHoldPeriods();
            } else {
                minCloseVolToCashUsd6 = uint64(vm.envOr("MIN_CLOSEVOL_TO_CASH_USD6", uint256(0)));
                emergencyFloorCloseVolUsd6 = uint64(vm.envOr("EMERGENCY_FLOOR_CLOSEVOL_USD6", uint256(0)));
                cashHoldPeriods = uint8(vm.envOr("CASH_HOLD_PERIODS", uint256(0)));
                extremeHoldPeriods = uint8(vm.envOr("EXTREME_HOLD_PERIODS", uint256(0)));
            }

            if (
                emergencyFloorCloseVolUsd6 == 0
                    || emergencyFloorCloseVolUsd6 >= minCloseVolToCashUsd6
            ) {
                hookValidation.ok = false;
                hookValidation.reason = "invalid emergency floor relation (require 0 < emergency < minCloseToCash)";
            }

            bool allowWeakHoldPeriods = vm.envOr("ALLOW_WEAK_HOLD_PERIODS", false);
            if (
                hookValidation.ok
                    && (cashHoldPeriods < 2 || extremeHoldPeriods < 2)
                    && !allowWeakHoldPeriods
            ) {
                LoggingLib.ok("warning: weak hold periods detected in local profile");
            }
        }

        bool ok = tokenValidation.ok && budget.ok && range.ok && hookValidation.ok;

        string memory reportPath = vm.envOr(
            "OPS_LOCAL_PREFLIGHT_REPORT",
            string.concat(vm.projectRoot(), "/ops/local/out/reports/preflight.local.json")
        );

        JsonReportLib.writePreflightReport(
            reportPath, "local-preflight", cfg, tokenValidation, budget, range, hookValidation, snapshot, ok
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
