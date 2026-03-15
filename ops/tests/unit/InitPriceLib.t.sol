// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {InitPriceLib} from "../../shared/lib/InitPriceLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract InitPriceLibHarness {
    function requireInitSqrtPriceX96(OpsTypes.CoreConfig memory cfg) external view returns (uint160) {
        return InitPriceLib.requireInitSqrtPriceX96(cfg);
    }
}

contract InitPriceLibTest is Test {
    InitPriceLibHarness internal harness;

    function setUp() public {
        harness = new InitPriceLibHarness();
    }

    function test_requireInitSqrtPriceX96_matches_existing_usdc_eth_bootstrap_price() public view {
        OpsTypes.CoreConfig memory cfg;
        cfg.volatileToken = address(0);
        cfg.stableToken = address(0xBEEF);
        cfg.token0 = address(0);
        cfg.token1 = cfg.stableToken;
        cfg.stableDecimals = 6;
        cfg.initPriceUsdE18 = 2_500e18;

        assertEq(harness.requireInitSqrtPriceX96(cfg), 3_961_408_125_713_216_879_677_197);
    }

    function test_requireInitSqrtPriceX96_handles_stable_as_token0() public {
        MockERC20 volatileToken = new MockERC20("Volatile", "VOL", 18);

        OpsTypes.CoreConfig memory cfg;
        cfg.volatileToken = address(volatileToken);
        cfg.stableToken = address(0x0000000000000000000000000000000000000001);
        cfg.token0 = cfg.stableToken;
        cfg.token1 = cfg.volatileToken;
        cfg.stableDecimals = 18;
        cfg.initPriceUsdE18 = 4e18;

        assertEq(harness.requireInitSqrtPriceX96(cfg), 39_614_081_257_132_168_796_771_975_168);
    }
}
