// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

import {OpsTypes} from "../types/OpsTypes.sol";

library HookIdentityLib {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 internal constant MAX_LOOP = 160_444;
    uint160 internal constant EXPECTED_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function constructorArgs(OpsTypes.DeploymentConfig memory cfg) internal pure returns (bytes memory args) {
        args = abi.encode(
            IPoolManager(cfg.poolManager),
            Currency.wrap(cfg.token0),
            Currency.wrap(cfg.token1),
            cfg.tickSpacing,
            Currency.wrap(cfg.stableToken),
            cfg.stableDecimals,
            cfg.floorFeePips,
            cfg.cashFeePips,
            cfg.extremeFeePips,
            cfg.periodSeconds,
            cfg.emaPeriods,
            cfg.lullResetSeconds,
            cfg.owner,
            cfg.hookFeePercent,
            cfg.minCloseVolToCashUsd6,
            cfg.cashEnterTriggerBps,
            cfg.cashHoldPeriods,
            cfg.minCloseVolToExtremeUsd6,
            cfg.extremeEnterTriggerBps,
            cfg.upExtremeConfirmPeriods,
            cfg.extremeHoldPeriods,
            cfg.extremeExitTriggerBps,
            cfg.downExtremeConfirmPeriods,
            cfg.cashExitTriggerBps,
            cfg.downCashConfirmPeriods,
            cfg.emergencyFloorCloseVolUsd6,
            cfg.emergencyConfirmPeriods
        );
    }

    function expectedHookAddress(OpsTypes.DeploymentConfig memory cfg)
        internal
        pure
        returns (address hookAddress, bytes32 salt, bytes memory args)
    {
        args = constructorArgs(cfg);
        bytes memory creationCodeWithArgs = abi.encodePacked(type(VolumeDynamicFeeHook).creationCode, args);

        for (uint256 rawSalt; rawSalt < MAX_LOOP; rawSalt++) {
            hookAddress = HookMiner.computeAddress(CREATE2_DEPLOYER, rawSalt, creationCodeWithArgs);
            if ((uint160(hookAddress) & Hooks.ALL_HOOK_MASK) == EXPECTED_FLAGS) {
                salt = bytes32(rawSalt);
                return (hookAddress, salt, args);
            }
        }

        revert("HookIdentityLib: could not derive canonical hook address");
    }
}
