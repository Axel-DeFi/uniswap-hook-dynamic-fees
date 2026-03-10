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
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract CollectGasObservationsLocal is Script {
    function run() external {
        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        require(cfg.hookAddress != address(0) && cfg.hookAddress.code.length > 0, "HOOK_ADDRESS missing");

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        uint256 swapAmountRaw = vm.envOr("GAS_SWAP_STABLE_RAW", uint256(6_000_000));
        uint256 periodSeconds = vm.envOr("PERIOD_SECONDS", uint256(60));
        uint256 lullResetSeconds = vm.envOr("LULL_RESET_SECONDS", uint256(600));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(cfg.token0),
            currency1: Currency.wrap(cfg.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.hookAddress)
        });

        VolumeDynamicFeeHook hook = VolumeDynamicFeeHook(payable(cfg.hookAddress));
        MockPoolManager manager = MockPoolManager(payable(cfg.poolManager));

        vm.startBroadcast(pk);
        if (hook.isPaused()) {
            hook.unpause();
        }

        // Normal swap without rollover.
        manager.callAfterSwap(hook, key, _stableDelta(cfg, swapAmountRaw));

        // Swap that closes period.
        vm.warp(block.timestamp + periodSeconds + 1);
        manager.callAfterSwap(hook, key, toBalanceDelta(0, 0));

        // First swap after lull-reset threshold.
        vm.warp(block.timestamp + lullResetSeconds + 1);
        manager.callAfterSwap(hook, key, _stableDelta(cfg, swapAmountRaw));

        // Pause and resume operations.
        hook.pause();
        hook.unpause();

        // Accrue HookFee before claim.
        manager.callAfterSwap(hook, key, _stableDelta(cfg, swapAmountRaw));

        // Paused emergency reset flow.
        hook.pause();
        hook.emergencyResetToFloor();
        hook.unpause();

        // Claim all currently accrued HookFees.
        hook.claimAllHookFees();
        vm.stopBroadcast();
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
