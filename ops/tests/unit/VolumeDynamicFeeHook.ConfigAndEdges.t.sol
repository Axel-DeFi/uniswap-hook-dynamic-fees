// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "../utils/VolumeDynamicFeeHookV2DeployHelper.sol";

contract VolumeDynamicFeeHookConfigHarness is VolumeDynamicFeeHook {
    constructor(
        IPoolManager _poolManager,
        Currency _poolCurrency0,
        Currency _poolCurrency1,
        int24 _poolTickSpacing,
        Currency _stableCurrency,
        uint8 stableDecimals,
        uint24 _floorFee,
        uint24 _cashFee,
        uint24 _extremeFee,
        uint32 _periodSeconds,
        uint8 _emaPeriods,
        uint16 _deadbandBps,
        uint32 _lullResetSeconds,
        address ownerAddr,
        uint16 hookFeePercent,
        uint64 _minCloseVolToCashUsd6,
        uint16 _upRToCashBps,
        uint8 _cashHoldPeriods,
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
            _floorFee,
            _cashFee,
            _extremeFee,
            _periodSeconds,
            _emaPeriods,
            _deadbandBps,
            _lullResetSeconds,
            ownerAddr,
            hookFeePercent,
            _minCloseVolToCashUsd6,
            _upRToCashBps,
            _cashHoldPeriods,
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
    address internal constant OUTSIDER = address(0xCAFE);

    struct DeployCfg {
        address token0;
        address token1;
        int24 tickSpacing;
        address stable;
        uint8 stableDecimals;
        uint24 floorFee;
        uint24 cashFee;
        uint24 extremeFee;
        uint32 periodSeconds;
        uint8 emaPeriods;
        uint16 deadbandBps;
        uint32 lullResetSeconds;
        address owner;
        uint16 hookFeePercent;
        uint64 emergencyFloorCloseVolUsd6;
        uint8 emergencyConfirmPeriods;
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
            floorFee: V2_DEFAULT_FLOOR_FEE,
            cashFee: V2_DEFAULT_CASH_FEE,
            extremeFee: V2_DEFAULT_EXTREME_FEE,
            periodSeconds: PERIOD_SECONDS,
            emaPeriods: 8,
            deadbandBps: 500,
            lullResetSeconds: LULL_RESET_SECONDS,
            owner: address(this),
            hookFeePercent: V2_INITIAL_HOOK_FEE_PERCENT,
            emergencyFloorCloseVolUsd6: V2_EMERGENCY_FLOOR_CLOSEVOL_USD6,
            emergencyConfirmPeriods: V2_EMERGENCY_CONFIRM_PERIODS
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
            cfg.floorFee,
            cfg.cashFee,
            cfg.extremeFee,
            cfg.periodSeconds,
            cfg.emaPeriods,
            cfg.deadbandBps,
            cfg.lullResetSeconds,
            cfg.owner,
            cfg.hookFeePercent,
            V2_MIN_CLOSEVOL_TO_CASH_USD6,
            V2_UP_R_TO_CASH_BPS,
            V2_CASH_HOLD_PERIODS,
            V2_MIN_CLOSEVOL_TO_EXTREME_USD6,
            V2_UP_R_TO_EXTREME_BPS,
            V2_UP_EXTREME_CONFIRM_PERIODS,
            V2_EXTREME_HOLD_PERIODS,
            V2_DOWN_R_FROM_EXTREME_BPS,
            V2_DOWN_EXTREME_CONFIRM_PERIODS,
            V2_DOWN_R_FROM_CASH_BPS,
            V2_DOWN_CASH_CONFIRM_PERIODS,
            cfg.emergencyFloorCloseVolUsd6,
            cfg.emergencyConfirmPeriods
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
            cfg.floorFee,
            cfg.cashFee,
            cfg.extremeFee,
            cfg.periodSeconds,
            cfg.emaPeriods,
            cfg.deadbandBps,
            cfg.lullResetSeconds,
            cfg.owner,
            cfg.hookFeePercent,
            V2_MIN_CLOSEVOL_TO_CASH_USD6,
            V2_UP_R_TO_CASH_BPS,
            V2_CASH_HOLD_PERIODS,
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

    function test_constructor_reverts_when_lullReset_equals_period() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.lullResetSeconds = cfg.periodSeconds;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
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

    function test_constructor_reverts_when_floor_fee_is_zero() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.floorFee = 0;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_when_fee_order_is_invalid() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.cashFee = cfg.floorFee;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);

        cfg = _defaultCfg();
        cfg.extremeFee = cfg.cashFee;
        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_when_emergency_floor_threshold_is_zero() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.emergencyFloorCloseVolUsd6 = 0;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_reverts_when_emergency_floor_threshold_is_not_below_cash_threshold() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.emergencyFloorCloseVolUsd6 = V2_MIN_CLOSEVOL_TO_CASH_USD6;

        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        _deploy(cfg);
    }

    function test_constructor_accepts_positive_emergency_floor_threshold() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.emergencyFloorCloseVolUsd6 = 1;

        VolumeDynamicFeeHookConfigHarness h = _deploy(cfg);
        assertEq(h.emergencyFloorCloseVolUsd6(), 1);
    }

    function test_constructor_reverts_on_zero_owner() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.owner = address(0);

        vm.expectRevert(VolumeDynamicFeeHook.InvalidOwner.selector);
        _deploy(cfg);
    }

    function test_constructor_accepts_nonzero_hookFee_without_separate_recipient_config() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.hookFeePercent = 1;

        VolumeDynamicFeeHookConfigHarness deployed = _deploy(cfg);
        assertEq(deployed.owner(), cfg.owner);
        assertEq(deployed.hookFeePercent(), 1);
    }

    function test_constructor_reverts_when_hookFee_percent_above_hard_cap() public {
        DeployCfg memory cfg = _defaultCfg();
        cfg.hookFeePercent = 11;

        vm.expectRevert(
            abi.encodeWithSelector(
                VolumeDynamicFeeHook.HookFeePercentLimitExceeded.selector, uint16(11), uint16(10)
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

    function test_afterInitialize_reverts_when_dynamic_fee_flag_is_not_exact_constant() public {
        DeployCfg memory cfg = _defaultCfg();
        VolumeDynamicFeeHookConfigHarness fresh = _deploy(cfg);
        PoolKey memory badKey = _keyFor(cfg, address(fresh));
        badKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG | uint24(1);

        vm.expectRevert(VolumeDynamicFeeHook.NotDynamicFeePool.selector);
        manager.callAfterInitialize(fresh, badKey);
    }

    function test_claimHookFees_rejects_non_owner_recipient() public {
        vm.expectRevert(VolumeDynamicFeeHook.InvalidRecipient.selector);
        hook.claimHookFees(address(0x1234), 0, 0);
    }

    function test_claimAllHookFees_uses_current_owner_after_transfer() public {
        manager.callAfterSwap(hook, key, toBalanceDelta(-10_000_000, 9_000_000));
        (, uint256 feesBeforeTransfer) = hook.hookFeesAccrued();
        assertGt(feesBeforeTransfer, 0, "precondition: accrued fees must exist");

        address newOwner = address(0xBEEF);
        hook.proposeNewOwner(newOwner);
        vm.prank(newOwner);
        hook.acceptOwner();

        vm.expectRevert(VolumeDynamicFeeHook.NotOwner.selector);
        hook.claimAllHookFees();

        uint256 takeCountBefore = manager.takeCount();
        vm.prank(newOwner);
        hook.claimAllHookFees();

        (, uint256 feesAfterClaim) = hook.hookFeesAccrued();
        assertEq(feesAfterClaim, 0, "new owner must claim prior accrual");
        assertEq(manager.takeCount(), takeCountBefore + 1, "claim payout must target new owner");
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

    function test_default_minCountedSwapUsd6_is_4e6() public view {
        assertEq(hook.minCountedSwapUsd6(), 4_000_000);
        assertEq(hook.minCountedSwapUsd6(), hook.DEFAULT_MIN_COUNTED_SWAP_USD6());
    }

    function test_regimeFees_are_exposed_explicitly() public view {
        (uint24 floorFee_, uint24 cashFee_, uint24 extremeFee_) = hook.getRegimeFees();
        assertEq(floorFee_, V2_DEFAULT_FLOOR_FEE);
        assertEq(cashFee_, V2_DEFAULT_CASH_FEE);
        assertEq(extremeFee_, V2_DEFAULT_EXTREME_FEE);
    }

    function test_rescue_guards() public {
        vm.expectRevert(VolumeDynamicFeeHook.InvalidRescueCurrency.selector);
        hook.rescueToken(Currency.wrap(TOKEN0), 1);

        vm.expectRevert(VolumeDynamicFeeHook.ClaimTooLarge.selector);
        hook.rescueETH(1);

        vm.prank(OUTSIDER);
        vm.expectRevert(VolumeDynamicFeeHook.NotOwner.selector);
        hook.rescueETH(0);
    }

    function test_rescueETH_transfers_to_owner() public {
        address ownerAddr = address(0xA11CE);
        DeployCfg memory cfg = _defaultCfg();
        cfg.owner = ownerAddr;

        VolumeDynamicFeeHookConfigHarness ownerHook = _deploy(cfg);

        uint256 amount = 1 ether;
        vm.deal(address(ownerHook), amount);
        uint256 ownerBalanceBefore = ownerAddr.balance;

        vm.prank(ownerAddr);
        ownerHook.rescueETH(amount);

        assertEq(ownerAddr.balance, ownerBalanceBefore + amount);
        assertEq(address(ownerHook).balance, 0);
    }

    function test_rescueETH_legacy_signature_is_unavailable() public {
        (bool ok,) =
            address(hook).call(abi.encodeWithSignature("rescueETH(address,uint256)", address(this), 0));
        assertFalse(ok, "legacy rescueETH(address,uint256) signature must not be callable");
    }

    function test_rescueToken_transfers_nonPool_token_to_owner() public {
        MockERC20 token = new MockERC20("Rescue Token", "RSC", 18);
        uint256 amount = 7 ether;
        token.mint(address(hook), amount);

        uint256 ownerBefore = token.balanceOf(address(this));
        hook.rescueToken(Currency.wrap(address(token)), amount);

        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(this)), ownerBefore + amount);
    }
}
