// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {BudgetLib} from "../../shared/lib/BudgetLib.sol";
import {HookIdentityLib} from "../../shared/lib/HookIdentityLib.sol";
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

        address configuredHookAddress = cfg.hookAddress;
        (address canonicalHookAddress, bytes32 canonicalSalt, bytes memory constructorArgs) =
            HookIdentityLib.expectedHookAddress(cfg);

        if (configuredHookAddress != address(0) && configuredHookAddress != canonicalHookAddress) {
            LoggingLib.fail("configured HOOK_ADDRESS is non-canonical; ignoring configured address");
            LoggingLib.infoAddress("[ops] configured hook", configuredHookAddress);
            LoggingLib.infoAddress("[ops] canonical hook", canonicalHookAddress);
        }

        if (canonicalHookAddress.code.length > 0) {
            cfg.hookAddress = canonicalHookAddress;
            OpsTypes.HookValidation memory existing = HookValidationLib.validateHook(cfg);
            if (existing.ok) {
                address currentOwner = VolumeDynamicFeeHook(payable(canonicalHookAddress)).owner();
                (bool reuseNativeRecipientOk, string memory reuseNativeRecipientReason) = NativeRecipientValidationLib.validatePayoutRecipientForNativePool(
                    cfg.token0, cfg.token1, currentOwner, cfg.poolManager
                );
                require(reuseNativeRecipientOk, reuseNativeRecipientReason);

                JsonReportLib.writeAddressState(
                    statePath, cfg.poolManager, canonicalHookAddress, cfg.volatileToken, cfg.stableToken
                );
                LoggingLib.ok("reuse existing hook");
                return;
            }

            revert(string.concat("canonical existing hook invalid: ", existing.reason));
        }

        OpsTypes.BudgetCheck memory budget = BudgetLib.checkBeforeBroadcast(cfg, cfg.deployer);
        require(budget.ok, budget.reason);

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        uint24 floorFee = cfg.floorFeePips;
        uint24 cashFee = cfg.cashFeePips;
        uint24 extremeFee = cfg.extremeFeePips;
        require(
            floorFee > 0 && floorFee < cashFee && cashFee < extremeFee && extremeFee <= LPFeeLibrary.MAX_LP_FEE,
            "invalid fee bounds"
        );

        address owner = cfg.owner;
        uint16 hookFeePercent = cfg.hookFeePercent;
        uint16 deadbandBps = cfg.deadbandBps;
        uint64 minCloseVolToCashUsd6 = cfg.minCloseVolToCashUsd6;
        uint8 cashHoldPeriods = cfg.cashHoldPeriods;
        uint64 minCloseVolToExtremeUsd6 = cfg.minCloseVolToExtremeUsd6;
        uint8 extremeHoldPeriods = cfg.extremeHoldPeriods;
        uint16 downRFromExtremeBps = cfg.downRFromExtremeBps;
        uint16 downRFromCashBps = cfg.downRFromCashBps;
        uint64 emergencyFloorCloseVolUsd6 = cfg.emergencyFloorCloseVolUsd6;
        bool allowWeakHoldPeriods = vm.envOr("ALLOW_WEAK_HOLD_PERIODS", false);
        require(
            emergencyFloorCloseVolUsd6 > 0 && emergencyFloorCloseVolUsd6 < minCloseVolToCashUsd6,
            "invalid emergency floor threshold"
        );
        require(deadbandBps < downRFromExtremeBps && deadbandBps < downRFromCashBps, "invalid deadband thresholds");
        require(
            allowWeakHoldPeriods || (cashHoldPeriods >= 2 && extremeHoldPeriods >= 2),
            "weak hold periods blocked (set ALLOW_WEAK_HOLD_PERIODS=true to override)"
        );

        (bool nativeRecipientOk, string memory nativeRecipientReason) = NativeRecipientValidationLib.validatePayoutRecipientForNativePool(
            cfg.token0, cfg.token1, owner, cfg.poolManager
        );
        require(nativeRecipientOk, nativeRecipientReason);

        vm.startBroadcast(pk);
        bytes memory creationCodeWithArgs =
            abi.encodePacked(type(VolumeDynamicFeeHook).creationCode, constructorArgs);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(canonicalSalt, creationCodeWithArgs));
        vm.stopBroadcast();

        require(ok, "create2 deploy failed");
        require(canonicalHookAddress.code.length > 0, "hook code missing");

        cfg.hookAddress = canonicalHookAddress;
        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(cfg);
        require(validation.ok, validation.reason);

        JsonReportLib.writeAddressState(
            statePath, cfg.poolManager, canonicalHookAddress, cfg.volatileToken, cfg.stableToken
        );

        LoggingLib.ok("hook deployed");
    }
}
