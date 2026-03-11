// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ConstructorArgsConfigLib} from "../../shared/lib/ConstructorArgsConfigLib.sol";
import {HookIdentityLib} from "../../shared/lib/HookIdentityLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "../utils/VolumeDynamicFeeHookV2DeployHelper.sol";

contract ConstructorArgsConfigLibTest is Test, VolumeDynamicFeeHookV2DeployHelper {
    address internal constant TOKEN0 = address(0x0000000000000000000000000000000000001111);
    address internal constant TOKEN1 = address(0x0000000000000000000000000000000000002222);
    int24 internal constant TICK_SPACING = 10;
    uint32 internal constant PERIOD_SECONDS = 300;
    uint32 internal constant LULL_RESET_SECONDS = 3600;
    uint8 internal constant EMA_PERIODS = 8;
    uint16 internal constant DEADBAND_BPS = 500;

    MockPoolManager internal manager;

    function setUp() public {
        manager = new MockPoolManager();
    }

    function test_toCoreConfig_roundTrips_constructor_identity() public view {
        OpsTypes.CoreConfig memory original = _cfg(address(this), 18, V2_INITIAL_HOOK_FEE_PERCENT);
        bytes memory args = HookIdentityLib.constructorArgs(original);

        OpsTypes.CoreConfig memory decoded = ConstructorArgsConfigLib.toCoreConfig(args);

        assertEq(decoded.poolManager, original.poolManager);
        assertEq(decoded.owner, original.owner);
        assertEq(decoded.volatileToken, original.volatileToken);
        assertEq(decoded.stableToken, original.stableToken);
        assertEq(decoded.token0, original.token0);
        assertEq(decoded.token1, original.token1);
        assertEq(decoded.stableDecimals, original.stableDecimals);
        assertEq(decoded.tickSpacing, original.tickSpacing);
        assertEq(decoded.floorFeePips, original.floorFeePips);
        assertEq(decoded.cashFeePips, original.cashFeePips);
        assertEq(decoded.extremeFeePips, original.extremeFeePips);
        assertEq(decoded.periodSeconds, original.periodSeconds);
        assertEq(decoded.emaPeriods, original.emaPeriods);
        assertEq(decoded.deadbandBps, original.deadbandBps);
        assertEq(decoded.lullResetSeconds, original.lullResetSeconds);
        assertEq(decoded.hookFeePercent, original.hookFeePercent);
        assertEq(decoded.minCountedSwapUsd6, 4_000_000);
        assertEq(decoded.minCloseVolToCashUsd6, original.minCloseVolToCashUsd6);
        assertEq(decoded.upRToCashBps, original.upRToCashBps);
        assertEq(decoded.cashHoldPeriods, original.cashHoldPeriods);
        assertEq(decoded.minCloseVolToExtremeUsd6, original.minCloseVolToExtremeUsd6);
        assertEq(decoded.upRToExtremeBps, original.upRToExtremeBps);
        assertEq(decoded.upExtremeConfirmPeriods, original.upExtremeConfirmPeriods);
        assertEq(decoded.extremeHoldPeriods, original.extremeHoldPeriods);
        assertEq(decoded.downRFromExtremeBps, original.downRFromExtremeBps);
        assertEq(decoded.downExtremeConfirmPeriods, original.downExtremeConfirmPeriods);
        assertEq(decoded.downRFromCashBps, original.downRFromCashBps);
        assertEq(decoded.downCashConfirmPeriods, original.downCashConfirmPeriods);
        assertEq(decoded.emergencyFloorCloseVolUsd6, original.emergencyFloorCloseVolUsd6);
        assertEq(decoded.emergencyConfirmPeriods, original.emergencyConfirmPeriods);
    }

    function test_toCoreConfig_preserves_canonical_hook_address() public view {
        OpsTypes.CoreConfig memory original = _cfg(address(0xBEEF), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        bytes memory args = HookIdentityLib.constructorArgs(original);
        OpsTypes.CoreConfig memory decoded = ConstructorArgsConfigLib.toCoreConfig(args);

        (address originalHook,,) = HookIdentityLib.expectedHookAddress(original);
        (address decodedHook,,) = HookIdentityLib.expectedHookAddress(decoded);

        assertEq(decodedHook, originalHook);
    }

    function _cfg(address owner_, uint8 stableDecimals_, uint16 hookFeePercent_)
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
        cfg.hookAddress = address(0);
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
