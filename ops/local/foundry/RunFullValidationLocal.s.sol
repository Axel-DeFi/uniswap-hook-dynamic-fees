// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "../../tests/mocks/MockPoolManager.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {BudgetLib} from "../../shared/lib/BudgetLib.sol";
import {RangeSafetyLib} from "../../shared/lib/RangeSafetyLib.sol";
import {PoolStateLib} from "../../shared/lib/PoolStateLib.sol";
import {JsonReportLib} from "../../shared/lib/JsonReportLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract RunFullValidationLocal is Script {
    function run() external {
        LoggingLib.phase("local.full");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        require(budget.ok, budget.reason);

        OpsTypes.RangeCheck memory range = RangeSafetyLib.validateRange(cfg);
        require(range.ok, range.reason);

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(cfg.token0),
            currency1: Currency.wrap(cfg.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.hookAddress)
        });

        uint256 swapAmount = vm.envOr("FULL_SWAP_STABLE_RAW", range.maxSwapStableRaw);
        if (swapAmount == 0) {
            swapAmount = 2_000_000;
        }
        uint256 iterations = vm.envOr("FULL_SWAP_ITERATIONS", uint256(4));
        uint256 periodSeconds = vm.envOr("PERIOD_SECONDS", uint256(60));

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < iterations; i++) {
            MockPoolManager(payable(cfg.poolManager)).callAfterSwap(
                VolumeDynamicFeeHook(payable(cfg.hookAddress)), key, _stableDelta(cfg, swapAmount)
            );
            vm.warp(block.timestamp + periodSeconds + 1);
            MockPoolManager(payable(cfg.poolManager)).callAfterSwap(
                VolumeDynamicFeeHook(payable(cfg.hookAddress)), key, toBalanceDelta(0, 0)
            );
        }
        vm.stopBroadcast();

        OpsTypes.PoolSnapshot memory snapshot = PoolStateLib.snapshotHook(cfg.hookAddress);
        require(snapshot.initialized, "not initialized");
        require(snapshot.feeIdx >= snapshot.floorIdx && snapshot.feeIdx <= snapshot.extremeIdx, "fee out of bounds");

        string memory reportPath = vm.envOr(
            "OPS_LOCAL_FULL_REPORT", string.concat(vm.projectRoot(), "/ops/local/out/reports/full.local.json")
        );
        JsonReportLib.writeStateReport(reportPath, snapshot);

        LoggingLib.ok("full validation complete");
    }

    function _stableDelta(OpsTypes.CoreConfig memory cfg, uint256 amountStableRaw)
        private
        pure
        returns (BalanceDelta)
    {
        uint256 maxInt128 = uint256(type(uint128).max >> 1);
        require(amountStableRaw <= maxInt128, "swap amount too large for int128");
        int128 amt = int128(uint128(amountStableRaw));
        if (cfg.stableToken == cfg.token0) {
            return toBalanceDelta(-amt, 0);
        }
        return toBalanceDelta(0, -amt);
    }
}
