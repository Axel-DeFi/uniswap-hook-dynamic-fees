// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ConfigLoader} from "../lib/ConfigLoader.sol";
import {HookIdentityLib} from "../lib/HookIdentityLib.sol";
import {HookValidationLib} from "../lib/HookValidationLib.sol";
import {LoggingLib} from "../lib/LoggingLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";
import {LiveOpsBase} from "./LiveOpsBase.s.sol";

contract ValidateHookLive is LiveOpsBase {
    function run() external view {
        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        (address canonicalHookAddress,,) = HookIdentityLib.expectedHookAddress(cfg);

        if (cfg.hookAddress != address(0) && cfg.hookAddress != canonicalHookAddress) {
            revert("HOOK_ADDRESS not canonical for current release/config");
        }

        cfg.hookAddress = canonicalHookAddress;
        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        if (!validation.ok) {
            revert(validation.reason);
        }

        LoggingLib.ok("live hook validation passed");
    }
}
