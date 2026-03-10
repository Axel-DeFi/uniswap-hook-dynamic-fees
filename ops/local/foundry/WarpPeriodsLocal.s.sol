// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "../../tests/mocks/MockPoolManager.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract WarpPeriodsLocal is Script {
    function run() external {
        LoggingLib.phase("local.warp-periods");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        require(cfg.hookAddress != address(0), "HOOK_ADDRESS missing");

        uint256 periods = vm.envOr("PERIODS_TO_WARP", uint256(1));
        uint256 periodSeconds = vm.envOr("PERIOD_SECONDS", uint256(60));
        vm.warp(block.timestamp + periods * periodSeconds + 1);

        bool closeNow = vm.envOr("WARP_CLOSE_PERIOD", true);
        if (closeNow) {
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(cfg.token0),
                currency1: Currency.wrap(cfg.token1),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: cfg.tickSpacing,
                hooks: IHooks(cfg.hookAddress)
            });

            MockPoolManager(cfg.poolManager).callAfterSwap(
                VolumeDynamicFeeHook(payable(cfg.hookAddress)), key, toBalanceDelta(0, 0)
            );
        }

        LoggingLib.ok("warp complete");
    }
}
