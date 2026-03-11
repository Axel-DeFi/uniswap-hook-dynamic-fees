// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {HookIdentityLib} from "./HookIdentityLib.sol";
import {HookValidationLib} from "./HookValidationLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";

library CanonicalHookResolverLib {
    function requireExistingCanonicalHook(OpsTypes.CoreConfig memory cfg)
        internal
        view
        returns (OpsTypes.CoreConfig memory resolvedCfg, address canonicalHookAddress)
    {
        (canonicalHookAddress,,) = HookIdentityLib.expectedHookAddress(cfg);

        if (cfg.hookAddress != address(0) && cfg.hookAddress != canonicalHookAddress) {
            revert("HOOK_ADDRESS not canonical for current release/config");
        }

        cfg.hookAddress = canonicalHookAddress;

        if (canonicalHookAddress.code.length == 0) {
            revert("canonical HOOK_ADDRESS missing");
        }

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        if (!validation.ok) {
            revert(validation.reason);
        }

        return (cfg, canonicalHookAddress);
    }
}
