// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
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

        cfg.poolManager = _requireAddressEither("POOL_MANAGER", "DEPLOY_POOL_MANAGER", false);
        cfg.hookAddress = EnvLib.envOrAddress("HOOK_ADDRESS", address(0));
        cfg.poolAddress = EnvLib.envOrAddress("POOL_ADDRESS", address(0));

        cfg.volatileToken = _requireAddressEither("VOLATILE", "DEPLOY_VOLATILE", true);
        cfg.stableToken = _requireAddressEither("STABLE", "DEPLOY_STABLE", false);
        if (cfg.stableToken == cfg.volatileToken) {
            revert ErrorLib.InvalidEnv("VOLATILE/STABLE", "tokens must differ");
        }

        (cfg.token0, cfg.token1) = sortPair(cfg.volatileToken, cfg.stableToken);

        cfg.stableDecimals = _requireUint8Either("STABLE_DECIMALS", "DEPLOY_STABLE_DECIMALS");
        if (cfg.stableDecimals != 6 && cfg.stableDecimals != 18) {
            revert ErrorLib.InvalidEnv("STABLE_DECIMALS", "must be 6 or 18");
        }

        cfg.tickSpacing = _requirePositiveInt24Either("TICK_SPACING", "DEPLOY_TICK_SPACING");
        if (cfg.tickSpacing <= 0) {
            revert ErrorLib.InvalidEnv("TICK_SPACING", "must be > 0");
        }

        cfg.owner = EnvLib.hasKey("OWNER")
            ? EnvLib.requireAddress("OWNER", false)
            : EnvLib.hasKey("DEPLOY_OWNER") ? EnvLib.requireAddress("DEPLOY_OWNER", false) : cfg.deployer;
        if (cfg.owner == address(0)) {
            revert ErrorLib.InvalidEnv("OWNER", "zero address");
        }

        cfg.floorFeePips = _requirePipsFromPercentEither("FLOOR_FEE_PERCENT", "DEPLOY_FLOOR_FEE_PERCENT");
        cfg.cashFeePips = _requirePipsFromPercentEither("CASH_FEE_PERCENT", "DEPLOY_CASH_FEE_PERCENT");
        cfg.extremeFeePips =
            _requirePipsFromPercentEither("EXTREME_FEE_PERCENT", "DEPLOY_EXTREME_FEE_PERCENT");
        cfg.periodSeconds = _requireUint32Either("PERIOD_SECONDS", "DEPLOY_PERIOD_SECONDS");
        cfg.emaPeriods = _requireUint8Either("EMA_PERIODS", "DEPLOY_EMA_PERIODS");
        cfg.lullResetSeconds = _requireUint32Either("LULL_RESET_SECONDS", "DEPLOY_LULL_RESET_SECONDS");
        cfg.hookFeePercent = _requireUint16Either("HOOK_FEE_PERCENT", "DEPLOY_HOOK_FEE_PERCENT");
        cfg.minCountedSwapUsd6 = EnvLib.envOrUint64("MIN_COUNTED_SWAP_USD6", DEFAULT_MIN_COUNTED_SWAP_USD6);
        if (cfg.minCountedSwapUsd6 < 1_000_000 || cfg.minCountedSwapUsd6 > 10_000_000) {
            revert ErrorLib.InvalidEnv("MIN_COUNTED_SWAP_USD6", "must be in 1000000..10000000");
        }
        cfg.minCloseVolToCashUsd6 =
            _requireUsd6FromUsdEither("MIN_VOLUME_TO_ENTER_CASH_USD", "DEPLOY_MIN_VOLUME_TO_ENTER_CASH_USD");
        cfg.cashEnterTriggerBps =
            _requireBpsFromMultiplierXEither("CASH_ENTER_TRIGGER_EMA_X", "DEPLOY_CASH_ENTER_TRIGGER_EMA_X");
        cfg.cashHoldPeriods = _requireUint8Either("CASH_HOLD_PERIODS", "DEPLOY_CASH_HOLD_PERIODS");
        cfg.minCloseVolToExtremeUsd6 = _requireUsd6FromUsdEither(
            "MIN_VOLUME_TO_ENTER_EXTREME_USD", "DEPLOY_MIN_VOLUME_TO_ENTER_EXTREME_USD"
        );
        cfg.extremeEnterTriggerBps = _requireBpsFromMultiplierXEither(
            "EXTREME_ENTER_TRIGGER_EMA_X", "DEPLOY_EXTREME_ENTER_TRIGGER_EMA_X"
        );
        cfg.upExtremeConfirmPeriods =
            _requireUint8Either("ENTER_EXTREME_CONFIRM_PERIODS", "DEPLOY_ENTER_EXTREME_CONFIRM_PERIODS");
        cfg.extremeHoldPeriods = _requireUint8Either("EXTREME_HOLD_PERIODS", "DEPLOY_EXTREME_HOLD_PERIODS");
        cfg.extremeExitTriggerBps = _requireBpsFromMultiplierXEither(
            "EXTREME_EXIT_TRIGGER_EMA_X", "DEPLOY_EXTREME_EXIT_TRIGGER_EMA_X"
        );
        cfg.downExtremeConfirmPeriods =
            _requireUint8Either("EXIT_EXTREME_CONFIRM_PERIODS", "DEPLOY_EXIT_EXTREME_CONFIRM_PERIODS");
        cfg.cashExitTriggerBps =
            _requireBpsFromMultiplierXEither("CASH_EXIT_TRIGGER_EMA_X", "DEPLOY_CASH_EXIT_TRIGGER_EMA_X");
        cfg.downCashConfirmPeriods =
            _requireUint8Either("EXIT_CASH_CONFIRM_PERIODS", "DEPLOY_EXIT_CASH_CONFIRM_PERIODS");
        cfg.emergencyFloorCloseVolUsd6 =
            _requireUsd6FromUsdEither("EMERGENCY_FLOOR_TRIGGER_USD", "DEPLOY_EMERGENCY_FLOOR_TRIGGER_USD");
        cfg.emergencyConfirmPeriods =
            _requireUint8Either("EMERGENCY_CONFIRM_PERIODS", "DEPLOY_EMERGENCY_CONFIRM_PERIODS");

        cfg.initPriceUsdE18 = EnvLib.envOrDecimalE18("INIT_PRICE_USD", 0);

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

        cfg.poolManager = strict
            ? EnvLib.requireAddress("DEPLOY_POOL_MANAGER", false)
            : EnvLib.envOrAddress("DEPLOY_POOL_MANAGER", runtimeCfg.poolManager);

        address deployVolatile = strict
            ? EnvLib.requireAddress("DEPLOY_VOLATILE", true)
            : EnvLib.envOrAddress("DEPLOY_VOLATILE", runtimeCfg.volatileToken);
        cfg.stableToken = strict
            ? EnvLib.requireAddress("DEPLOY_STABLE", false)
            : EnvLib.envOrAddress("DEPLOY_STABLE", runtimeCfg.stableToken);
        if (deployVolatile == cfg.stableToken) {
            revert ErrorLib.InvalidEnv("DEPLOY_VOLATILE/DEPLOY_STABLE", "tokens must differ");
        }
        (cfg.token0, cfg.token1) = sortPair(deployVolatile, cfg.stableToken);

        cfg.stableDecimals = strict
            ? EnvLib.requireUint8("DEPLOY_STABLE_DECIMALS")
            : EnvLib.envOrUint8("DEPLOY_STABLE_DECIMALS", runtimeCfg.stableDecimals);
        if (cfg.stableDecimals != 6 && cfg.stableDecimals != 18) {
            revert ErrorLib.InvalidEnv("DEPLOY_STABLE_DECIMALS", "must be 6 or 18");
        }

        cfg.tickSpacing = strict
            ? EnvLib.requirePositiveInt24("DEPLOY_TICK_SPACING")
            : EnvLib.envOrPositiveInt24("DEPLOY_TICK_SPACING", runtimeCfg.tickSpacing);
        if (cfg.tickSpacing <= 0) {
            revert ErrorLib.InvalidEnv("DEPLOY_TICK_SPACING", "must be > 0");
        }

        cfg.owner = strict
            ? EnvLib.requireAddress("DEPLOY_OWNER", false)
            : EnvLib.envOrAddress("DEPLOY_OWNER", runtimeCfg.owner);
        cfg.floorFeePips = strict
            ? EnvLib.requirePipsFromPercent("DEPLOY_FLOOR_FEE_PERCENT")
            : EnvLib.envOrPipsFromPercent("DEPLOY_FLOOR_FEE_PERCENT", runtimeCfg.floorFeePips);
        cfg.cashFeePips = strict
            ? EnvLib.requirePipsFromPercent("DEPLOY_CASH_FEE_PERCENT")
            : EnvLib.envOrPipsFromPercent("DEPLOY_CASH_FEE_PERCENT", runtimeCfg.cashFeePips);
        cfg.extremeFeePips = strict
            ? EnvLib.requirePipsFromPercent("DEPLOY_EXTREME_FEE_PERCENT")
            : EnvLib.envOrPipsFromPercent("DEPLOY_EXTREME_FEE_PERCENT", runtimeCfg.extremeFeePips);
        cfg.periodSeconds = strict
            ? EnvLib.requireUint32("DEPLOY_PERIOD_SECONDS")
            : EnvLib.envOrUint32("DEPLOY_PERIOD_SECONDS", runtimeCfg.periodSeconds);
        cfg.emaPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_EMA_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_EMA_PERIODS", runtimeCfg.emaPeriods);
        cfg.lullResetSeconds = strict
            ? EnvLib.requireUint32("DEPLOY_LULL_RESET_SECONDS")
            : EnvLib.envOrUint32("DEPLOY_LULL_RESET_SECONDS", runtimeCfg.lullResetSeconds);
        cfg.hookFeePercent = strict
            ? EnvLib.requireUint16("DEPLOY_HOOK_FEE_PERCENT")
            : EnvLib.envOrUint16("DEPLOY_HOOK_FEE_PERCENT", runtimeCfg.hookFeePercent);
        cfg.minCloseVolToCashUsd6 = strict
            ? EnvLib.requireUsd6FromUsd("DEPLOY_MIN_VOLUME_TO_ENTER_CASH_USD")
            : EnvLib.envOrUsd6FromUsd("DEPLOY_MIN_VOLUME_TO_ENTER_CASH_USD", runtimeCfg.minCloseVolToCashUsd6);
        cfg.cashEnterTriggerBps = strict
            ? EnvLib.requireBpsFromMultiplierX("DEPLOY_CASH_ENTER_TRIGGER_EMA_X")
            : EnvLib.envOrBpsFromMultiplierX(
                    "DEPLOY_CASH_ENTER_TRIGGER_EMA_X", runtimeCfg.cashEnterTriggerBps
                );
        cfg.cashHoldPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_CASH_HOLD_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_CASH_HOLD_PERIODS", runtimeCfg.cashHoldPeriods);
        cfg.minCloseVolToExtremeUsd6 = strict
            ? EnvLib.requireUsd6FromUsd("DEPLOY_MIN_VOLUME_TO_ENTER_EXTREME_USD")
            : EnvLib.envOrUsd6FromUsd(
                "DEPLOY_MIN_VOLUME_TO_ENTER_EXTREME_USD", runtimeCfg.minCloseVolToExtremeUsd6
            );
        cfg.extremeEnterTriggerBps = strict
            ? EnvLib.requireBpsFromMultiplierX("DEPLOY_EXTREME_ENTER_TRIGGER_EMA_X")
            : EnvLib.envOrBpsFromMultiplierX(
                "DEPLOY_EXTREME_ENTER_TRIGGER_EMA_X", runtimeCfg.extremeEnterTriggerBps
            );
        cfg.upExtremeConfirmPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_ENTER_EXTREME_CONFIRM_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_ENTER_EXTREME_CONFIRM_PERIODS", runtimeCfg.upExtremeConfirmPeriods);
        cfg.extremeHoldPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_EXTREME_HOLD_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_EXTREME_HOLD_PERIODS", runtimeCfg.extremeHoldPeriods);
        cfg.extremeExitTriggerBps = strict
            ? EnvLib.requireBpsFromMultiplierX("DEPLOY_EXTREME_EXIT_TRIGGER_EMA_X")
            : EnvLib.envOrBpsFromMultiplierX(
                "DEPLOY_EXTREME_EXIT_TRIGGER_EMA_X", runtimeCfg.extremeExitTriggerBps
            );
        cfg.downExtremeConfirmPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_EXIT_EXTREME_CONFIRM_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_EXIT_EXTREME_CONFIRM_PERIODS", runtimeCfg.downExtremeConfirmPeriods);
        cfg.cashExitTriggerBps = strict
            ? EnvLib.requireBpsFromMultiplierX("DEPLOY_CASH_EXIT_TRIGGER_EMA_X")
            : EnvLib.envOrBpsFromMultiplierX("DEPLOY_CASH_EXIT_TRIGGER_EMA_X", runtimeCfg.cashExitTriggerBps);
        cfg.downCashConfirmPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_EXIT_CASH_CONFIRM_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_EXIT_CASH_CONFIRM_PERIODS", runtimeCfg.downCashConfirmPeriods);
        cfg.emergencyFloorCloseVolUsd6 = strict
            ? EnvLib.requireUsd6FromUsd("DEPLOY_EMERGENCY_FLOOR_TRIGGER_USD")
            : EnvLib.envOrUsd6FromUsd(
                "DEPLOY_EMERGENCY_FLOOR_TRIGGER_USD", runtimeCfg.emergencyFloorCloseVolUsd6
            );
        cfg.emergencyConfirmPeriods = strict
            ? EnvLib.requireUint8("DEPLOY_EMERGENCY_CONFIRM_PERIODS")
            : EnvLib.envOrUint8("DEPLOY_EMERGENCY_CONFIRM_PERIODS", runtimeCfg.emergencyConfirmPeriods);
    }

    function requireDeploymentBindingConsistency(
        OpsTypes.CoreConfig memory runtimeCfg,
        OpsTypes.DeploymentConfig memory deployCfg
    ) internal pure {
        if (runtimeCfg.poolManager != deployCfg.poolManager) {
            revert ErrorLib.InvalidEnv("POOL_MANAGER", "must match DEPLOY_POOL_MANAGER");
        }
        if (runtimeCfg.token0 != deployCfg.token0 || runtimeCfg.token1 != deployCfg.token1) {
            revert ErrorLib.InvalidEnv("VOLATILE/STABLE", "must match DEPLOY_VOLATILE/DEPLOY_STABLE");
        }
        if (runtimeCfg.stableToken != deployCfg.stableToken) {
            revert ErrorLib.InvalidEnv("STABLE", "must match DEPLOY_STABLE");
        }
        if (runtimeCfg.stableDecimals != deployCfg.stableDecimals) {
            revert ErrorLib.InvalidEnv("STABLE_DECIMALS", "must match DEPLOY_STABLE_DECIMALS");
        }
        if (runtimeCfg.tickSpacing != deployCfg.tickSpacing) {
            revert ErrorLib.InvalidEnv("TICK_SPACING", "must match DEPLOY_TICK_SPACING");
        }
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

    function _requireAddressEither(string memory key, string memory fallbackKey, bool allowZero)
        private
        view
        returns (address)
    {
        if (EnvLib.hasKey(key)) return EnvLib.requireAddress(key, allowZero);
        if (EnvLib.hasKey(fallbackKey)) return EnvLib.requireAddress(fallbackKey, allowZero);
        revert ErrorLib.MissingEnv(key);
    }

    function _requireUint8Either(string memory key, string memory fallbackKey) private view returns (uint8) {
        if (EnvLib.hasKey(key)) return EnvLib.requireUint8(key);
        if (EnvLib.hasKey(fallbackKey)) return EnvLib.requireUint8(fallbackKey);
        revert ErrorLib.MissingEnv(key);
    }

    function _requireUint16Either(string memory key, string memory fallbackKey)
        private
        view
        returns (uint16)
    {
        if (EnvLib.hasKey(key)) return EnvLib.requireUint16(key);
        if (EnvLib.hasKey(fallbackKey)) return EnvLib.requireUint16(fallbackKey);
        revert ErrorLib.MissingEnv(key);
    }

    function _requireUint32Either(string memory key, string memory fallbackKey)
        private
        view
        returns (uint32)
    {
        if (EnvLib.hasKey(key)) return EnvLib.requireUint32(key);
        if (EnvLib.hasKey(fallbackKey)) return EnvLib.requireUint32(fallbackKey);
        revert ErrorLib.MissingEnv(key);
    }

    function _requirePositiveInt24Either(string memory key, string memory fallbackKey)
        private
        view
        returns (int24)
    {
        if (EnvLib.hasKey(key)) return EnvLib.requirePositiveInt24(key);
        if (EnvLib.hasKey(fallbackKey)) return EnvLib.requirePositiveInt24(fallbackKey);
        revert ErrorLib.MissingEnv(key);
    }

    function _requirePipsFromPercentEither(string memory key, string memory fallbackKey)
        private
        view
        returns (uint24)
    {
        if (EnvLib.hasKey(key)) return EnvLib.requirePipsFromPercent(key);
        if (EnvLib.hasKey(fallbackKey)) return EnvLib.requirePipsFromPercent(fallbackKey);
        revert ErrorLib.MissingEnv(key);
    }

    function _requireUsd6FromUsdEither(string memory key, string memory fallbackKey)
        private
        view
        returns (uint64)
    {
        if (EnvLib.hasKey(key)) return EnvLib.requireUsd6FromUsd(key);
        if (EnvLib.hasKey(fallbackKey)) return EnvLib.requireUsd6FromUsd(fallbackKey);
        revert ErrorLib.MissingEnv(key);
    }

    function _requireBpsFromMultiplierXEither(string memory key, string memory fallbackKey)
        private
        view
        returns (uint16)
    {
        if (EnvLib.hasKey(key)) return EnvLib.requireBpsFromMultiplierX(key);
        if (EnvLib.hasKey(fallbackKey)) return EnvLib.requireBpsFromMultiplierX(fallbackKey);
        revert ErrorLib.MissingEnv(key);
    }
}
