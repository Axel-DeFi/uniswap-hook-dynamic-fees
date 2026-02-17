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

        int24 tickSpacing = 60;

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

    function test_pause_unpause_applyFeeOnNextSwap() public {
        manager.callAfterInitialize(hook, key);
        assertEq(manager.updateCount(), 1, "expected 1 fee update after init");

        // Pause should NOT immediately call PoolManager; it sets a pending apply.
        hook.pause();
        assertTrue(hook.isPaused(), "expected paused");
        assertEq(manager.updateCount(), 1, "pause should not update fee immediately");

        // Next swap should apply pause fee.
        manager.callAfterSwap(hook, key, _deltaStableAbs1k());
        assertEq(manager.updateCount(), 2, "expected pause fee update on next swap");

        uint24 pauseFee = hook.feeTiers(uint256(PAUSE_FEE_IDX));
        assertEq(manager.lastFee(), pauseFee, "pause fee mismatch");

        // Unpause should again defer fee update to next swap.
        hook.unpause();
        assertTrue(!hook.isPaused(), "expected unpaused");
        assertEq(manager.updateCount(), 2, "unpause should not update fee immediately");

        manager.callAfterSwap(hook, key, _deltaStableAbs1k());
        assertEq(manager.updateCount(), 3, "expected fee update on next swap after unpause");

        uint24 expected = hook.feeTiers(uint256(INITIAL_FEE_IDX));
        assertEq(manager.lastFee(), expected, "unpause fee mismatch");
    }

    function test_pause_applyPendingPause_appliesImmediately_viaUnlock() public {
        manager.callAfterInitialize(hook, key);
        assertEq(manager.updateCount(), 1, "expected 1 fee update after init");

        hook.pause();
        assertTrue(hook.isPaused(), "expected paused");
        assertTrue(hook.isPauseApplyPending(), "expected pending apply");
        assertEq(manager.updateCount(), 1, "pause should not update fee immediately");

        hook.applyPendingPause();
        assertEq(manager.updateCount(), 2, "expected immediate fee update via unlock");

        uint24 pauseFee = hook.feeTiers(uint256(PAUSE_FEE_IDX));
        assertEq(manager.lastFee(), pauseFee, "pause fee mismatch");

        assertTrue(!hook.isPauseApplyPending(), "expected pending cleared");
    }

    function test_unpause_applyPendingPause_appliesImmediately_viaUnlock() public {
        manager.callAfterInitialize(hook, key);

        hook.pause();
        hook.applyPendingPause();
        assertEq(manager.updateCount(), 2, "expected pause applied");

        hook.unpause();
        assertTrue(!hook.isPaused(), "expected unpaused");
        assertTrue(hook.isPauseApplyPending(), "expected pending apply");

        hook.applyPendingPause();
        assertEq(manager.updateCount(), 3, "expected immediate unpause fee update via unlock");

        uint24 expected = hook.feeTiers(uint256(INITIAL_FEE_IDX));
        assertEq(manager.lastFee(), expected, "unpause fee mismatch");

        assertTrue(!hook.isPauseApplyPending(), "expected pending cleared");
    }
}
