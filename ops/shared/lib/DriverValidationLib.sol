// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

library DriverValidationLib {
    function validateSwapDriver(address driver, address poolManager)
        internal
        returns (bool ok, string memory reason)
    {
        return _validate(driver, poolManager, true);
    }

    function validateLiquidityDriver(address driver, address poolManager)
        internal
        returns (bool ok, string memory reason)
    {
        return _validate(driver, poolManager, false);
    }

    function requireValidSwapDriver(address driver, address poolManager) internal {
        (bool ok, string memory reason) = validateSwapDriver(driver, poolManager);
        require(ok, reason);
    }

    function requireValidLiquidityDriver(address driver, address poolManager) internal {
        (bool ok, string memory reason) = validateLiquidityDriver(driver, poolManager);
        require(ok, reason);
    }

    function _validate(address driver, address poolManager, bool swapDriver)
        private
        returns (bool ok, string memory reason)
    {
        string memory label = swapDriver ? "SWAP_DRIVER" : "LIQUIDITY_DRIVER";

        if (driver == address(0)) {
            return (false, string.concat(label, " missing"));
        }
        if (driver.code.length == 0) {
            return (false, string.concat(label, " has no code"));
        }
        if (poolManager == address(0) || poolManager.code.length == 0) {
            return (false, "POOL_MANAGER has no code");
        }

        IPoolManager manager;
        try IDriverManager(driver).manager() returns (IPoolManager currentManager) {
            manager = currentManager;
        } catch {
            return (false, string.concat(label, " missing manager()"));
        }

        if (address(manager) != poolManager) {
            return (false, string.concat(label, " PoolManager mismatch"));
        }

        address expectedDriver = swapDriver
            ? address(new PoolSwapTest(IPoolManager(poolManager)))
            : address(new PoolModifyLiquidityTest(IPoolManager(poolManager)));
        if (driver.codehash != expectedDriver.codehash) {
            return (false, string.concat(label, " codehash mismatch"));
        }

        return (true, "ok");
    }
}

interface IDriverManager {
    function manager() external view returns (IPoolManager);
}
