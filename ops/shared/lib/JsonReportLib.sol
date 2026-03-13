// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {OpsTypes} from "../types/OpsTypes.sol";

library JsonReportLib {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function writePreflightReport(
        string memory path,
        string memory phase,
        OpsTypes.CoreConfig memory cfg,
        OpsTypes.TokenValidation memory tokenValidation,
        OpsTypes.BudgetCheck memory budget,
        OpsTypes.RangeCheck memory range,
        OpsTypes.HookValidation memory hookValidation,
        OpsTypes.PoolSnapshot memory snapshot,
        bool ok
    ) internal {
        string memory json = string.concat(
            "{",
            _kv("phase", phase),
            ",",
            _kv("ok", _bool(ok)),
            ",",
            _kv("chainIdExpected", vm.toString(cfg.chainIdExpected)),
            ",",
            _kv("chainIdActual", vm.toString(block.chainid)),
            ",",
            _kv("deployer", vm.toString(cfg.deployer)),
            ",",
            _kv("poolManager", vm.toString(cfg.poolManager)),
            ",",
            _kv("hookAddress", vm.toString(cfg.hookAddress)),
            ",",
            _kv("tokenValidation", _bool(tokenValidation.ok)),
            ",",
            _kv("tokenReason", tokenValidation.reason),
            ",",
            _kv("budgetValidation", _bool(budget.ok)),
            ",",
            _kv("budgetReason", budget.reason),
            ",",
            _kv("rangeValidation", _bool(range.ok)),
            ",",
            _kv("rangeReason", range.reason),
            ",",
            _kv("hookValidation", _bool(hookValidation.ok)),
            ",",
            _kv("hookReason", hookValidation.reason),
            ",",
            _kv("snapshotInitialized", _bool(snapshot.initialized)),
            ",",
            _kv("snapshotPaused", _bool(snapshot.paused)),
            ",",
            _kv("snapshotFeeIdx", vm.toString(snapshot.feeIdx)),
            "}"
        );
        vm.writeFile(path, json);
    }

    function writeStateReport(string memory path, OpsTypes.PoolSnapshot memory snapshot) internal {
        string memory json = string.concat(
            "{",
            _kv("initialized", _bool(snapshot.initialized)),
            ",",
            _kv("paused", _bool(snapshot.paused)),
            ",",
            _kv("periodVolUsd6", vm.toString(snapshot.periodVolUsd6)),
            ",",
            _kv("emaVolUsd6Scaled", vm.toString(snapshot.emaVolUsd6Scaled)),
            ",",
            _kv("periodStart", vm.toString(snapshot.periodStart)),
            ",",
            _kv("feeIdx", vm.toString(snapshot.feeIdx)),
            ",",
            _kv("currentFeeBips", vm.toString(snapshot.currentFeeBips)),
            "}"
        );
        vm.writeFile(path, json);
    }

    function writeAddressState(
        string memory path,
        address poolManager,
        address hook,
        address volatileToken,
        address stableToken
    ) internal {
        string memory json = string.concat(
            "{",
            _kv("poolManager", vm.toString(poolManager)),
            ",",
            _kv("hookAddress", vm.toString(hook)),
            ",",
            _kv("volatileToken", vm.toString(volatileToken)),
            ",",
            _kv("stableToken", vm.toString(stableToken)),
            "}"
        );
        vm.writeFile(path, json);
    }

    function _bool(bool value) private pure returns (string memory) {
        return value ? "true" : "false";
    }

    function _kv(string memory key, string memory value) private pure returns (string memory) {
        return string.concat('"', key, '":"', _escape(value), '"');
    }

    function _escape(string memory value) private pure returns (string memory) {
        bytes memory src = bytes(value);
        bytes memory out = new bytes(src.length * 2);
        uint256 o;
        for (uint256 i = 0; i < src.length; i++) {
            bytes1 c = src[i];
            if (c == '"' || c == "\\") {
                out[o++] = "\\";
            }
            out[o++] = c;
        }

        bytes memory trimmed = new bytes(o);
        for (uint256 j = 0; j < o; j++) {
            trimmed[j] = out[j];
        }
        return string(trimmed);
    }
}
