// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "../utils/VolumeDynamicFeeHookV2DeployHelper.sol";

contract VolumeDynamicFeeHookNativeClaimAccountingIntegrationTest is
    Test,
    VolumeDynamicFeeHookV2DeployHelper
{
    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;

    VolumeDynamicFeeHook internal hook;
    PoolKey internal key;

    TestERC20 internal token1;

    uint32 internal constant PERIOD_SECONDS = 300;
    uint8 internal constant EMA_PERIODS = 8;
    uint16 internal constant DEADBAND_BPS = 500;
    uint32 internal constant LULL_RESET_SECONDS = 3600;

    int24 internal constant TICK_SPACING = 60;

    receive() external payable {}

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        token1 = new TestERC20(1e36);
        vm.deal(address(this), 10 ether);

        Currency c0 = Currency.wrap(address(0));
        Currency c1 = Currency.wrap(address(token1));

        token1.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        bytes memory constructorArgs = _constructorArgsV2(
            IPoolManager(address(manager)),
            c0,
            c1,
            TICK_SPACING,
            c1,
            18,
            V2_DEFAULT_FLOOR_FEE,
            V2_DEFAULT_CASH_FEE,
            V2_DEFAULT_EXTREME_FEE,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            address(this),
            V2_INITIAL_HOOK_FEE_PERCENT
        );

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address mined, bytes32 salt) =
            HookMiner.find(address(this), flags, type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        hook = _deployHookV2(
            salt,
            IPoolManager(address(manager)),
            c0,
            c1,
            TICK_SPACING,
            c1,
            18,
            V2_DEFAULT_FLOOR_FEE,
            V2_DEFAULT_CASH_FEE,
            V2_DEFAULT_EXTREME_FEE,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            address(this),
            V2_INITIAL_HOOK_FEE_PERCENT
        );

        assertEq(address(hook), mined, "hook address mismatch");

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        manager.initialize(key, Constants.SQRT_PRICE_1_1);

        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: bytes32(0)});
        liquidityRouter.modifyLiquidity{value: 1 ether}(key, addParams, "");
    }

    function test_claimAllHookFees_nativeCurrency0_path_increases_owner_eth_balance() public {
        _swapExactInputToken1ForNative(9_000_000_000_000_000);

        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        assertGt(fees0, 0);
        assertEq(fees1, 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), fees0);

        uint256 ownerBefore = address(this).balance;

        hook.claimAllHookFees();

        uint256 ownerAfter = address(this).balance;
        assertEq(ownerAfter - ownerBefore, fees0);

        (fees0, fees1) = hook.hookFeesAccrued();
        assertEq(fees0, 0);
        assertEq(fees1, 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
    }

    function _swapExactInputToken1ForNative(uint256 amountIn) internal {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: Constants.SQRT_PRICE_2_1
        });

        swapRouter.swap(key, params, settings, "");
    }
}
