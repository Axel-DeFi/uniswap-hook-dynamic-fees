// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

contract OptimismConfigFilesTest is Test {
    function test_optimism_deploy_env_has_target_redeploy_profile() public view {
        string memory text = vm.readFile("ops/optimism/config/deploy.env");

        _assertContains(text, "DEPLOY_TICK_SPACING=60");
        _assertContains(text, "DEPLOY_FLOOR_TO_CASH_MIN_CLOSE_VOLUME=400000000");
        _assertContains(text, "DEPLOY_FLOOR_TO_CASH_MIN_FLOW_EMA_X=1.35");
        _assertContains(text, "DEPLOY_CASH_HOLD_PERIODS=2");
        _assertContains(text, "DEPLOY_CASH_TO_EXTREME_MIN_CLOSE_VOLUME=2500000000");
        _assertContains(text, "DEPLOY_CASH_TO_EXTREME_MIN_FLOW_EMA_X=4.10");
        _assertContains(text, "DEPLOY_CASH_TO_EXTREME_CONFIRM_PERIODS=2");
        _assertContains(text, "DEPLOY_EXTREME_HOLD_PERIODS=2");
        _assertContains(text, "DEPLOY_EXTREME_TO_CASH_MAX_FLOW_EMA_X=1.20");
        _assertContains(text, "DEPLOY_EXTREME_TO_CASH_CONFIRM_PERIODS=2");
        _assertContains(text, "DEPLOY_CASH_TO_FLOOR_MAX_FLOW_EMA_X=1.20");
        _assertContains(text, "DEPLOY_CASH_TO_FLOOR_CONFIRM_PERIODS=3");
        _assertContains(text, "DEPLOY_EMERGENCY_TO_FLOOR_MAX_CLOSE_VOLUME=100000000");
        _assertContains(text, "DEPLOY_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS=6");
    }

    function test_optimism_defaults_env_has_runtime_expectations_for_target_profile() public view {
        string memory text = vm.readFile("ops/optimism/config/defaults.env");

        _assertNotContains(text, "HOOK_ADDRESS=");
        _assertNotContains(text, "POOL_ID=");
        _assertContains(text, "MIN_COUNTED_SWAP_VOLUME=4000000");
        _assertContains(text, "FLOOR_TO_CASH_MIN_CLOSE_VOLUME=400000000");
        _assertContains(text, "FLOOR_TO_CASH_MIN_FLOW_EMA_X=1.35");
        _assertContains(text, "CASH_HOLD_PERIODS=2");
        _assertContains(text, "CASH_TO_EXTREME_MIN_CLOSE_VOLUME=2500000000");
        _assertContains(text, "CASH_TO_EXTREME_MIN_FLOW_EMA_X=4.10");
        _assertContains(text, "CASH_TO_EXTREME_CONFIRM_PERIODS=2");
        _assertContains(text, "EXTREME_HOLD_PERIODS=2");
        _assertContains(text, "EXTREME_TO_CASH_MAX_FLOW_EMA_X=1.20");
        _assertContains(text, "EXTREME_TO_CASH_CONFIRM_PERIODS=2");
        _assertContains(text, "CASH_TO_FLOOR_MAX_FLOW_EMA_X=1.20");
        _assertContains(text, "CASH_TO_FLOOR_CONFIRM_PERIODS=3");
        _assertContains(text, "EMERGENCY_TO_FLOOR_MAX_CLOSE_VOLUME=100000000");
        _assertContains(text, "EMERGENCY_TO_FLOOR_CONFIRM_PERIODS=6");
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
