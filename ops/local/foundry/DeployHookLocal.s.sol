// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {HookIdentityLib} from "../../shared/lib/HookIdentityLib.sol";
import {HookValidationLib} from "../../shared/lib/HookValidationLib.sol";
import {NativeRecipientValidationLib} from "../../shared/lib/NativeRecipientValidationLib.sol";
import {JsonReportLib} from "../../shared/lib/JsonReportLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract DeployHookLocal is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        OpsTypes.CoreConfig memory runtimeCfg = ConfigLoader.loadCoreConfig();
        OpsTypes.DeploymentConfig memory deployCfg = ConfigLoader.loadDeploymentConfig(runtimeCfg);
        ConfigLoader.validateChainId(runtimeCfg.chainIdExpected);
        ConfigLoader.requireDeploymentBindingConsistency(runtimeCfg, deployCfg);

        string memory statePath = vm.envOr(
            "OPS_LOCAL_STATE_PATH",
            string.concat(vm.projectRoot(), "/ops/local/out/state/local.addresses.json")
        );

        address configuredHookAddress = runtimeCfg.hookAddress;
        (address canonicalHookAddress, bytes32 canonicalSalt, bytes memory constructorArgs) =
            HookIdentityLib.expectedHookAddress(deployCfg);

        if (configuredHookAddress != address(0) && configuredHookAddress != canonicalHookAddress) {
            console2.log("ignoring non-canonical configured hook", configuredHookAddress);
            console2.log("canonical hook", canonicalHookAddress);
        }

        if (canonicalHookAddress.code.length > 0) {
            runtimeCfg.hookAddress = canonicalHookAddress;
            OpsTypes.HookValidation memory existing = HookValidationLib.validateHook(runtimeCfg);
            if (existing.ok) {
                address currentOwner = VolumeDynamicFeeHook(payable(canonicalHookAddress)).owner();
                (bool nativeRecipientOk, string memory nativeRecipientReason) = NativeRecipientValidationLib.validatePayoutRecipientForNativePool(
                    runtimeCfg.token0, runtimeCfg.token1, currentOwner, runtimeCfg.poolManager
                );
                require(nativeRecipientOk, nativeRecipientReason);

                JsonReportLib.writeAddressState(
                    statePath,
                    runtimeCfg.poolManager,
                    canonicalHookAddress,
                    runtimeCfg.volatileToken,
                    runtimeCfg.stableToken
                );
                console2.log("reuse hook", canonicalHookAddress);
                return;
            }

            revert(string.concat("canonical existing hook invalid: ", existing.reason));
        }

        uint256 pk = runtimeCfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        uint24 floorFee = deployCfg.floorFeePips;
        uint24 cashFee = deployCfg.cashFeePips;
        uint24 extremeFee = deployCfg.extremeFeePips;
        require(
            floorFee > 0 && floorFee < cashFee && cashFee < extremeFee && extremeFee <= LPFeeLibrary.MAX_LP_FEE,
            "invalid fee bounds"
        );

        address owner = deployCfg.owner;
        uint16 deadbandBps = deployCfg.deadbandBps;
        uint64 minCloseVolToCashUsd6 = deployCfg.minCloseVolToCashUsd6;
        uint8 cashHoldPeriods = deployCfg.cashHoldPeriods;
        uint64 minCloseVolToExtremeUsd6 = deployCfg.minCloseVolToExtremeUsd6;
        uint8 extremeHoldPeriods = deployCfg.extremeHoldPeriods;
        uint16 downRFromExtremeBps = deployCfg.downRFromExtremeBps;
        uint16 downRFromCashBps = deployCfg.downRFromCashBps;
        uint64 emergencyFloorCloseVolUsd6 = deployCfg.emergencyFloorCloseVolUsd6;
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

        (bool nativeRecipientOk, string memory nativeRecipientReason) = NativeRecipientValidationLib.validatePayoutRecipientForNativePool(
            runtimeCfg.token0, runtimeCfg.token1, owner, runtimeCfg.poolManager
        );
        require(nativeRecipientOk, nativeRecipientReason);

        vm.startBroadcast(pk);
        bytes memory creationCodeWithArgs =
            abi.encodePacked(type(VolumeDynamicFeeHook).creationCode, constructorArgs);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(canonicalSalt, creationCodeWithArgs));
        vm.stopBroadcast();

        require(ok, "create2 deploy failed");
        require(canonicalHookAddress.code.length > 0, "hook code missing");

        runtimeCfg.hookAddress = canonicalHookAddress;
        OpsTypes.HookValidation memory validation = HookValidationLib.validateHook(runtimeCfg);
        require(validation.ok, validation.reason);

        JsonReportLib.writeAddressState(
            statePath,
            runtimeCfg.poolManager,
            canonicalHookAddress,
            runtimeCfg.volatileToken,
            runtimeCfg.stableToken
        );

        console2.log("hook deployed", canonicalHookAddress);
    }
}
