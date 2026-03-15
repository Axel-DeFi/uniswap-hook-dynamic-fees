// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

import {HookIdentityLib} from "../../shared/lib/HookIdentityLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "../utils/VolumeDynamicFeeHookV2DeployHelper.sol";

contract HookIdentityHarness {
    function expectedHookAddress(OpsTypes.DeploymentConfig memory cfg)
        external
        pure
        returns (address hookAddress, bytes32 salt, bytes memory args)
    {
        return HookIdentityLib.expectedHookAddress(cfg);
    }
}

contract HookIdentityLibTest is Test, VolumeDynamicFeeHookV2DeployHelper {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant TOKEN0 = address(0x0000000000000000000000000000000000001111);
    address internal constant TOKEN1 = address(0x0000000000000000000000000000000000002222);
    int24 internal constant TICK_SPACING = 10;
    uint32 internal constant PERIOD_SECONDS = 300;
    uint32 internal constant LULL_RESET_SECONDS = 3600;
    uint8 internal constant EMA_PERIODS = 8;

    MockPoolManager internal manager;
    HookIdentityHarness internal harness;

    function setUp() public {
        manager = new MockPoolManager();
        harness = new HookIdentityHarness();
    }

    function test_expectedHookAddress_is_stable_even_if_canonical_address_has_code() public {
        OpsTypes.DeploymentConfig memory cfg = _cfg(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);

        (address expectedHookAddress, bytes32 expectedSalt, bytes memory constructorArgs) =
            harness.expectedHookAddress(cfg);

        uint160 expectedFlags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        assertEq(uint160(expectedHookAddress) & Hooks.ALL_HOOK_MASK, expectedFlags);

        (address minedBefore, bytes32 minedSaltBefore) = HookMiner.find(
            CREATE2_DEPLOYER, expectedFlags, type(VolumeDynamicFeeHook).creationCode, constructorArgs
        );
        assertEq(minedBefore, expectedHookAddress);
        assertEq(minedSaltBefore, expectedSalt);

        vm.etch(expectedHookAddress, hex"00");

        (address stableHookAddress, bytes32 stableSalt,) = harness.expectedHookAddress(cfg);
        assertEq(stableHookAddress, expectedHookAddress);
        assertEq(stableSalt, expectedSalt);
    }

    function test_expectedHookAddress_changes_when_constructor_identity_changes() public view {
        OpsTypes.DeploymentConfig memory cfgA = _cfg(address(this), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        OpsTypes.DeploymentConfig memory cfgB = _cfg(address(0xBEEF), 6, V2_INITIAL_HOOK_FEE_PERCENT);

        (address hookA,,) = harness.expectedHookAddress(cfgA);
        (address hookB,,) = harness.expectedHookAddress(cfgB);

        assertTrue(hookA != hookB);
    }

    function _cfg(address owner_, uint8 stableDecimals_, uint16 hookFeePercent_)
        internal
        view
        returns (OpsTypes.DeploymentConfig memory cfg)
    {
        cfg.poolManager = address(manager);
        cfg.owner = owner_;
        cfg.token0 = TOKEN0;
        cfg.token1 = TOKEN1;
        cfg.stableToken = TOKEN0;
        cfg.stableDecimals = stableDecimals_;
        cfg.tickSpacing = TICK_SPACING;
        cfg.floorFeePips = V2_DEFAULT_FLOOR_FEE;
        cfg.cashFeePips = V2_DEFAULT_CASH_FEE;
        cfg.extremeFeePips = V2_DEFAULT_EXTREME_FEE;
        cfg.periodSeconds = PERIOD_SECONDS;
        cfg.emaPeriods = EMA_PERIODS;
        cfg.lullResetSeconds = LULL_RESET_SECONDS;
        cfg.hookFeePercent = hookFeePercent_;
        cfg.minCloseVolToCashUsd6 = V2_MIN_VOLUME_TO_ENTER_CASH_USD6;
        cfg.cashEnterTriggerBps = V2_CASH_ENTER_TRIGGER_BPS;
        cfg.cashHoldPeriods = V2_CASH_HOLD_PERIODS;
        cfg.minCloseVolToExtremeUsd6 = V2_MIN_VOLUME_TO_ENTER_EXTREME_USD6;
        cfg.extremeEnterTriggerBps = V2_EXTREME_ENTER_TRIGGER_BPS;
        cfg.upExtremeConfirmPeriods = V2_UP_EXTREME_CONFIRM_PERIODS;
        cfg.extremeHoldPeriods = V2_EXTREME_HOLD_PERIODS;
        cfg.extremeExitTriggerBps = V2_EXTREME_EXIT_TRIGGER_BPS;
        cfg.downExtremeConfirmPeriods = V2_DOWN_EXTREME_CONFIRM_PERIODS;
        cfg.cashExitTriggerBps = V2_CASH_EXIT_TRIGGER_BPS;
        cfg.downCashConfirmPeriods = V2_DOWN_CASH_CONFIRM_PERIODS;
        cfg.emergencyFloorCloseVolUsd6 = V2_EMERGENCY_FLOOR_TRIGGER_USD6;
        cfg.emergencyConfirmPeriods = V2_EMERGENCY_CONFIRM_PERIODS;
    }
}
