// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "../utils/VolumeDynamicFeeHookV2DeployHelper.sol";

contract VolumeDynamicFeeHookAdminHarness is VolumeDynamicFeeHook {
    constructor(
        IPoolManager _poolManager,
        Currency _poolCurrency0,
        Currency _poolCurrency1,
        int24 _poolTickSpacing,
        Currency _stableCurrency,
        uint8 stableDecimals,
        uint8 _floorIdx,
        uint24[] memory _feeTiers,
        uint32 _periodSeconds,
        uint8 _emaPeriods,
        uint16 _deadbandBps,
        uint32 _lullResetSeconds,
        address ownerAddr,
        address hookFeeRecipientAddr,
        uint16 hookFeePercent,
        uint24 _cashTier,
        uint64 _minCloseVolToCashUsd6,
        uint16 _upRToCashBps,
        uint8 _cashHoldPeriods,
        uint24 _extremeTier,
        uint64 _minCloseVolToExtremeUsd6,
        uint16 _upRToExtremeBps,
        uint8 _upExtremeConfirmPeriods,
        uint8 _extremeHoldPeriods,
        uint16 _downRFromExtremeBps,
        uint8 _downExtremeConfirmPeriods,
        uint16 _downRFromCashBps,
        uint8 _downCashConfirmPeriods,
        uint64 _emergencyFloorCloseVolUsd6,
        uint8 _emergencyConfirmPeriods
    )
        VolumeDynamicFeeHook(
            _poolManager,
            _poolCurrency0,
            _poolCurrency1,
            _poolTickSpacing,
            _stableCurrency,
            stableDecimals,
            _floorIdx,
            _feeTiers,
            _periodSeconds,
            _emaPeriods,
            _deadbandBps,
            _lullResetSeconds,
            ownerAddr,
            hookFeeRecipientAddr,
            hookFeePercent,
            _cashTier,
            _minCloseVolToCashUsd6,
            _upRToCashBps,
            _cashHoldPeriods,
            _extremeTier,
            _minCloseVolToExtremeUsd6,
            _upRToExtremeBps,
            _upExtremeConfirmPeriods,
            _extremeHoldPeriods,
            _downRFromExtremeBps,
            _downExtremeConfirmPeriods,
            _downRFromCashBps,
            _downCashConfirmPeriods,
            _emergencyFloorCloseVolUsd6,
            _emergencyConfirmPeriods
        )
    {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract VolumeDynamicFeeHookAdminTest is Test, VolumeDynamicFeeHookV2DeployHelper {
    MockPoolManager internal manager;
    VolumeDynamicFeeHookAdminHarness internal hook;
    PoolKey internal key;

    address internal constant TOKEN0 = address(0x0000000000000000000000000000000000001111);
    address internal constant TOKEN1 = address(0x0000000000000000000000000000000000002222);

    address internal owner = address(this);
    address internal outsider = address(0xCAFE);
    address internal nextOwner = address(0xBEEF);

    uint32 internal constant PERIOD_SECONDS = 300;
    uint8 internal constant EMA_PERIODS = 8;
    uint16 internal constant DEADBAND_BPS = 500;
    uint32 internal constant LULL_RESET_SECONDS = 3600;

    function setUp() public {
        manager = new MockPoolManager();

        uint24[] memory tiers = _defaultFeeTiersV2();
        hook = _deployHarness(tiers, 0, owner, owner, V2_INITIAL_HOOK_FEE_PERCENT, 6);
        key = _poolKey(address(hook));

        manager.callAfterInitialize(hook, key);
    }

    function _poolKey(address hookAddr) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(hookAddr)
        });
    }

    function _deployHarness(
        uint24[] memory tiers,
        uint8 floorIdx,
        address owner_,
        address hookFeeRecipient_,
        uint16 hookFeePercent_,
        uint8 stableDecimals
    ) internal returns (VolumeDynamicFeeHookAdminHarness h) {
        h = new VolumeDynamicFeeHookAdminHarness(
            IPoolManager(address(manager)),
            Currency.wrap(TOKEN0),
            Currency.wrap(TOKEN1),
            10,
            Currency.wrap(TOKEN0),
            stableDecimals,
            floorIdx,
            tiers,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            owner_,
            hookFeeRecipient_,
            hookFeePercent_,
            _resolveCashTier(tiers),
            V2_MIN_CLOSEVOL_TO_CASH_USD6,
            V2_UP_R_TO_CASH_BPS,
            V2_CASH_HOLD_PERIODS,
            _resolveExtremeTier(tiers),
            V2_MIN_CLOSEVOL_TO_EXTREME_USD6,
            V2_UP_R_TO_EXTREME_BPS,
            V2_UP_EXTREME_CONFIRM_PERIODS,
            V2_EXTREME_HOLD_PERIODS,
            V2_DOWN_R_FROM_EXTREME_BPS,
            V2_DOWN_EXTREME_CONFIRM_PERIODS,
            V2_DOWN_R_FROM_CASH_BPS,
            V2_DOWN_CASH_CONFIRM_PERIODS,
            V2_EMERGENCY_FLOOR_CLOSEVOL_USD6,
            V2_EMERGENCY_CONFIRM_PERIODS
        );
    }

    function _swap(bool zeroForOne, int256 amountSpecified, int128 amount0, int128 amount1) internal {
        SwapParams memory params = SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0});
        BalanceDelta delta = toBalanceDelta(amount0, amount1);
        manager.callAfterSwapWithParams(hook, key, params, delta);
    }

    function _moveToCashRegimeWithHold() internal {
        _swap(true, -1, -1_000_000_000, 900_000_000);
        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        _swap(true, -1, -2_300_000_000, 2_070_000_000);
        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (uint8 feeIdx, uint8 holdRemaining,,,,,,,) = hook.getStateDebug();
        assertEq(feeIdx, hook.cashIdx(), "precondition: active tier must be cash");
        assertGt(holdRemaining, 0, "precondition: cash hold must be active");
    }

    function test_hookFee_is_returned_via_afterSwap_delta_path() public {
        hook.scheduleHookFeePercentChange(10);
        vm.warp(block.timestamp + 48 hours);
        hook.executeHookFeePercentChange();

        // unspecified currency for exact-input zeroForOne is token1 (delta.amount1)
        _swap(true, -1, -1_000_000_000, 900_000_000);

        // 900_000_000 * 400 / 1e6 = 360_000 LP fee; hook fee 10% => 36_000
        assertEq(manager.lastAfterSwapSelector(), IHooks.afterSwap.selector);
        assertEq(manager.lastAfterSwapDelta(), int128(36_000));
        assertEq(manager.takeCount(), 0, "poolManager.take must not be used in HookFee path");
        assertEq(manager.mintCount(), 1, "poolManager.mint must capture hook claim balance");

        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        assertEq(fees0, 0);
        assertEq(fees1, 36_000);
    }

    function test_hookFee_approximation_exactInput_vs_exactOutput_paths() public {
        // Exact-input: unspecified side is token1 in zeroForOne flow.
        _swap(true, -90_000_000, -100_000_000, 90_000_000);

        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        uint256 exactInputAccrual = fees1;
        assertEq(fees0, 0);
        assertGt(exactInputAccrual, 0, "exact-input path should accrue non-zero HookFee");

        // Exact-output: unspecified side is token0 in zeroForOne flow.
        _swap(true, 90_000_000, -100_000_000, 90_000_000);

        (fees0, fees1) = hook.hookFeesAccrued();
        uint256 exactOutputAccrual = fees0;
        assertGt(exactOutputAccrual, 0, "exact-output path should accrue non-zero HookFee");
        assertEq(fees1, exactInputAccrual, "exact-input token1 accrual should not be overwritten");
        assertGt(
            exactOutputAccrual,
            exactInputAccrual,
            "exact-output path can deviate because approximation uses unspecified-side amount"
        );
    }

    function test_hookFee_cap_enforced_at_10_percent() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                VolumeDynamicFeeHook.HookFeePercentLimitExceeded.selector,
                uint16(11),
                uint16(10)
            )
        );
        hook.scheduleHookFeePercentChange(11);
    }

    function test_timelock_schedule_cancel_execute() public {
        hook.scheduleHookFeePercentChange(4);

        (bool exists, uint16 nextValue, uint64 executeAfter) = hook.pendingHookFeePercentChange();
        assertTrue(exists);
        assertEq(nextValue, 4);
        assertEq(executeAfter, uint64(block.timestamp) + 48 hours);

        vm.expectRevert(
            abi.encodeWithSelector(VolumeDynamicFeeHook.HookFeePercentChangeNotReady.selector, executeAfter)
        );
        hook.executeHookFeePercentChange();

        hook.cancelHookFeePercentChange();
        (exists,,) = hook.pendingHookFeePercentChange();
        assertFalse(exists);

        hook.scheduleHookFeePercentChange(5);
        vm.warp(block.timestamp + 48 hours);
        hook.executeHookFeePercentChange();
        assertEq(hook.hookFeePercent(), 5);
    }

    function test_owner_transfer_propose_cancel_accept_flow() public {
        vm.prank(outsider);
        vm.expectRevert(VolumeDynamicFeeHook.NotOwner.selector);
        hook.proposeNewOwner(nextOwner);

        hook.proposeNewOwner(nextOwner);
        assertEq(hook.pendingOwner(), nextOwner);

        vm.prank(outsider);
        vm.expectRevert(VolumeDynamicFeeHook.NotPendingOwner.selector);
        hook.acceptOwner();

        hook.cancelOwnerTransfer();
        assertEq(hook.pendingOwner(), address(0));

        hook.proposeNewOwner(nextOwner);
        vm.prank(nextOwner);
        hook.acceptOwner();

        assertEq(hook.owner(), nextOwner);
        assertEq(hook.pendingOwner(), address(0));
    }

    function test_owner_transfer_rejects_propose_current_owner() public {
        vm.expectRevert(VolumeDynamicFeeHook.InvalidOwner.selector);
        hook.proposeNewOwner(owner);
    }

    function test_setTimingParams_reverts_when_lullReset_equals_period() public {
        hook.pause();

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        hook.setTimingParams(PERIOD_SECONDS, EMA_PERIODS, PERIOD_SECONDS, DEADBAND_BPS);
    }

    function test_cashHoldPeriods_one_results_in_zero_effective_hold_protection() public {
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = VolumeDynamicFeeHook.ControllerParams({
            minCloseVolToCashUsd6: V2_MIN_CLOSEVOL_TO_CASH_USD6,
            upRToCashBps: V2_UP_R_TO_CASH_BPS,
            cashHoldPeriods: 1,
            minCloseVolToExtremeUsd6: V2_MIN_CLOSEVOL_TO_EXTREME_USD6,
            upRToExtremeBps: V2_UP_R_TO_EXTREME_BPS,
            upExtremeConfirmPeriods: V2_UP_EXTREME_CONFIRM_PERIODS,
            extremeHoldPeriods: V2_EXTREME_HOLD_PERIODS,
            downRFromExtremeBps: V2_DOWN_R_FROM_EXTREME_BPS,
            downExtremeConfirmPeriods: V2_DOWN_EXTREME_CONFIRM_PERIODS,
            downRFromCashBps: V2_DOWN_R_FROM_CASH_BPS,
            downCashConfirmPeriods: 1,
            emergencyFloorCloseVolUsd6: V2_EMERGENCY_FLOOR_CLOSEVOL_USD6,
            emergencyConfirmPeriods: V2_EMERGENCY_CONFIRM_PERIODS
        });
        hook.setControllerParams(p);
        hook.unpause();

        _moveToCashRegimeWithHold();
        (uint8 feeIdxAfterJump, uint8 holdAfterJump,,,,,,,) = hook.getStateDebug();
        assertEq(feeIdxAfterJump, hook.cashIdx(), "precondition: active tier must be cash");
        assertEq(holdAfterJump, 1, "configured hold must initialize to one");

        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (uint8 feeIdxAfterNextClose, uint8 holdAfterNextClose,,,,,,,) = hook.getStateDebug();
        assertEq(
            feeIdxAfterNextClose,
            hook.floorIdx(),
            "cashHoldPeriods=1 should not provide an extra fully protected period"
        );
        assertEq(holdAfterNextClose, 0, "hold must be consumed at the next close");
    }

    function test_pause_unpause_freeze_resume_semantics() public {
        _swap(true, -1, -10_000_000, 9_000_000);
        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (
            uint8 feeIdxBefore,
            uint8 holdBefore,
            uint8 upBefore,
            uint8 downBefore,
            uint8 emergencyBefore,
            uint64 periodStartBefore,
            ,
            uint96 emaBefore,

        ) = hook.getStateDebug();

        uint256 updateCountBeforePause = manager.updateCount();
        hook.pause();
        assertTrue(hook.isPaused());

        (
            uint8 feeIdxPaused,
            uint8 holdPaused,
            uint8 upPaused,
            uint8 downPaused,
            uint8 emergencyPaused,
            uint64 periodStartPaused,
            uint64 periodVolPaused,
            uint96 emaPaused,

        ) = hook.getStateDebug();

        assertEq(feeIdxPaused, feeIdxBefore);
        assertEq(holdPaused, holdBefore);
        assertEq(upPaused, upBefore);
        assertEq(downPaused, downBefore);
        assertEq(emergencyPaused, emergencyBefore);
        assertEq(emaPaused, emaBefore);
        assertEq(periodVolPaused, 0);
        assertGe(periodStartPaused, periodStartBefore);

        _swap(true, -1, -6_000_000, 5_700_000);
        assertEq(manager.lastAfterSwapDelta() > 0, true, "HookFee should still be charged while paused");

        (
            uint8 feeIdxAfterSwapWhilePaused,
            ,
            ,
            ,
            ,
            uint64 periodStartAfterSwapWhilePaused,
            uint64 periodVolAfterSwapWhilePaused,
            ,
        ) = hook.getStateDebug();
        assertEq(feeIdxAfterSwapWhilePaused, feeIdxBefore);
        assertEq(periodStartAfterSwapWhilePaused, periodStartPaused);
        assertEq(periodVolAfterSwapWhilePaused, 0);
        assertEq(manager.updateCount(), updateCountBeforePause, "paused swaps must not trigger fee tier updates");

        hook.unpause();
        assertFalse(hook.isPaused());

        _swap(true, -1, -6_000_000, 5_700_000);
        (,,, ,,, uint64 periodVolAfterUnpause,,) = hook.getStateDebug();
        assertEq(periodVolAfterUnpause, 6_000_000);
    }

    function test_emergency_resets_require_paused_and_apply_semantics() public {
        vm.expectRevert(VolumeDynamicFeeHook.RequiresPaused.selector);
        hook.emergencyResetToFloor();

        hook.pause();
        hook.emergencyResetToCash();

        (
            uint8 feeIdx,
            uint8 hold,
            uint8 up,
            uint8 down,
            uint8 emergency,
            uint64 periodStart,
            uint64 periodVol,
            uint96 ema,
            bool paused
        ) = hook.getStateDebug();

        assertEq(feeIdx, hook.cashIdx());
        assertEq(hold, 0);
        assertEq(up, 0);
        assertEq(down, 0);
        assertEq(emergency, 0);
        assertEq(periodVol, 0);
        assertEq(ema, 0);
        assertTrue(paused);
        assertEq(periodStart, uint64(block.timestamp));

        hook.emergencyResetToFloor();
        (feeIdx,,,,,, periodVol, ema, paused) = hook.getStateDebug();
        assertEq(feeIdx, hook.floorIdx());
        assertEq(periodVol, 0);
        assertEq(ema, 0);
        assertTrue(paused);
    }

    function test_setFeeTiersAndRoles_found_old_tier_at_non_role_index_resets_to_floor() public {
        _moveToCashRegimeWithHold();
        hook.pause();

        uint24[] memory tiers = new uint24[](4);
        tiers[0] = 400;
        tiers[1] = 2500;
        tiers[2] = 9000;
        tiers[3] = 12000;

        uint256 updatesBefore = manager.updateCount();
        hook.setFeeTiersAndRoles(tiers, 0, 2, 3);

        (uint8 feeIdx, uint8 hold, uint8 up, uint8 down, uint8 emergency,,,,) = hook.getStateDebug();
        assertEq(feeIdx, hook.floorIdx());
        assertEq(hold, 0);
        assertEq(up, 0);
        assertEq(down, 0);
        assertEq(emergency, 0);
        assertEq(manager.updateCount(), updatesBefore + 1);
        assertEq(manager.lastFee(), hook.feeTiers(hook.floorIdx()));
    }

    function test_setFeeTiersAndRoles_floor_role_never_keeps_hold_or_streaks() public {
        _moveToCashRegimeWithHold();
        hook.pause();

        uint24[] memory tiers = new uint24[](3);
        tiers[0] = 2500;
        tiers[1] = 9000;
        tiers[2] = 12000;

        hook.setFeeTiersAndRoles(tiers, 0, 1, 2);

        (uint8 feeIdx, uint8 hold, uint8 up, uint8 down, uint8 emergency,,,,) = hook.getStateDebug();
        assertEq(feeIdx, hook.floorIdx());
        assertEq(hold, 0);
        assertEq(up, 0);
        assertEq(down, 0);
        assertEq(emergency, 0);
    }

    function test_lullReset_activates_pendingMinCountedSwap_before_first_new_period_swap() public {
        assertEq(hook.minCountedSwapUsd6(), 4_000_000);
        hook.scheduleMinCountedSwapUsd6Change(10_000_000);

        vm.warp(block.timestamp + LULL_RESET_SECONDS);
        _swap(true, -1, -7_000_000, 6_650_000);

        assertEq(hook.minCountedSwapUsd6(), 10_000_000);
        (bool pendingExists,) = hook.pendingMinCountedSwapUsd6Change();
        assertFalse(pendingExists);

        (uint64 periodVol,,,) = hook.unpackedState();
        assertEq(periodVol, 0, "first swap after lull reset must use the new threshold");
    }

    function test_feeTierCount_getter_tracks_tier_length_and_bounds() public {
        assertEq(hook.feeTierCount(), 3);
        assertEq(hook.feeTiers(0), 400);
        assertEq(hook.feeTiers(1), 2500);
        assertEq(hook.feeTiers(2), 9000);

        hook.pause();
        uint24[] memory tiers = new uint24[](4);
        tiers[0] = 400;
        tiers[1] = 1200;
        tiers[2] = 2500;
        tiers[3] = 9000;
        hook.setFeeTiersAndRoles(tiers, 0, 2, 3);

        assertEq(hook.feeTierCount(), 4);
        assertEq(hook.feeTiers(3), 9000);

        uint16 outOfBounds = hook.feeTierCount();
        vm.expectRevert(VolumeDynamicFeeHook.InvalidFeeIndex.selector);
        hook.feeTiers(outOfBounds);
    }

    function test_minCountedSwapUsd6_filters_only_telemetry_and_applies_next_period() public {
        assertEq(hook.minCountedSwapUsd6(), 4_000_000);

        _swap(true, -1, -1_000_000, 900_000);
        (uint64 periodVol,,, ) = hook.unpackedState();
        assertEq(periodVol, 0, "dust swap must not be counted");
        assertEq(manager.lastAfterSwapDelta() > 0, true, "dust swap still pays HookFee");

        _swap(true, -1, -6_000_000, 5_700_000);
        (periodVol,,,) = hook.unpackedState();
        assertEq(periodVol, 6_000_000);

        hook.scheduleMinCountedSwapUsd6Change(10_000_000);
        _swap(true, -1, -6_000_000, 5_700_000);
        (periodVol,,,) = hook.unpackedState();
        assertEq(periodVol, 12_000_000, "new threshold must not apply mid-period");

        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);
        assertEq(hook.minCountedSwapUsd6(), 10_000_000);

        _swap(true, -1, -6_000_000, 5_700_000);
        (periodVol,,,) = hook.unpackedState();
        assertEq(periodVol, 0, "new threshold must apply after next period boundary");
    }

    function test_scaledEma_updates_with_precision() public {
        _swap(true, -1, -10_000_000, 9_500_000);
        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (, uint96 ema1,,) = hook.unpackedState();
        uint96 expected1 = uint96(10_000_000 * 1_000_000);
        assertEq(ema1, expected1);

        _swap(true, -1, -20_000_000, 19_000_000);
        vm.warp(block.timestamp + PERIOD_SECONDS);
        _swap(true, -1, 0, 0);

        (, uint96 ema2,,) = hook.unpackedState();
        uint96 expected2 = uint96((uint256(expected1) * (EMA_PERIODS - 1) + uint256(20_000_000) * 1_000_000) / EMA_PERIODS);
        assertEq(ema2, expected2);
    }

    function test_stable_decimals_only_6_or_18() public {
        uint24[] memory tiers = _defaultFeeTiersV2();

        VolumeDynamicFeeHookAdminHarness h6 = _deployHarness(tiers, 0, owner, owner, 1, 6);
        assertEq(h6.floorIdx(), 0);

        VolumeDynamicFeeHookAdminHarness h18 = _deployHarness(tiers, 0, owner, owner, 1, 18);
        assertEq(h18.floorIdx(), 0);

        vm.expectRevert(abi.encodeWithSelector(VolumeDynamicFeeHook.InvalidStableDecimals.selector, uint8(8)));
        _deployHarness(tiers, 0, owner, owner, 1, 8);
    }

    function test_receive_reverts() public {
        vm.deal(outsider, 1 ether);

        vm.prank(outsider);
        vm.expectRevert(VolumeDynamicFeeHook.EthReceiveRejected.selector);
        (bool ok,) = address(hook).call{value: 1}("");
        ok;
    }

    function test_claimHookFees_and_pause_admin_unpause_integration() public {
        _swap(true, -1, -10_000_000, 9_500_000);
        (uint256 b0, uint256 b1) = hook.hookFeesAccrued();
        assertEq(b0 + b1 > 0, true);

        hook.claimAllHookFees();
        assertEq(manager.unlockCount(), 1, "claim must go through poolManager.unlock");
        assertEq(manager.burnCount() > 0, true, "claim must burn poolManager claim balances");
        assertEq(manager.takeCount() > 0, true, "claim must take from poolManager accounting");
        (b0, b1) = hook.hookFeesAccrued();
        assertEq(b0, 0);
        assertEq(b1, 0);

        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = VolumeDynamicFeeHook.ControllerParams({
            minCloseVolToCashUsd6: V2_MIN_CLOSEVOL_TO_CASH_USD6 + 1,
            upRToCashBps: V2_UP_R_TO_CASH_BPS,
            cashHoldPeriods: V2_CASH_HOLD_PERIODS,
            minCloseVolToExtremeUsd6: V2_MIN_CLOSEVOL_TO_EXTREME_USD6,
            upRToExtremeBps: V2_UP_R_TO_EXTREME_BPS,
            upExtremeConfirmPeriods: V2_UP_EXTREME_CONFIRM_PERIODS,
            extremeHoldPeriods: V2_EXTREME_HOLD_PERIODS,
            downRFromExtremeBps: V2_DOWN_R_FROM_EXTREME_BPS,
            downExtremeConfirmPeriods: V2_DOWN_EXTREME_CONFIRM_PERIODS,
            downRFromCashBps: V2_DOWN_R_FROM_CASH_BPS,
            downCashConfirmPeriods: V2_DOWN_CASH_CONFIRM_PERIODS,
            emergencyFloorCloseVolUsd6: V2_EMERGENCY_FLOOR_CLOSEVOL_USD6,
            emergencyConfirmPeriods: V2_EMERGENCY_CONFIRM_PERIODS
        });
        hook.setControllerParams(p);
        hook.setTimingParams(PERIOD_SECONDS, EMA_PERIODS, LULL_RESET_SECONDS, DEADBAND_BPS);

        hook.unpause();
        assertFalse(hook.isPaused());

        _swap(true, -1, -6_000_000, 5_700_000);
        (uint64 pv,,,) = hook.unpackedState();
        assertEq(pv, 6_000_000);
    }
}
