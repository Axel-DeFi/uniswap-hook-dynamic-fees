// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract SeedBalancesLocal is Script {
    function run() external {
        LoggingLib.phase("local.seed-balances");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        uint256 seedStable = vm.envOr("SEED_STABLE_RAW", uint256(0));
        uint256 seedVolatile = vm.envOr("SEED_VOLATILE_RAW", uint256(0));

        vm.startBroadcast(pk);
        if (cfg.stableToken != address(0) && seedStable > 0) {
            IMintable(cfg.stableToken).mint(cfg.deployer, seedStable);
        }
        if (cfg.volatileToken != address(0) && seedVolatile > 0) {
            IMintable(cfg.volatileToken).mint(cfg.deployer, seedVolatile);
        }
        vm.stopBroadcast();

        LoggingLib.ok("seed balances done");
    }
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}
