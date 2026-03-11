// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {HookIdentityLib} from "../../shared/lib/HookIdentityLib.sol";
import {HookValidationLib} from "../../shared/lib/HookValidationLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract ValidateHookSepolia is Script {
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

        LoggingLib.ok("sepolia hook validation passed");
    }
}
