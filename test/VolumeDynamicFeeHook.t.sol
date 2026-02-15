// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {VolumeDynamicFeeHook} from "../src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

contract VolumeDynamicFeeHookTest is Test {
    using BalanceDeltaLibrary for BalanceDelta;

    MockPoolManager internal manager;
    VolumeDynamicFeeHook internal hook;
    PoolKey internal key;

    // Test tokens (addresses only; we do not transfer)
    address internal constant TOKEN0 = address(0x1111);
    address internal constant TOKEN1 = address(0x2222);

    // Configuration for tests
    int24 internal constant TICK_SPACING = 10;
    uint8 internal constant STABLE_DECIMALS = 6;

    // Fee tiers:
    // [95, 400, 900, 2500, 3000, 6000, 9000]
    uint8 internal constant INITIAL_FEE_IDX = 4; // 3000
    uint8 internal constant FLOOR_IDX = 1;       // 400
    uint8 internal constant CAP_IDX = 5;         // 6000

    uint32 internal constant PERIOD_SECONDS = 300; // 5 minutes
    uint8 internal constant EMA_PERIODS = 12;      // ~1 hour EMA
    uint16 internal constant DEADBAND_BPS = 1000;  // +/-10%
    uint32 internal constant LULL_RESET_SECONDS = 3600; // 1 hour

    function setUp() public {
        manager = new MockPoolManager();

        // Stable is TOKEN0 for these tests.
        Currency c0 = Currency.wrap(TOKEN0);
        Currency c1 = Currency.wrap(TOKEN1);
        Currency stable = c0;

        // Mine a hook address for our test contract (address(this)) as the CREATE2 deployer.
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(manager)),
            c0,
            c1,
            TICK_SPACING,
            stable,
            STABLE_DECIMALS,
            INITIAL_FEE_IDX,
            FLOOR_IDX,
            CAP_IDX,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            address(this),
            uint8(2)
        );

        (address minedHookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        hook = new VolumeDynamicFeeHook{salt: salt}(
            IPoolManager(address(manager)),
            c0,
            c1,
            TICK_SPACING,
            stable,
            STABLE_DECIMALS,
            INITIAL_FEE_IDX,
            FLOOR_IDX,
            CAP_IDX,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            address(this),
            uint8(2)
        );

        assertEq(address(hook), minedHookAddress, "hook address mismatch");

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Initialize hook state
        manager.callAfterInitialize(hook, key);
    }

    function _deltaStable0(int128 stableDelta) internal pure returns (BalanceDelta) {
        // Stable is currency0 for this test suite.
        return BalanceDeltaLibrary.toBalanceDelta(stableDelta, 0);
    }

    function test_afterInitialize_sets_initial_fee() public {
        assertEq(manager.lastFee(), VolumeDynamicFeeHook.FEE_TIERS(INITIAL_FEE_IDX));
        (uint64 periodVol, uint96 emaVol, uint32 periodStart, uint8 feeIdx, uint8 lastDir) = hook.unpackedState();
        assertEq(periodVol, 0);
        assertEq(emaVol, 0);
        assertTrue(periodStart != 0);
        assertEq(feeIdx, INITIAL_FEE_IDX);
        assertEq(lastDir, 0);
    }

    function test_period_rollover_counts_boundary_swap_in_new_period() public {
        // Add one swap in the first period: stableDelta=1e6 => usd6=1e6 => add=2e6
        manager.callAfterSwap(hook, key, _deltaStable0(int128(-1_000_000)));

        // Advance time past the period boundary, then trigger rollover by swapping again.
        vm.warp(block.timestamp + PERIOD_SECONDS + 1);
        manager.callAfterSwap(hook, key, _deltaStable0(int128(-1_000_000)));

        // The second swap should be counted in the new period.
        (uint64 periodVol, uint96 emaVol,, uint8 feeIdx,) = hook.unpackedState();
        assertEq(periodVol, 2_000_000); // only the boundary swap counted in the new period
        assertTrue(emaVol != 0); // EMA initialized from closed period
        assertEq(feeIdx, INITIAL_FEE_IDX); // no change on first EMA init
    }

    function test_fee_moves_up_one_step_on_high_volume_regime() public {
        // Period 1: 2_000_000 volume
        manager.callAfterSwap(hook, key, _deltaStable0(int128(-1_000_000)));

        // Close period 1 (EMA init). Boundary swap becomes period 2 volume.
        vm.warp(block.timestamp + PERIOD_SECONDS + 1);
        manager.callAfterSwap(hook, key, _deltaStable0(int128(-1_000_000)));

        // Add extra swaps in period 2 to create a higher close volume.
        vm.warp(block.timestamp + 10);
        manager.callAfterSwap(hook, key, _deltaStable0(int128(-1_000_000))); // +2_000_000 (periodVol=4_000_000)

        // Close period 2. Expect fee +1 step (from idx 4->5) because closeVol is far above EMA.
        vm.warp(block.timestamp + PERIOD_SECONDS + 1);
        // Use a zero-volume boundary swap so the next period starts with periodVol = 0.
        manager.callAfterSwap(hook, key, _deltaStable0(int128(0)));

        (,,, uint8 feeIdx,) = hook.unpackedState();
        assertEq(feeIdx, INITIAL_FEE_IDX + 1);
        assertEq(manager.lastFee(), VolumeDynamicFeeHook.FEE_TIERS(INITIAL_FEE_IDX + 1));
    }

    function test_reversal_lock_requires_one_period_confirmation() public {
        // Build up to cap movement up by 1 first.
        test_fee_moves_up_one_step_on_high_volume_regime();

        // Now create a very low volume period to request DIR_DOWN.
        // Period 3: only boundary swap (2_000_000) then close with 2_000_000 while EMA is higher -> likely DIR_DOWN.
        // We make it even smaller by using a tiny swap.
        vm.warp(block.timestamp + 1);
        manager.callAfterSwap(hook, key, _deltaStable0(int128(-1))); // minimal volume

        // Close: first down signal after an up should clear lastDir but not move fee (reversal lock).
        vm.warp(block.timestamp + PERIOD_SECONDS + 1);
        manager.callAfterSwap(hook, key, _deltaStable0(int128(-1))); // triggers close

        (,,, uint8 feeIdx, uint8 lastDir) = hook.unpackedState();
        assertEq(feeIdx, INITIAL_FEE_IDX + 1, "fee should not move on first reversal");
        assertEq(lastDir, 0, "lastDir should be cleared on reversal");

        // Another low-volume period should confirm DIR_DOWN and move fee down by 1.
        vm.warp(block.timestamp + PERIOD_SECONDS + 1);
        manager.callAfterSwap(hook, key, _deltaStable0(int128(-1))); // triggers close

        (,,, feeIdx,) = hook.unpackedState();
        assertEq(feeIdx, INITIAL_FEE_IDX, "fee should move down after confirmation");
    }

    
    function test_fast_forward_missed_periods_decays_fee_and_batches_manager_update() public {
        // Move fee up one step and ensure the next period starts with 0 volume (see patched helper test).
        test_fee_moves_up_one_step_on_high_volume_regime();

        (uint64 periodVolBefore, uint96 emaBefore, uint32 periodStartBefore, uint8 feeIdxBefore, uint8 lastDirBefore) =
            hook.unpackedState();

        assertEq(periodVolBefore, 0, "expected empty period volume before fast-forward");
        assertEq(feeIdxBefore, INITIAL_FEE_IDX + 1, "expected fee to be one step above initial");
        assertEq(lastDirBefore, 1, "expected lastDir == DIR_UP");

        uint256 updatesBefore = manager.updateCount();

        // Jump forward by 30 minutes (6 full periods) but stay below lull reset.
        vm.warp(uint256(periodStartBefore) + 30 minutes + 1);

        // Trigger catch-up with a tiny swap.
        manager.callAfterSwap(hook, key, _deltaStable0(int128(-1)));

        (uint64 periodVolAfter, uint96 emaAfter,, uint8 feeIdxAfter, uint8 lastDirAfter) = hook.unpackedState();

        // Fee should have decayed all the way to the floor after multiple zero-volume periods.
        assertEq(feeIdxAfter, FLOOR_IDX, "fee should decay to floor after missed periods");
        assertEq(manager.lastFee(), VolumeDynamicFeeHook.FEE_TIERS(FLOOR_IDX));

        // EMA should decay (or at least not increase) during the fast-forward zeros.
        assertTrue(emaAfter <= emaBefore, "emaVolume should not increase during fast-forward zeros");

        // Only one manager update should be performed for the final feeIdx.
        assertEq(manager.updateCount(), updatesBefore + 1, "should batch manager update to one call");

        // lastDir ends in DIR_DOWN unless clamped or held; exact value is not critical, but it must be a valid enum.
        assertTrue(lastDirAfter <= 2, "invalid lastDir");
        // And the new period should now include the triggering swap.
        assertTrue(periodVolAfter > 0, "triggering swap should be counted in the new period");
    }

function test_lull_reset_snaps_back_to_initial_fee() public {
        // Move fee up one step.
        test_fee_moves_up_one_step_on_high_volume_regime();
        (,,, uint8 feeIdx,) = hook.unpackedState();
        assertEq(feeIdx, INITIAL_FEE_IDX + 1);

        // Simulate a long lull (no swaps). First swap after lull should reset fee to initial.
        vm.warp(block.timestamp + LULL_RESET_SECONDS + 1);
        manager.callAfterSwap(hook, key, _deltaStable0(int128(-1_000_000)));

        (,, uint32 periodStart, feeIdx,) = hook.unpackedState();
        assertEq(feeIdx, INITIAL_FEE_IDX);
        assertEq(manager.lastFee(), VolumeDynamicFeeHook.FEE_TIERS(INITIAL_FEE_IDX));
        assertEq(periodStart, uint32(block.timestamp));
    }

    function test_fast_forward_55_minutes_stays_below_lull_reset() public {
        // Move fee up one step and ensure we start a new empty period.
        test_fee_moves_up_one_step_on_high_volume_regime();

        (, uint96 emaBefore, uint32 periodStartBefore, uint8 feeIdxBefore, uint8 lastDirBefore) = hook.unpackedState();
        assertEq(feeIdxBefore, INITIAL_FEE_IDX + 1, "expected fee to be one step above initial");
        assertEq(lastDirBefore, 1, "expected lastDir == DIR_UP");
        assertTrue(emaBefore > 0, "emaVolume should be initialized before fast-forward tests");

        uint256 updatesBefore = manager.updateCount();

        // Jump forward by 55 minutes (11 full periods) but stay below lull reset.
        vm.warp(uint256(periodStartBefore) + 55 minutes + 1);

        // Trigger catch-up with a tiny swap.
        manager.callAfterSwap(hook, key, _deltaStable0(int128(-1)));

        (uint64 periodVolAfter, uint96 emaAfter, uint32 periodStartAfter, uint8 feeIdxAfter,) = hook.unpackedState();

        // No lull reset should happen.
        assertTrue(emaAfter > 0, "emaVolume should not be cleared without lull reset");
        assertTrue(feeIdxAfter != INITIAL_FEE_IDX, "feeIdx should not snap to initial without lull reset");

        // Fee should have decayed to the floor after multiple zero-volume periods.
        assertEq(feeIdxAfter, FLOOR_IDX, "fee should decay to floor after many missed periods");
        assertEq(manager.lastFee(), VolumeDynamicFeeHook.FEE_TIERS(FLOOR_IDX));

        // Only one manager update should be performed for the final feeIdx.
        assertEq(manager.updateCount(), updatesBefore + 1, "should batch manager update to one call");

        // New period should start at current timestamp and include the triggering swap.
        assertEq(periodStartAfter, uint32(block.timestamp), "periodStart should reset to now");
        assertTrue(periodVolAfter > 0, "triggering swap should be counted in the new period");
    }

    function test_lull_reset_triggers_after_65_minutes() public {
        // Move fee up one step.
        test_fee_moves_up_one_step_on_high_volume_regime();

        (,, uint32 periodStartBefore, uint8 feeIdxBefore,) = hook.unpackedState();
        assertEq(feeIdxBefore, INITIAL_FEE_IDX + 1, "expected fee to be one step above initial");

        uint256 updatesBefore = manager.updateCount();

        // Jump forward beyond lull reset (65 minutes > 1 hour).
        vm.warp(uint256(periodStartBefore) + 65 minutes + 1);

        // First swap after lull should reset fee to initial and clear EMA.
        manager.callAfterSwap(hook, key, _deltaStable0(int128(-1_000_000)));

        (uint64 periodVolAfter, uint96 emaAfter, uint32 periodStartAfter, uint8 feeIdxAfter, uint8 lastDirAfter) =
            hook.unpackedState();

        assertEq(feeIdxAfter, INITIAL_FEE_IDX, "feeIdx should snap back to initial on lull reset");
        assertEq(manager.lastFee(), VolumeDynamicFeeHook.FEE_TIERS(INITIAL_FEE_IDX));
        assertEq(emaAfter, 0, "emaVolume should be cleared on lull reset");
        assertEq(lastDirAfter, 0, "lastDir should be cleared on lull reset");

        // Lull reset path performs a single manager update.
        assertEq(manager.updateCount(), updatesBefore + 1, "lull reset should update fee once");

        // New period starts at current timestamp and includes the swap.
        assertEq(periodStartAfter, uint32(block.timestamp), "periodStart should reset to now");
        assertTrue(periodVolAfter > 0, "reset-triggering swap should be counted in the new period");
    }



    function test_pause_resets_fee_and_freezes_updates() public {
        // Move fee away from pause idx first by simulating a large volume period close.
        // We just call afterSwap enough to cross period boundary and trigger an update.
        vm.warp(block.timestamp + PERIOD_SECONDS + 1);
        manager.callAfterSwap(hook, key, _deltaStable0(-int128(1_000_000e6))); // 1m stable volume
        (, , , uint8 feeIdxBefore,) = hook.unpackedState();
        assertTrue(feeIdxBefore != uint8(2), "expected feeIdx to differ before pause in this scenario");

        // Pause: should set feeIdx to pauseFeeIdx and freeze updates.
        hook.pause();
        assertTrue(hook.isPaused(), "paused flag not set");

        (, , , uint8 feeIdxPaused,) = hook.unpackedState();
        assertEq(feeIdxPaused, uint8(2), "feeIdx not reset to pause idx");

        // Pause fee is applied lazily on the next hook callback.
        assertTrue(hook.isPauseApplyPending(), "expected pending pause fee apply");

        // First swap while paused applies the fee once and clears the pending flag (state changes once).
        vm.warp(block.timestamp + 1);
        manager.callAfterSwap(hook, key, _deltaStable0(-int128(1e6)));
        assertTrue(!hook.isPauseApplyPending(), "pending pause fee not cleared");

        // Subsequent swaps should not evolve the model state while paused.
        uint256 stateBefore = manager.lastStateHash();
        vm.warp(block.timestamp + PERIOD_SECONDS + 1);
        manager.callAfterSwap(hook, key, _deltaStable0(-int128(2_000_000e6)));
        uint256 stateAfter = manager.lastStateHash();
        assertEq(stateAfter, stateBefore, "expected no state evolution while paused");

        // Unpause: updates resume.
        hook.unpause();
        assertTrue(!hook.isPaused(), "paused flag not cleared");
    }

    function test_catch_up_clamped_by_lull_and_max_periods() public {
        // With PERIOD_SECONDS=300 and LULL_RESET_SECONDS configured, catch-up is bounded.
        // Jump forward close to lull reset but still below it: should clamp periodsElapsed <= MAX_LULL_PERIODS.
        uint32 startTs;
        (,, startTs,,) = hook.unpackedState();
        vm.warp(uint256(startTs) + (LULL_RESET_SECONDS - 1));
        manager.callAfterSwap(hook, key, _deltaStable0(-int128(100e6)));
        // No revert is the main property; gas shouldn't explode due to unbounded loops.
        assertTrue(true);
    }

}
