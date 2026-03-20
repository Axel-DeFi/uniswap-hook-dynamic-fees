// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

library OpsTypes {
    enum Runtime {
        Local,
        Live
    }

    struct CoreConfig {
        Runtime runtime;
        string rpcUrl;
        uint256 chainIdExpected;
        bool broadcast;
        uint256 privateKey;
        address deployer;
        address poolManager;
        address hookAddress;
        bytes32 poolId;
        address owner;
        address volatileToken;
        address stableToken;
        address token0;
        address token1;
        uint8 stableDecimals;
        int24 tickSpacing;
        uint24 floorFeePips;
        uint24 cashFeePips;
        uint24 extremeFeePips;
        uint32 periodSeconds;
        uint8 emaPeriods;
        uint32 lullResetSeconds;
        uint16 hookFeePercent;
        uint64 minCountedSwapUsd6;
        uint64 minCloseVolToCashUsd6;
        uint16 cashEnterTriggerBps;
        uint8 cashHoldPeriods;
        uint64 minCloseVolToExtremeUsd6;
        uint16 extremeEnterTriggerBps;
        uint8 upExtremeConfirmPeriods;
        uint8 extremeHoldPeriods;
        uint16 extremeExitTriggerBps;
        uint8 downExtremeConfirmPeriods;
        uint16 cashExitTriggerBps;
        uint8 downCashConfirmPeriods;
        uint64 emergencyFloorCloseVolUsd6;
        uint8 emergencyConfirmPeriods;
        uint256 initPriceUsdE18;
        uint256 minEthBalanceWei;
        uint256 minStableBalanceRaw;
        uint256 minVolatileBalanceRaw;
        uint256 liquidityBudgetStableRaw;
        uint256 liquidityBudgetVolatileRaw;
        uint256 swapBudgetStableRaw;
        uint256 swapBudgetVolatileRaw;
        uint256 safetyBufferEthWei;
    }

    struct DeploymentConfig {
        address poolManager;
        address token0;
        address token1;
        int24 tickSpacing;
        address stableToken;
        uint8 stableDecimals;
        address owner;
        uint24 floorFeePips;
        uint24 cashFeePips;
        uint24 extremeFeePips;
        uint32 periodSeconds;
        uint8 emaPeriods;
        uint32 lullResetSeconds;
        uint16 hookFeePercent;
        uint64 minCloseVolToCashUsd6;
        uint16 cashEnterTriggerBps;
        uint8 cashHoldPeriods;
        uint64 minCloseVolToExtremeUsd6;
        uint16 extremeEnterTriggerBps;
        uint8 upExtremeConfirmPeriods;
        uint8 extremeHoldPeriods;
        uint16 extremeExitTriggerBps;
        uint8 downExtremeConfirmPeriods;
        uint16 cashExitTriggerBps;
        uint8 downCashConfirmPeriods;
        uint64 emergencyFloorCloseVolUsd6;
        uint8 emergencyConfirmPeriods;
    }

    struct BalanceSnapshot {
        uint256 ethWei;
        uint256 stableRaw;
        uint256 volatileRaw;
    }

    struct BudgetCheck {
        bool ok;
        string reason;
        uint256 requiredEthWei;
        uint256 requiredStableRaw;
        uint256 requiredVolatileRaw;
        BalanceSnapshot snapshot;
    }

    struct RangeCheck {
        bool ok;
        string reason;
        uint256 initPriceUsdE18;
        uint256 maxSwapStableRaw;
    }

    struct PoolSnapshot {
        bool initialized;
        bool paused;
        uint64 periodVolUsd6;
        uint96 emaVolUsd6Scaled;
        uint64 periodStart;
        uint8 feeIdx;
        uint24 currentFeeBips;
        uint24 floorFeeBips;
        uint24 cashFeeBips;
        uint24 extremeFeeBips;
    }

    struct HookValidation {
        bool ok;
        string reason;
        uint256 codeSize;
        bool permissionFlagsMatch;
        bool poolBindingMatch;
        bool stableInPool;
    }

    struct TokenValidation {
        bool ok;
        string reason;
        bool volatileOk;
        bool stableOk;
        uint8 stableDecimalsExpected;
        uint8 stableDecimalsOnchain;
    }
}
