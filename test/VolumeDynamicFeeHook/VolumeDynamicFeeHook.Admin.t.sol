// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "./utils/VolumeDynamicFeeHookV2DeployHelper.sol";

contract VolumeDynamicFeeHookAdminHarness is VolumeDynamicFeeHook {
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
        address _owner,
        address _guardian,
        address _creator,
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
            _owner,
            _guardian,
            _creator,
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
}

contract VolumeDynamicFeeHookAdminTest is Test, VolumeDynamicFeeHookV2DeployHelper {
    MockPoolManager internal manager;
    VolumeDynamicFeeHookAdminHarness internal hook;
    PoolKey internal key;

    address internal constant TOKEN0 = address(0x0000000000000000000000000000000000001111);
    address internal constant TOKEN1 = address(0x0000000000000000000000000000000000002222);

    address internal owner = address(this);
    address internal guardian = address(0xBEEF);
    address internal outsider = address(0xCAFE);

    uint32 internal constant PERIOD_SECONDS = 300;
    uint8 internal constant EMA_PERIODS = 8;
    uint16 internal constant DEADBAND_BPS = 500;
    uint32 internal constant LULL_RESET_SECONDS = 3600;

    function setUp() public {
        manager = new MockPoolManager();

        uint24[] memory tiers = _defaultFeeTiersV2();
        hook = _deployHarness(tiers, 0, 2, owner, guardian, owner, 1_000);
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

    function _defaultControllerParams()
        internal
        pure
        returns (VolumeDynamicFeeHook.ControllerParams memory p)
    {
        p = VolumeDynamicFeeHook.ControllerParams({
            minCloseVolToCashUsd6: V2_MIN_CLOSEVOL_TO_CASH_USD6,
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
    }

    function _deployHarness(
        uint24[] memory tiers,
        uint8 floorIdx,
        uint8 capIdx,
        address owner_,
        address guardian_,
        address creator_,
        uint16 creatorFeeBps_
    ) internal returns (VolumeDynamicFeeHookAdminHarness h) {
        h = new VolumeDynamicFeeHookAdminHarness(
            IPoolManager(address(manager)),
            Currency.wrap(TOKEN0),
            Currency.wrap(TOKEN1),
            10,
            Currency.wrap(TOKEN0),
            6,
            floorIdx,
            capIdx,
            tiers,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            owner_,
            guardian_,
            creator_,
            creatorFeeBps_,
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

    function test_onlyOwner_can_call_admin_setters() public {
        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        uint24[] memory tiers = _defaultFeeTiersV2();

        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.setGuardian(address(0x1234));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.setCreatorFeeConfig(address(0x1234), 500);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.setControllerParams(p);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.setTimingParams(PERIOD_SECONDS, EMA_PERIODS, LULL_RESET_SECONDS, DEADBAND_BPS);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        hook.setFeeTiersAndRoles(tiers, 0, 1, 2, 2);
        vm.stopPrank();
    }

    function test_guardian_permissions_are_limited_to_pause_flow() public {
        vm.prank(outsider);
        vm.expectRevert(VolumeDynamicFeeHook.NotGuardian.selector);
        hook.pause();

        vm.prank(guardian);
        hook.pause();
        assertTrue(hook.isPaused());

        vm.prank(guardian);
        hook.emergencyResetStateToFloor();

        vm.prank(guardian);
        hook.unpause();
        assertFalse(hook.isPaused());

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        hook.setGuardian(address(0x1234));
    }

    function test_emergencyReset_requires_paused_state() public {
        vm.prank(guardian);
        vm.expectRevert(VolumeDynamicFeeHook.RequiresPaused.selector);
        hook.emergencyResetStateToFloor();
    }

    function test_setters_require_paused_when_configured_for_safety() public {
        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        uint24[] memory tiers = _defaultFeeTiersV2();

        vm.expectRevert(VolumeDynamicFeeHook.RequiresPaused.selector);
        hook.setControllerParams(p);

        vm.expectRevert(VolumeDynamicFeeHook.RequiresPaused.selector);
        hook.setTimingParams(PERIOD_SECONDS, EMA_PERIODS, LULL_RESET_SECONDS, DEADBAND_BPS);

        vm.expectRevert(VolumeDynamicFeeHook.RequiresPaused.selector);
        hook.setFeeTiersAndRoles(tiers, 0, 1, 2, 2);
    }

    function test_setFeeTiers_validation_reverts_on_bad_input() public {
        vm.prank(guardian);
        hook.pause();

        uint24[] memory nonIncreasing = new uint24[](3);
        nonIncreasing[0] = 400;
        nonIncreasing[1] = 400;
        nonIncreasing[2] = 9000;
        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfig.selector);
        hook.setFeeTiersAndRoles(nonIncreasing, 0, 1, 2, 2);

        uint24[] memory ok = _defaultFeeTiersV2();
        vm.expectRevert(VolumeDynamicFeeHook.InvalidFeeIndex.selector);
        hook.setFeeTiersAndRoles(ok, 0, 1, 3, 2);

        vm.expectRevert(VolumeDynamicFeeHook.InvalidTierBounds.selector);
        hook.setFeeTiersAndRoles(ok, 1, 0, 2, 2);
    }

    function test_setControllerParams_validation_reverts_on_invalid_periods() public {
        vm.prank(guardian);
        hook.pause();

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.cashHoldPeriods = 0;
        vm.expectRevert(VolumeDynamicFeeHook.InvalidHoldPeriods.selector);
        hook.setControllerParams(p);

        p = _defaultControllerParams();
        p.upExtremeConfirmPeriods = 0;
        vm.expectRevert(VolumeDynamicFeeHook.InvalidConfirmPeriods.selector);
        hook.setControllerParams(p);
    }

    function test_setFeeTiersAndRoles_resets_state_to_new_floor() public {
        vm.prank(guardian);
        hook.pause();

        vm.warp(block.timestamp + 7);
        uint24[] memory tiers = new uint24[](3);
        tiers[0] = 400;
        tiers[1] = 1200;
        tiers[2] = 9000;

        hook.setFeeTiersAndRoles(tiers, 1, 1, 2, 2);

        (uint64 pv, uint96 ema, uint64 ps, uint8 feeIdx,) = hook.unpackedState();
        assertEq(pv, 0);
        assertEq(ema, 0);
        assertEq(feeIdx, 1);
        assertEq(ps, uint64(block.timestamp));
        assertEq(hook.floorIdx(), 1);
        assertEq(hook.cashIdx(), 1);
    }

    function test_setTimingParams_resets_state_and_updates_values() public {
        vm.prank(guardian);
        hook.pause();

        uint64 prevPeriodStart;
        (,, prevPeriodStart,,) = hook.unpackedState();

        vm.warp(block.timestamp + 9);
        hook.setTimingParams(600, 10, 7_200, 800);

        (uint64 pv, uint96 ema, uint64 ps, uint8 feeIdx,) = hook.unpackedState();
        assertEq(pv, 0);
        assertEq(ema, 0);
        assertEq(feeIdx, hook.floorIdx());
        assertGt(ps, prevPeriodStart);
        assertEq(hook.periodSeconds(), 600);
        assertEq(hook.emaPeriods(), 10);
        assertEq(hook.lullResetSeconds(), 7_200);
        assertEq(hook.deadbandBps(), 800);
    }

    function test_creatorFee_zero_percent_is_strict_noop_in_beforeSwap() public {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(1_000_000_000), sqrtPriceLimitX96: 0});

        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, params, "");
        (uint256 accrued0Before,) = hook.creatorFeesAccrued();
        assertEq(manager.takeCount(), 1);
        assertGt(accrued0Before, 0);

        hook.setCreatorFeeConfig(owner, 0);

        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, params, "");
        (uint256 accrued0After,) = hook.creatorFeesAccrued();
        assertEq(manager.takeCount(), 1);
        assertEq(accrued0After, accrued0Before);
    }

    function test_integration_configure_onchain_before_initialize_then_fee_moves() public {
        uint24[] memory tiers = new uint24[](3);
        tiers[0] = 400;
        tiers[1] = 1500;
        tiers[2] = 9000;

        VolumeDynamicFeeHookAdminHarness h = _deployHarness(tiers, 0, 2, owner, guardian, owner, 0);
        PoolKey memory k = _poolKey(address(h));

        vm.prank(guardian);
        h.pause();

        vm.prank(owner);
        h.setFeeTiersAndRoles(tiers, 0, 1, 2, 2);

        VolumeDynamicFeeHook.ControllerParams memory p = _defaultControllerParams();
        p.minCloseVolToCashUsd6 = 100_000_000;
        p.upRToCashBps = 11_000;
        p.minCloseVolToExtremeUsd6 = 200_000_000;
        p.upRToExtremeBps = 15_000;
        p.upExtremeConfirmPeriods = 1;
        p.cashHoldPeriods = 2;
        p.extremeHoldPeriods = 2;

        vm.prank(owner);
        h.setControllerParams(p);

        vm.prank(owner);
        h.setTimingParams(PERIOD_SECONDS, EMA_PERIODS, LULL_RESET_SECONDS, DEADBAND_BPS);

        vm.prank(guardian);
        h.unpause();

        manager.callAfterInitialize(h, k);
        assertEq(h.currentFeeBips(), tiers[0]);

        manager.callAfterSwap(h, k, toBalanceDelta(-300_000_000, 0));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(h, k, toBalanceDelta(0, 0));

        manager.callAfterSwap(h, k, toBalanceDelta(-500_000_000, 0));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(h, k, toBalanceDelta(0, 0));

        (,,, uint8 feeIdx,) = h.unpackedState();
        assertEq(feeIdx, 1);
        assertEq(h.currentFeeBips(), tiers[1]);
    }
}
