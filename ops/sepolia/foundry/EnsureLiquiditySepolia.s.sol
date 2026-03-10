// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {BudgetLib} from "../../shared/lib/BudgetLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract EnsureLiquiditySepolia is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        LoggingLib.phase("sepolia.ensure-liquidity");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        require(cfg.hookAddress != address(0) && cfg.hookAddress.code.length > 0, "HOOK_ADDRESS missing");

        address driver = vm.envOr("LIQUIDITY_DRIVER", address(0));
        require(driver != address(0) && driver.code.length > 0, "LIQUIDITY_DRIVER missing");

        PoolKey memory key = _poolKey(cfg);
        IPoolManager manager = IPoolManager(cfg.poolManager);
        (uint160 sqrtPriceX96, int24 tickCurrent,,) = manager.getSlot0(key.toId());
        require(sqrtPriceX96 > 0, "pool not initialized");
        if (manager.getLiquidity(key.toId()) > 0) {
            LoggingLib.ok("liquidity already present");
            return;
        }

        OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        require(budget.ok, budget.reason);

        uint256 amount0 = cfg.token0 == cfg.stableToken ? cfg.liquidityBudgetStableRaw : cfg.liquidityBudgetVolatileRaw;
        uint256 amount1 = cfg.token1 == cfg.stableToken ? cfg.liquidityBudgetStableRaw : cfg.liquidityBudgetVolatileRaw;
        require(amount0 > 0 || amount1 > 0, "liquidity budget is zero");

        (int24 tickLower, int24 tickUpper) = _deriveLiquidityRange(cfg.tickSpacing, tickCurrent, amount0, amount1);
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, amount0, amount1);

        if (liquidity == 0) {
            bool preferToken0Only;
            if (amount0 > 0 && amount1 == 0) {
                preferToken0Only = true;
            } else if (amount1 > 0 && amount0 == 0) {
                preferToken0Only = false;
            } else {
                preferToken0Only = cfg.stableToken == cfg.token0;
            }
            (tickLower, tickUpper) = _deriveOneSidedRange(cfg.tickSpacing, tickCurrent, preferToken0Only);
            sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
            sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
            liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, amount0, amount1);
        }
        if (liquidity == 0 && amount1 > 0) {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLowerX96, sqrtUpperX96, amount1);
        }
        if (liquidity == 0 && amount0 > 0) {
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtLowerX96, sqrtUpperX96, amount0);
        }
        uint256 maxLiquidityDelta = vm.envOr("MAX_LIQUIDITY_DELTA", uint256(1_000_000_000_000));
        require(maxLiquidityDelta > 0 && maxLiquidityDelta <= type(uint128).max, "MAX_LIQUIDITY_DELTA invalid");
        if (uint256(liquidity) > maxLiquidityDelta) {
            liquidity = uint128(maxLiquidityDelta);
        }
        if (liquidity == 0) {
            uint256 fallbackDelta = vm.envOr("LIQUIDITY_FALLBACK_DELTA", uint256(1));
            require(fallbackDelta > 0 && fallbackDelta <= type(uint128).max, "LIQUIDITY_FALLBACK_DELTA invalid");
            liquidity = uint128(fallbackDelta);
        }

        (uint256 required0, uint256 required1) =
            _requiredTokenInputs(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, liquidity);
        if (required0 > amount0 || required1 > amount1) {
            LoggingLib.ok("liquidity ensure skipped (required tokens exceed configured budget)");
            return;
        }

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });

        vm.startBroadcast(pk);
        _approveMaxIfERC20(cfg.token0, driver, amount0);
        _approveMaxIfERC20(cfg.token1, driver, amount1);
        bool sent;
        try ILiquidityDriver(driver).modifyLiquidity{value: _nativeValue(cfg.token0, amount0, cfg.token1, amount1)}(
            key, params, ""
        ) {
            sent = true;
        } catch {
            sent = false;
        }
        vm.stopBroadcast();

        if (sent) {
            LoggingLib.ok("liquidity ensure tx sent");
        } else {
            LoggingLib.ok("liquidity ensure skipped (driver call reverted)");
        }
    }

    function _poolKey(OpsTypes.CoreConfig memory cfg) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(cfg.token0),
            currency1: Currency.wrap(cfg.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.hookAddress)
        });
    }

    function _approveMaxIfERC20(address token, address spender, uint256 amount) private {
        if (token == address(0) || amount == 0) return;
        IERC20Minimal(token).approve(spender, type(uint256).max);
    }

    function _nativeValue(address token0, uint256 amount0, address token1, uint256 amount1)
        private
        pure
        returns (uint256)
    {
        if (token0 == address(0)) return amount0;
        if (token1 == address(0)) return amount1;
        return 0;
    }

    function _deriveLiquidityRange(int24 tickSpacing, int24 currentTick, uint256 amount0, uint256 amount1)
        private
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        int24 aligned = _floorToSpacing(currentTick, tickSpacing);
        int256 rawWindow = int256(tickSpacing) * 600;
        if (rawWindow > type(int24).max) rawWindow = type(int24).max;
        int24 window = int24(rawWindow);
        if (window < tickSpacing) window = tickSpacing;

        if (amount0 == 0 && amount1 > 0) {
            tickUpper = aligned - tickSpacing;
            tickLower = tickUpper - window;
        } else if (amount1 == 0 && amount0 > 0) {
            tickLower = aligned + tickSpacing;
            tickUpper = tickLower + window;
        } else {
            tickLower = aligned - window;
            tickUpper = aligned + window;
        }

        if (tickLower < minTick) tickLower = minTick;
        if (tickUpper > maxTick) tickUpper = maxTick;

        if (tickLower >= tickUpper) {
            tickLower = minTick;
            tickUpper = maxTick;
        }
    }

    function _floorToSpacing(int24 tick, int24 spacing) private pure returns (int24) {
        int24 remainder = tick % spacing;
        if (remainder < 0) {
            return tick - remainder - spacing;
        }
        return tick - remainder;
    }

    function _deriveOneSidedRange(int24 tickSpacing, int24 currentTick, bool token0Only)
        private
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        int24 aligned = _floorToSpacing(currentTick, tickSpacing);

        int256 rawWindow = int256(tickSpacing) * 4;
        if (rawWindow > type(int24).max) rawWindow = type(int24).max;
        int24 window = int24(rawWindow);
        if (window < tickSpacing) window = tickSpacing;

        if (token0Only) {
            tickLower = aligned + tickSpacing;
            tickUpper = tickLower + window;
        } else {
            tickUpper = aligned - tickSpacing;
            tickLower = tickUpper - window;
        }

        if (tickLower < minTick) tickLower = minTick;
        if (tickUpper > maxTick) tickUpper = maxTick;
        if (tickLower >= tickUpper) {
            tickLower = minTick;
            tickUpper = maxTick;
        }
    }

    function _requiredTokenInputs(
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint128 liquidity
    ) private pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceX96 <= sqrtLowerX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLowerX96, sqrtUpperX96, liquidity, true);
            return (amount0, 0);
        }
        if (sqrtPriceX96 < sqrtUpperX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpperX96, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtPriceX96, liquidity, true);
            return (amount0, amount1);
        }
        amount1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtUpperX96, liquidity, true);
    }
}

interface ILiquidityDriver {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable;
}
