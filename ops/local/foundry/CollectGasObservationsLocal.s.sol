// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
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
    uint32 internal constant MAX_LULL_PERIODS = 24;

    function run() external {
        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        require(cfg.hookAddress != address(0) && cfg.hookAddress.code.length > 0, "HOOK_ADDRESS missing");

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        uint256 swapAmountRaw = vm.envOr("GAS_SWAP_STABLE_RAW", uint256(6_000_000));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(cfg.token0),
            currency1: Currency.wrap(cfg.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.hookAddress)
        });

        VolumeDynamicFeeHook hook = VolumeDynamicFeeHook(payable(cfg.hookAddress));
        MockPoolManager manager = MockPoolManager(payable(cfg.poolManager));
        uint32 periodSeconds = hook.periodSeconds();
        uint8 emaPeriods = hook.emaPeriods();
        uint16 deadbandBps = hook.deadbandBps();
        uint32 lullResetSeconds = hook.lullResetSeconds();
        uint256 worstCaseLullResetRaw = uint256(periodSeconds) * uint256(MAX_LULL_PERIODS);
        require(worstCaseLullResetRaw <= type(uint32).max, "periodSeconds too large");
        uint32 worstCaseLullResetSeconds = uint32(worstCaseLullResetRaw);
        uint256 worstCaseCatchUpWarpSeconds = worstCaseLullResetRaw - 1;

        vm.startBroadcast(pk);
        if (hook.isPaused()) {
            hook.unpause();
        }
        if (lullResetSeconds != worstCaseLullResetSeconds) {
            hook.pause();
            hook.setTimingParams(periodSeconds, emaPeriods, worstCaseLullResetSeconds, deadbandBps);
            hook.unpause();
            lullResetSeconds = worstCaseLullResetSeconds;
        }

        // Normal swap without rollover.
        manager.callAfterSwap(hook, key, _stableDelta(cfg, swapAmountRaw));

        // Swap that closes period.
        vm.warp(block.timestamp + uint256(periodSeconds));
        manager.callAfterSwap(hook, key, toBalanceDelta(0, 0));

        // Worst-case catch-up: close MAX_LULL_PERIODS - 1 periods just below lull reset.
        vm.warp(block.timestamp + worstCaseCatchUpWarpSeconds);
        manager.callAfterSwap(hook, key, toBalanceDelta(0, 0));

        // First swap after lull-reset threshold.
        vm.warp(block.timestamp + uint256(lullResetSeconds) + 1);
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
