// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {StatelessDynamicFeeHook} from "../src/StatelessDynamicFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice Deploys the hook with CREATE2 and mines a salt so the hook address has BEFORE_SWAP_FLAG.
/// @dev Uses the canonical EIP-2470 CREATE2 deployer at 0x4e59... to make the deployer address stable.
contract DeployHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920ca78fbf26c0b4956c;

    function run() external {
        address manager = vm.envAddress("POOL_MANAGER");

        bytes memory initCode =
            abi.encodePacked(type(StatelessDynamicFeeHook).creationCode, abi.encode(IPoolManager(manager)));
        bytes32 initCodeHash = keccak256(initCode);

        bytes32 salt = _mineSalt(initCodeHash, uint160(Hooks.BEFORE_SWAP_FLAG));
        address predicted = _computeCreate2Address(CREATE2_DEPLOYER, salt, initCodeHash);

        console2.log("Mined salt:");
        console2.logBytes32(salt);
        console2.log("Predicted hook:");
        console2.logAddress(predicted);
        console2.log("Flag check (beforeSwap):", (uint160(predicted) & uint160(Hooks.BEFORE_SWAP_FLAG)) != 0);

        vm.startBroadcast();

        address deployed = _deployCreate2(salt, initCode);

        vm.stopBroadcast();

        require(deployed == predicted, "deploy mismatch");
        require(
            (uint160(deployed) & uint160(Hooks.BEFORE_SWAP_FLAG)) == uint160(Hooks.BEFORE_SWAP_FLAG),
            "missing BEFORE_SWAP flag"
        );

        console2.log("Deployed hook:");
        console2.logAddress(deployed);
    }

    function _mineSalt(bytes32 initCodeHash, uint160 requiredFlags) internal view returns (bytes32 salt) {
        // Increase maxIterations if needed (network-dependent).
        uint256 maxIterations = uint256(vm.envOr("SALT_SEARCH_MAX", uint256(2_000_000)));
        for (uint256 i = 0; i < maxIterations; i++) {
            salt = bytes32(i);
            address predicted = _computeCreate2Address(CREATE2_DEPLOYER, salt, initCodeHash);
            if ((uint160(predicted) & requiredFlags) == requiredFlags) return salt;
        }
        revert("salt mining failed");
    }

    function _computeCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash));
        return address(uint160(uint256(h)));
    }

    function _deployCreate2(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        // EIP-2470 Create2 deployer has function deploy(bytes32 salt, bytes memory code) returns (address)
        (bool ok, bytes memory data) =
            CREATE2_DEPLOYER.call(abi.encodeWithSignature("deploy(bytes32,bytes)", salt, initCode));
        require(ok, "create2 deployer call failed");
        deployed = abi.decode(data, (address));
    }
}
