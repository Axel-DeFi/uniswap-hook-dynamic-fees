// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

/// @notice Minimal unlock callback interface used by PoolManager.unlock().
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @notice Minimal PoolManager mock for compilation and basic hook call flow.
/// @dev Not a full IPoolManager implementation; only what the hook uses.
contract MockPoolManager {
    uint24 public lastFee;
    uint256 public updateCount;

    error NotHook();

    // forge-lint: disable-next-line(mixed-case-function)
    function updateDynamicLPFee(PoolKey calldata key, uint24 newFee) external {
        if (msg.sender != address(key.hooks)) revert NotHook();
        lastFee = newFee;
        updateCount += 1;
    }

    /// @notice Mimics PoolManager.unlock by calling back into the caller (msg.sender).
    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function callAfterInitialize(VolumeDynamicFeeHook hook, PoolKey calldata key) external {
        hook.afterInitialize(address(0xBEEF), key, 0, 0);
    }

    function callAfterSwap(VolumeDynamicFeeHook hook, PoolKey calldata key, BalanceDelta delta) external {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0});
        hook.afterSwap(address(0xBEEF), key, params, delta, "");
    }
}
