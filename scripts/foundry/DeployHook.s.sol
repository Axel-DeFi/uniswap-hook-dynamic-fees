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
///        - INITIAL_FEE_IDX, FLOOR_IDX, CAP_IDX
///        - PERIOD_SECONDS, EMA_PERIODS, DEADBAND_BPS, LULL_RESET_SECONDS
///        - GUARDIAN, PAUSE_FEE_IDX
contract DeployHook is Script {
    // Foundry deterministic CREATE2 deployer proxy used by forge scripts.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");

        address volatileToken = vm.envAddress("VOLATILE");
        address stableToken = vm.envAddress("STABLE");

        int24 tickSpacing = int24(vm.envInt("TICK_SPACING"));
        uint8 stableDecimals = uint8(vm.envUint("STABLE_DECIMALS"));

        uint8 initialFeeIdx = uint8(vm.envUint("INITIAL_FEE_IDX"));
        uint8 floorIdx = uint8(vm.envUint("FLOOR_IDX"));
        uint8 capIdx = uint8(vm.envUint("CAP_IDX"));

        uint32 periodSeconds = uint32(vm.envUint("PERIOD_SECONDS"));
        uint8 emaPeriods = uint8(vm.envUint("EMA_PERIODS"));
        uint16 deadbandBps = uint16(vm.envUint("DEADBAND_BPS"));
        uint32 lullResetSeconds = uint32(vm.envUint("LULL_RESET_SECONDS"));
        address guardian = vm.envAddress("GUARDIAN");
        uint8 pauseFeeIdx = uint8(vm.envUint("PAUSE_FEE_IDX"));

        // Canonical PoolKey ordering (currency0 < currency1) is enforced by address sort.
        (address token0, address token1) = _sort(volatileToken, stableToken);

        Currency c0 = Currency.wrap(token0);
        Currency c1 = Currency.wrap(token1);
        Currency usd = Currency.wrap(stableToken);

        // Hook must have flags encoded in its address.
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManager),
            c0,
            c1,
            tickSpacing,
            usd,
            stableDecimals,
            initialFeeIdx,
            floorIdx,
            capIdx,
            periodSeconds,
            emaPeriods,
            deadbandBps,
            lullResetSeconds,
            guardian,
            pauseFeeIdx
        );

        (address minedHookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        vm.startBroadcast();
        VolumeDynamicFeeHook hook = new VolumeDynamicFeeHook{salt: salt}(
            IPoolManager(poolManager),
            c0,
            c1,
            tickSpacing,
            usd,
            stableDecimals,
            initialFeeIdx,
            floorIdx,
            capIdx,
            periodSeconds,
            emaPeriods,
            deadbandBps,
            lullResetSeconds,
            guardian,
            pauseFeeIdx
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
}
