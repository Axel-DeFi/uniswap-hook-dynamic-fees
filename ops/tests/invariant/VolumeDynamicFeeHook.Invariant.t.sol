// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "../utils/VolumeDynamicFeeHookV2DeployHelper.sol";

contract VolumeDynamicFeeHookHandler is Test {
    MockPoolManager public manager;
    VolumeDynamicFeeHook public hook;
    PoolKey public key;
    bool public stableIsCurrency0;

    uint32 public periodSeconds;
    uint32 public lullResetSeconds;
    bool public initialized;

    uint256 public expectedHookFees0;
    uint256 public expectedHookFees1;

    function init(
        MockPoolManager _manager,
        VolumeDynamicFeeHook _hook,
        PoolKey memory _key,
        bool _stableIsCurrency0
    ) external {
        require(!initialized, "already initialized");
        manager = _manager;
        hook = _hook;
        key = _key;
        stableIsCurrency0 = _stableIsCurrency0;

        periodSeconds = _hook.periodSeconds();
        lullResetSeconds = _hook.lullResetSeconds();
        initialized = true;
    }

    function opSwap(uint128 amountStable6) external {
        require(initialized, "not init");

        uint128 amt = amountStable6;
        if (amt > uint128(type(int128).max)) amt = uint128(type(int128).max);

        BalanceDelta delta;
        uint128 otherSide = uint128((uint256(amt) * 95) / 100);
        if (stableIsCurrency0) {
            delta = toBalanceDelta(-int128(amt), int128(otherSide));
        } else {
            delta = toBalanceDelta(int128(otherSide), -int128(amt));
        }

        manager.callAfterSwap(hook, key, delta);

        int128 hookDelta = manager.lastAfterSwapDelta();
        if (hookDelta > 0) {
            // Handler always swaps with params (zeroForOne=true, amountSpecified=-1) in MockPoolManager,
            // so HookFee is always accrued in token1.
            expectedHookFees1 += uint256(uint128(hookDelta));
        }
    }

    function opClose(uint32 dt) external {
        require(initialized, "not init");

        uint256 jitter = uint256(dt) % 10;
        vm.warp(block.timestamp + uint256(periodSeconds) + jitter);
        manager.callAfterSwap(hook, key, toBalanceDelta(0, 0));
    }

    function opWarp(uint32 dt) external {
        require(initialized, "not init");

        uint256 step = bound(uint256(dt), 0, uint256(lullResetSeconds) * 2);
        vm.warp(block.timestamp + step);
    }

    function opPause() external {
        require(initialized, "not init");
        hook.pause();
    }

    function opUnpause() external {
        require(initialized, "not init");
        hook.unpause();
    }

    function opEmergencyFloor() external {
        require(initialized, "not init");
        if (!hook.isPaused()) return;
        hook.emergencyResetToFloor();
    }

    function opEmergencyCash() external {
        require(initialized, "not init");
        if (!hook.isPaused()) return;
        hook.emergencyResetToCash();
    }

    function opScheduleHookFee(uint16 nextPercent) external {
        require(initialized, "not init");

        nextPercent = uint16(bound(nextPercent, 0, 10));
        (bool exists,,) = hook.pendingHookFeePercentChange();
        if (exists) return;
        hook.scheduleHookFeePercentChange(nextPercent);
    }

    function opCancelHookFee() external {
        require(initialized, "not init");

        (bool exists,,) = hook.pendingHookFeePercentChange();
        if (!exists) return;
        hook.cancelHookFeePercentChange();
    }

    function opExecuteHookFee(uint32 warpBy) external {
        require(initialized, "not init");

        uint256 step = bound(uint256(warpBy), 0, 3 days);
        vm.warp(block.timestamp + step);

        (bool exists,, uint64 executeAfter) = hook.pendingHookFeePercentChange();
        if (!exists) return;

        if (block.timestamp < executeAfter) {
            return;
        }
        hook.executeHookFeePercentChange();
    }
}

abstract contract VolumeDynamicFeeHookInvariantBase is
    StdInvariant,
    Test,
    VolumeDynamicFeeHookV2DeployHelper
{
    MockPoolManager internal manager;
    VolumeDynamicFeeHook internal hook;
    PoolKey internal key;
    VolumeDynamicFeeHookHandler internal handler;

    uint8 internal constant FLOOR_IDX = 0;

    uint32 internal constant PERIOD_SECONDS = 300;
    uint8 internal constant EMA_PERIODS = 8;
    uint16 internal constant DEADBAND_BPS = 500;
    uint32 internal constant LULL_RESET_SECONDS = 3600;

    uint8 internal constant STABLE_DECIMALS = 6;

    function stableIsCurrency0() internal pure virtual returns (bool);
    function tickSpacing() internal pure virtual returns (int24);

    function setUp() public {
        manager = new MockPoolManager();

        address token0 = address(0x0000000000000000000000000000000000001111);
        address token1 = address(0x0000000000000000000000000000000000002222);

        Currency c0 = Currency.wrap(token0);
        Currency c1 = Currency.wrap(token1);
        Currency usd = stableIsCurrency0() ? c0 : c1;
        uint24[] memory feeTiers = _defaultFeeTiersV2();

        handler = new VolumeDynamicFeeHookHandler();

        uint160 flags =
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

        bytes memory constructorArgs = _constructorArgsV2(
            IPoolManager(address(manager)),
            c0,
            c1,
            tickSpacing(),
            usd,
            STABLE_DECIMALS,
            FLOOR_IDX,
            feeTiers,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            address(handler),
            address(handler),
            V2_INITIAL_HOOK_FEE_PERCENT
        );

        (address mined, bytes32 salt) =
            HookMiner.find(address(this), flags, type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        hook = _deployHookV2(
            salt,
            IPoolManager(address(manager)),
            c0,
            c1,
            tickSpacing(),
            usd,
            STABLE_DECIMALS,
            FLOOR_IDX,
            feeTiers,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            address(handler),
            address(handler),
            V2_INITIAL_HOOK_FEE_PERCENT
        );

        assertEq(address(hook), mined, "hook address mismatch");

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing(),
            hooks: IHooks(address(hook))
        });

        manager.callAfterInitialize(hook, key);
        handler.init(manager, hook, key, stableIsCurrency0());

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.opSwap.selector;
        selectors[1] = handler.opClose.selector;
        selectors[2] = handler.opWarp.selector;
        selectors[3] = handler.opPause.selector;
        selectors[4] = handler.opUnpause.selector;
        selectors[5] = handler.opEmergencyFloor.selector;
        selectors[6] = handler.opEmergencyCash.selector;
        selectors[7] = handler.opScheduleHookFee.selector;
        selectors[8] = handler.opCancelHookFee.selector;
        selectors[9] = handler.opExecuteHookFee.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_feeIdxAlwaysWithinBounds() public view {
        (,, uint64 ps, uint8 feeIdx) = hook.unpackedState();
        assertTrue(ps != 0, "not initialized");
        assertTrue(feeIdx < hook.feeTierCount(), "feeIdx >= feeTierCount");
        assertTrue(feeIdx >= hook.floorIdx() && feeIdx <= hook.extremeIdx(), "feeIdx out of range");
    }

    function invariant_roleOrderingAlwaysStrict() public view {
        assertTrue(hook.floorIdx() < hook.cashIdx(), "floor !< cash");
        assertTrue(hook.cashIdx() < hook.extremeIdx(), "cash !< extreme");
    }

    function invariant_tiersStrictlyIncreasing() public view {
        uint16 n = hook.feeTierCount();
        for (uint256 i = 1; i < n; ++i) {
            assertTrue(hook.feeTiers(i - 1) < hook.feeTiers(i), "tiers not strictly increasing");
        }
    }

    function invariant_packedStateFieldBounds() public view {
        (uint8 feeIdx, uint8 holdRemaining, uint8 upExtremeStreak, uint8 downStreak, uint8 emergencyStreak,,,,) =
            hook.getStateDebug();

        assertTrue(feeIdx < hook.feeTierCount(), "packed feeIdx overflow");
        assertTrue(holdRemaining <= 31, "packed hold overflow");
        assertTrue(upExtremeStreak <= 3, "packed up overflow");
        assertTrue(downStreak <= 7, "packed down overflow");
        assertTrue(emergencyStreak <= 3, "packed emergency overflow");
    }

    function invariant_pendingTimelockStateConsistent() public view {
        (bool exists, uint16 nextValue, uint64 executeAfter) = hook.pendingHookFeePercentChange();
        if (!exists) {
            assertEq(nextValue, 0, "stale pending value");
            assertEq(executeAfter, 0, "stale pending eta");
            return;
        }

        assertTrue(nextValue <= 10, "pending percent over cap");
        assertTrue(executeAfter > 0, "invalid pending eta");
    }

    function invariant_hookFeeAccountingMatchesObservedDelta() public view {
        (uint256 hookFees0, uint256 hookFees1) = hook.hookFeesAccrued();
        assertEq(hookFees0, handler.expectedHookFees0(), "unexpected token0 hook fees");
        assertEq(hookFees1, handler.expectedHookFees1(), "unexpected token1 hook fees");
    }
}

contract VolumeDynamicFeeHookInvariant_Stable0_Tick10 is VolumeDynamicFeeHookInvariantBase {
    function stableIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function tickSpacing() internal pure override returns (int24) {
        return 10;
    }
}

contract VolumeDynamicFeeHookInvariant_Stable1_Tick10 is VolumeDynamicFeeHookInvariantBase {
    function stableIsCurrency0() internal pure override returns (bool) {
        return false;
    }

    function tickSpacing() internal pure override returns (int24) {
        return 10;
    }
}

contract VolumeDynamicFeeHookInvariant_Stable0_Tick60 is VolumeDynamicFeeHookInvariantBase {
    function stableIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function tickSpacing() internal pure override returns (int24) {
        return 60;
    }
}

contract VolumeDynamicFeeHookInvariant_Stable1_Tick60 is VolumeDynamicFeeHookInvariantBase {
    function stableIsCurrency0() internal pure override returns (bool) {
        return false;
    }

    function tickSpacing() internal pure override returns (int24) {
        return 60;
    }
}
