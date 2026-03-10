// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

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

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {BudgetLib} from "../../shared/lib/BudgetLib.sol";
import {RangeSafetyLib} from "../../shared/lib/RangeSafetyLib.sol";
import {PoolStateLib} from "../../shared/lib/PoolStateLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

struct TestSettings {
    bool takeClaims;
    bool settleUsingBurn;
}

struct SwapPlan {
    bool executable;
    uint256 value;
    SwapParams params;
}

contract RunRerunSafeValidationSepolia is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        LoggingLib.phase("sepolia.rerun-safe");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        require(cfg.hookAddress != address(0) && cfg.hookAddress.code.length > 0, "HOOK_ADDRESS missing");

        OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        require(budget.ok, budget.reason);

        OpsTypes.RangeCheck memory range = RangeSafetyLib.validateRange(cfg);
        require(range.ok, range.reason);

        address driver = vm.envOr("SWAP_DRIVER", address(0));
        require(driver != address(0) && driver.code.length > 0, "SWAP_DRIVER missing");

        uint256 amountStable = vm.envOr("RERUN_SWAP_STABLE_RAW", uint256(1_000_000));
        require(amountStable <= uint256(type(int256).max), "swap amount too large");

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        PoolKey memory key = _poolKey(cfg);
        IPoolManager manager = IPoolManager(cfg.poolManager);

        vm.startBroadcast(pk);
        _approveMaxIfERC20(cfg.stableToken, driver, amountStable);
        _approveMaxIfERC20(cfg.volatileToken, driver, cfg.swapBudgetVolatileRaw);

        uint256 executed;
        for (uint256 i = 0; i < 2; i++) {
            (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
            SwapPlan memory plan = _selectPlan(cfg, sqrtPriceX96, amountStable);
            if (!plan.executable) break;
            ISwapDriver(driver).swap{value: plan.value}(key, plan.params, TestSettings(false, false), "");
            executed++;
        }
        vm.stopBroadcast();

        OpsTypes.PoolSnapshot memory snapshot = PoolStateLib.snapshotHook(cfg.hookAddress);
        require(snapshot.feeIdx >= snapshot.floorIdx && snapshot.feeIdx <= snapshot.extremeIdx, "fee out of bounds");

        if (executed == 0) {
            LoggingLib.ok("rerun-safe validation skipped (price at boundary / no viable swap side)");
        } else {
            LoggingLib.ok("rerun-safe validation complete");
        }
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

    function _approveMaxIfERC20(address token, address spender, uint256 amount) private {
        if (token == address(0) || amount == 0) return;
        IERC20Minimal(token).approve(spender, type(uint256).max);
    }
}

interface ISwapDriver {
    function swap(PoolKey memory key, SwapParams memory params, TestSettings memory testSettings, bytes memory hookData)
        external
        payable;
}
