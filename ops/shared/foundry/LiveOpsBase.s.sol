// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

abstract contract LiveOpsBase is Script {
    function _network() internal view returns (string memory) {
        return vm.envOr("OPS_NETWORK", string("live"));
    }

    function _networkDir() internal view returns (string memory) {
        return vm.envOr("OPS_NETWORK_DIR", string.concat(vm.projectRoot(), "/ops/", _network()));
    }

    function _phase(string memory suffix) internal view returns (string memory) {
        return string.concat(_network(), ".", suffix);
    }

    function _statePath() internal view returns (string memory) {
        return vm.envOr(
            "OPS_STATE_PATH",
            string.concat(_networkDir(), "/out/state/", _network(), ".addresses.json")
        );
    }

    function _driversStatePath() internal view returns (string memory) {
        return vm.envOr(
            "OPS_DRIVERS_STATE_PATH",
            string.concat(_networkDir(), "/out/state/", _network(), ".drivers.json")
        );
    }

    function _preflightReportPath() internal view returns (string memory) {
        return vm.envOr(
            "OPS_PREFLIGHT_REPORT",
            string.concat(_networkDir(), "/out/reports/preflight.", _network(), ".json")
        );
    }

    function _inspectReportPath() internal view returns (string memory) {
        return vm.envOr(
            "OPS_INSPECT_REPORT",
            string.concat(_networkDir(), "/out/state/inspect.", _network(), ".json")
        );
    }

    function _fullReportPath() internal view returns (string memory) {
        return vm.envOr(
            "OPS_FULL_REPORT",
            string.concat(_networkDir(), "/out/reports/full.", _network(), ".json")
        );
    }
}
