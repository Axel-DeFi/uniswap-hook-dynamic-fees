// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

import {ConfigLoader} from "../lib/ConfigLoader.sol";
import {TokenValidationLib} from "../lib/TokenValidationLib.sol";
import {BudgetLib} from "../lib/BudgetLib.sol";
import {RangeSafetyLib} from "../lib/RangeSafetyLib.sol";
import {HookIdentityLib} from "../lib/HookIdentityLib.sol";
import {HookValidationLib} from "../lib/HookValidationLib.sol";
import {NativeRecipientValidationLib} from "../lib/NativeRecipientValidationLib.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {JsonReportLib} from "../lib/JsonReportLib.sol";
import {LoggingLib} from "../lib/LoggingLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";
import {LiveOpsBase} from "./LiveOpsBase.s.sol";

contract PreflightLive is LiveOpsBase {
    function run() external {
        LoggingLib.phase(_phase("preflight"));

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        ConfigLoader.validateChainId(cfg.chainIdExpected);

        require(cfg.poolManager.code.length > 0, "POOL_MANAGER has no code");

        OpsTypes.TokenValidation memory tokenValidation = TokenValidationLib.validateTokens(cfg);
        OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        OpsTypes.RangeCheck memory range = RangeSafetyLib.validateRange(cfg);
        (address canonicalHookAddress,,) = HookIdentityLib.expectedHookAddress(cfg);

        OpsTypes.HookValidation memory hookValidation;
        OpsTypes.PoolSnapshot memory snapshot;

        if (cfg.hookAddress != address(0)) {
            if (cfg.hookAddress != canonicalHookAddress) {
                hookValidation.ok = false;
                hookValidation.reason = "HOOK_ADDRESS not canonical for current release/config";
            } else if (canonicalHookAddress.code.length == 0) {
                hookValidation.ok = false;
                hookValidation.reason = "stale HOOK_ADDRESS (no code)";
            } else {
                cfg.hookAddress = canonicalHookAddress;
                hookValidation = HookValidationLib.validateHook(cfg);
                snapshot = PoolStateLib.snapshotHook(canonicalHookAddress);
            }
        } else if (canonicalHookAddress.code.length > 0) {
            cfg.hookAddress = canonicalHookAddress;
            hookValidation = HookValidationLib.validateHook(cfg);
            snapshot = PoolStateLib.snapshotHook(canonicalHookAddress);
        } else {
            hookValidation.ok = true;
            hookValidation.reason = "hook not set";
        }

        if (hookValidation.ok) {
            address payoutRecipient;
            bool hookDeployed = cfg.hookAddress != address(0) && cfg.hookAddress.code.length > 0;

            if (hookDeployed) {
                payoutRecipient = VolumeDynamicFeeHook(payable(cfg.hookAddress)).owner();
            } else {
                payoutRecipient = vm.envOr("OWNER", cfg.deployer);
            }

            (bool nativeRecipientOk, string memory nativeRecipientReason) = NativeRecipientValidationLib.validatePayoutRecipientForNativePool(
                cfg.token0, cfg.token1, payoutRecipient, cfg.poolManager
            );
            if (!nativeRecipientOk) {
                hookValidation.ok = false;
                hookValidation.reason = nativeRecipientReason;
            }
        }

        if (hookValidation.ok) {
            bool hookDeployed = cfg.hookAddress != address(0) && cfg.hookAddress.code.length > 0;

            uint64 minCloseVolToCashUsd6;
            uint64 emergencyFloorCloseVolUsd6;
            uint8 cashHoldPeriods;
            uint8 extremeHoldPeriods;

            if (hookDeployed) {
                VolumeDynamicFeeHook h = VolumeDynamicFeeHook(payable(cfg.hookAddress));
                minCloseVolToCashUsd6 = h.minCloseVolToCashUsd6();
                emergencyFloorCloseVolUsd6 = h.emergencyFloorCloseVolUsd6();
                cashHoldPeriods = h.cashHoldPeriods();
                extremeHoldPeriods = h.extremeHoldPeriods();
            } else {
                minCloseVolToCashUsd6 = cfg.minCloseVolToCashUsd6;
                emergencyFloorCloseVolUsd6 = cfg.emergencyFloorCloseVolUsd6;
                cashHoldPeriods = cfg.cashHoldPeriods;
                extremeHoldPeriods = cfg.extremeHoldPeriods;
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
                hookValidation.ok = false;
                hookValidation.reason = "weak hold periods blocked (set ALLOW_WEAK_HOLD_PERIODS=true to override)";
            }
        }

        bool ok = tokenValidation.ok && budget.ok && range.ok && hookValidation.ok;

        string memory reportPath = _preflightReportPath();

        JsonReportLib.writePreflightReport(
            reportPath,
            string.concat(_network(), "-preflight"),
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
            revert("live preflight failed");
        }

        LoggingLib.ok("preflight passed");
    }
}
