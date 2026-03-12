// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {OpsTypes} from "../types/OpsTypes.sol";

library ConstructorArgsConfigLib {
    function toDeploymentConfig(bytes memory constructorArgs)
        internal
        pure
        returns (OpsTypes.DeploymentConfig memory cfg)
    {
        (
            address poolManager,
            address poolCurrency0,
            address poolCurrency1,
            int24 poolTickSpacing,
            address stableCurrency,
            uint8 stableDecimals,
            uint24 floorFeePips,
            uint24 cashFeePips,
            uint24 extremeFeePips,
            uint32 periodSeconds,
            uint8 emaPeriods,
            uint16 deadbandBps,
            uint32 lullResetSeconds,
            address owner,
            uint16 hookFeePercent,
            uint64 minCloseVolToCashUsd6,
            uint16 upRToCashBps,
            uint8 cashHoldPeriods,
            uint64 minCloseVolToExtremeUsd6,
            uint16 upRToExtremeBps,
            uint8 upExtremeConfirmPeriods,
            uint8 extremeHoldPeriods,
            uint16 downRFromExtremeBps,
            uint8 downExtremeConfirmPeriods,
            uint16 downRFromCashBps,
            uint8 downCashConfirmPeriods,
            uint64 emergencyFloorCloseVolUsd6,
            uint8 emergencyConfirmPeriods
        ) = abi.decode(
            constructorArgs,
            (
                address,
                address,
                address,
                int24,
                address,
                uint8,
                uint24,
                uint24,
                uint24,
                uint32,
                uint8,
                uint16,
                uint32,
                address,
                uint16,
                uint64,
                uint16,
                uint8,
                uint64,
                uint16,
                uint8,
                uint8,
                uint16,
                uint8,
                uint16,
                uint8,
                uint64,
                uint8
            )
        );

        cfg.poolManager = poolManager;
        cfg.owner = owner;
        cfg.stableToken = stableCurrency;
        cfg.token0 = poolCurrency0;
        cfg.token1 = poolCurrency1;
        cfg.stableDecimals = stableDecimals;
        cfg.tickSpacing = poolTickSpacing;
        cfg.floorFeePips = floorFeePips;
        cfg.cashFeePips = cashFeePips;
        cfg.extremeFeePips = extremeFeePips;
        cfg.periodSeconds = periodSeconds;
        cfg.emaPeriods = emaPeriods;
        cfg.deadbandBps = deadbandBps;
        cfg.lullResetSeconds = lullResetSeconds;
        cfg.hookFeePercent = hookFeePercent;
        cfg.minCloseVolToCashUsd6 = minCloseVolToCashUsd6;
        cfg.upRToCashBps = upRToCashBps;
        cfg.cashHoldPeriods = cashHoldPeriods;
        cfg.minCloseVolToExtremeUsd6 = minCloseVolToExtremeUsd6;
        cfg.upRToExtremeBps = upRToExtremeBps;
        cfg.upExtremeConfirmPeriods = upExtremeConfirmPeriods;
        cfg.extremeHoldPeriods = extremeHoldPeriods;
        cfg.downRFromExtremeBps = downRFromExtremeBps;
        cfg.downExtremeConfirmPeriods = downExtremeConfirmPeriods;
        cfg.downRFromCashBps = downRFromCashBps;
        cfg.downCashConfirmPeriods = downCashConfirmPeriods;
        cfg.emergencyFloorCloseVolUsd6 = emergencyFloorCloseVolUsd6;
        cfg.emergencyConfirmPeriods = emergencyConfirmPeriods;
    }
}
