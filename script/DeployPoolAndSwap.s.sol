// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/CurrencyLibrary.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

// Test helpers from v4-core (works well on local Anvil for demonstrations).
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "@uniswap/v4-core/src/test/MockERC20.sol";

import {StatelessDynamicFeeHook} from "../src/StatelessDynamicFeeHook.sol";

/// @notice Creates a dynamic-fee pool and performs a small swap and a larger swap.
///         Logs the hook-computed fee overrides for each swap.
contract DeployPoolAndSwap is Script {
    using CurrencyLibrary for Currency;

    function run() external {
        address managerAddr = vm.envAddress("POOL_MANAGER");
        address hookAddr = vm.envAddress("HOOK");

        PoolManager manager = PoolManager(managerAddr);
        StatelessDynamicFeeHook hook = StatelessDynamicFeeHook(hookAddr);

        vm.startBroadcast();

        // Deploy demo tokens & helpers.
        MockERC20 t0 = new MockERC20("Token0", "T0", 18);
        MockERC20 t1 = new MockERC20("Token1", "T1", 18);
        t0.mint(msg.sender, 10_000_000e18);
        t1.mint(msg.sender, 10_000_000e18);

        PoolModifyLiquidityTest modify = new PoolModifyLiquidityTest(manager);
        PoolSwapTest swapTest = new PoolSwapTest(manager);

        t0.approve(address(modify), type(uint256).max);
        t1.approve(address(modify), type(uint256).max);
        t0.approve(address(swapTest), type(uint256).max);
        t1.approve(address(swapTest), type(uint256).max);

        // Sort currencies as required by PoolKey.
        Currency c0 = Currency.wrap(address(t0));
        Currency c1 = Currency.wrap(address(t1));
        if (c1 < c0) (c0, c1) = (c1, c0);

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // Initialize at 1:1.
        manager.initialize(key, uint160(2 ** 96), "");

        // Add some liquidity.
        modify.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: int256(1e18),
                salt: 0
            }),
            ""
        );

        // Prepare swaps.
        IPoolManager.SwapParams memory small =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});
        IPoolManager.SwapParams memory large =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(1e21), sqrtPriceLimitX96: 0});

        // Log computed fee overrides (call hook as if PoolManager called it).
        vm.prank(managerAddr);
        (, , uint24 o1) = hook.beforeSwap(msg.sender, key, small, "");
        vm.prank(managerAddr);
        (, , uint24 o2) = hook.beforeSwap(msg.sender, key, large, "");

        uint24 f1 = o1 & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        uint24 f2 = o2 & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;

        console2.log("Small swap override fee (hundredths of a bip):", uint256(f1));
        console2.log("Large swap override fee (hundredths of a bip):", uint256(f2));

        // Execute swaps.
        swapTest.swap(
            key,
            small,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        swapTest.swap(
            key,
            large,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        vm.stopBroadcast();

        console2.log("Pool created and swaps executed.");
    }
}
