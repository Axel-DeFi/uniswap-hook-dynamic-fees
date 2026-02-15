// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {HookMiner} from "@uniswap/v4-hooks-public/src/utils/HookMiner.sol";

import {VolumeDynamicFeeHook} from "../src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

/// @notice Minimal local-deploy test:
/// 1) mines a CREATE2 salt so the hook address has correct v4 flags,
/// 2) deploys the hook via CREATE2 (inside the test VM),
/// 3) initializes a dynamic-fee pool via a mock pool manager.
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

        // Choose deterministic addresses (stable must be either token0 or token1).
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
            address(this),
            PAUSE_FEE_IDX
        );

        (address mined, bytes32 salt) = HookMiner.find(address(this), flags, type(VolumeDynamicFeeHook).creationCode, constructorArgs);

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
            address(this),
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

    function test_localDeploy_and_afterInitialize_setsFee() public {
        // Calls hook.afterInitialize with msg.sender == poolManager (the mock).
        manager.callAfterInitialize(hook, key);

        assertEq(manager.updateCount(), 1, "expected 1 fee update");
        assertEq(manager.lastFee(), hook.currentFeeBips(), "fee mismatch");
    }

    function test_localDeploy_and_afterSwap_updatesVolumeState() public {
        manager.callAfterInitialize(hook, key);

        // Simulate a swap where stable (currency0) amount changes by 1,000 USDC (6 decimals).
        // Sign doesn't matter: hook takes absolute value.
        BalanceDelta delta = toBalanceDelta(int128(-1_000_000_000), 0);
        manager.callAfterSwap(hook, key, delta);

        (uint64 periodVolUsd6, uint96 emaUsd6, uint32 periodStart, uint8 feeIdx, uint8 lastDir) = hook.unpackedState();

        // Silence "unused" warnings; also nice sanity checks.
        assertTrue(periodStart != 0, "expected initialized state");
        assertTrue(periodVolUsd6 != 0, "expected volume to accumulate");
        assertTrue(feeIdx <= CAP_IDX, "feeIdx in range");
        assertTrue(lastDir <= 2, "dir in range");
        assertTrue(emaUsd6 >= 0, "ema ok");
    }
}
