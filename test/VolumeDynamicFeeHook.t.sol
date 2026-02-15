// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {VolumeDynamicFeeHook} from "../src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

/// @notice Minimal compilation-focused tests.
/// @dev We keep this intentionally simple to unblock `forge build`.
contract VolumeDynamicFeeHookTest is Test {
    MockPoolManager internal manager;
    VolumeDynamicFeeHook internal hook;

    PoolKey internal key;

    // constructor params
    uint8 internal constant INITIAL_FEE_IDX = 3;
    uint8 internal constant FLOOR_FEE_IDX = 0;
    uint8 internal constant CAP_FEE_IDX = 6;
    uint8 internal constant PAUSE_FEE_IDX = 3;

    function setUp() public {
        manager = new MockPoolManager();

        Currency c0 = Currency.wrap(address(0x1111111111111111111111111111111111111111));
        Currency c1 = Currency.wrap(address(0x2222222222222222222222222222222222222222));

        hook = new VolumeDynamicFeeHook(
            // cast mock to interface type
            IPoolManager(address(manager)),
            c0,
            c1,
            60,
            c0, // stable is currency0
            6,  // stable decimals
            INITIAL_FEE_IDX,
            FLOOR_FEE_IDX,
            CAP_FEE_IDX,
            1 hours,
            3,      // ema periods
            100,    // deadband bps
            24 hours,
            address(this),
            PAUSE_FEE_IDX
        );

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: uint24(LPFeeLibrary.DYNAMIC_FEE_FLAG),
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // initialize once via manager so BaseHook's onlyPoolManager guard is satisfied
        manager.callAfterInitialize(hook, key);
    }

    function test_build_smoke() public view {
        assertTrue(address(hook) != address(0));
        assertEq(manager.updateCount(), 1, "expected fee to be initialized once");
    }

    function test_swap_call_compiles_and_runs() public {
        // stable is currency0, so set amount0 delta
        BalanceDelta delta = toBalanceDelta(int128(-1_000_000), 0);
        manager.callAfterSwap(hook, key, delta);
        assertTrue(manager.updateCount() >= 1);
    }
}
