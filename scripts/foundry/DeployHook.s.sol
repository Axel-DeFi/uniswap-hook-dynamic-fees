// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {NativeRecipientValidationLib} from "ops/shared/lib/NativeRecipientValidationLib.sol";

/// @notice Mines the hook address flags and deploys VolumeDynamicFeeHook via CREATE2.
/// @dev Constructor args (including v2 controller params) are pre-encoded off-chain and passed via CONSTRUCTOR_ARGS_HEX.
contract DeployHook is Script {
    // Foundry deterministic CREATE2 deployer proxy used by forge scripts.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        bytes memory constructorArgs = vm.envBytes("CONSTRUCTOR_ARGS_HEX");
        require(constructorArgs.length > 0, "DeployHook: CONSTRUCTOR_ARGS_HEX missing");

        (, address poolCurrency0, address poolCurrency1,,,,,,,,,,, address hookFeeRecipient,,,,,,,,,,,,,,) = abi.decode(
            constructorArgs,
            (
                address,
                address,
                address,
                int24,
                address,
                uint8,
                uint8,
                uint24[],
                uint32,
                uint8,
                uint16,
                uint32,
                address,
                address,
                uint16,
                uint24,
                uint64,
                uint16,
                uint8,
                uint24,
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

        // Hook must have flags encoded in its address.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address minedHookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        (bool nativeRecipientOk, string memory nativeRecipientReason) = NativeRecipientValidationLib.validateHookFeeRecipientForNativePool(
            poolCurrency0, poolCurrency1, hookFeeRecipient, minedHookAddress
        );
        require(nativeRecipientOk, nativeRecipientReason);

        bytes memory creationCodeWithArgs =
            abi.encodePacked(type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        vm.startBroadcast();
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, creationCodeWithArgs));
        vm.stopBroadcast();
        require(ok, "DeployHook: create2 deploy failed");

        require(minedHookAddress.code.length > 0, "DeployHook: no code at mined address");

        console2.log("VolumeDynamicFeeHook deployed at:", minedHookAddress);
        console2.log("Salt:", uint256(salt));
        console2.log("Flags:", flags);

        // Persist the deployed hook address for the next step (pool creation).
        string memory out = vm.serializeAddress("deploy", "hook", minedHookAddress);
        vm.writeJson(out, vm.envOr("DEPLOY_JSON_PATH", string("out/deploy.json")));
    }
}
