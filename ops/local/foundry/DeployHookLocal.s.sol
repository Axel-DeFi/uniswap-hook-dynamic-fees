// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {HookValidationLib} from "../../shared/lib/HookValidationLib.sol";
import {NativeRecipientValidationLib} from "../../shared/lib/NativeRecipientValidationLib.sol";
import {JsonReportLib} from "../../shared/lib/JsonReportLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract DeployHookLocal is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        ConfigLoader.validateChainId(cfg.chainIdExpected);

        string memory statePath = vm.envOr(
            "OPS_LOCAL_STATE_PATH",
            string.concat(vm.projectRoot(), "/ops/local/out/state/local.addresses.json")
        );

        address hookAddress = cfg.hookAddress;
        if (hookAddress != address(0) && hookAddress.code.length > 0) {
            cfg.hookAddress = hookAddress;
            OpsTypes.HookValidation memory existing = HookValidationLib.validateHook(cfg);
            if (existing.ok) {
                address currentOwner = VolumeDynamicFeeHook(payable(hookAddress)).owner();
                (bool nativeRecipientOk, string memory nativeRecipientReason) = NativeRecipientValidationLib.validatePayoutRecipientForNativePool(
                    cfg.token0, cfg.token1, currentOwner, hookAddress
                );
                require(nativeRecipientOk, nativeRecipientReason);

                JsonReportLib.writeAddressState(
                    statePath, cfg.poolManager, hookAddress, cfg.volatileToken, cfg.stableToken
                );
                console2.log("reuse hook", hookAddress);
                return;
            }

            console2.log("existing hook invalid, deploying replacement", existing.reason);
        }

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        uint24 floorFee = uint24(vm.envUint("FLOOR_FEE_PIPS"));
        uint24 cashFee = uint24(vm.envUint("CASH_FEE_PIPS"));
        uint24 extremeFee = uint24(vm.envUint("EXTREME_FEE_PIPS"));
        require(
            floorFee > 0 && floorFee < cashFee && cashFee < extremeFee && extremeFee <= LPFeeLibrary.MAX_LP_FEE,
            "invalid fee bounds"
        );

        address owner = vm.envOr("OWNER", vm.addr(pk));
        uint16 hookFeePercent = uint16(vm.envUint("HOOK_FEE_PERCENT"));
        uint16 deadbandBps = uint16(vm.envUint("DEADBAND_BPS"));
        uint64 minCloseVolToCashUsd6 = uint64(vm.envUint("MIN_CLOSEVOL_TO_CASH_USD6"));
        uint8 cashHoldPeriods = uint8(vm.envUint("CASH_HOLD_PERIODS"));
        uint64 minCloseVolToExtremeUsd6 = uint64(vm.envUint("MIN_CLOSEVOL_TO_EXTREME_USD6"));
        uint8 extremeHoldPeriods = uint8(vm.envUint("EXTREME_HOLD_PERIODS"));
        uint16 downRFromExtremeBps = uint16(vm.envUint("DOWN_R_FROM_EXTREME_BPS"));
        uint16 downRFromCashBps = uint16(vm.envUint("DOWN_R_FROM_CASH_BPS"));
        uint64 emergencyFloorCloseVolUsd6 = uint64(vm.envUint("EMERGENCY_FLOOR_CLOSEVOL_USD6"));
        bool allowWeakHoldPeriods = vm.envOr("ALLOW_WEAK_HOLD_PERIODS", false);
        require(
            emergencyFloorCloseVolUsd6 > 0 && emergencyFloorCloseVolUsd6 < minCloseVolToCashUsd6,
            "invalid emergency floor threshold"
        );
        require(deadbandBps < downRFromExtremeBps && deadbandBps < downRFromCashBps, "invalid deadband thresholds");
        if ((cashHoldPeriods < 2 || extremeHoldPeriods < 2) && !allowWeakHoldPeriods) {
            console2.log(
                "warning: weak hold periods in local profile (set ALLOW_WEAK_HOLD_PERIODS=true to silence)"
            );
        }

        bytes memory constructorArgs = abi.encode(
            IPoolManager(cfg.poolManager),
            Currency.wrap(cfg.token0),
            Currency.wrap(cfg.token1),
            cfg.tickSpacing,
            Currency.wrap(cfg.stableToken),
            cfg.stableDecimals,
            floorFee,
            cashFee,
            extremeFee,
            uint32(vm.envUint("PERIOD_SECONDS")),
            uint8(vm.envUint("EMA_PERIODS")),
            deadbandBps,
            uint32(vm.envUint("LULL_RESET_SECONDS")),
            owner,
            hookFeePercent,
            minCloseVolToCashUsd6,
            uint16(vm.envUint("UP_R_TO_CASH_BPS")),
            cashHoldPeriods,
            minCloseVolToExtremeUsd6,
            uint16(vm.envUint("UP_R_TO_EXTREME_BPS")),
            uint8(vm.envUint("UP_EXTREME_CONFIRM_PERIODS")),
            extremeHoldPeriods,
            downRFromExtremeBps,
            uint8(vm.envUint("DOWN_EXTREME_CONFIRM_PERIODS")),
            downRFromCashBps,
            uint8(vm.envUint("DOWN_CASH_CONFIRM_PERIODS")),
            emergencyFloorCloseVolUsd6,
            uint8(vm.envUint("EMERGENCY_CONFIRM_PERIODS"))
        );

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address mined, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        (bool nativeRecipientOk, string memory nativeRecipientReason) = NativeRecipientValidationLib.validatePayoutRecipientForNativePool(
            cfg.token0, cfg.token1, owner, mined
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

        console2.log("hook deployed", mined);
    }
}
