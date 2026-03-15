// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {GasMeasurementLib} from "../../shared/lib/GasMeasurementLib.sol";

contract GasMeasurementLibTest is Test {
    function test_parseOperation_accepts_transition_label() public pure {
        assertEq(uint8(GasMeasurementLib.parseOperation("cash_to_extreme")), uint8(GasMeasurementLib.Operation.CashToExtreme));
    }

    function test_minUpPassCloseVolUsd6_returns_volume_above_minimum() public pure {
        uint96 emaBeforeScaled = uint96(1_000_000_000 * 1_000_000);
        uint64 closeVol = GasMeasurementLib.minUpPassCloseVolUsd6(emaBeforeScaled, 8, 18_500, 1_000_000_000);
        uint96 emaAfterScaled = GasMeasurementLib.updateEmaScaled(emaBeforeScaled, closeVol, 8);
        uint256 rBps = (uint256(closeVol) * 1_000_000 * 10_000) / uint256(emaAfterScaled);

        assertGe(closeVol, 1_000_000_000);
        assertGe(rBps, 18_500);
    }

    function test_chooseDownPassCloseVolUsd6_stays_above_emergency_floor_and_below_threshold() public pure {
        uint96 emaBeforeScaled = uint96(4_200_000_000 * 1_000_000);
        uint64 closeVol = GasMeasurementLib.chooseDownPassCloseVolUsd6(emaBeforeScaled, 8, 12_500, 4_000_000, 600_000_000);
        uint96 emaAfterScaled = GasMeasurementLib.updateEmaScaled(emaBeforeScaled, closeVol, 8);
        uint256 rBps = (uint256(closeVol) * 1_000_000 * 10_000) / uint256(emaAfterScaled);

        assertGt(closeVol, 600_000_000);
        assertGe(closeVol, 4_000_000);
        assertLe(rBps, 12_500);
    }

    function test_usd6ToStableRaw_supports_18_decimals() public pure {
        assertEq(GasMeasurementLib.usd6ToStableRaw(7_000_000, 18), 7_000_000 * 1e12);
    }
}
