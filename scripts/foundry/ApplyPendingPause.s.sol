// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

/// @notice Applies a pending pause/unpause update immediately via PoolManager.unlock callback.
/// @dev Requires the broadcaster to be the configured guardian.
contract ApplyPendingPause is Script {
    function run() external {
        address hookAddr = vm.envAddress("HOOK_ADDRESS");
        vm.startBroadcast();
        VolumeDynamicFeeHook(hookAddr).applyPendingPause();
        vm.stopBroadcast();

        console2.log("Applied pending pause/unpause update (if any) for hook:", hookAddr);
    }
}
