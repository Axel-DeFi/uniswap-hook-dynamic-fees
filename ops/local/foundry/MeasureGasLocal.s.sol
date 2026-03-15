// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {GasMeasurementLib} from "../../shared/lib/GasMeasurementLib.sol";
import {GasMeasurementLocalBase} from "./GasMeasurementLocalBase.sol";

contract MeasureGasLocal is Script, GasMeasurementLocalBase {
    function run() external {
        string memory rawOperation = vm.envString("OPS_GAS_OPERATION");
        GasMeasurementLib.Operation operation = GasMeasurementLib.parseOperation(rawOperation);

        _setUpMeasurementEnv();

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        vm.startBroadcast(pk);
        _runOperation(operation);
        vm.stopBroadcast();
    }
}
