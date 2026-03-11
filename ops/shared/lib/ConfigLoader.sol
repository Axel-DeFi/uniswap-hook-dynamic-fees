// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {OpsTypes} from "../types/OpsTypes.sol";
import {Vm} from "forge-std/Vm.sol";

import {EnvLib} from "./EnvLib.sol";
import {ErrorLib} from "./ErrorLib.sol";

library ConfigLoader {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint64 internal constant DEFAULT_MIN_COUNTED_SWAP_USD6 = 4_000_000;

    function loadCoreConfig() internal view returns (OpsTypes.CoreConfig memory cfg) {
        cfg.runtime = _loadRuntime();
        cfg.rpcUrl = EnvLib.envOrString("RPC_URL", "");
        cfg.chainIdExpected = EnvLib.envOrUint("CHAIN_ID_EXPECTED", block.chainid);
        cfg.broadcast = EnvLib.envOrBool("OPS_BROADCAST", false);

        cfg.privateKey = EnvLib.envOrUint("PRIVATE_KEY", 0);
        if (cfg.privateKey != 0) {
            cfg.deployer = vm.addr(cfg.privateKey);
        } else {
            cfg.deployer = EnvLib.envOrAddress("DEPLOYER", address(0));
        }

        cfg.poolManager = EnvLib.requireAddress("POOL_MANAGER", false);
        cfg.hookAddress = EnvLib.envOrAddress("HOOK_ADDRESS", address(0));
        cfg.poolAddress = EnvLib.envOrAddress("POOL_ADDRESS", address(0));

        cfg.volatileToken = EnvLib.requireAddress("VOLATILE", true);
        cfg.stableToken = EnvLib.requireAddress("STABLE", false);
        if (cfg.stableToken == cfg.volatileToken) {
            revert ErrorLib.InvalidEnv("VOLATILE/STABLE", "tokens must differ");
        }

        (cfg.token0, cfg.token1) = sortPair(cfg.volatileToken, cfg.stableToken);

        cfg.stableDecimals = EnvLib.requireUint8("STABLE_DECIMALS");
        if (cfg.stableDecimals != 6 && cfg.stableDecimals != 18) {
            revert ErrorLib.InvalidEnv("STABLE_DECIMALS", "must be 6 or 18");
        }

        cfg.tickSpacing = EnvLib.toPositiveInt24Checked(EnvLib.requireUint("TICK_SPACING"), "TICK_SPACING");
        if (cfg.tickSpacing <= 0) {
            revert ErrorLib.InvalidEnv("TICK_SPACING", "must be > 0");
        }

        cfg.owner = EnvLib.envOrAddress("OWNER", cfg.deployer);
        if (cfg.owner == address(0)) {
            revert ErrorLib.InvalidEnv("OWNER", "zero address");
        }

        cfg.floorFeePips = EnvLib.requireUint24("FLOOR_FEE_PIPS");
        cfg.cashFeePips = EnvLib.requireUint24("CASH_FEE_PIPS");
        cfg.extremeFeePips = EnvLib.requireUint24("EXTREME_FEE_PIPS");
        cfg.periodSeconds = EnvLib.requireUint32("PERIOD_SECONDS");
        cfg.emaPeriods = EnvLib.requireUint8("EMA_PERIODS");
        cfg.deadbandBps = EnvLib.requireUint16("DEADBAND_BPS");
        cfg.lullResetSeconds = EnvLib.requireUint32("LULL_RESET_SECONDS");
        cfg.hookFeePercent = EnvLib.requireUint16("HOOK_FEE_PERCENT");
        cfg.minCountedSwapUsd6 =
            EnvLib.envOrUint64("MIN_COUNTED_SWAP_USD6", DEFAULT_MIN_COUNTED_SWAP_USD6);
        if (cfg.minCountedSwapUsd6 < 1_000_000 || cfg.minCountedSwapUsd6 > 10_000_000) {
            revert ErrorLib.InvalidEnv("MIN_COUNTED_SWAP_USD6", "must be in 1000000..10000000");
        }
        cfg.minCloseVolToCashUsd6 = EnvLib.requireUint64("MIN_CLOSEVOL_TO_CASH_USD6");
        cfg.upRToCashBps = EnvLib.requireUint16("UP_R_TO_CASH_BPS");
        cfg.cashHoldPeriods = EnvLib.requireUint8("CASH_HOLD_PERIODS");
        cfg.minCloseVolToExtremeUsd6 = EnvLib.requireUint64("MIN_CLOSEVOL_TO_EXTREME_USD6");
        cfg.upRToExtremeBps = EnvLib.requireUint16("UP_R_TO_EXTREME_BPS");
        cfg.upExtremeConfirmPeriods = EnvLib.requireUint8("UP_EXTREME_CONFIRM_PERIODS");
        cfg.extremeHoldPeriods = EnvLib.requireUint8("EXTREME_HOLD_PERIODS");
        cfg.downRFromExtremeBps = EnvLib.requireUint16("DOWN_R_FROM_EXTREME_BPS");
        cfg.downExtremeConfirmPeriods = EnvLib.requireUint8("DOWN_EXTREME_CONFIRM_PERIODS");
        cfg.downRFromCashBps = EnvLib.requireUint16("DOWN_R_FROM_CASH_BPS");
        cfg.downCashConfirmPeriods = EnvLib.requireUint8("DOWN_CASH_CONFIRM_PERIODS");
        cfg.emergencyFloorCloseVolUsd6 = EnvLib.requireUint64("EMERGENCY_FLOOR_CLOSEVOL_USD6");
        cfg.emergencyConfirmPeriods = EnvLib.requireUint8("EMERGENCY_CONFIRM_PERIODS");

        cfg.initPriceUsdE18 = EnvLib.envOrDecimalE18("INIT_PRICE_USD", 0);
        cfg.liqRangeMinUsdE18 = EnvLib.envOrDecimalE18("LIQ_RANGE_MIN_USD", 0);
        cfg.liqRangeMaxUsdE18 = EnvLib.envOrDecimalE18("LIQ_RANGE_MAX_USD", 0);

        cfg.maxSwapFractionBps = EnvLib.envOrUint("MAX_SWAP_FRACTION_BPS", 1_500);
        if (cfg.maxSwapFractionBps == 0 || cfg.maxSwapFractionBps > 10_000) {
            revert ErrorLib.InvalidEnv("MAX_SWAP_FRACTION_BPS", "must be in 1..10000");
        }

        cfg.minEthBalanceWei = EnvLib.envOrUint("BUDGET_MIN_ETH_WEI", 0);
        cfg.minStableBalanceRaw = EnvLib.envOrUint("BUDGET_MIN_STABLE_RAW", 0);
        cfg.minVolatileBalanceRaw = EnvLib.envOrUint("BUDGET_MIN_VOLATILE_RAW", 0);

        cfg.liquidityBudgetStableRaw = EnvLib.envOrUint("BUDGET_LIQ_STABLE_RAW", 0);
        cfg.liquidityBudgetVolatileRaw = EnvLib.envOrUint("BUDGET_LIQ_VOLATILE_RAW", 0);
        cfg.swapBudgetStableRaw = EnvLib.envOrUint("BUDGET_SWAP_STABLE_RAW", 0);
        cfg.swapBudgetVolatileRaw = EnvLib.envOrUint("BUDGET_SWAP_VOLATILE_RAW", 0);
        cfg.safetyBufferEthWei = EnvLib.envOrUint("BUDGET_SAFETY_BUFFER_ETH_WEI", 0);
    }

    function validateChainId(uint256 expectedChainId) internal view {
        if (expectedChainId != block.chainid) {
            revert ErrorLib.ChainIdMismatch(expectedChainId, block.chainid);
        }
    }

    function loadDeploymentConfig(OpsTypes.CoreConfig memory runtimeCfg)
        internal
        view
        returns (OpsTypes.DeploymentConfig memory cfg)
    {
        bool strict = runtimeCfg.runtime == OpsTypes.Runtime.Live;

        cfg.poolManager = runtimeCfg.poolManager;
        cfg.token0 = runtimeCfg.token0;
        cfg.token1 = runtimeCfg.token1;
        cfg.tickSpacing = runtimeCfg.tickSpacing;
        cfg.stableToken = runtimeCfg.stableToken;
        cfg.stableDecimals = runtimeCfg.stableDecimals;

        cfg.owner = strict
            ? EnvLib.requireAddress("DEPLOY_OWNER", false)
            : EnvLib.envOrAddress("DEPLOY_OWNER", runtimeCfg.owner);
        cfg.floorFeePips = strict
            ? EnvLib.requireUint24("DEPLOY_FLOOR_FEE_PIPS")
            : EnvLib.envOrUint24("DEPLOY_FLOOR_FEE_PIPS", runtimeCfg.floorFeePips);
        cfg.cashFeePips = strict
            ? EnvLib.requireUint24("DEPLOY_CASH_FEE_PIPS")
            : EnvLib.envOrUint24("DEPLOY_CASH_FEE_PIPS", runtimeCfg.cashFeePips);
        cfg.extremeFeePips = strict
            ? EnvLib.requireUint24("DEPLOY_EXTREME_FEE_PIPS")
            : EnvLib.envOrUint24("DEPLOY_EXTREME_FEE_PIPS", runtimeCfg.extremeFeePips);
        cfg.periodSeconds = strict
            ? EnvLib.requireUint32("DEPLOY_PERIOD_SECONDS")
            : EnvLib.envOrUint32("DEPLOY_PERIOD_SECONDS", runtimeCfg.periodSeconds);
        cfg.emaPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_EMA_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_EMA_PERIODS", runtimeCfg.emaPeriods);
        cfg.deadbandBps = strict
            ? EnvLib.requireUint16("DEPLOY_DEADBAND_BPS")
            : EnvLib.envOrUint16("DEPLOY_DEADBAND_BPS", runtimeCfg.deadbandBps);
        cfg.lullResetSeconds = strict
            ? EnvLib.requireUint32("DEPLOY_LULL_RESET_SECONDS")
            : EnvLib.envOrUint32("DEPLOY_LULL_RESET_SECONDS", runtimeCfg.lullResetSeconds);
        cfg.hookFeePercent = strict
            ? EnvLib.requireUint16("DEPLOY_HOOK_FEE_PERCENT")
            : EnvLib.envOrUint16("DEPLOY_HOOK_FEE_PERCENT", runtimeCfg.hookFeePercent);
        cfg.minCloseVolToCashUsd6 = strict
            ? EnvLib.requireUint64("DEPLOY_MIN_CLOSEVOL_TO_CASH_USD6")
            : EnvLib.envOrUint64("DEPLOY_MIN_CLOSEVOL_TO_CASH_USD6", runtimeCfg.minCloseVolToCashUsd6);
        cfg.upRToCashBps = strict
            ? EnvLib.requireUint16("DEPLOY_UP_R_TO_CASH_BPS")
            : EnvLib.envOrUint16("DEPLOY_UP_R_TO_CASH_BPS", runtimeCfg.upRToCashBps);
        cfg.cashHoldPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_CASH_HOLD_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_CASH_HOLD_PERIODS", runtimeCfg.cashHoldPeriods);
        cfg.minCloseVolToExtremeUsd6 = strict
            ? EnvLib.requireUint64("DEPLOY_MIN_CLOSEVOL_TO_EXTREME_USD6")
            : EnvLib.envOrUint64("DEPLOY_MIN_CLOSEVOL_TO_EXTREME_USD6", runtimeCfg.minCloseVolToExtremeUsd6);
        cfg.upRToExtremeBps = strict
            ? EnvLib.requireUint16("DEPLOY_UP_R_TO_EXTREME_BPS")
            : EnvLib.envOrUint16("DEPLOY_UP_R_TO_EXTREME_BPS", runtimeCfg.upRToExtremeBps);
        cfg.upExtremeConfirmPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_UP_EXTREME_CONFIRM_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_UP_EXTREME_CONFIRM_PERIODS", runtimeCfg.upExtremeConfirmPeriods);
        cfg.extremeHoldPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_EXTREME_HOLD_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_EXTREME_HOLD_PERIODS", runtimeCfg.extremeHoldPeriods);
        cfg.downRFromExtremeBps = strict
            ? EnvLib.requireUint16("DEPLOY_DOWN_R_FROM_EXTREME_BPS")
            : EnvLib.envOrUint16("DEPLOY_DOWN_R_FROM_EXTREME_BPS", runtimeCfg.downRFromExtremeBps);
        cfg.downExtremeConfirmPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_DOWN_EXTREME_CONFIRM_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_DOWN_EXTREME_CONFIRM_PERIODS", runtimeCfg.downExtremeConfirmPeriods);
        cfg.downRFromCashBps = strict
            ? EnvLib.requireUint16("DEPLOY_DOWN_R_FROM_CASH_BPS")
            : EnvLib.envOrUint16("DEPLOY_DOWN_R_FROM_CASH_BPS", runtimeCfg.downRFromCashBps);
        cfg.downCashConfirmPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_DOWN_CASH_CONFIRM_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_DOWN_CASH_CONFIRM_PERIODS", runtimeCfg.downCashConfirmPeriods);
        cfg.emergencyFloorCloseVolUsd6 = strict
            ? EnvLib.requireUint64("DEPLOY_EMERGENCY_FLOOR_CLOSEVOL_USD6")
            : EnvLib.envOrUint64("DEPLOY_EMERGENCY_FLOOR_CLOSEVOL_USD6", runtimeCfg.emergencyFloorCloseVolUsd6);
        cfg.emergencyConfirmPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_EMERGENCY_CONFIRM_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_EMERGENCY_CONFIRM_PERIODS", runtimeCfg.emergencyConfirmPeriods);
    }

    function sortPair(address a, address b) internal pure returns (address token0, address token1) {
        if (a < b) {
            return (a, b);
        }
        return (b, a);
    }

    function _loadRuntime() private view returns (OpsTypes.Runtime runtime) {
        string memory raw = EnvLib.envOrString("OPS_RUNTIME", "local");
        bytes32 id = keccak256(bytes(_lower(raw)));
        if (id == keccak256("local")) {
            return OpsTypes.Runtime.Local;
        }
        return OpsTypes.Runtime.Live;
    }

    function _lower(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) {
                b[i] = bytes1(uint8(b[i]) + 32);
            }
        }
        return string(b);
    }
}
