// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {CanonicalHookResolverLib} from "../../shared/lib/CanonicalHookResolverLib.sol";
import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {PoolStateLib} from "../../shared/lib/PoolStateLib.sol";
import {JsonReportLib} from "../../shared/lib/JsonReportLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract InspectSepoliaState is Script {
    function run() external {
        LoggingLib.phase("sepolia.inspect");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        (cfg,) = CanonicalHookResolverLib.requireExistingCanonicalHook(cfg);
        OpsTypes.PoolSnapshot memory snapshot = PoolStateLib.snapshotHook(cfg.hookAddress);

        string memory reportPath = vm.envOr(
            "OPS_SEPOLIA_INSPECT_REPORT",
            string.concat(vm.projectRoot(), "/ops/sepolia/out/state/inspect.sepolia.json")
        );

        JsonReportLib.writeStateReport(reportPath, snapshot);
        console2.log("inspect report", reportPath);
    }
}
