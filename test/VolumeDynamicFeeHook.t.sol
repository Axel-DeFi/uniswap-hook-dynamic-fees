// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "test/mocks/MockPoolManager.sol";

/// @notice Minimal security-hardening tests:
/// - Deploy hook locally with correct v4 address flags (CREATE2 + mined salt)
/// - Verify basic access control (only PoolManager for callbacks)
/// - Verify key validation + expected revert paths
/// - Verify pause/unpause fee application via PoolManager
///
/// @dev This is NOT a network deploy. Everything runs inside Foundry's local EVM during `forge test`.
contract VolumeDynamicFeeHookTest is Test {
    MockPoolManager internal manager;
    VolumeDynamicFeeHook internal hook;

    PoolKey internal key;

    // Config (keep these simple for now)
    uint8 internal constant INITIAL_FEE_IDX = 3;
    uint8 internal constant FLOOR_IDX = 0;
    uint8 internal constant CAP_IDX = 6;
    uint8 internal constant PAUSE_FEE_IDX = 3;

    uint32 internal constant PERIOD_SECONDS = 3600; // 1h
    uint8 internal constant EMA_PERIODS = 8;
    uint16 internal constant DEADBAND_BPS = 500; // 5%
    uint32 internal constant LULL_RESET_SECONDS = 86400; // 24h

    uint8 internal constant STABLE_DECIMALS = 6;

    function setUp() public {
        manager = new MockPoolManager();

        // Deterministic test addresses (stable must be either token0 or token1).
        // IMPORTANT: currency0 must be < currency1 by address.
        address token0 = address(0x0000000000000000000000000000000000001111);
        address token1 = address(0x0000000000000000000000000000000000002222);
        address stable = token0;

        Currency c0 = Currency.wrap(token0);
        Currency c1 = Currency.wrap(token1);
        Currency usd = Currency.wrap(stable);

        int24 tickSpacing = 10;

        // Hook must have flags encoded in its address.
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(manager)),
            c0,
            c1,
            tickSpacing,
            usd,
            STABLE_DECIMALS,
            INITIAL_FEE_IDX,
            FLOOR_IDX,
            CAP_IDX,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            address(this), // guardian
            PAUSE_FEE_IDX
        );

        (address mined, bytes32 salt) =
            HookMiner.find(address(this), flags, type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        hook = new VolumeDynamicFeeHook{salt: salt}(
            IPoolManager(address(manager)),
            c0,
            c1,
            tickSpacing,
            usd,
            STABLE_DECIMALS,
            INITIAL_FEE_IDX,
            FLOOR_IDX,
            CAP_IDX,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            address(this), // guardian
            PAUSE_FEE_IDX
        );

        assertEq(address(hook), mined, "hook address mismatch");

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
    }

    function _deltaStableAbs1k() internal pure returns (BalanceDelta) {
        // 1,000 units of a 6-decimal stable (e.g. USDC) => 1_000_000_000
        return toBalanceDelta(int128(-1_000_000_000), 0);
    }

    function _deltaStableAbs(uint128 amountStable6) internal pure returns (BalanceDelta) {
        return toBalanceDelta(-int128(amountStable6), 0);
    }

    function _deltaZero() internal pure returns (BalanceDelta) {
        return toBalanceDelta(0, 0);
    }

    // -----------------------------------------------------------------------
    // Happy path smoke
    // -----------------------------------------------------------------------

    function test_localDeploy_and_afterInitialize_setsFee() public {
        manager.callAfterInitialize(hook, key);

        assertEq(manager.updateCount(), 1, "expected 1 fee update");
        assertEq(manager.lastFee(), hook.currentFeeBips(), "fee mismatch");
    }

    function test_localDeploy_and_afterSwap_updatesVolumeState() public {
        manager.callAfterInitialize(hook, key);

        manager.callAfterSwap(hook, key, _deltaStableAbs1k());

        (uint64 periodVolUsd6, uint96 emaUsd6, uint32 periodStart, uint8 feeIdx, uint8 lastDir) =
            hook.unpackedState();

        assertTrue(periodStart != 0, "expected initialized state");
        assertTrue(periodVolUsd6 != 0, "expected volume to accumulate");
        assertTrue(feeIdx <= CAP_IDX, "feeIdx in range");
        assertTrue(lastDir <= 2, "dir in range");
        assertTrue(emaUsd6 >= 0, "ema ok");
    }

    // -----------------------------------------------------------------------
    // Hardening: access control / revert paths
    // -----------------------------------------------------------------------

    function test_onlyPoolManager_can_call_afterInitialize() public {
        vm.expectRevert();
        hook.afterInitialize(address(0xBEEF), key, 0, 0);
    }

    function test_onlyPoolManager_can_call_afterSwap() public {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0});

        vm.expectRevert();
        hook.afterSwap(address(0xBEEF), key, params, _deltaStableAbs1k(), "");
    }

    function test_afterSwap_beforeInitialize_reverts() public {
        vm.expectRevert(VolumeDynamicFeeHook.NotInitialized.selector);
        manager.callAfterSwap(hook, key, _deltaStableAbs1k());
    }

    function test_afterInitialize_twice_reverts() public {
        manager.callAfterInitialize(hook, key);

        vm.expectRevert(VolumeDynamicFeeHook.AlreadyInitialized.selector);
        manager.callAfterInitialize(hook, key);
    }

    function test_invalidPoolKey_reverts() public {
        PoolKey memory bad = key;
        bad.tickSpacing = int24(int256(key.tickSpacing) + 1);

        vm.expectRevert(VolumeDynamicFeeHook.InvalidPoolKey.selector);
        manager.callAfterInitialize(hook, bad);
    }

    function test_nonDynamicFeePool_reverts() public {
        PoolKey memory bad = key;
        bad.fee = 3000; // fixed fee, not dynamic

        vm.expectRevert(VolumeDynamicFeeHook.NotDynamicFeePool.selector);
        manager.callAfterInitialize(hook, bad);
    }

    function test_pause_onlyGuardian() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(VolumeDynamicFeeHook.NotGuardian.selector);
        hook.pause();
    }

    function test_pause_unpause_applyFeeImmediately() public {
        manager.callAfterInitialize(hook, key);
        assertEq(manager.updateCount(), 1, "expected 1 fee update after init");

        hook.pause();
        assertTrue(hook.isPaused(), "expected paused");
        assertEq(manager.updateCount(), 2, "expected immediate pause fee update");

        uint24 pauseFee = hook.feeTiers(uint256(PAUSE_FEE_IDX));
        assertEq(manager.lastFee(), pauseFee, "pause fee mismatch");

        hook.unpause();
        assertTrue(!hook.isPaused(), "expected unpaused");
        assertEq(manager.updateCount(), 3, "expected immediate unpause fee update");

        uint24 expected = hook.feeTiers(uint256(INITIAL_FEE_IDX));
        assertEq(manager.lastFee(), expected, "unpause fee mismatch");
    }

    function test_pause_beforeInitialize_appliesOnInitialize() public {
        hook.pause();
        assertTrue(hook.isPaused(), "expected paused");
        assertEq(manager.updateCount(), 0, "no fee update before initialize");

        manager.callAfterInitialize(hook, key);
        assertEq(manager.updateCount(), 1, "expected pause fee set on initialize");

        uint24 pauseFee = hook.feeTiers(uint256(PAUSE_FEE_IDX));
        assertEq(manager.lastFee(), pauseFee, "pause fee mismatch after initialize");
        assertTrue(hook.isPaused(), "expected still paused");

        hook.unpause();
        assertEq(manager.updateCount(), 2, "expected immediate unpause fee update");

        uint24 expected = hook.feeTiers(uint256(INITIAL_FEE_IDX));
        assertEq(manager.lastFee(), expected, "unpause fee mismatch");
        assertTrue(!hook.isPaused(), "expected unpaused");
    }

    // -----------------------------------------------------------------------
    // Fee model behavior (deadband / reversal lock / catch-up / lull reset)
    // -----------------------------------------------------------------------

    function test_deadband_keeps_fee_unchanged() public {
        manager.callAfterInitialize(hook, key);

        // Period #1: seed EMA with 1,000 stable swap volume.
        manager.callAfterSwap(hook, key, _deltaStableAbs1k());
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        // Period #2 close volume ~= 97.5% of Period #1 (inside 5% deadband after EMA update).
        manager.callAfterSwap(hook, key, _deltaStableAbs(975_000_000));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        (,, uint32 periodStart, uint8 feeIdx, uint8 lastDir) = hook.unpackedState();
        assertTrue(periodStart != 0, "expected initialized");
        assertEq(feeIdx, INITIAL_FEE_IDX, "fee should remain unchanged in deadband");
        assertEq(lastDir, 0, "dir should be NONE");
    }

    function test_reversal_lock_blocks_immediate_flip() public {
        manager.callAfterInitialize(hook, key);

        // Period #1: seed EMA (no fee move).
        manager.callAfterSwap(hook, key, _deltaStableAbs1k());
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        // Period #2: zero volume -> move DOWN by one step.
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        (,, uint32 ps1, uint8 feeAfterDown, uint8 dirAfterDown) = hook.unpackedState();
        assertTrue(ps1 != 0, "expected initialized");
        assertEq(feeAfterDown, INITIAL_FEE_IDX - 1, "expected one step down");
        assertEq(dirAfterDown, 2, "expected DOWN dir");

        // Period #3: high volume would normally signal UP, but reversal lock must block immediate flip.
        manager.callAfterSwap(hook, key, _deltaStableAbs(2_000_000_000));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        (,, uint32 ps2, uint8 feeAfterFlipAttempt, uint8 dirAfterFlipAttempt) = hook.unpackedState();
        assertTrue(ps2 != 0, "expected initialized");
        assertEq(feeAfterFlipAttempt, INITIAL_FEE_IDX - 1, "reversal lock should block flip");
        assertEq(dirAfterFlipAttempt, 0, "dir should reset to NONE after blocked reversal");
    }

    function test_catchup_applies_multiple_period_closes_in_one_swap() public {
        manager.callAfterInitialize(hook, key);
        assertEq(manager.updateCount(), 1, "expected one update on init");

        // Accumulate volume for the first close.
        manager.callAfterSwap(hook, key, _deltaStableAbs1k());

        // Miss three full periods but stay below lull reset threshold.
        vm.warp(block.timestamp + (PERIOD_SECONDS * 3) + 10);
        manager.callAfterSwap(hook, key, _deltaZero());

        (,, uint32 periodStart, uint8 feeIdx, uint8 lastDir) = hook.unpackedState();
        assertTrue(periodStart != 0, "expected initialized");
        assertEq(feeIdx, INITIAL_FEE_IDX - 2, "expected two-step downward catch-up");
        assertEq(lastDir, 2, "expected DOWN dir after catch-up");

        // One PoolManager write for the final fee after in-memory fast-forward.
        assertEq(manager.updateCount(), 2, "expected a single dynamic fee write during catch-up");
    }

    function test_lull_reset_restores_initial_fee_and_clears_ema() public {
        manager.callAfterInitialize(hook, key);

        // Seed EMA and move fee down by one step.
        manager.callAfterSwap(hook, key, _deltaStableAbs1k());
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        (uint64 pvBefore, uint96 emaBefore, uint32 psBefore, uint8 feeBefore, uint8 dirBefore) =
            hook.unpackedState();
        assertTrue(psBefore != 0, "expected initialized");
        assertEq(feeBefore, INITIAL_FEE_IDX - 1, "expected fee moved down before lull");
        assertTrue(emaBefore > 0, "expected non-zero EMA before lull");
        assertEq(dirBefore, 2, "expected DOWN dir before lull");
        assertEq(pvBefore, 0, "expected zero period volume after close");

        // Long inactivity triggers lull reset on the next swap.
        vm.warp(block.timestamp + LULL_RESET_SECONDS);
        manager.callAfterSwap(hook, key, _deltaZero());

        (uint64 pvAfter, uint96 emaAfter, uint32 psAfter, uint8 feeAfter, uint8 dirAfter) =
            hook.unpackedState();
        assertTrue(psAfter > psBefore, "expected periodStart reset");
        assertEq(feeAfter, INITIAL_FEE_IDX, "expected fee reset to initial on lull");
        assertEq(emaAfter, 0, "expected EMA cleared on lull reset");
        assertEq(dirAfter, 0, "expected dir reset to NONE");
        assertEq(pvAfter, 0, "expected zero period volume after zero trigger swap");
    }
}
