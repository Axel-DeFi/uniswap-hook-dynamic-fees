// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @notice Creates + initializes a v4 dynamic-fee pool using a deployed hook.
/// @dev Reads VOLATILE/STABLE and derives canonical currency0/currency1 by address sorting.
contract CreatePool is Script {
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address hook = vm.envAddress("HOOK_ADDRESS");

        address volatileToken = vm.envAddress("VOLATILE");
        address stableToken = vm.envAddress("STABLE");

        int24 tickSpacing = int24(vm.envInt("TICK_SPACING"));
        uint160 sqrtPriceX96 = uint160(vm.envUint("INIT_SQRT_PRICE_X96"));

        (address token0, address token1) = _sort(volatileToken, stableToken);

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

        console2.log("Pool initialized.");
        console2.log("Hook:", hook);
        console2.log("currency0:", token0);
        console2.log("currency1:", token1);
        console2.log("stable:", stableToken);
    }

    function _sort(address a, address b) internal pure returns (address token0, address token1) {
        if (a < b) return (a, b);
        return (b, a);
    }
}