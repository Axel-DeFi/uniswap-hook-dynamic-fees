// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {BudgetLib} from "../../shared/lib/BudgetLib.sol";
import {HookValidationLib} from "../../shared/lib/HookValidationLib.sol";
import {NativeRecipientValidationLib} from "../../shared/lib/NativeRecipientValidationLib.sol";
import {JsonReportLib} from "../../shared/lib/JsonReportLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract EnsureHookSepolia is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        LoggingLib.phase("sepolia.ensure-hook");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        ConfigLoader.validateChainId(cfg.chainIdExpected);

        string memory statePath = vm.envOr(
            "OPS_SEPOLIA_STATE_PATH",
            string.concat(vm.projectRoot(), "/ops/sepolia/out/state/sepolia.addresses.json")
        );

        if (cfg.hookAddress != address(0) && cfg.hookAddress.code.length > 0) {
            OpsTypes.HookValidation memory existing = HookValidationLib.validateHook(cfg);
            if (existing.ok) {
                address currentRecipient = VolumeDynamicFeeHook(payable(cfg.hookAddress)).hookFeeRecipient();
                (bool nativeRecipientOk, string memory nativeRecipientReason) = NativeRecipientValidationLib.validateHookFeeRecipientForNativePool(
                    cfg.token0, cfg.token1, currentRecipient, cfg.hookAddress
                );
                require(nativeRecipientOk, nativeRecipientReason);

                JsonReportLib.writeAddressState(
                    statePath, cfg.poolManager, cfg.hookAddress, cfg.volatileToken, cfg.stableToken
                );
                LoggingLib.ok("reuse existing hook");
                return;
            }

            LoggingLib.fail(string.concat("existing hook invalid: ", existing.reason));
            LoggingLib.ok("deploying replacement hook");
        }

        OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        require(budget.ok, budget.reason);

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        uint24[] memory feeTiers = _loadFeeTiers();
        uint8 floorIdx = uint8(vm.envUint("FLOOR_IDX"));
        uint8 cashIdx = uint8(vm.envUint("CASH_IDX"));
        uint8 extremeIdx = uint8(vm.envUint("EXTREME_IDX"));
        require(
            floorIdx < feeTiers.length && cashIdx < feeTiers.length && extremeIdx < feeTiers.length,
            "tier index out of range"
        );
        require(floorIdx < cashIdx && cashIdx < extremeIdx, "invalid tier order");

        uint24 cashTier = feeTiers[cashIdx];
        uint24 extremeTier = feeTiers[extremeIdx];

        address owner = vm.envOr("OWNER", vm.addr(pk));
        uint16 hookFeePercent = uint16(vm.envUint("HOOK_FEE_PERCENT"));
        address hookFeeRecipient = vm.envOr("HOOK_FEE_ADDRESS", owner);
        require(hookFeeRecipient != address(0), "HOOK_FEE_ADDRESS invalid");

        bytes memory constructorArgs = abi.encode(
            IPoolManager(cfg.poolManager),
            Currency.wrap(cfg.token0),
            Currency.wrap(cfg.token1),
            cfg.tickSpacing,
            Currency.wrap(cfg.stableToken),
            cfg.stableDecimals,
            floorIdx,
            feeTiers,
            uint32(vm.envUint("PERIOD_SECONDS")),
            uint8(vm.envUint("EMA_PERIODS")),
            uint16(vm.envUint("DEADBAND_BPS")),
            uint32(vm.envUint("LULL_RESET_SECONDS")),
            owner,
            hookFeeRecipient,
            hookFeePercent,
            cashTier,
            uint64(vm.envUint("MIN_CLOSEVOL_TO_CASH_USD6")),
            uint16(vm.envUint("UP_R_TO_CASH_BPS")),
            uint8(vm.envUint("CASH_HOLD_PERIODS")),
            extremeTier,
            uint64(vm.envUint("MIN_CLOSEVOL_TO_EXTREME_USD6")),
            uint16(vm.envUint("UP_R_TO_EXTREME_BPS")),
            uint8(vm.envUint("UP_EXTREME_CONFIRM_PERIODS")),
            uint8(vm.envUint("EXTREME_HOLD_PERIODS")),
            uint16(vm.envUint("DOWN_R_FROM_EXTREME_BPS")),
            uint8(vm.envUint("DOWN_EXTREME_CONFIRM_PERIODS")),
            uint16(vm.envUint("DOWN_R_FROM_CASH_BPS")),
            uint8(vm.envUint("DOWN_CASH_CONFIRM_PERIODS")),
            uint64(vm.envUint("EMERGENCY_FLOOR_CLOSEVOL_USD6")),
            uint8(vm.envUint("EMERGENCY_CONFIRM_PERIODS"))
        );

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address mined, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        (bool nativeRecipientOk, string memory nativeRecipientReason) = NativeRecipientValidationLib.validateHookFeeRecipientForNativePool(
            cfg.token0, cfg.token1, hookFeeRecipient, mined
        );
        require(nativeRecipientOk, nativeRecipientReason);

        vm.startBroadcast(pk);
        bytes memory creationCodeWithArgs =
            abi.encodePacked(type(VolumeDynamicFeeHook).creationCode, constructorArgs);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, creationCodeWithArgs));
        vm.stopBroadcast();

        require(ok, "create2 deploy failed");
        require(mined.code.length > 0, "hook code missing");

        cfg.hookAddress = mined;
        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        require(validation.ok, validation.reason);

        JsonReportLib.writeAddressState(statePath, cfg.poolManager, mined, cfg.volatileToken, cfg.stableToken);

        LoggingLib.ok("hook deployed");
    }

    function _loadFeeTiers() private view returns (uint24[] memory tiers) {
        uint256[] memory raw = vm.envUint("FEE_TIERS_PIPS", ",");
        require(raw.length > 1, "FEE_TIERS_PIPS requires >=2 tiers");

        tiers = new uint24[](raw.length);
        uint24 prev = 0;
        for (uint256 i = 0; i < raw.length; i++) {
            require(raw[i] > 0 && raw[i] <= type(uint24).max, "tier out of range");
            uint24 tier = uint24(raw[i]);
            if (i > 0) require(tier > prev, "tiers must increase");
            tiers[i] = tier;
            prev = tier;
        }
    }
}
