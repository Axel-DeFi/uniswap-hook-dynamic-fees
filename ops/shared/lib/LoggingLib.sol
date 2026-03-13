// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {OpsTypes} from "../types/OpsTypes.sol";

library LoggingLib {
    function phase(string memory name) internal view {
        console2.log("[ops] phase:", name);
        console2.log("[ops] chainId:", block.chainid);
    }

    function infoAddress(string memory label, address value) internal pure {
        console2.log(label, value);
    }

    function infoUint(string memory label, uint256 value) internal pure {
        console2.log(label, value);
    }

    function configSummary(OpsTypes.CoreConfig memory cfg) internal pure {
        console2.log("[ops] poolManager", cfg.poolManager);
        console2.log("[ops] hookAddress", cfg.hookAddress);
        console2.log("[ops] volatile", cfg.volatileToken);
        console2.log("[ops] stable", cfg.stableToken);
        console2.log("[ops] tickSpacing", cfg.tickSpacing);
        console2.log("[ops] stableDecimals", cfg.stableDecimals);
    }

    function ok(string memory msg_) internal pure {
        console2.log("[ops] ok:", msg_);
    }

    function fail(string memory msg_) internal pure {
        console2.log("[ops] fail:", msg_);
    }
}
