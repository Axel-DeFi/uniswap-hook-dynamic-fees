// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {EnvLib} from "../../shared/lib/EnvLib.sol";
import {ErrorLib} from "../../shared/lib/ErrorLib.sol";

contract EnvLibBoundsHarness {
    function requireBpsFromPercent(string memory key) external view returns (uint16) {
        return EnvLib.requireBpsFromPercent(key);
    }

    function requireUsd6FromUsd(string memory key) external view returns (uint64) {
        return EnvLib.requireUsd6FromUsd(key);
    }

    function parseDecimalToScale(string memory raw, string memory key, uint8 scaleDecimals)
        external
        pure
        returns (uint256)
    {
        return EnvLib.parseDecimalToScale(raw, key, scaleDecimals);
    }

    function toUint8Checked(uint256 raw, string memory key) external pure returns (uint8) {
        return EnvLib.toUint8Checked(raw, key);
    }

    function toUint16Checked(uint256 raw, string memory key) external pure returns (uint16) {
        return EnvLib.toUint16Checked(raw, key);
    }

    function toUint24Checked(uint256 raw, string memory key) external pure returns (uint24) {
        return EnvLib.toUint24Checked(raw, key);
    }

    function toUint32Checked(uint256 raw, string memory key) external pure returns (uint32) {
        return EnvLib.toUint32Checked(raw, key);
    }

    function toUint64Checked(uint256 raw, string memory key) external pure returns (uint64) {
        return EnvLib.toUint64Checked(raw, key);
    }

    function toPositiveInt24Checked(uint256 raw, string memory key) external pure returns (int24) {
        return EnvLib.toPositiveInt24Checked(raw, key);
    }
}

contract EnvLibBoundsTest is Test {
    EnvLibBoundsHarness internal harness;

    function setUp() public {
        harness = new EnvLibBoundsHarness();
    }

    function test_checked_uint_narrowing_accepts_in_range_values() public view {
        assertEq(harness.toUint8Checked(type(uint8).max, "EMA_PERIODS"), type(uint8).max);
        assertEq(harness.toUint16Checked(type(uint16).max, "DEADBAND_PERCENT"), type(uint16).max);
        assertEq(harness.toUint24Checked(type(uint24).max, "FLOOR_FEE_PIPS"), type(uint24).max);
        assertEq(harness.toUint32Checked(type(uint32).max, "PERIOD_SECONDS"), type(uint32).max);
        assertEq(harness.toUint64Checked(type(uint64).max, "MIN_VOLUME_TO_ENTER_CASH_USD"), type(uint64).max);
        assertEq(
            harness.toPositiveInt24Checked(uint256(uint24(type(int24).max)), "TICK_SPACING"), type(int24).max
        );
    }

    function test_parse_decimal_to_scale_accepts_fractional_and_underscored_values() public view {
        assertEq(harness.parseDecimalToScale("1_234.56789", "EXAMPLE_USD", 6), 1_234_567_890);
    }

    function test_require_bps_from_percent_parses_decimal_percent() public {
        vm.setEnv("DEADBAND_PERCENT", "5.25");
        assertEq(harness.requireBpsFromPercent("DEADBAND_PERCENT"), 525);
    }

    function test_require_usd6_from_usd_parses_decimal_dollars() public {
        vm.setEnv("EMERGENCY_FLOOR_TRIGGER_USD", "600.1250019");
        assertEq(harness.requireUsd6FromUsd("EMERGENCY_FLOOR_TRIGGER_USD"), 600_125_001);
    }

    function test_checked_uint8_narrowing_reverts_on_overflow() public {
        vm.expectRevert(
            abi.encodeWithSelector(ErrorLib.InvalidEnv.selector, "EMA_PERIODS", "value too large for uint8")
        );
        harness.toUint8Checked(uint256(type(uint8).max) + 1, "EMA_PERIODS");
    }

    function test_checked_positive_int24_narrowing_reverts_on_overflow() public {
        vm.expectRevert(
            abi.encodeWithSelector(ErrorLib.InvalidEnv.selector, "TICK_SPACING", "must fit positive int24")
        );
        harness.toPositiveInt24Checked(uint256(uint24(type(int24).max)) + 1, "TICK_SPACING");
    }
}
