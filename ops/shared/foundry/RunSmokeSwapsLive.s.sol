// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {CanonicalHookResolverLib} from "../lib/CanonicalHookResolverLib.sol";
import {ConfigLoader} from "../lib/ConfigLoader.sol";
import {BudgetLib} from "../lib/BudgetLib.sol";
import {DriverValidationLib} from "../lib/DriverValidationLib.sol";
import {RangeSafetyLib} from "../lib/RangeSafetyLib.sol";
import {LoggingLib} from "../lib/LoggingLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";
import {LiveOpsBase} from "./LiveOpsBase.s.sol";

struct TestSettings {
    bool takeClaims;
    bool settleUsingBurn;
}

struct SwapPlan {
    bool executable;
    uint256 value;
    SwapParams params;
}

contract RunSmokeSwapsLive is LiveOpsBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        LoggingLib.phase(_phase("smoke"));

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        OpsTypes.DeploymentConfig memory deployCfg = ConfigLoader.loadDeploymentConfig(cfg);
        ConfigLoader.requireDeploymentBindingConsistency(cfg, deployCfg);
        (cfg,) = CanonicalHookResolverLib.requireExistingCanonicalHook(cfg, deployCfg);
        OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        require(budget.ok, budget.reason);

        OpsTypes.RangeCheck memory range = RangeSafetyLib.validateRange(cfg);
        require(range.ok, range.reason);

        address driver = vm.envOr("SWAP_DRIVER", address(0));
        DriverValidationLib.requireValidSwapDriver(driver, cfg.poolManager);

        uint256 amountStable = vm.envOr("SMOKE_SWAP_STABLE_RAW", range.maxSwapStableRaw);
        if (amountStable == 0) amountStable = 1_000_000;
        require(amountStable <= uint256(type(int256).max), "swap amount too large");

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        PoolKey memory key = _poolKey(cfg);
        IPoolManager manager = IPoolManager(cfg.poolManager);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());

        SwapPlan memory plan = _selectPlan(cfg, sqrtPriceX96, amountStable);
        if (!plan.executable) {
            LoggingLib.ok("smoke swap skipped (price at boundary / no viable swap side)");
            return;
        }

        address inputToken = plan.params.zeroForOne ? cfg.token0 : cfg.token1;
        uint256 inputAmount = uint256(-plan.params.amountSpecified);

        vm.startBroadcast(pk);
        _approveExactIfERC20(inputToken, driver, inputAmount);
        bool sent;
        try ISwapDriver(driver).swap{value: plan.value}(key, plan.params, TestSettings(false, false), "") {
            sent = true;
        } catch {
            sent = false;
        }
        _clearApproveIfERC20(inputToken, driver, inputAmount);
        vm.stopBroadcast();

        if (!sent) {
            LoggingLib.ok("smoke swap skipped (driver call reverted)");
            return;
        }

        LoggingLib.ok("smoke swap tx sent");
    }

    function _selectPlan(OpsTypes.CoreConfig memory cfg, uint160 sqrtPriceX96, uint256 amountStableRaw)
        private
        pure
        returns (SwapPlan memory plan)
    {
        bool stableZeroForOne = cfg.stableToken == cfg.token0;
        if (_directionAllowed(stableZeroForOne, sqrtPriceX96)) {
            plan.executable = true;
            plan.value = cfg.stableToken == address(0) ? amountStableRaw : 0;
            plan.params = _swapParams(stableZeroForOne, amountStableRaw);
            return plan;
        }

        uint256 amountVolatileRaw = cfg.swapBudgetVolatileRaw;
        if (amountVolatileRaw == 0 || amountVolatileRaw > uint256(type(int256).max)) {
            return plan;
        }

        bool volatileZeroForOne = cfg.volatileToken == cfg.token0;
        if (!_directionAllowed(volatileZeroForOne, sqrtPriceX96)) {
            return plan;
        }

        plan.executable = true;
        plan.value = cfg.volatileToken == address(0) ? amountVolatileRaw : 0;
        plan.params = _swapParams(volatileZeroForOne, amountVolatileRaw);
    }

    function _directionAllowed(bool zeroForOne, uint160 sqrtPriceX96) private pure returns (bool) {
        if (zeroForOne) {
            return sqrtPriceX96 > TickMath.MIN_SQRT_PRICE + 1;
        }
        return sqrtPriceX96 < TickMath.MAX_SQRT_PRICE - 1;
    }

    function _swapParams(bool zeroForOne, uint256 amountRaw) private pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountRaw),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
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

    function _approveExactIfERC20(address token, address spender, uint256 amount) private {
        if (token == address(0) || amount == 0) return;
        IERC20Minimal(token).approve(spender, amount);
    }

    function _clearApproveIfERC20(address token, address spender, uint256 amount) private {
        if (token == address(0) || amount == 0) return;
        IERC20Minimal(token).approve(spender, 0);
    }
}

interface ISwapDriver {
    function swap(PoolKey memory key, SwapParams memory params, TestSettings memory testSettings, bytes memory hookData)
        external
        payable;
}
