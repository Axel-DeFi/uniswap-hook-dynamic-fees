// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "../../tests/mocks/MockPoolManager.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {PoolStateLib} from "../../shared/lib/PoolStateLib.sol";
import {LoggingLib} from "../../shared/lib/LoggingLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract EnsurePoolLocal is Script {
    function run() external {
        LoggingLib.phase("local.ensure-pool");

        OpsTypes.CoreConfig memory cfg = ConfigLoader.loadCoreConfig();
        require(cfg.hookAddress != address(0) && cfg.hookAddress.code.length > 0, "HOOK_ADDRESS missing");

        OpsTypes.PoolSnapshot memory snapshot = PoolStateLib.snapshotHook(cfg.hookAddress);
        if (snapshot.initialized) {
            LoggingLib.ok("pool already initialized");
            return;
        }

        uint256 pk = cfg.privateKey;
        require(pk != 0, "PRIVATE_KEY missing");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(cfg.token0),
            currency1: Currency.wrap(cfg.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.hookAddress)
        });

        vm.startBroadcast(pk);
        MockPoolManager(payable(cfg.poolManager)).callAfterInitialize(VolumeDynamicFeeHook(payable(cfg.hookAddress)), key);
        vm.stopBroadcast();

        LoggingLib.ok("pool initialized via mock manager");
    }
}
