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
import {PoolStateLib} from "../../shared/lib/PoolStateLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract RunRerunSafeValidationLocal is Script {
    function run() external {
        LoggingLib.phase("local.rerun-safe");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        require(cfg.hookAddress != address(0) && cfg.hookAddress.code.length > 0, "HOOK_ADDRESS missing");

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(cfg.token0),
            currency1: Currency.wrap(cfg.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.hookAddress)
        });

        uint256 periodSeconds = vm.envOr("PERIOD_SECONDS", uint256(60));
        uint256 swapAmount = vm.envOr("RERUN_SWAP_STABLE_RAW", uint256(1_000_000));

        vm.startBroadcast(pk);
        _cycle(cfg, key, swapAmount, periodSeconds);
        _cycle(cfg, key, swapAmount, periodSeconds);
        vm.stopBroadcast();

        OpsTypes.PoolSnapshot memory snapshot = PoolStateLib.snapshotHook(cfg.hookAddress);
        require(snapshot.initialized, "hook uninitialized");
        require(snapshot.feeIdx >= snapshot.floorIdx && snapshot.feeIdx <= snapshot.extremeIdx, "fee out of bounds");

        LoggingLib.ok("rerun-safe validation complete (2 cycles)");
    }

    function _cycle(OpsTypes.CoreConfig memory cfg, PoolKey memory key, uint256 swapAmount, uint256 periodSeconds)
        private
    {
        MockPoolManager(cfg.poolManager).callAfterSwap(
            VolumeDynamicFeeHook(payable(cfg.hookAddress)), key, _stableDelta(cfg, swapAmount)
        );
        vm.warp(block.timestamp + periodSeconds + 1);
        MockPoolManager(cfg.poolManager).callAfterSwap(
            VolumeDynamicFeeHook(payable(cfg.hookAddress)), key, toBalanceDelta(0, 0)
        );
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
