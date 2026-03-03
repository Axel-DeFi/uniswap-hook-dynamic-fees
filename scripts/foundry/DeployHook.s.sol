// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

/// @notice Mines the hook address flags and deploys VolumeDynamicFeeHook via CREATE2.
/// @dev Environment variables are read from config/hook.<chain>.conf (dotenv-style).
///      Required:
///        - POOL_MANAGER
///        - VOLATILE, STABLE, STABLE_DECIMALS, TICK_SPACING
///        - FLOOR_IDX, CAP_IDX (derived by deploy_hook.sh from FLOOR_TIER/CAP_TIER)
///        - FEE_TIER_COUNT
///        - FEE_TIER_0 ... FEE_TIER_{N-1}
///        - PERIOD_SECONDS, EMA_PERIODS, DEADBAND_BPS, LULL_RESET_SECONDS
///        - GUARDIAN
///        - CREATOR_FEE_BPS (or CREATOR_FEE_PERCENT as fallback)
///        - Optional: CREATOR_FEE_ADDRESS (or legacy CREATOR)
contract DeployHook is Script {
    // Foundry deterministic CREATE2 deployer proxy used by forge scripts.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct DeployConfig {
        address poolManager;
        address volatileToken;
        address stableToken;
        int24 tickSpacing;
        uint8 stableDecimals;
        uint8 floorIdx;
        uint8 capIdx;
        uint24[] feeTiers;
        uint32 periodSeconds;
        uint8 emaPeriods;
        uint16 deadbandBps;
        uint32 lullResetSeconds;
        address guardian;
        address creator;
        uint16 creatorFeeBps;
    }

    function run() external {
        DeployConfig memory cfg = _loadConfig();

        // Canonical PoolKey ordering (currency0 < currency1) is enforced by address sort.
        (address token0, address token1) = _sort(cfg.volatileToken, cfg.stableToken);

        Currency c0 = Currency.wrap(token0);
        Currency c1 = Currency.wrap(token1);
        Currency usd = Currency.wrap(cfg.stableToken);

        // Hook must have flags encoded in its address.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );

        bytes memory constructorArgs = _constructorArgs(cfg, c0, c1, usd);

        (address minedHookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        vm.startBroadcast();
        VolumeDynamicFeeHook hook = new VolumeDynamicFeeHook{salt: salt}(
            IPoolManager(cfg.poolManager),
            c0,
            c1,
            cfg.tickSpacing,
            usd,
            cfg.stableDecimals,
            cfg.floorIdx,
            cfg.capIdx,
            cfg.feeTiers,
            cfg.periodSeconds,
            cfg.emaPeriods,
            cfg.deadbandBps,
            cfg.lullResetSeconds,
            cfg.guardian,
            cfg.creator,
            cfg.creatorFeeBps
        );
        vm.stopBroadcast();

        require(address(hook) == minedHookAddress, "DeployHook: hook address mismatch");

        console2.log("VolumeDynamicFeeHook deployed at:", address(hook));
        console2.log("Salt:", uint256(salt));
        console2.log("Flags:", flags);

        // Persist the deployed hook address for the next step (pool creation).
        string memory out = vm.serializeAddress("deploy", "hook", address(hook));
        vm.writeJson(out, vm.envOr("DEPLOY_JSON_PATH", string("out/deploy.json")));
    }

    function _sort(address a, address b) internal pure returns (address token0, address token1) {
        if (a < b) return (a, b);
        return (b, a);
    }

    function _loadConfig() internal view returns (DeployConfig memory cfg) {
        cfg.poolManager = vm.envAddress("POOL_MANAGER");
        cfg.volatileToken = vm.envAddress("VOLATILE");
        cfg.stableToken = vm.envAddress("STABLE");
        cfg.tickSpacing = int24(vm.envInt("TICK_SPACING"));
        cfg.stableDecimals = uint8(vm.envUint("STABLE_DECIMALS"));
        cfg.floorIdx = uint8(vm.envUint("FLOOR_IDX"));
        cfg.capIdx = uint8(vm.envUint("CAP_IDX"));
        uint256 tierCount = vm.envUint("FEE_TIER_COUNT");
        require(tierCount > 0 && tierCount <= type(uint8).max, "DeployHook: invalid FEE_TIER_COUNT");
        cfg.feeTiers = new uint24[](tierCount);
        for (uint256 i = 0; i < tierCount; ++i) {
            cfg.feeTiers[i] = uint24(vm.envUint(string.concat("FEE_TIER_", vm.toString(i))));
        }
        cfg.periodSeconds = uint32(vm.envUint("PERIOD_SECONDS"));
        cfg.emaPeriods = uint8(vm.envUint("EMA_PERIODS"));
        cfg.deadbandBps = uint16(vm.envUint("DEADBAND_BPS"));
        cfg.lullResetSeconds = uint32(vm.envUint("LULL_RESET_SECONDS"));
        cfg.guardian = vm.envAddress("GUARDIAN");
        cfg.creator = vm.envOr("CREATOR_FEE_ADDRESS", vm.envOr("CREATOR", cfg.guardian));
        cfg.creatorFeeBps = uint16(vm.envOr("CREATOR_FEE_BPS", vm.envUint("CREATOR_FEE_PERCENT") * 100));
    }

    function _constructorArgs(DeployConfig memory cfg, Currency c0, Currency c1, Currency usd)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            IPoolManager(cfg.poolManager),
            c0,
            c1,
            cfg.tickSpacing,
            usd,
            cfg.stableDecimals,
            cfg.floorIdx,
            cfg.capIdx,
            cfg.feeTiers,
            cfg.periodSeconds,
            cfg.emaPeriods,
            cfg.deadbandBps,
            cfg.lullResetSeconds,
            cfg.guardian,
            cfg.creator,
            cfg.creatorFeeBps
        );
    }
}
