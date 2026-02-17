// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @notice Creates + initializes a Uniswap v4 pool that uses a previously deployed hook.
/// @dev Requires the pool to be configured as a dynamic fee pool (PoolKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG).
///      This script expects HOOK_ADDRESS to be provided via config (config/pool.<chain>.conf).
contract CreatePool is Script {
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address hook = vm.envAddress("HOOK_ADDRESS");

        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");

        int24 tickSpacing = int24(vm.envInt("TICK_SPACING"));
        uint160 sqrtPriceX96 = uint160(vm.envUint("INIT_SQRT_PRICE_X96"));

        // Ensure PoolKey ordering (currency0 < currency1).
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });

        vm.startBroadcast();
        IPoolManager(poolManager).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        console2.log("Pool initialized with dynamic fee flag.");
        console2.log("Hook:", hook);
    }
}
