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

    function minCountedSwapVolume() external pure returns (uint64) {
        return 4_000_000;
    }

    function pendingHookFeePercentChange() external pure returns (bool, uint16, uint64) {
        return (false, 0, 0);
    }

    function pendingMinCountedSwapVolumeChange() external pure returns (bool, uint64) {
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

    function lullResetSeconds() external pure returns (uint32) {
        return 3600;
    }

    function floorToCashMinCloseVolume() external pure returns (uint64) {
        return 400 * 1e6;
    }

    function floorToCashMinFlowBps() external pure returns (uint16) {
        return 13_500;
    }

    function cashHoldPeriods() external pure returns (uint8) {
        return 4;
    }

    function cashToExtremeMinCloseVolume() external pure returns (uint64) {
        return 2_500 * 1e6;
    }

    function cashToExtremeMinFlowBps() external pure returns (uint16) {
        return 41_000;
    }

    function cashToExtremeConfirmPeriods() external pure returns (uint8) {
        return 2;
    }

    function extremeHoldPeriods() external pure returns (uint8) {
        return 4;
    }

    function extremeToCashMaxFlowBps() external pure returns (uint16) {
        return 12_000;
    }

    function extremeToCashConfirmPeriods() external pure returns (uint8) {
        return 2;
    }

    function cashToFloorMaxFlowBps() external pure returns (uint16) {
        return 12_000;
    }

    function cashToFloorConfirmPeriods() external pure returns (uint8) {
        return 3;
    }

    function emergencyToFloorMaxCloseVolume() external pure returns (uint64) {
        return 100 * 1e6;
    }

    function emergencyToFloorConfirmPeriods() external pure returns (uint8) {
        return 6;
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
        uint32 _lullResetSeconds,
        address ownerAddr,
        uint16 hookFeePercent,
        uint64 _floorToCashMinCloseVolume,
        uint16 _floorToCashMinFlowBps,
        uint8 _cashHoldPeriods,
        uint64 _cashToExtremeMinCloseVolume,
        uint16 _cashToExtremeMinFlowBps,
        uint8 _cashToExtremeConfirmPeriods,
        uint8 _extremeHoldPeriods,
        uint16 _extremeToCashMaxFlowBps,
        uint8 _extremeToCashConfirmPeriods,
        uint16 _cashToFloorMaxFlowBps,
        uint8 _cashToFloorConfirmPeriods,
        uint64 _emergencyToFloorMaxCloseVolume,
        uint8 _emergencyToFloorConfirmPeriods
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
            _lullResetSeconds,
            ownerAddr,
            hookFeePercent,
            _floorToCashMinCloseVolume,
            _floorToCashMinFlowBps,
            _cashHoldPeriods,
            _cashToExtremeMinCloseVolume,
            _cashToExtremeMinFlowBps,
            _cashToExtremeConfirmPeriods,
            _extremeHoldPeriods,
            _extremeToCashMaxFlowBps,
            _extremeToCashConfirmPeriods,
            _cashToFloorMaxFlowBps,
            _cashToFloorConfirmPeriods,
            _emergencyToFloorMaxCloseVolume,
            _emergencyToFloorConfirmPeriods
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

    function setUp() public {
        manager = new MockPoolManager();
    }

    function test_validateHook_accepts_matching_runtime_config() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.CoreConfig memory cfg =
            _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertTrue(validation.ok);
        assertEq(validation.reason, "ok");
    }

    function test_validateHook_rejects_owner_mismatch() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.CoreConfig memory cfg =
            _matchingCfg(address(hook), address(0xBEEF), 6, V2_INITIAL_HOOK_FEE_PERCENT);

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook owner mismatch");
    }

    function test_validateHook_rejects_poolManager_mismatch() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.CoreConfig memory cfg =
            _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        cfg.poolManager = address(new MockPoolManager());

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook PoolManager mismatch");
    }

    function test_validateHook_rejects_pending_owner() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        hook.proposeNewOwner(address(0xBEEF));

        OpsTypes.CoreConfig memory cfg =
            _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook pending owner exists");
    }

    function test_validateHook_rejects_timing_config_mismatch() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.CoreConfig memory cfg =
            _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        cfg.periodSeconds = PERIOD_SECONDS + 1;

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook timing config mismatch");
    }

    function test_validateHook_rejects_stable_decimals_mode_mismatch() public {
        HookValidationHarness hook = _deploy(address(this), 18, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.CoreConfig memory cfg =
            _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook stable decimals mismatch");
    }

    function test_validateHook_rejects_minCountedSwap_mismatch() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.CoreConfig memory cfg =
            _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        cfg.minCountedSwapVolume = 1_500_000;

        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook min counted swap mismatch");
    }

    function test_validateHook_rejects_pending_hookFee_percent_change() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        hook.scheduleHookFeePercentChange(0);

        OpsTypes.CoreConfig memory cfg =
            _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook pending HookFee percent change exists");
    }

    function test_validateHook_rejects_pending_minCountedSwap_change() public {
        HookValidationHarness hook = _deploy(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        hook.scheduleMinCountedSwapVolumeChange(1_500_000);

        OpsTypes.CoreConfig memory cfg =
            _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
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

        (address expected, bytes32 salt) = HookMiner.find(
            address(this), flags, type(PermissionSurfaceHookMock).creationCode, constructorArgs
        );

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

        OpsTypes.CoreConfig memory cfg =
            _matchingCfg(address(hook), address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        assertFalse(validation.ok);
        assertEq(validation.reason, "hook permissions mismatch");
    }

    function _deploy(address owner_, uint8 stableDecimals_, uint16 hookFeePercent_)
        internal
        returns (HookValidationHarness h)
    {
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
            LULL_RESET_SECONDS,
            owner_,
            hookFeePercent_,
            V2_FLOOR_TO_CASH_MIN_CLOSE_VOLUME,
            V2_FLOOR_TO_CASH_MIN_FLOW_BPS,
            V2_CASH_HOLD_PERIODS,
            V2_CASH_TO_EXTREME_MIN_CLOSE_VOLUME,
            V2_CASH_TO_EXTREME_MIN_FLOW_BPS,
            V2_CASH_TO_EXTREME_CONFIRM_PERIODS,
            V2_EXTREME_HOLD_PERIODS,
            V2_EXTREME_TO_CASH_MAX_FLOW_BPS,
            V2_EXTREME_TO_CASH_CONFIRM_PERIODS,
            V2_CASH_TO_FLOOR_MAX_FLOW_BPS,
            V2_CASH_TO_FLOOR_CONFIRM_PERIODS,
            V2_EMERGENCY_TO_FLOOR_MAX_CLOSE_VOLUME,
            V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS
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
        cfg.poolId = bytes32(0);
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
        cfg.lullResetSeconds = LULL_RESET_SECONDS;
        cfg.hookFeePercent = hookFeePercent_;
        cfg.minCountedSwapVolume = 4_000_000;
        cfg.floorToCashMinCloseVolume = V2_FLOOR_TO_CASH_MIN_CLOSE_VOLUME;
        cfg.floorToCashMinFlowBps = V2_FLOOR_TO_CASH_MIN_FLOW_BPS;
        cfg.cashHoldPeriods = V2_CASH_HOLD_PERIODS;
        cfg.cashToExtremeMinCloseVolume = V2_CASH_TO_EXTREME_MIN_CLOSE_VOLUME;
        cfg.cashToExtremeMinFlowBps = V2_CASH_TO_EXTREME_MIN_FLOW_BPS;
        cfg.cashToExtremeConfirmPeriods = V2_CASH_TO_EXTREME_CONFIRM_PERIODS;
        cfg.extremeHoldPeriods = V2_EXTREME_HOLD_PERIODS;
        cfg.extremeToCashMaxFlowBps = V2_EXTREME_TO_CASH_MAX_FLOW_BPS;
        cfg.extremeToCashConfirmPeriods = V2_EXTREME_TO_CASH_CONFIRM_PERIODS;
        cfg.cashToFloorMaxFlowBps = V2_CASH_TO_FLOOR_MAX_FLOW_BPS;
        cfg.cashToFloorConfirmPeriods = V2_CASH_TO_FLOOR_CONFIRM_PERIODS;
        cfg.emergencyToFloorMaxCloseVolume = V2_EMERGENCY_TO_FLOOR_MAX_CLOSE_VOLUME;
        cfg.emergencyToFloorConfirmPeriods = V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS;
    }
}
