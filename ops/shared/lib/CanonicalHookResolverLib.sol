// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {ConfigLoader} from "./ConfigLoader.sol";
import {HookIdentityLib} from "./HookIdentityLib.sol";
import {HookValidationLib} from "./HookValidationLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";

library CanonicalHookResolverLib {
    function requireExistingCanonicalHook(
        OpsTypes.CoreConfig memory runtimeCfg,
        OpsTypes.DeploymentConfig memory deployCfg
    )
        internal
        view
        returns (OpsTypes.CoreConfig memory resolvedCfg, address canonicalHookAddress)
    {
        ConfigLoader.requireDeploymentBindingConsistency(runtimeCfg, deployCfg);
        (canonicalHookAddress,,) = HookIdentityLib.expectedHookAddress(deployCfg);

        if (runtimeCfg.hookAddress != address(0) && runtimeCfg.hookAddress != canonicalHookAddress) {
            revert("HOOK_ADDRESS not canonical for current release/deployment snapshot");
        }

        runtimeCfg.hookAddress = canonicalHookAddress;

        if (canonicalHookAddress.code.length == 0) {
            revert("canonical HOOK_ADDRESS missing");
        }

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(runtimeCfg);
        if (!validation.ok) {
            revert(validation.reason);
        }

        return (runtimeCfg, canonicalHookAddress);
    }
}
