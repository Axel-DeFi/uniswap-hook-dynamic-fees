// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {NativeRecipientValidationLib} from "ops/shared/lib/NativeRecipientValidationLib.sol";
import {ConstructorArgsConfigLib} from "ops/shared/lib/ConstructorArgsConfigLib.sol";
import {HookIdentityLib} from "ops/shared/lib/HookIdentityLib.sol";
import {HookValidationLib} from "ops/shared/lib/HookValidationLib.sol";
import {OpsTypes} from "ops/shared/types/OpsTypes.sol";

/// @notice Mines the hook address flags and deploys VolumeDynamicFeeHook via CREATE2.
/// @dev Constructor args (including v2 controller params) are pre-encoded off-chain and passed via CONSTRUCTOR_ARGS_HEX.
contract DeployHook is Script {
    // Foundry deterministic CREATE2 deployer proxy used by forge scripts.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        bytes memory constructorArgs = vm.envBytes("CONSTRUCTOR_ARGS_HEX");
        require(constructorArgs.length > 0, "DeployHook: CONSTRUCTOR_ARGS_HEX missing");

        OpsTypes.CoreConfig memory cfg = ConstructorArgsConfigLib.toCoreConfig(constructorArgs);
        (address canonicalHookAddress, bytes32 canonicalSalt,) = HookIdentityLib.expectedHookAddress(cfg);
        cfg.hookAddress = canonicalHookAddress;

        (
            ,
            address poolCurrency0,
            address poolCurrency1,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            address owner,
            ,
            uint64 minCloseVolToCashUsd6,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint64 emergencyFloorCloseVolUsd6,
            ,
        ) = abi.decode(
            constructorArgs,
            (
                address,
                address,
                address,
                int24,
                address,
                uint8,
                uint24,
                uint24,
                uint24,
                uint32,
                uint8,
                uint16,
                uint32,
                address,
                uint16,
                uint64,
                uint16,
                uint8,
                uint64,
                uint16,
                uint8,
                uint8,
                uint16,
                uint8,
                uint16,
                uint8,
                uint64,
                uint8
            )
        );
        require(
            emergencyFloorCloseVolUsd6 > 0 && emergencyFloorCloseVolUsd6 < minCloseVolToCashUsd6,
            "DeployHook: invalid emergency floor relation"
        );

        (bool nativeRecipientOk, string memory nativeRecipientReason) = NativeRecipientValidationLib.validatePayoutRecipientForNativePool(
            poolCurrency0, poolCurrency1, owner, cfg.poolManager
        );
        require(nativeRecipientOk, nativeRecipientReason);

        if (canonicalHookAddress.code.length > 0) {
            OpsTypes.HookValidation memory existing = HookValidationLib.validateHook(cfg);
            require(existing.ok, string.concat("DeployHook: canonical hook invalid: ", existing.reason));

            console2.log("VolumeDynamicFeeHook already deployed at:", canonicalHookAddress);
            console2.log("Salt:", uint256(canonicalSalt));

            string memory existingOut = vm.serializeAddress("deploy", "hook", canonicalHookAddress);
            vm.writeJson(existingOut, vm.envOr("DEPLOY_JSON_PATH", string("out/deploy.json")));
            return;
        }

        bytes memory creationCodeWithArgs =
            abi.encodePacked(type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        vm.startBroadcast();
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(canonicalSalt, creationCodeWithArgs));
        vm.stopBroadcast();
        require(ok, "DeployHook: create2 deploy failed");

        require(canonicalHookAddress.code.length > 0, "DeployHook: no code at canonical address");

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        require(validation.ok, string.concat("DeployHook: canonical hook validation failed: ", validation.reason));

        console2.log("VolumeDynamicFeeHook deployed at:", canonicalHookAddress);
        console2.log("Salt:", uint256(canonicalSalt));

        // Persist the deployed hook address for the next step (pool creation).
        string memory out = vm.serializeAddress("deploy", "hook", canonicalHookAddress);
        vm.writeJson(out, vm.envOr("DEPLOY_JSON_PATH", string("out/deploy.json")));
    }
}
