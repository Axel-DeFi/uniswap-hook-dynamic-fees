// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "../utils/VolumeDynamicFeeHookV2DeployHelper.sol";

contract VolumeDynamicFeeHookConfigHarness is VolumeDynamicFeeHook {
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

contract VolumeDynamicFeeHookConfigAndEdgesTest is Test, VolumeDynamicFeeHookV2DeployHelper {
    MockPoolManager internal manager;
    VolumeDynamicFeeHookConfigHarness internal hook;
    PoolKey internal key;

    address internal constant TOKEN0 = address(0x0000000000000000000000000000000000001111);
    address internal constant TOKEN1 = address(0x0000000000000000000000000000000000002222);

    uint32 internal constant PERIOD_SECONDS = 300;
    uint32 internal constant LULL_RESET_SECONDS = 3600;

    struct DeployCfg {
        address token0;
        address token1;
        int24 tickSpacing;
        address stable;
        uint8 stableDecimals;
        uint8 floorIdx;
        uint24[] feeTiers;
        uint32 periodSeconds;
        uint8 emaPeriods;
        uint16 deadbandBps;
        uint32 lullResetSeconds;
        address owner;
        address hookFeeRecipient;
        uint16 hookFeePercent;
    }

    function setUp() public {
        manager = new MockPoolManager();

        DeployCfg memory cfg = _defaultCfg();
        hook = _deploy(cfg);
        key = _keyFor(cfg, address(hook));
        manager.callAfterInitialize(hook, key);
    }

    function _defaultCfg() internal view returns (DeployCfg memory cfg) {
        cfg = DeployCfg({
            token0: TOKEN0,
            token1: TOKEN1,
            tickSpacing: 10,
            stable: TOKEN0,
            stableDecimals: 6,
            floorIdx: 0,
            feeTiers: _defaultFeeTiersV2(),
            periodSeconds: PERIOD_SECONDS,
            emaPeriods: 8,
            deadbandBps: 500,
            lullResetSeconds: LULL_RESET_SECONDS,
            owner: address(this),
            hookFeeRecipient: address(this),
            hookFeePercent: V2_INITIAL_HOOK_FEE_PERCENT
        });
    }

    function _deploy(DeployCfg memory cfg) internal returns (VolumeDynamicFeeHookConfigHarness h) {
        h = new VolumeDynamicFeeHookConfigHarness(
            IPoolManager(address(manager)),
            Currency.wrap(cfg.token0),
            Currency.wrap(cfg.token1),
            cfg.tickSpacing,
            Currency.wrap(cfg.stable),
            cfg.stableDecimals,
            cfg.floorIdx,
            cfg.feeTiers,
            cfg.periodSeconds,
            cfg.emaPeriods,
            cfg.deadbandBps,
            cfg.lullResetSeconds,
            cfg.owner,
            cfg.hookFeeRecipient,
            cfg.hookFeePercent,
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

    function test_constructor_reverts_on_nonCanonicalCurrencyOrder() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.token0 = TOKEN1;
        cfg.token1 = TOKEN0;
        cfg.stable = cfg.token1;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_on_zeroPoolManager() public {
        DeployCfg memory cfg = _defaultCfg();

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        new VolumeDynamicFeeHookConfigHarness(
            IPoolManager(address(0)),
            Currency.wrap(cfg.token0),
            Currency.wrap(cfg.token1),
            cfg.tickSpacing,
            Currency.wrap(cfg.stable),
            cfg.stableDecimals,
            cfg.floorIdx,
            cfg.feeTiers,
            cfg.periodSeconds,
            cfg.emaPeriods,
            cfg.deadbandBps,
            cfg.lullResetSeconds,
            cfg.owner,
            cfg.hookFeeRecipient,
            cfg.hookFeePercent,
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

    function test_constructor_reverts_on_invalid_stable_decimals() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.stableDecimals = 8;

        vm.expectRevert(abi.encodeWithSelector(VolumeDynamicFeeHook.InvalidStableDecimals.selector, uint8(8)));
        _deploy(cfg);
    }

    function test_constructor_reverts_on_zero_owner() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.owner = address(0);

        vm.expectRevert(VolumeDynamicFeeHook.InvalidOwner.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_when_hookFee_recipient_missing() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.hookFeePercent = 1;
        cfg.hookFeeRecipient = address(0);

        vm.expectRevert(VolumeDynamicFeeHook.HookFeeRecipientRequired.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_when_hookFee_percent_above_hard_cap() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.hookFeePercent = 11;

        vm.expectRevert(
            abi.encodeWithSelector(
                VolumeDynamicFeeHook.HookFeePercentLimitExceeded.selector,
                uint16(11),
                uint16(10)
            )
        );
        _deploy(cfg);
    }

    function test_permissions_include_afterSwap_return_delta_flag() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.afterInitialize);
        assertTrue(perms.afterSwap);
        assertTrue(perms.afterSwapReturnDelta);
        assertFalse(perms.beforeSwap);
        assertFalse(perms.beforeSwapReturnDelta);
    }

    function test_owner_and_hookFeeRecipient_are_distinct_entities() public {
        assertEq(hook.owner(), address(this));
        assertEq(hook.hookFeeRecipient(), address(this));

        address recipient = address(0x1234);
        hook.setHookFeeRecipient(recipient);
        assertEq(hook.owner(), address(this));
        assertEq(hook.hookFeeRecipient(), recipient);
    }

    function test_setHookFeeRecipient_zero_reverts_when_fee_enabled() public {
        vm.expectRevert(VolumeDynamicFeeHook.HookFeeRecipientRequired.selector);
        hook.setHookFeeRecipient(address(0));
    }

    function test_scheduleHookFeePercentChange_rejects_parallel_pending_update() public {
        hook.scheduleHookFeePercentChange(4);

        vm.expectRevert(VolumeDynamicFeeHook.PendingHookFeePercentChangeExists.selector);
        hook.scheduleHookFeePercentChange(5);
    }

    function test_scheduleMinCountedSwapUsd6_reverts_below_min_bound() public {
        vm.expectRevert(VolumeDynamicFeeHook.InvalidMinCountedSwapUsd6.selector);
        hook.scheduleMinCountedSwapUsd6Change(999_999);
    }

    function test_scheduleMinCountedSwapUsd6_reverts_above_max_bound() public {
        vm.expectRevert(VolumeDynamicFeeHook.InvalidMinCountedSwapUsd6.selector);
        hook.scheduleMinCountedSwapUsd6Change(10_000_001);
    }

    function test_scheduleMinCountedSwapUsd6_accepts_range_bounds() public {
        hook.scheduleMinCountedSwapUsd6Change(1_000_000);
        (bool exists, uint64 nextValue) = hook.pendingMinCountedSwapUsd6Change();
        assertTrue(exists);
        assertEq(nextValue, 1_000_000);

        hook.cancelMinCountedSwapUsd6Change();

        hook.scheduleMinCountedSwapUsd6Change(10_000_000);
        (exists, nextValue) = hook.pendingMinCountedSwapUsd6Change();
        assertTrue(exists);
        assertEq(nextValue, 10_000_000);
    }

    function test_default_minCountedSwapUsd6_is_4e6() public {
        assertEq(hook.minCountedSwapUsd6(), 4_000_000);
        assertEq(hook.minCountedSwapUsd6(), hook.DEFAULT_MIN_COUNTED_SWAP_USD6());
    }

    function test_feeTier_roles_exposed_without_extremeIdx() public view {
        (uint24[] memory tiers, uint8 floor, uint8 cash, uint8 extreme) = hook.getFeeTiersAndRoles();
        assertEq(tiers.length, 3);
        assertEq(floor, 0);
        assertEq(cash, 1);
        assertEq(extreme, 2);
    }

    function test_rescue_guards() public {
        vm.expectRevert(VolumeDynamicFeeHook.InvalidRescueCurrency.selector);
        hook.rescueToken(Currency.wrap(TOKEN0), 1);

        vm.expectRevert(VolumeDynamicFeeHook.InvalidRecipient.selector);
        hook.rescueETH(address(0), 1);
    }
}
