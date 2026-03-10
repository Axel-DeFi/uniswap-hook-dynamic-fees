// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {OpsTypes} from "../types/OpsTypes.sol";

library HookValidationLib {
    function validateHook(OpsTypes.CoreConfig memory cfg)
        internal
        view
        returns (OpsTypes.HookValidation memory validation)
    {
        validation.ok = true;

        if (cfg.hookAddress == address(0)) {
            validation.ok = false;
            validation.reason = "HOOK_ADDRESS missing";
            return validation;
        }

        validation.codeSize = cfg.hookAddress.code.length;
        if (validation.codeSize == 0) {
            validation.ok = false;
            validation.reason = "hook has no code";
            return validation;
        }

        IVolumeHook hook = IVolumeHook(cfg.hookAddress);

        Hooks.Permissions memory perms = hook.getHookPermissions();
        validation.permissionFlagsMatch =
            perms.afterInitialize && perms.afterSwap && perms.afterSwapReturnDelta && !perms.beforeSwap
                && !perms.beforeSwapReturnDelta;
        if (!validation.permissionFlagsMatch) {
            validation.ok = false;
            validation.reason = "hook permissions mismatch";
            return validation;
        }

        address c0 = Currency.unwrap(hook.poolCurrency0());
        address c1 = Currency.unwrap(hook.poolCurrency1());
        validation.poolBindingMatch =
            (c0 == cfg.token0 && c1 == cfg.token1 && hook.poolTickSpacing() == cfg.tickSpacing);
        validation.stableInPool = (Currency.unwrap(hook.stableCurrency()) == cfg.stableToken);

        if (!validation.poolBindingMatch) {
            validation.ok = false;
            validation.reason = "hook pool binding mismatch";
            return validation;
        }

        if (!validation.stableInPool) {
            validation.ok = false;
            validation.reason = "hook stable token mismatch";
            return validation;
        }

        validation.reason = "ok";
    }
}

interface IVolumeHook {
    function getHookPermissions() external pure returns (Hooks.Permissions memory);
    function poolCurrency0() external view returns (Currency);
    function poolCurrency1() external view returns (Currency);
    function poolTickSpacing() external view returns (int24);
    function stableCurrency() external view returns (Currency);
}
