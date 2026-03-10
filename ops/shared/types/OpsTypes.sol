// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

library OpsTypes {
    enum Runtime {
        Local,
        Sepolia
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
        address poolAddress;
        address volatileToken;
        address stableToken;
        address token0;
        address token1;
        uint8 stableDecimals;
        int24 tickSpacing;
        uint256 initPriceUsdE18;
        uint256 liqRangeMinUsdE18;
        uint256 liqRangeMaxUsdE18;
        uint256 maxSwapFractionBps;
        uint256 minEthBalanceWei;
        uint256 minStableBalanceRaw;
        uint256 minVolatileBalanceRaw;
        uint256 liquidityBudgetStableRaw;
        uint256 liquidityBudgetVolatileRaw;
        uint256 swapBudgetStableRaw;
        uint256 swapBudgetVolatileRaw;
        uint256 safetyBufferEthWei;
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
        uint256 minPriceUsdE18;
        uint256 maxPriceUsdE18;
        uint256 initPriceUsdE18;
        uint256 centeredPriceUsdE18;
        uint256 marginBps;
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
