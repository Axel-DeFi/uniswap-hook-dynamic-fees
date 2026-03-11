// SPDX-License-Identifier: Apache-2.0
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

contract VolumeDynamicFeeHookClaimAccountingIntegrationTest is Test, VolumeDynamicFeeHookV2DeployHelper {
    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;

    VolumeDynamicFeeHook internal hook;
    PoolKey internal key;

    TestERC20 internal tokenA;
    TestERC20 internal tokenB;

    uint32 internal constant PERIOD_SECONDS = 300;
    uint8 internal constant EMA_PERIODS = 8;
    uint16 internal constant DEADBAND_BPS = 500;
    uint32 internal constant LULL_RESET_SECONDS = 3600;

    int24 internal constant TICK_SPACING = 60;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        tokenA = new TestERC20(1e36);
        tokenB = new TestERC20(1e36);

        Currency c0;
        Currency c1;
        if (address(tokenA) < address(tokenB)) {
            c0 = Currency.wrap(address(tokenA));
            c1 = Currency.wrap(address(tokenB));
        } else {
            c0 = Currency.wrap(address(tokenB));
            c1 = Currency.wrap(address(tokenA));
        }

        TestERC20(Currency.unwrap(c0)).approve(address(liquidityRouter), type(uint256).max);
        TestERC20(Currency.unwrap(c1)).approve(address(liquidityRouter), type(uint256).max);
        TestERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
        TestERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);

        bytes memory constructorArgs = _constructorArgsV2(
            IPoolManager(address(manager)),
            c0,
            c1,
            TICK_SPACING,
            c0,
            6,
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
            c0,
            6,
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
        liquidityRouter.modifyLiquidity(key, addParams, "");
    }

    function test_claimHookFees_token1_path_increases_owner_balance() public {
        _swapExactInput(true, 9_000_000);

        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        assertEq(fees0, 0);
        assertGt(fees1, 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), fees1);

        uint256 ownerBefore = _balanceOf(key.currency1, address(this));

        hook.claimHookFees(address(this), 0, fees1);

        uint256 ownerAfter = _balanceOf(key.currency1, address(this));
        assertEq(ownerAfter - ownerBefore, fees1);

        (fees0, fees1) = hook.hookFeesAccrued();
        assertEq(fees0, 0);
        assertEq(fees1, 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
    }

    function test_claimHookFees_token0_path_increases_owner_balance() public {
        _swapExactInput(false, 9_000_000);

        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        assertGt(fees0, 0);
        assertEq(fees1, 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), fees0);

        uint256 ownerBefore = _balanceOf(key.currency0, address(this));

        hook.claimHookFees(address(this), fees0, 0);

        uint256 ownerAfter = _balanceOf(key.currency0, address(this));
        assertEq(ownerAfter - ownerBefore, fees0);

        (fees0, fees1) = hook.hookFeesAccrued();
        assertEq(fees0, 0);
        assertEq(fees1, 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
    }

    function test_claimAllHookFees_transfers_both_tokens_to_owner() public {
        _swapExactInput(true, 9_000_000);
        _swapExactInput(false, 9_000_000);

        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        assertGt(fees0, 0);
        assertGt(fees1, 0);

        uint256 owner0Before = _balanceOf(key.currency0, address(this));
        uint256 owner1Before = _balanceOf(key.currency1, address(this));

        hook.claimAllHookFees();

        uint256 owner0After = _balanceOf(key.currency0, address(this));
        uint256 owner1After = _balanceOf(key.currency1, address(this));

        assertEq(owner0After - owner0Before, fees0);
        assertEq(owner1After - owner1Before, fees1);

        (fees0, fees1) = hook.hookFeesAccrued();
        assertEq(fees0, 0);
        assertEq(fees1, 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
    }

    function test_owner_transfer_moves_claim_destination_for_previously_accrued_fees() public {
        _swapExactInput(true, 9_000_000);
        _swapExactInput(false, 9_000_000);

        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        assertGt(fees0, 0);
        assertGt(fees1, 0);

        address newOwner = address(0xBEEF);
        uint256 newOwner0Before = _balanceOf(key.currency0, newOwner);
        uint256 newOwner1Before = _balanceOf(key.currency1, newOwner);

        hook.proposeNewOwner(newOwner);
        vm.prank(newOwner);
        hook.acceptOwner();

        vm.expectRevert(VolumeDynamicFeeHook.NotOwner.selector);
        hook.claimAllHookFees();

        vm.prank(newOwner);
        hook.claimAllHookFees();

        uint256 newOwner0After = _balanceOf(key.currency0, newOwner);
        uint256 newOwner1After = _balanceOf(key.currency1, newOwner);
        assertEq(newOwner0After - newOwner0Before, fees0);
        assertEq(newOwner1After - newOwner1Before, fees1);

        (fees0, fees1) = hook.hookFeesAccrued();
        assertEq(fees0, 0);
        assertEq(fees1, 0);
    }

    function test_pending_minCountedSwapUsd6_activates_only_on_next_period_boundary_integration() public {
        assertEq(hook.minCountedSwapUsd6(), 4_000_000);

        _swapExactInput(true, 6_000_000);
        (uint64 periodVol,,,) = hook.unpackedState();
        assertGt(periodVol, 0, "initial threshold must count this swap");

        hook.scheduleMinCountedSwapUsd6Change(10_000_000);

        uint64 periodVolBefore = periodVol;
        _swapExactInput(true, 6_000_000);
        (periodVol,,,) = hook.unpackedState();
        assertGt(periodVol, periodVolBefore, "pending threshold must not apply mid-period");

        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swapExactInput(true, 1_000_000);

        assertEq(hook.minCountedSwapUsd6(), 10_000_000);
        (periodVol,,,) = hook.unpackedState();
        assertEq(periodVol, 0, "new threshold must apply after period rollover");

        _swapExactInput(true, 6_000_000);
        (periodVol,,,) = hook.unpackedState();
        assertEq(periodVol, 0, "sub-threshold swaps must remain excluded");
    }

    function _swapExactInput(bool zeroForOne, uint256 amountIn) internal {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? Constants.SQRT_PRICE_1_2 : Constants.SQRT_PRICE_2_1
        });

        swapRouter.swap(key, params, settings, "");
    }

    function _balanceOf(Currency currency, address account) internal view returns (uint256) {
        return TestERC20(Currency.unwrap(currency)).balanceOf(account);
    }
}
