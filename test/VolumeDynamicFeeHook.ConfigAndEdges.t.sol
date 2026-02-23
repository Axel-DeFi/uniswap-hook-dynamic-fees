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
import {MockPoolManager} from "test/mocks/MockPoolManager.sol";

/// @notice Harness that bypasses permission-bit address validation to isolate constructor config checks.
contract VolumeDynamicFeeHookHarness is VolumeDynamicFeeHook {
    constructor(
        IPoolManager _poolManager,
        Currency _poolCurrency0,
        Currency _poolCurrency1,
        int24 _poolTickSpacing,
        Currency _stableCurrency,
        uint8 stableDecimals,
        uint8 _initialFeeIdx,
        uint8 _floorIdx,
        uint8 _capIdx,
        uint32 _periodSeconds,
        uint8 _emaPeriods,
        uint16 _deadbandBps,
        uint32 _lullResetSeconds,
        address _guardian,
        uint8 _pauseFeeIdx
    )
        VolumeDynamicFeeHook(
            _poolManager,
            _poolCurrency0,
            _poolCurrency1,
            _poolTickSpacing,
            _stableCurrency,
            stableDecimals,
            _initialFeeIdx,
            _floorIdx,
            _capIdx,
            _periodSeconds,
            _emaPeriods,
            _deadbandBps,
            _lullResetSeconds,
            _guardian,
            _pauseFeeIdx
        )
    {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract VolumeDynamicFeeHookConfigAndEdgesTest is Test {
    struct DeployCfg {
        address token0;
        address token1;
        int24 tickSpacing;
        address stable;
        uint8 stableDecimals;
        uint8 initialFeeIdx;
        uint8 floorIdx;
        uint8 capIdx;
        uint32 periodSeconds;
        uint8 emaPeriods;
        uint16 deadbandBps;
        uint32 lullResetSeconds;
        address guardian;
        uint8 pauseFeeIdx;
    }

    MockPoolManager internal manager;
    VolumeDynamicFeeHookHarness internal hook;
    PoolKey internal key;

    uint32 internal constant PERIOD_SECONDS = 3600;
    uint32 internal constant LULL_RESET_SECONDS = 86400;
    uint8 internal constant INITIAL_FEE_IDX = 3;
    uint8 internal constant FLOOR_IDX = 0;
    uint8 internal constant CAP_IDX = 6;
    uint8 internal constant PAUSE_FEE_IDX = 3;

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
            initialFeeIdx: INITIAL_FEE_IDX,
            floorIdx: FLOOR_IDX,
            capIdx: CAP_IDX,
            periodSeconds: PERIOD_SECONDS,
            emaPeriods: 8,
            deadbandBps: 500,
            lullResetSeconds: LULL_RESET_SECONDS,
            guardian: address(this),
            pauseFeeIdx: PAUSE_FEE_IDX
        });
    }

    function _deploy(DeployCfg memory cfg) internal returns (VolumeDynamicFeeHookHarness h) {
        h = new VolumeDynamicFeeHookHarness(
            IPoolManager(address(manager)),
            Currency.wrap(cfg.token0),
            Currency.wrap(cfg.token1),
            cfg.tickSpacing,
            Currency.wrap(cfg.stable),
            cfg.stableDecimals,
            cfg.initialFeeIdx,
            cfg.floorIdx,
            cfg.capIdx,
            cfg.periodSeconds,
            cfg.emaPeriods,
            cfg.deadbandBps,
            cfg.lullResetSeconds,
            cfg.guardian,
            cfg.pauseFeeIdx
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

    function test_constructor_reverts_when_stable_not_in_pool() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.stable = address(0x0000000000000000000000000000000000003333);

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

    function test_constructor_reverts_on_zeroGuardian() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.guardian = address(0);

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_pauseFeeIdx_out_of_range() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.pauseFeeIdx = 7;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidFeeIndex.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_fee_idx_out_of_range() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.capIdx = 7;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidFeeIndex.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_floor_initial_cap_relation() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.floorIdx = 4;
        cfg.initialFeeIdx = 3;
        cfg.capIdx = 6;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_pause_outside_floor_cap() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.floorIdx = 2;
        cfg.capIdx = 4;
        cfg.pauseFeeIdx = 1;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_stableDecimals_gt_18() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.stableDecimals = 19;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_feeTiers_values_and_out_of_bounds() public view {
        assertEq(hook.feeTiers(0), 95);
        assertEq(hook.feeTiers(1), 400);
        assertEq(hook.feeTiers(2), 900);
        assertEq(hook.feeTiers(3), 2500);
        assertEq(hook.feeTiers(4), 3000);
        assertEq(hook.feeTiers(5), 6000);
        assertEq(hook.feeTiers(6), 9000);
    }

    function test_feeTiers_reverts_on_index_ge_count() public {
        vm.expectRevert(VolumeDynamicFeeHook.InvalidFeeIndex.selector);
        hook.feeTiers(7);
    }

    function test_permissions_are_exactly_afterInitialize_and_afterSwap() public view {
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
        assertEq(idx, PAUSE_FEE_IDX);
        assertEq(manager.updateCount(), updatesAfterPause);
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
        assertEq(pv, 2_000_000); // 1e6 USD6 * 2
    }

    function test_stableDecimals_gt_6_scales_down_to_usd6() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.stableDecimals = 18;

        VolumeDynamicFeeHookHarness h = _deploy(cfg);
        PoolKey memory k = _keyFor(cfg, address(h));

        manager.callAfterInitialize(h, k);
        manager.callAfterSwap(h, k, _deltaA0(-1e18)); // 1.0 stable in 18 decimals

        (uint64 pv,,,,) = h.unpackedState();
        assertEq(pv, 2_000_000); // 1e6 USD6 * 2
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
        assertEq(pvA1, 2_000_000);
    }

    function test_fee_reaches_cap_and_does_not_exceed() public {
        _seedEma();

        for (uint256 i = 0; i < 10; i++) {
            manager.callAfterSwap(hook, key, _deltaA0(-5_000_000_000));
            vm.warp(block.timestamp + PERIOD_SECONDS);
            manager.callAfterSwap(hook, key, _deltaZero());
        }

        (,,, uint8 idxBefore,) = hook.unpackedState();
        assertEq(idxBefore, CAP_IDX);

        uint256 updatesBefore = manager.updateCount();
        manager.callAfterSwap(hook, key, _deltaA0(-5_000_000_000));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        (,,, uint8 idxAfter,) = hook.unpackedState();
        assertEq(idxAfter, CAP_IDX);
        assertEq(manager.updateCount(), updatesBefore);
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

    function test_lull_reset_when_already_initial_does_not_write_fee() public {
        manager.callAfterInitialize(hook, key);
        assertEq(manager.updateCount(), 1);

        vm.warp(block.timestamp + LULL_RESET_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        (uint64 pv, uint96 ema,, uint8 idx, uint8 dir) = hook.unpackedState();
        assertEq(idx, INITIAL_FEE_IDX);
        assertEq(pv, 0);
        assertEq(ema, 0);
        assertEq(dir, 0);
        assertEq(manager.updateCount(), 1);
    }
}
