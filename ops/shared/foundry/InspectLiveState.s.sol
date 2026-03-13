// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {CanonicalHookResolverLib} from "../lib/CanonicalHookResolverLib.sol";
import {ConfigLoader} from "../lib/ConfigLoader.sol";
import {PoolStateLib} from "../lib/PoolStateLib.sol";
import {JsonReportLib} from "../lib/JsonReportLib.sol";
import {LoggingLib} from "../lib/LoggingLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";
import {LiveOpsBase} from "./LiveOpsBase.s.sol";

contract InspectLiveState is LiveOpsBase {
    function run() external {
        LoggingLib.phase(_phase("inspect"));

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        OpsTypes.DeploymentConfig memory deployCfg = ConfigLoader.loadDeploymentConfig(cfg);
        ConfigLoader.requireDeploymentBindingConsistency(cfg, deployCfg);
        (cfg,) = CanonicalHookResolverLib.requireExistingCanonicalHook(cfg, deployCfg);
        OpsTypes.PoolSnapshot memory snapshot = PoolStateLib.snapshotHook(cfg.hookAddress);

        string memory reportPath = _inspectReportPath();

        JsonReportLib.writeStateReport(reportPath, snapshot);
        console2.log("inspect report", reportPath);
    }
}
