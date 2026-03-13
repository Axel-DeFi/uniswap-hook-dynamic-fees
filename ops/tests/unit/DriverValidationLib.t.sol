// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DriverValidationLib} from "../../shared/lib/DriverValidationLib.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

contract FakeSwapDriver {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }
}

contract DriverValidationHarness {
    function validateSwapDriver(address driver, address poolManager)
        external
        returns (bool ok, string memory reason)
    {
        return DriverValidationLib.validateSwapDriver(driver, poolManager);
    }

    function validateLiquidityDriver(address driver, address poolManager)
        external
        returns (bool ok, string memory reason)
    {
        return DriverValidationLib.validateLiquidityDriver(driver, poolManager);
    }
}

contract DriverValidationLibTest is Test {
    MockPoolManager internal manager;
    MockPoolManager internal otherManager;
    DriverValidationHarness internal harness;

    function setUp() public {
        manager = new MockPoolManager();
        otherManager = new MockPoolManager();
        harness = new DriverValidationHarness();
    }

    function test_validateSwapDriver_accepts_matching_driver() public {
        PoolSwapTest driver = new PoolSwapTest(IPoolManager(address(manager)));

        (bool ok, string memory reason) = harness.validateSwapDriver(address(driver), address(manager));

        assertTrue(ok);
        assertEq(reason, "ok");
    }

    function test_validateLiquidityDriver_rejects_manager_mismatch() public {
        PoolModifyLiquidityTest driver = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        (bool ok, string memory reason) = harness.validateLiquidityDriver(address(driver), address(otherManager));

        assertFalse(ok);
        assertEq(reason, "LIQUIDITY_DRIVER PoolManager mismatch");
    }

    function test_validateSwapDriver_rejects_codehash_mismatch() public {
        FakeSwapDriver driver = new FakeSwapDriver(IPoolManager(address(manager)));

        (bool ok, string memory reason) = harness.validateSwapDriver(address(driver), address(manager));

        assertFalse(ok);
        assertEq(reason, "SWAP_DRIVER codehash mismatch");
    }
}
