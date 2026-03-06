// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "../utils/VolumeDynamicFeeHookV2DeployHelper.sol";

/// @notice Harness that bypasses permission-bit address validation to isolate constructor config checks.
contract VolumeDynamicFeeHookHarness is VolumeDynamicFeeHook {
    constructor(
        IPoolManager _poolManager,
        Currency _poolCurrency0,
        Currency _poolCurrency1,
        int24 _poolTickSpacing,
        Currency _stableCurrency,
        uint8 stableDecimals,
        uint8 _floorIdx,
        uint8 _capIdx,
        uint24[] memory _feeTiers,
        uint32 _periodSeconds,
        uint8 _emaPeriods,
        uint16 _deadbandBps,
        uint32 _lullResetSeconds,
        address _creator,
        address _creatorFeeRecipient,
        uint16 _creatorFeeLimitPercent,
        uint16 _creatorFeeBps,
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
            _capIdx,
            _feeTiers,
            _periodSeconds,
            _emaPeriods,
            _deadbandBps,
            _lullResetSeconds,
            _creator,
            _creatorFeeRecipient,
            _creatorFeeLimitPercent,
            _creatorFeeBps,
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

    function exposedComputeNextFeeIdx(uint8 feeIdx, uint8 lastDir, uint64 closeVol, uint96 emaVol)
        external
        view
        returns (uint8 newFeeIdx, uint8 newLastDir, bool changed, uint8 reasonCode)
    {
        return _computeNextFeeIdx(feeIdx, lastDir, closeVol, emaVol);
    }
}

contract VolumeDynamicFeeHookConfigAndEdgesTest is Test, VolumeDynamicFeeHookV2DeployHelper {
    event FeeUpdated(uint24 newFee, uint8 newFeeIdx, uint64 closedVolumeUsd6, uint96 emaVolumeUsd6);
    event PeriodClosed(
        uint24 fromFee,
        uint8 fromFeeIdx,
        uint24 toFee,
        uint8 toFeeIdx,
        uint64 closedVolumeUsd6,
        uint96 emaVolumeUsd6,
        uint64 lpFeesUsd6,
        uint8 reasonCode
    );
    event RescueTransfer(address indexed currency, uint256 amount, address indexed recipient);

    struct DeployCfg {
        address token0;
        address token1;
        int24 tickSpacing;
        address stable;
        uint8 stableDecimals;
        uint8 floorIdx;
        uint8 capIdx;
        uint24[] feeTiers;
        uint32 periodSeconds;
        uint8 emaPeriods;
        uint16 deadbandBps;
        uint32 lullResetSeconds;
        address creator;
        address creatorFeeRecipient;
        uint16 creatorFeeLimitPercent;
        uint16 creatorFeeBps;
    }

    MockPoolManager internal manager;
    VolumeDynamicFeeHookHarness internal hook;
    PoolKey internal key;

    uint32 internal constant PERIOD_SECONDS = 3600;
    uint32 internal constant LULL_RESET_SECONDS = 86400;
    uint8 internal constant FLOOR_IDX = 0;
    uint8 internal constant CAP_IDX = 5;

    function setUp() public {
        manager = new MockPoolManager();

        DeployCfg memory cfg = _defaultCfg();
        hook = _deploy(cfg);
        key = _keyFor(cfg, address(hook));
    }

    function _defaultCfg() internal view returns (DeployCfg memory cfg) {
        cfg = DeployCfg({
            token0: address(0x0000000000000000000000000000000000001111),
            token1: address(0x0000000000000000000000000000000000002222),
            tickSpacing: 10,
            stable: address(0x0000000000000000000000000000000000001111),
            stableDecimals: 6,
            floorIdx: FLOOR_IDX,
            capIdx: CAP_IDX,
            feeTiers: _defaultFeeTiers(),
            periodSeconds: PERIOD_SECONDS,
            emaPeriods: 8,
            deadbandBps: 500,
            lullResetSeconds: LULL_RESET_SECONDS,
            creator: address(this),
            creatorFeeRecipient: address(this),
            creatorFeeLimitPercent: V2_CREATOR_FEE_LIMIT_PERCENT,
            creatorFeeBps: 1000
        });
    }

    function _defaultFeeTiers() internal pure returns (uint24[] memory tiers) {
        tiers = new uint24[](6);
        tiers[0] = 90;
        tiers[1] = 400;
        tiers[2] = 900;
        tiers[3] = 2500;
        tiers[4] = 4500;
        tiers[5] = 9000;
    }

    function _deploy(DeployCfg memory cfg) internal returns (VolumeDynamicFeeHookHarness h) {
        h = new VolumeDynamicFeeHookHarness(
            IPoolManager(address(manager)),
            Currency.wrap(cfg.token0),
            Currency.wrap(cfg.token1),
            cfg.tickSpacing,
            Currency.wrap(cfg.stable),
            cfg.stableDecimals,
            cfg.floorIdx,
            cfg.capIdx,
            cfg.feeTiers,
            cfg.periodSeconds,
            cfg.emaPeriods,
            cfg.deadbandBps,
            cfg.lullResetSeconds,
            cfg.creator,
            cfg.creatorFeeRecipient,
            cfg.creatorFeeLimitPercent,
            cfg.creatorFeeBps,
            _resolveCashTier(cfg.feeTiers),
            V2_MIN_CLOSEVOL_TO_CASH_USD6,
            V2_UP_R_TO_CASH_BPS,
            V2_CASH_HOLD_PERIODS,
            _resolveExtremeTier(cfg.feeTiers),
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

    function _keyFor(DeployCfg memory cfg, address hookAddr) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(cfg.token0),
            currency1: Currency.wrap(cfg.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(hookAddr)
        });
    }

    function _deltaA0(int128 amount0) internal pure returns (BalanceDelta) {
        return toBalanceDelta(amount0, 0);
    }

    function _deltaA1(int128 amount1) internal pure returns (BalanceDelta) {
        return toBalanceDelta(0, amount1);
    }

    function _deltaZero() internal pure returns (BalanceDelta) {
        return toBalanceDelta(0, 0);
    }

    function _seedEma() internal {
        manager.callAfterInitialize(hook, key);
        manager.callAfterSwap(hook, key, _deltaA0(-1_000_000_000));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());
    }

    function test_constructor_reverts_on_nonCanonicalCurrencyOrder() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.token0 = address(0x0000000000000000000000000000000000002222);
        cfg.token1 = address(0x0000000000000000000000000000000000001111);
        cfg.stable = cfg.token1;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_zeroPoolManager() public {
        DeployCfg memory cfg = _defaultCfg();

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        new VolumeDynamicFeeHookHarness(
            IPoolManager(address(0)),
            Currency.wrap(cfg.token0),
            Currency.wrap(cfg.token1),
            cfg.tickSpacing,
            Currency.wrap(cfg.stable),
            cfg.stableDecimals,
            cfg.floorIdx,
            cfg.capIdx,
            cfg.feeTiers,
            cfg.periodSeconds,
            cfg.emaPeriods,
            cfg.deadbandBps,
            cfg.lullResetSeconds,
            cfg.creator,
            cfg.creatorFeeRecipient,
            cfg.creatorFeeLimitPercent,
            cfg.creatorFeeBps,
            _resolveCashTier(cfg.feeTiers),
            V2_MIN_CLOSEVOL_TO_CASH_USD6,
            V2_UP_R_TO_CASH_BPS,
            V2_CASH_HOLD_PERIODS,
            _resolveExtremeTier(cfg.feeTiers),
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

    function test_constructor_reverts_when_stable_not_in_pool() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.stable = address(0x0000000000000000000000000000000000003333);

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_zeroTickSpacing() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.tickSpacing = 0;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_negativeTickSpacing() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.tickSpacing = -10;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_zeroPeriodSeconds() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.periodSeconds = 0;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_emaPeriods_lt_2() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.emaPeriods = 1;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_emaPeriods_gt_max() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.emaPeriods = 65;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_deadband_gt_5000() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.deadbandBps = 5001;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_lull_lt_period() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.lullResetSeconds = cfg.periodSeconds - 1;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_lull_gt_max() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.lullResetSeconds = cfg.periodSeconds * 24 + 1;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_missing_creatorFeeRecipient_when_fee_enabled() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.creatorFeeRecipient = address(0);

        vm.expectRevert(VolumeDynamicFeeHook.CreatorFeeRecipientRequired.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_creatorFeeBps_gt_creatorFeeLimit() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.creatorFeeBps = cfg.creatorFeeLimitPercent * 100 + 1;
        uint16 maxAllowedBps = cfg.creatorFeeLimitPercent * 100;

        vm.expectRevert(
            abi.encodeWithSelector(
                VolumeDynamicFeeHook.CreatorFeeLimitExceeded.selector, cfg.creatorFeeBps, maxAllowedBps
            )
        );
        _deploy(cfg);
    }

    function test_constructor_reverts_on_creatorFeeLimitPercent_gt_100() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.creatorFeeLimitPercent = 101;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_fee_idx_out_of_range() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.capIdx = 6;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidFeeIndex.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_floor_gt_cap_relation() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.floorIdx = 5;
        cfg.capIdx = 4;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidTierBounds.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_stableDecimals_gt_18() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.stableDecimals = 19;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_accepts_dynamic_fee_tier_count() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.feeTiers = new uint24[](3);
        cfg.feeTiers[0] = 90;
        cfg.feeTiers[1] = 400;
        cfg.feeTiers[2] = 900;
        cfg.floorIdx = 0;
        cfg.capIdx = 2;

        VolumeDynamicFeeHookHarness h = _deploy(cfg);
        assertEq(h.feeTierCount(), 3);
        assertEq(h.feeTiers(0), 90);
        assertEq(h.feeTiers(1), 400);
        assertEq(h.feeTiers(2), 900);
        vm.expectRevert(VolumeDynamicFeeHook.InvalidFeeIndex.selector);
        h.feeTiers(3);
    }

    function test_constructor_reverts_on_non_increasing_fee_tiers() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.feeTiers = new uint24[](3);
        cfg.feeTiers[0] = 90;
        cfg.feeTiers[1] = 90;
        cfg.feeTiers[2] = 900;
        cfg.floorIdx = 0;
        cfg.capIdx = 2;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidTierBounds.selector);
        _deploy(cfg);
    }

    function test_feeTiers_values_and_out_of_bounds() public view {
        assertEq(hook.feeTiers(0), 90);
        assertEq(hook.feeTiers(1), 400);
        assertEq(hook.feeTiers(2), 900);
        assertEq(hook.feeTiers(3), 2500);
        assertEq(hook.feeTiers(4), 4500);
        assertEq(hook.feeTiers(5), 9000);
    }

    function test_feeTiers_reverts_on_index_ge_count() public {
        vm.expectRevert(VolumeDynamicFeeHook.InvalidFeeIndex.selector);
        hook.feeTiers(6);
    }

    function test_permissions_include_beforeSwap_and_afterSwap() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();

        assertFalse(p.beforeInitialize);
        assertTrue(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_currentFeeBips_reverts_before_initialize() public {
        vm.expectRevert(VolumeDynamicFeeHook.NotInitialized.selector);
        hook.currentFeeBips();
    }

    function test_periodStart_supports_timestamps_beyond_uint32_horizon() public {
        uint256 startTs = uint256(type(uint32).max) + 12_345;
        vm.warp(startTs);

        manager.callAfterInitialize(hook, key);
        (,, uint64 periodStart,,) = hook.unpackedState();
        assertEq(periodStart, uint64(startTs));

        uint256 nextTs = startTs + PERIOD_SECONDS;
        vm.warp(nextTs);
        manager.callAfterSwap(hook, key, _deltaZero());

        (,, uint64 periodStartAfter,,) = hook.unpackedState();
        assertEq(periodStartAfter, uint64(nextTs));
    }

    function test_invalidPoolKey_reverts_on_wrong_currency0() public {
        PoolKey memory bad = key;
        bad.currency0 = Currency.wrap(address(0x0000000000000000000000000000000000003333));

        vm.expectRevert(VolumeDynamicFeeHook.InvalidPoolKey.selector);
        manager.callAfterInitialize(hook, bad);
    }

    function test_invalidPoolKey_reverts_on_wrong_currency1() public {
        PoolKey memory bad = key;
        bad.currency1 = Currency.wrap(address(0x0000000000000000000000000000000000003333));

        vm.expectRevert(VolumeDynamicFeeHook.InvalidPoolKey.selector);
        manager.callAfterInitialize(hook, bad);
    }

    function test_invalidPoolKey_reverts_on_wrong_hook_address() public {
        PoolKey memory bad = key;
        bad.hooks = IHooks(address(0x0000000000000000000000000000000000003333));

        vm.expectRevert(VolumeDynamicFeeHook.InvalidPoolKey.selector);
        manager.callAfterInitialize(hook, bad);
    }

    function test_pause_is_idempotent() public {
        manager.callAfterInitialize(hook, key);
        assertEq(manager.updateCount(), 1);

        hook.pause();
        uint256 updatesAfterFirstPause = manager.updateCount();
        assertEq(updatesAfterFirstPause, 2);
        assertTrue(hook.isPaused());

        hook.pause();
        assertEq(manager.updateCount(), updatesAfterFirstPause);
    }

    function test_unpause_is_idempotent() public {
        manager.callAfterInitialize(hook, key);
        hook.pause();
        assertEq(manager.updateCount(), 2);

        hook.unpause();
        uint256 updatesAfterFirstUnpause = manager.updateCount();
        assertEq(updatesAfterFirstUnpause, 3);
        assertFalse(hook.isPaused());

        hook.unpause();
        assertEq(manager.updateCount(), updatesAfterFirstUnpause);
    }

    function test_afterSwap_while_paused_does_not_change_volume_or_fee() public {
        manager.callAfterInitialize(hook, key);
        hook.pause();
        uint256 updatesAfterPause = manager.updateCount();

        manager.callAfterSwap(hook, key, _deltaA0(-1_000_000_000));
        (uint64 pv, uint96 ema,, uint8 idx,) = hook.unpackedState();

        assertEq(pv, 0);
        assertEq(ema, 0);
        assertEq(idx, FLOOR_IDX);
        assertEq(manager.updateCount(), updatesAfterPause);
    }

    function test_rescueToken_reverts_for_non_creator() public {
        vm.prank(address(0x000000000000000000000000000000000000dEaD));
        vm.expectRevert(VolumeDynamicFeeHook.NotCreator.selector);
        hook.rescueToken(Currency.wrap(address(0x0000000000000000000000000000000000003333)), 1);
    }

    function test_rescueToken_reverts_for_pool_currency0() public {
        vm.expectRevert(VolumeDynamicFeeHook.InvalidRescueCurrency.selector);
        hook.rescueToken(key.currency0, 1);
    }

    function test_rescueToken_reverts_for_pool_currency1() public {
        vm.expectRevert(VolumeDynamicFeeHook.InvalidRescueCurrency.selector);
        hook.rescueToken(key.currency1, 1);
    }

    function test_rescueToken_emits_event_for_non_pool_currency() public {
        Currency token = Currency.wrap(address(0x0000000000000000000000000000000000003333));

        vm.expectEmit(true, false, true, true, address(hook));
        emit RescueTransfer(Currency.unwrap(token), 123, hook.creator());

        hook.rescueToken(token, 123);
    }

    function test_periodVolume_saturates_at_uint64_max() public {
        manager.callAfterInitialize(hook, key);
        manager.callAfterSwap(hook, key, _deltaA0(type(int128).min));

        (uint64 pv,,,,) = hook.unpackedState();
        assertEq(pv, type(uint64).max);
    }

    function test_stableDecimals_lt_6_scales_up_to_usd6() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.stableDecimals = 3;

        VolumeDynamicFeeHookHarness h = _deploy(cfg);
        PoolKey memory k = _keyFor(cfg, address(h));

        manager.callAfterInitialize(h, k);
        manager.callAfterSwap(h, k, _deltaA0(-1_000)); // 1.000 stable in 3 decimals

        (uint64 pv,,,,) = h.unpackedState();
        assertEq(pv, 1_000_000); // 1e6 USD6
    }

    function test_stableDecimals_gt_6_scales_down_to_usd6() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.stableDecimals = 18;

        VolumeDynamicFeeHookHarness h = _deploy(cfg);
        PoolKey memory k = _keyFor(cfg, address(h));

        manager.callAfterInitialize(h, k);
        manager.callAfterSwap(h, k, _deltaA0(-1e18)); // 1.0 stable in 18 decimals

        (uint64 pv,,,,) = h.unpackedState();
        assertEq(pv, 1_000_000); // 1e6 USD6
    }

    function test_when_stable_is_currency1_volume_uses_amount1() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.stable = cfg.token1;

        VolumeDynamicFeeHookHarness h = _deploy(cfg);
        PoolKey memory k = _keyFor(cfg, address(h));

        manager.callAfterInitialize(h, k);
        manager.callAfterSwap(h, k, _deltaA0(-1_000_000)); // amount0 should be ignored
        (uint64 pvA0,,,,) = h.unpackedState();
        assertEq(pvA0, 0);

        manager.callAfterSwap(h, k, _deltaA1(-1_000_000)); // amount1 is stable side
        (uint64 pvA1,,,,) = h.unpackedState();
        assertEq(pvA1, 1_000_000);
    }

    function test_fee_reaches_cap_and_does_not_exceed() public {
        _seedEma();

        for (uint256 i = 0; i < 10; i++) {
            manager.callAfterSwap(hook, key, _deltaA0(-50_000_000_000));
            vm.warp(block.timestamp + PERIOD_SECONDS);
            manager.callAfterSwap(hook, key, _deltaZero());
        }

        (,,, uint8 idxBefore,) = hook.unpackedState();
        assertEq(idxBefore, hook.cashIdx());

        uint256 updatesBefore = manager.updateCount();
        manager.callAfterSwap(hook, key, _deltaA0(-50_000_000_000));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        (,,, uint8 idxAfter,) = hook.unpackedState();
        assertEq(idxAfter, idxBefore);
        assertTrue(idxAfter <= CAP_IDX);
        assertEq(manager.updateCount(), updatesBefore);
    }

    function test_computeNextFeeIdx_at_cap_clears_lastDir_when_no_step() public view {
        (uint8 nf, uint8 nd, bool changed,) = hook.exposedComputeNextFeeIdx(CAP_IDX, 0, 1_000_000, 1_000_000);
        assertEq(nf, CAP_IDX);
        assertEq(nd, 0);
        assertFalse(changed);
    }

    function test_computeNextFeeIdx_at_floor_clears_lastDir_when_no_step() public view {
        (uint8 nf, uint8 nd, bool changed,) = hook.exposedComputeNextFeeIdx(FLOOR_IDX, 0, 0, 1_000_000);
        assertEq(nf, FLOOR_IDX);
        assertEq(nd, 0);
        assertFalse(changed);
    }

    function test_reason_code_deadband_is_9() public view {
        assertEq(hook.REASON_DEADBAND(), 9);
    }

    function test_reason_code_ema_bootstrap_is_10() public view {
        assertEq(hook.REASON_EMA_BOOTSTRAP(), 10);
    }

    function test_period_close_emits_ema_bootstrap_reason_code_10() public {
        manager.callAfterInitialize(hook, key);

        manager.callAfterSwap(hook, key, _deltaA0(-2_000_000));
        vm.warp(block.timestamp + PERIOD_SECONDS);

        uint24 fee = hook.feeTiers(uint256(FLOOR_IDX));
        uint64 lpFeesUsd6 = uint64((uint256(2_000_000) * uint256(fee)) / 1_000_000);
        vm.expectEmit(true, true, true, true, address(hook));
        emit PeriodClosed(fee, FLOOR_IDX, fee, FLOOR_IDX, 2_000_000, 2_000_000, lpFeesUsd6, 10);
        manager.callAfterSwap(hook, key, _deltaZero());
    }

    function test_period_close_emits_deadband_reason_code_9() public {
        int128 bootstrapCloseVol = -1_000_000_000; // meets minCloseVolToCashUsd6
        int128 deadbandBlockedCloseVol = -2_100_000_000; // rBps > threshold but < threshold + deadband

        manager.callAfterInitialize(hook, key);

        manager.callAfterSwap(hook, key, _deltaA0(bootstrapCloseVol));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero()); // EMA bootstrap close

        manager.callAfterSwap(hook, key, _deltaA0(deadbandBlockedCloseVol));
        vm.warp(block.timestamp + PERIOD_SECONDS);

        uint24 fee = hook.feeTiers(uint256(FLOOR_IDX));
        uint64 closeVol = uint64(uint128(-deadbandBlockedCloseVol));
        uint64 lpFeesUsd6 = uint64((uint256(closeVol) * uint256(fee)) / 1_000_000);
        uint96 ema = uint96((uint256(uint64(uint128(-bootstrapCloseVol))) * 7 + closeVol) / 8);
        vm.expectEmit(true, true, true, true, address(hook));
        emit PeriodClosed(fee, FLOOR_IDX, fee, FLOOR_IDX, closeVol, ema, lpFeesUsd6, 9);
        manager.callAfterSwap(hook, key, _deltaZero());
    }

    function test_period_close_commits_state_before_fee_update_call() public {
        manager.callAfterInitialize(hook, key);
        assertEq(manager.updateCount(), 1);

        // Bootstrap EMA without changing fee.
        manager.callAfterSwap(hook, key, _deltaA0(-2_000_000));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        // Force a floor->cash jump in v2 to trigger updateDynamicLPFee().
        manager.callAfterSwap(hook, key, _deltaA0(-4_000_000_000));
        uint256 closeTs = block.timestamp + PERIOD_SECONDS;
        vm.warp(closeTs);
        manager.callAfterSwap(hook, key, _deltaZero());

        assertEq(manager.updateCount(), 2);
        assertEq(manager.observedFeeIdx(), hook.cashIdx());
        assertEq(manager.observedPeriodStart(), uint64(closeTs));
        assertEq(manager.observedPeriodVolUsd6(), 0);
        assertEq(manager.observedEmaVolUsd6(), 501_750_000);
        assertEq(manager.observedLastDir(), 0);
    }

    function test_zero_ema_and_zero_close_keeps_fee_at_floor() public {
        manager.callAfterInitialize(hook, key);

        (,,, uint8 idxBefore,) = hook.unpackedState();
        assertEq(idxBefore, FLOOR_IDX);

        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        (uint64 pv, uint96 ema,, uint8 idxAfter, uint8 dirAfter) = hook.unpackedState();
        assertEq(idxAfter, FLOOR_IDX);
        assertEq(dirAfter, 0);
        assertEq(ema, 0);
        assertEq(pv, 0);
    }

    function test_dust_close_volume_leq_one_usd_is_treated_as_zero() public {
        manager.callAfterInitialize(hook, key);

        // 1.000000 stable in 6 decimals -> closeVol = 1_000_000 (dust threshold).
        manager.callAfterSwap(hook, key, _deltaA0(-1_000_000));
        vm.warp(block.timestamp + PERIOD_SECONDS);

        manager.callAfterSwap(hook, key, _deltaZero());

        (uint64 pv, uint96 ema,, uint8 idxAfter, uint8 dirAfter) = hook.unpackedState();
        assertEq(idxAfter, FLOOR_IDX);
        assertEq(dirAfter, 0);
        assertEq(ema, 0);
        assertEq(pv, 0);
    }

    function test_close_volume_above_one_usd_is_not_treated_as_zero() public {
        manager.callAfterInitialize(hook, key);

        // 1.000001 stable in 6 decimals -> closeVol = 1_000_001 (> dust threshold).
        manager.callAfterSwap(hook, key, _deltaA0(-1_000_001));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        (uint64 pv, uint96 ema,, uint8 idxAfter, uint8 dirAfter) = hook.unpackedState();
        assertEq(idxAfter, FLOOR_IDX);
        assertEq(dirAfter, 0);
        assertEq(ema, 1_000_001);
        assertEq(pv, 0);
    }

    function test_fee_reaches_floor_and_does_not_go_lower() public {
        _seedEma();

        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + PERIOD_SECONDS);
            manager.callAfterSwap(hook, key, _deltaZero());
        }

        (,,, uint8 idxBefore,) = hook.unpackedState();
        assertEq(idxBefore, FLOOR_IDX);

        uint256 updatesBefore = manager.updateCount();
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        (,,, uint8 idxAfter,) = hook.unpackedState();
        assertEq(idxAfter, FLOOR_IDX);
        assertEq(manager.updateCount(), updatesBefore);
    }

    function test_lull_reset_when_already_floor_does_not_write_fee() public {
        manager.callAfterInitialize(hook, key);
        assertEq(manager.updateCount(), 1);

        vm.warp(block.timestamp + LULL_RESET_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        (uint64 pv, uint96 ema,, uint8 idx, uint8 dir) = hook.unpackedState();
        assertEq(idx, FLOOR_IDX);
        assertEq(pv, 0);
        assertEq(ema, 0);
        assertEq(dir, 0);
        assertEq(manager.updateCount(), 1);
    }
}
