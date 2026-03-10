// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {PoolStateLib} from "../../shared/lib/PoolStateLib.sol";
import {JsonReportLib} from "../../shared/lib/JsonReportLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract InspectLocalState is Script {
    function run() external {
        LoggingLib.phase("local.inspect");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        OpsTypes.PoolSnapshot memory snapshot = PoolStateLib.snapshotHook(cfg.hookAddress);

        string memory reportPath = vm.envOr(
            "OPS_LOCAL_INSPECT_REPORT",
            string.concat(vm.projectRoot(), "/ops/local/out/state/inspect.local.json")
        );

        JsonReportLib.writeStateReport(reportPath, snapshot);
        console2.log("inspect report", reportPath);
    }
}
