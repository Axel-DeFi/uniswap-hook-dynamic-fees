// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {VolumeDynamicFeeHook} from "../../src/VolumeDynamicFeeHook.sol";

/// @notice Minimal PoolManager mock for unit testing this hook's algorithm.
/// @dev Only implements the pieces this hook touches.
contract MockPoolManager {
    uint24 public lastFee;
    uint256 public updateCount;

    error NotHook();

    function updateDynamicLPFee(PoolKey calldata key, uint24 newFee) external {
        if (msg.sender != address(key.hooks)) revert NotHook();
        lastFee = newFee;
        updateCount += 1;
    }

    function callAfterInitialize(VolumeDynamicFeeHook hook, PoolKey calldata key) external {
        hook.afterInitialize(address(0xBEEF), key, 0, 0, "");
    }

    function callAfterSwap(VolumeDynamicFeeHook hook, PoolKey calldata key, BalanceDelta delta) external {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 0,
            sqrtPriceLimitX96: 0
        });

        hook.afterSwap(address(0xBEEF), key, params, delta, "");
    }
}
