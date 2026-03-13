// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

import {HookValidationLib} from "../../shared/lib/HookValidationLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "../utils/VolumeDynamicFeeHookV2DeployHelper.sol";

contract PermissionSurfaceHookMock {
    IPoolManager public poolManager;
    Currency public poolCurrency0;
    Currency public poolCurrency1;
    int24 public poolTickSpacing;
    Currency public stableCurrency;
    uint8 public stableDecimals;
    address public owner;
    uint16 public hookFeePercent;

    bool private immutable enableBeforeInitialize;

    constructor(
        IPoolManager poolManager_,
        Currency poolCurrency0_,
        Currency poolCurrency1_,
        int24 poolTickSpacing_,
        Currency stableCurrency_,
        uint8 stableDecimals_,
        address owner_,
        uint16 hookFeePercent_,
        bool enableBeforeInitialize_
    ) {
        poolManager = poolManager_;
        poolCurrency0 = poolCurrency0_;
        poolCurrency1 = poolCurrency1_;
        poolTickSpacing = poolTickSpacing_;
        stableCurrency = stableCurrency_;
        stableDecimals = stableDecimals_;
        owner = owner_;
        hookFeePercent = hookFeePercent_;
        enableBeforeInitialize = enableBeforeInitialize_;
    }

    function getHookPermissions() external view returns (Hooks.Permissions memory perms) {
        perms.beforeInitialize = enableBeforeInitialize;
        perms.afterInitialize = true;
        perms.afterSwap = true;
        perms.afterSwapReturnDelta = true;
    }

    function pendingOwner() external pure returns (address) {
        return address(0);
    }

    function minCountedSwapUsd6() external pure returns (uint64) {
        return 4_000_000;
    }

    function pendingHookFeePercentChange() external pure returns (bool, uint16, uint64) {
        return (false, 0, 0);
    }

    function pendingMinCountedSwapUsd6Change() external pure returns (bool, uint64) {
        return (false, 0);
    }

    function floorFee() external pure returns (uint24) {
        return 400;
    }

    function cashFee() external pure returns (uint24) {
        return 2_500;
    }

    function extremeFee() external pure returns (uint24) {
        return 9_000;
    }

    function periodSeconds() external pure returns (uint32) {
        return 300;
    }

    function emaPeriods() external pure returns (uint8) {
        return 8;
    }

    function deadbandBps() external pure returns (uint16) {
        return 500;
    }

    function lullResetSeconds() external pure returns (uint32) {
        return 3600;
    }

    function minCloseVolToCashUsd6() external pure returns (uint64) {
        return 1_000 * 1e6;
    }

    function upRToCashBps() external pure returns (uint16) {
        return 18_000;
    }

    function cashHoldPeriods() external pure returns (uint8) {
        return 4;
    }

    function minCloseVolToExtremeUsd6() external pure returns (uint64) {
        return 4_000 * 1e6;
    }

    function upRToExtremeBps() external pure returns (uint16) {
        return 40_000;
    }

    function upExtremeConfirmPeriods() external pure returns (uint8) {
        return 2;
    }

    function extremeHoldPeriods() external pure returns (uint8) {
        return 4;
    }

    function downRFromExtremeBps() external pure returns (uint16) {
        return 13_000;
    }

    function downExtremeConfirmPeriods() external pure returns (uint8) {
        return 2;
    }

    function downRFromCashBps() external pure returns (uint16) {
        return 13_000;
    }

    function downCashConfirmPeriods() external pure returns (uint8) {
        return 3;
    }

    function emergencyFloorCloseVolUsd6() external pure returns (uint64) {
        return 600 * 1e6;
    }

    function emergencyConfirmPeriods() external pure returns (uint8) {
        return 3;
    }
}

contract HookValidationHarness is VolumeDynamicFeeHook {
    constructor(
        IPoolManager _poolManager,
        Currency _poolCurrency0,
        Currency _poolCurrency1,
        int24 _poolTickSpacing,
        Currency _stableCurrency,
        uint8 stableDecimals_,
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
            stableDecimals_,
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

contract HookValidationLibTest is Test, VolumeDynamicFeeHookV2DeployHelper {
    MockPoolManager internal manager;

    address internal constant TOKEN0 = address(0x0000000000000000000000000000000000001111);
    address internal constant TOKEN1 = address(0x0000000000000000000000000000000000002222);
    int24 internal constant TICK_SPACING = 10;
    uint32 internal constant PERIOD_SECONDS = 300;
    uint32 internal constant LULL_RESET_SECONDS = 3600;
    uint8 internal constant EMA_PERIODS = 8;
    uint16 internal constant DEADBAND_BPS = 500;

    function setUp() public {
        manager = new MockPoolManager();
    }

    function test_validateHook_accepts_matching_runtime_config() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.CoreConfig memory cfg = _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertTrue(validation.ok);
        assertEq(validation.reason, "ok");
    }

    function test_validateHook_rejects_owner_mismatch() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.CoreConfig memory cfg = _matchingCfg(address(hook), address(0xBEEF), 6, V2_INITIAL_HOOK_FEE_PERCENT);

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook owner mismatch");
    }

    function test_validateHook_rejects_poolManager_mismatch() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.CoreConfig memory cfg = _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        cfg.poolManager = address(new MockPoolManager());

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook PoolManager mismatch");
    }

    function test_validateHook_rejects_pending_owner() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        hook.proposeNewOwner(address(0xBEEF));

        OpsTypes.CoreConfig memory cfg = _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook pending owner exists");
    }

    function test_validateHook_rejects_timing_config_mismatch() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.CoreConfig memory cfg = _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        cfg.periodSeconds = PERIOD_SECONDS + 1;

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook timing config mismatch");
    }

    function test_validateHook_rejects_stable_decimals_mode_mismatch() public {
        HookValidationHarness hook = _deploy(address(this), 18, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.CoreConfig memory cfg = _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook stable decimals mismatch");
    }

    function test_validateHook_rejects_minCountedSwap_mismatch() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.CoreConfig memory cfg = _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        cfg.minCountedSwapUsd6 = 1_500_000;

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook min counted swap mismatch");
    }

    function test_validateHook_rejects_pending_hookFee_percent_change() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        hook.scheduleHookFeePercentChange(0);

        OpsTypes.CoreConfig memory cfg = _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook pending HookFee percent change exists");
    }

    function test_validateHook_rejects_pending_minCountedSwap_change() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        hook.scheduleMinCountedSwapUsd6Change(1_500_000);

        OpsTypes.CoreConfig memory cfg = _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook pending min counted swap change exists");
    }

    function test_validateHook_rejects_extra_permission_surface() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(manager)),
            Currency.wrap(TOKEN0),
            Currency.wrap(TOKEN1),
            TICK_SPACING,
            Currency.wrap(TOKEN0),
            uint8(6),
            address(this),
            V2_INITIAL_HOOK_FEE_PERCENT,
            true
        );

        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(PermissionSurfaceHookMock).creationCode, constructorArgs);

        PermissionSurfaceHookMock hook = new PermissionSurfaceHookMock{salt: salt}(
            IPoolManager(address(manager)),
            Currency.wrap(TOKEN0),
            Currency.wrap(TOKEN1),
            TICK_SPACING,
            Currency.wrap(TOKEN0),
            6,
            address(this),
            V2_INITIAL_HOOK_FEE_PERCENT,
            true
        );

        assertEq(address(hook), expected);

        OpsTypes.CoreConfig memory cfg = _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook permissions mismatch");
    }

    function _deploy(address owner_, uint8 stableDecimals_, uint16 hookFeePercent_) internal returns (HookValidationHarness h) {
        bytes memory constructorArgs = _constructorArgsV2(
            IPoolManager(address(manager)),
            Currency.wrap(TOKEN0),
            Currency.wrap(TOKEN1),
            TICK_SPACING,
            Currency.wrap(TOKEN0),
            stableDecimals_,
            V2_DEFAULT_FLOOR_FEE,
            V2_DEFAULT_CASH_FEE,
            V2_DEFAULT_EXTREME_FEE,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            owner_,
            hookFeePercent_
        );

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (, bytes32 salt) =
            HookMiner.find(address(this), flags, type(HookValidationHarness).creationCode, constructorArgs);

        h = new HookValidationHarness{salt: salt}(
            IPoolManager(address(manager)),
            Currency.wrap(TOKEN0),
            Currency.wrap(TOKEN1),
            TICK_SPACING,
            Currency.wrap(TOKEN0),
            stableDecimals_,
            V2_DEFAULT_FLOOR_FEE,
            V2_DEFAULT_CASH_FEE,
            V2_DEFAULT_EXTREME_FEE,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            owner_,
            hookFeePercent_,
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

    function _matchingCfg(address hookAddr, address owner_, uint8 stableDecimals_, uint16 hookFeePercent_)
        internal
        view
        returns (OpsTypes.CoreConfig memory cfg)
    {
        cfg.runtime = OpsTypes.Runtime.Local;
        cfg.rpcUrl = "";
        cfg.chainIdExpected = block.chainid;
        cfg.broadcast = false;
        cfg.privateKey = 0;
        cfg.deployer = address(this);
        cfg.poolManager = address(manager);
        cfg.hookAddress = hookAddr;
        cfg.poolAddress = address(0);
        cfg.owner = owner_;
        cfg.volatileToken = TOKEN1;
        cfg.stableToken = TOKEN0;
        cfg.token0 = TOKEN0;
        cfg.token1 = TOKEN1;
        cfg.stableDecimals = stableDecimals_;
        cfg.tickSpacing = TICK_SPACING;
        cfg.floorFeePips = V2_DEFAULT_FLOOR_FEE;
        cfg.cashFeePips = V2_DEFAULT_CASH_FEE;
        cfg.extremeFeePips = V2_DEFAULT_EXTREME_FEE;
        cfg.periodSeconds = PERIOD_SECONDS;
        cfg.emaPeriods = EMA_PERIODS;
        cfg.deadbandBps = DEADBAND_BPS;
        cfg.lullResetSeconds = LULL_RESET_SECONDS;
        cfg.hookFeePercent = hookFeePercent_;
        cfg.minCountedSwapUsd6 = 4_000_000;
        cfg.minCloseVolToCashUsd6 = V2_MIN_CLOSEVOL_TO_CASH_USD6;
        cfg.upRToCashBps = V2_UP_R_TO_CASH_BPS;
        cfg.cashHoldPeriods = V2_CASH_HOLD_PERIODS;
        cfg.minCloseVolToExtremeUsd6 = V2_MIN_CLOSEVOL_TO_EXTREME_USD6;
        cfg.upRToExtremeBps = V2_UP_R_TO_EXTREME_BPS;
        cfg.upExtremeConfirmPeriods = V2_UP_EXTREME_CONFIRM_PERIODS;
        cfg.extremeHoldPeriods = V2_EXTREME_HOLD_PERIODS;
        cfg.downRFromExtremeBps = V2_DOWN_R_FROM_EXTREME_BPS;
        cfg.downExtremeConfirmPeriods = V2_DOWN_EXTREME_CONFIRM_PERIODS;
        cfg.downRFromCashBps = V2_DOWN_R_FROM_CASH_BPS;
        cfg.downCashConfirmPeriods = V2_DOWN_CASH_CONFIRM_PERIODS;
        cfg.emergencyFloorCloseVolUsd6 = V2_EMERGENCY_FLOOR_CLOSEVOL_USD6;
        cfg.emergencyConfirmPeriods = V2_EMERGENCY_CONFIRM_PERIODS;
    }
}
