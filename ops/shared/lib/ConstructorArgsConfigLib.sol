// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
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
            uint32 lullResetSeconds,
            address owner,
            uint16 hookFeePercent,
            uint64 floorToCashMinCloseVolume,
            uint16 floorToCashMinFlowBps,
            uint8 cashHoldPeriods,
            uint64 cashToExtremeMinCloseVolume,
            uint16 cashToExtremeMinFlowBps,
            uint8 cashToExtremeConfirmPeriods,
            uint8 extremeHoldPeriods,
            uint16 extremeToCashMaxFlowBps,
            uint8 extremeToCashConfirmPeriods,
            uint16 cashToFloorMaxFlowBps,
            uint8 cashToFloorConfirmPeriods,
            uint64 emergencyToFloorMaxCloseVolume,
            uint8 emergencyToFloorConfirmPeriods
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
        cfg.lullResetSeconds = lullResetSeconds;
        cfg.hookFeePercent = hookFeePercent;
        cfg.floorToCashMinCloseVolume = floorToCashMinCloseVolume;
        cfg.floorToCashMinFlowBps = floorToCashMinFlowBps;
        cfg.cashHoldPeriods = cashHoldPeriods;
        cfg.cashToExtremeMinCloseVolume = cashToExtremeMinCloseVolume;
        cfg.cashToExtremeMinFlowBps = cashToExtremeMinFlowBps;
        cfg.cashToExtremeConfirmPeriods = cashToExtremeConfirmPeriods;
        cfg.extremeHoldPeriods = extremeHoldPeriods;
        cfg.extremeToCashMaxFlowBps = extremeToCashMaxFlowBps;
        cfg.extremeToCashConfirmPeriods = extremeToCashConfirmPeriods;
        cfg.cashToFloorMaxFlowBps = cashToFloorMaxFlowBps;
        cfg.cashToFloorConfirmPeriods = cashToFloorConfirmPeriods;
        cfg.emergencyToFloorMaxCloseVolume = emergencyToFloorMaxCloseVolume;
        cfg.emergencyToFloorConfirmPeriods = emergencyToFloorConfirmPeriods;
    }
}
