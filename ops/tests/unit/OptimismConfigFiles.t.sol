// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

contract OptimismConfigFilesTest is Test {
    function test_optimism_deploy_env_has_target_redeploy_profile() public view {
        string memory text = vm.readFile("ops/optimism/config/deploy.env");

        _assertContains(text, "DEPLOY_MIN_VOLUME_TO_ENTER_CASH_USD=400");
        _assertContains(text, "DEPLOY_CASH_ENTER_TRIGGER_EMA_X=1.35");
        _assertContains(text, "DEPLOY_CASH_HOLD_PERIODS=2");
        _assertContains(text, "DEPLOY_MIN_VOLUME_TO_ENTER_EXTREME_USD=2500");
        _assertContains(text, "DEPLOY_EXTREME_ENTER_TRIGGER_EMA_X=4.10");
        _assertContains(text, "DEPLOY_ENTER_EXTREME_CONFIRM_PERIODS=2");
        _assertContains(text, "DEPLOY_EXTREME_HOLD_PERIODS=2");
        _assertContains(text, "DEPLOY_EXTREME_EXIT_TRIGGER_EMA_X=1.20");
        _assertContains(text, "DEPLOY_EXIT_EXTREME_CONFIRM_PERIODS=2");
        _assertContains(text, "DEPLOY_CASH_EXIT_TRIGGER_EMA_X=1.20");
        _assertContains(text, "DEPLOY_EXIT_CASH_CONFIRM_PERIODS=3");
        _assertContains(text, "DEPLOY_EMERGENCY_FLOOR_TRIGGER_USD=100");
        _assertContains(text, "DEPLOY_EMERGENCY_CONFIRM_PERIODS=6");
    }

    function test_optimism_defaults_env_has_runtime_expectations_for_target_profile() public view {
        string memory text = vm.readFile("ops/optimism/config/defaults.env");

        _assertContains(text, "MIN_COUNTED_SWAP_USD6=4000000");
        _assertContains(text, "MIN_VOLUME_TO_ENTER_CASH_USD=400");
        _assertContains(text, "CASH_ENTER_TRIGGER_EMA_X=1.35");
        _assertContains(text, "CASH_HOLD_PERIODS=2");
        _assertContains(text, "MIN_VOLUME_TO_ENTER_EXTREME_USD=2500");
        _assertContains(text, "EXTREME_ENTER_TRIGGER_EMA_X=4.10");
        _assertContains(text, "ENTER_EXTREME_CONFIRM_PERIODS=2");
        _assertContains(text, "EXTREME_HOLD_PERIODS=2");
        _assertContains(text, "EXTREME_EXIT_TRIGGER_EMA_X=1.20");
        _assertContains(text, "EXIT_EXTREME_CONFIRM_PERIODS=2");
        _assertContains(text, "CASH_EXIT_TRIGGER_EMA_X=1.20");
        _assertContains(text, "EXIT_CASH_CONFIRM_PERIODS=3");
        _assertContains(text, "EMERGENCY_FLOOR_TRIGGER_USD=100");
        _assertContains(text, "EMERGENCY_CONFIRM_PERIODS=6");
    }

    function test_show_hook_config_uses_new_controller_names() public view {
        string memory text = vm.readFile("scripts/show_hook_config.sh");

        _assertContains(text, "floorToCashMinCloseVolume");
        _assertContains(text, "floorToCashMinFlowBps");
        _assertContains(text, "cashToExtremeMinCloseVolume");
        _assertContains(text, "cashToExtremeMinFlowBps");
        _assertContains(text, "cashToExtremeConfirmPeriods");
        _assertContains(text, "extremeToCashMaxFlowBps");
        _assertContains(text, "extremeToCashConfirmPeriods");
        _assertContains(text, "cashToFloorMaxFlowBps");
        _assertContains(text, "cashToFloorConfirmPeriods");
        _assertContains(text, "emergencyToFloorMaxCloseVolume");
        _assertContains(text, "emergencyToFloorConfirmPeriods");
        _assertContains(text, "minCountedSwapVolume");

        _assertNotContains(text, string.concat("minCloseVol", "ToCash", "Usd6"));
        _assertNotContains(text, string.concat("cashEnter", "Trigger", "Bps"));
        _assertNotContains(text, string.concat("minCloseVol", "ToExtreme", "Usd6"));
        _assertNotContains(text, string.concat("extremeEnter", "Trigger", "Bps"));
        _assertNotContains(text, string.concat("upExtreme", "Confirm", "Periods"));
        _assertNotContains(text, string.concat("extremeExit", "Trigger", "Bps"));
        _assertNotContains(text, string.concat("downExtreme", "Confirm", "Periods"));
        _assertNotContains(text, string.concat("cashExit", "Trigger", "Bps"));
        _assertNotContains(text, string.concat("downCash", "Confirm", "Periods"));
        _assertNotContains(text, string.concat("emergencyFloor", "CloseVol", "Usd6"));
        _assertNotContains(text, string.concat("emergency", "Confirm", "Periods"));
        _assertNotContains(text, string.concat("minCounted", "Swap", "Usd6"));
    }

    function _assertContains(string memory haystack, string memory needle) internal pure {
        assertTrue(_contains(haystack, needle), string.concat("missing: ", needle));
    }

    function _assertNotContains(string memory haystack, string memory needle) internal pure {
        assertFalse(_contains(haystack, needle), string.concat("unexpected: ", needle));
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);

        if (n.length == 0) return true;
        if (n.length > h.length) return false;

        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool match_ = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }

        return false;
    }
}
