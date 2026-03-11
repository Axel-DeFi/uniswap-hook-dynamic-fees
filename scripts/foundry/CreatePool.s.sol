// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {ConstructorArgsConfigLib} from "ops/shared/lib/ConstructorArgsConfigLib.sol";
import {EnvLib} from "ops/shared/lib/EnvLib.sol";
import {HookIdentityLib} from "ops/shared/lib/HookIdentityLib.sol";
import {HookValidationLib} from "ops/shared/lib/HookValidationLib.sol";
import {OpsTypes} from "ops/shared/types/OpsTypes.sol";

/// @notice Creates + initializes a v4 dynamic-fee pool using a deployed hook.
/// @dev Reads VOLATILE/STABLE and derives canonical currency0/currency1 by address sorting.
contract CreatePool is Script {
    function run() external {
        bytes memory constructorArgs = vm.envBytes("CONSTRUCTOR_ARGS_HEX");
        require(constructorArgs.length > 0, "CONSTRUCTOR_ARGS_HEX missing");

        OpsTypes.CoreConfig memory cfg = ConstructorArgsConfigLib.toCoreConfig(constructorArgs);
        (address canonicalHookAddress,,) = HookIdentityLib.expectedHookAddress(cfg);

        address hook = EnvLib.requireAddress("HOOK_ADDRESS", false);
        require(hook == canonicalHookAddress, "HOOK_ADDRESS not canonical for current release/config");
        cfg.hookAddress = canonicalHookAddress;

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        require(validation.ok, validation.reason);

        uint256 sqrtPriceRaw = EnvLib.requireUint("INIT_SQRT_PRICE_X96");
        require(sqrtPriceRaw <= type(uint160).max, "INIT_SQRT_PRICE_X96 out of uint160 range");
        uint160 sqrtPriceX96 = uint160(sqrtPriceRaw);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(cfg.token0),
            currency1: Currency.wrap(cfg.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(canonicalHookAddress)
        });

        vm.startBroadcast();
        IPoolManager(cfg.poolManager).initialize(key, sqrtPriceX96);
        vm.stopBroadcast();

        console2.log("Pool initialized.");
        console2.log("Hook:", canonicalHookAddress);
        console2.log("currency0:", cfg.token0);
        console2.log("currency1:", cfg.token1);
        console2.log("stable:", cfg.stableToken);
    }
}
