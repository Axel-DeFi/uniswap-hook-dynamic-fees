// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {OpsTypes} from "../types/OpsTypes.sol";
import {Vm} from "forge-std/Vm.sol";

import {EnvLib} from "./EnvLib.sol";
import {ErrorLib} from "./ErrorLib.sol";

library ConfigLoader {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

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

        cfg.stableDecimals = uint8(EnvLib.requireUint("STABLE_DECIMALS"));
        if (cfg.stableDecimals != 6 && cfg.stableDecimals != 18) {
            revert ErrorLib.InvalidEnv("STABLE_DECIMALS", "must be 6 or 18");
        }

        cfg.tickSpacing = int24(int256(EnvLib.requireUint("TICK_SPACING")));
        if (cfg.tickSpacing <= 0) {
            revert ErrorLib.InvalidEnv("TICK_SPACING", "must be > 0");
        }

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

    function sortPair(address a, address b) internal pure returns (address token0, address token1) {
        if (a < b) {
            return (a, b);
        }
        return (b, a);
    }

    function _loadRuntime() private view returns (OpsTypes.Runtime runtime) {
        string memory raw = EnvLib.envOrString("OPS_RUNTIME", "local");
        bytes32 id = keccak256(bytes(_lower(raw)));
        if (id == keccak256("sepolia")) {
            return OpsTypes.Runtime.Sepolia;
        }
        return OpsTypes.Runtime.Local;
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
