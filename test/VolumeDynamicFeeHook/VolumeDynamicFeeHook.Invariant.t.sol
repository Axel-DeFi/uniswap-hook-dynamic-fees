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
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

contract VolumeDynamicFeeHookHandler is Test {
    MockPoolManager public manager;
    VolumeDynamicFeeHook public hook;
    PoolKey public key;
    bool public stableIsCurrency0;

    uint32 public periodSeconds;
    uint32 public lullResetSeconds;
    bool public initialized;

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
        uint128 max = uint128(type(int128).max);
        if (amt > max) amt = max;

        BalanceDelta delta =
            stableIsCurrency0 ? toBalanceDelta(-int128(amt), 0) : toBalanceDelta(0, -int128(amt));
        manager.callAfterSwap(hook, key, delta);
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
}

abstract contract VolumeDynamicFeeHookInvariantBase is StdInvariant, Test {
    MockPoolManager internal manager;
    VolumeDynamicFeeHook internal hook;
    PoolKey internal key;
    VolumeDynamicFeeHookHandler internal handler;

    uint8 internal constant INITIAL_FEE_IDX = 3;
    uint8 internal constant FLOOR_IDX = 0;
    uint8 internal constant CAP_IDX = 6;
    uint8 internal constant PAUSE_FEE_IDX = 3;

    uint32 internal constant PERIOD_SECONDS = 300; // fixed by requirement
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

        handler = new VolumeDynamicFeeHookHandler();

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(manager)),
            c0,
            c1,
            tickSpacing(),
            usd,
            STABLE_DECIMALS,
            INITIAL_FEE_IDX,
            FLOOR_IDX,
            CAP_IDX,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            address(handler),
            PAUSE_FEE_IDX
        );

        (address mined, bytes32 salt) =
            HookMiner.find(address(this), flags, type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        hook = new VolumeDynamicFeeHook{salt: salt}(
            IPoolManager(address(manager)),
            c0,
            c1,
            tickSpacing(),
            usd,
            STABLE_DECIMALS,
            INITIAL_FEE_IDX,
            FLOOR_IDX,
            CAP_IDX,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            address(handler),
            PAUSE_FEE_IDX
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
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.opSwap.selector;
        selectors[1] = handler.opClose.selector;
        selectors[2] = handler.opWarp.selector;
        selectors[3] = handler.opPause.selector;
        selectors[4] = handler.opUnpause.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_feeIdxAlwaysWithinBounds() public view {
        (,, uint64 ps, uint8 feeIdx, uint8 lastDir) = hook.unpackedState();
        assertTrue(ps != 0, "not initialized");
        assertTrue(feeIdx >= FLOOR_IDX && feeIdx <= CAP_IDX, "feeIdx out of bounds");
        assertTrue(lastDir <= 2, "lastDir out of range");
    }

    function invariant_pausedMeansPauseFee() public view {
        if (!hook.isPaused()) return;
        (,,, uint8 feeIdx,) = hook.unpackedState();
        assertEq(feeIdx, PAUSE_FEE_IDX, "paused feeIdx mismatch");
        assertEq(hook.currentFeeBips(), hook.feeTiers(uint256(PAUSE_FEE_IDX)), "paused fee mismatch");
    }

    function invariant_currentFeeMatchesTier() public view {
        (,,, uint8 feeIdx,,) = _unpack();
        assertEq(hook.currentFeeBips(), hook.feeTiers(uint256(feeIdx)), "fee tier mismatch");
    }

    function _unpack()
        internal
        view
        returns (uint64 pv, uint96 ema, uint64 ps, uint8 feeIdx, uint8 lastDir, bool paused)
    {
        (pv, ema, ps, feeIdx, lastDir) = hook.unpackedState();
        paused = hook.isPaused();
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
