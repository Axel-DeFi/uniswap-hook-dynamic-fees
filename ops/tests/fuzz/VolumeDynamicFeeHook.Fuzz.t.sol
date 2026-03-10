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

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "../utils/VolumeDynamicFeeHookV2DeployHelper.sol";

/// @notice Scenario-based fuzz tests designed to run with many random sequences.
contract VolumeDynamicFeeHookFuzzTest is Test, VolumeDynamicFeeHookV2DeployHelper {
    struct Scenario {
        VolumeDynamicFeeHook hook;
        PoolKey key;
        bool stableIsCurrency0;
        int24 tickSpacing;
    }

    MockPoolManager internal manager;
    Scenario[] internal scenarios;

    uint8 internal constant FLOOR_IDX = 0;

    uint32 internal constant PERIOD_SECONDS = 300;
    uint8 internal constant EMA_PERIODS = 8;
    uint16 internal constant DEADBAND_BPS = 500;
    uint32 internal constant LULL_RESET_SECONDS = 3600;

    uint8 internal constant STABLE_DECIMALS = 6;

    function setUp() public {
        manager = new MockPoolManager();

        address token0 = address(0x0000000000000000000000000000000000001111);
        address token1 = address(0x0000000000000000000000000000000000002222);

        Currency c0 = Currency.wrap(token0);
        Currency c1 = Currency.wrap(token1);

        _deployScenario(c0, c1, true, 10);
        _deployScenario(c0, c1, false, 10);
        _deployScenario(c0, c1, true, 60);
        _deployScenario(c0, c1, false, 60);
    }

    function _deployScenario(Currency c0, Currency c1, bool stableIsCurrency0, int24 tickSpacing) internal {
        Currency usd = stableIsCurrency0 ? c0 : c1;
        uint24[] memory feeTiers = _defaultFeeTiersV2();

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = _constructorArgsV2(
            IPoolManager(address(manager)),
            c0,
            c1,
            tickSpacing,
            usd,
            STABLE_DECIMALS,
            FLOOR_IDX,
            feeTiers,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            address(this),
            address(this),
            V2_INITIAL_HOOK_FEE_PERCENT
        );

        (address mined, bytes32 salt) =
            HookMiner.find(address(this), flags, type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        VolumeDynamicFeeHook hook = _deployHookV2(
            salt,
            IPoolManager(address(manager)),
            c0,
            c1,
            tickSpacing,
            usd,
            STABLE_DECIMALS,
            FLOOR_IDX,
            feeTiers,
            PERIOD_SECONDS,
            EMA_PERIODS,
            DEADBAND_BPS,
            LULL_RESET_SECONDS,
            address(this),
            address(this),
            V2_INITIAL_HOOK_FEE_PERCENT
        );

        assertEq(address(hook), mined, "hook address mismatch");

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });

        manager.callAfterInitialize(hook, key);

        scenarios.push(
            Scenario({hook: hook, key: key, stableIsCurrency0: stableIsCurrency0, tickSpacing: tickSpacing})
        );
    }

    function _deltaStableAbs(bool stableIsCurrency0, uint128 amountStable6)
        internal
        pure
        returns (BalanceDelta)
    {
        // keep one deterministic shape for fuzz; mock manager allows synthetic deltas
        uint128 otherSide = uint128((uint256(amountStable6) * 95) / 100);
        if (stableIsCurrency0) {
            return toBalanceDelta(-int128(amountStable6), int128(otherSide));
        }
        return toBalanceDelta(int128(otherSide), -int128(amountStable6));
    }

    function _deltaZero() internal pure returns (BalanceDelta) {
        return toBalanceDelta(0, 0);
    }

    function _rand(uint256 x) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(x)));
    }

    function _pick(uint256 seed) internal view returns (Scenario storage s) {
        uint256 idx = seed % scenarios.length;
        return scenarios[idx];
    }

    function _assertInvariants(Scenario storage s) internal view {
        (uint64 pv, uint96 ema, uint64 ps, uint8 feeIdx) = s.hook.unpackedState();
        (uint8 f, uint8 c, uint8 e) = (s.hook.floorIdx(), s.hook.cashIdx(), s.hook.extremeIdx());

        assertTrue(ps != 0, "periodStart==0");
        assertTrue(feeIdx < s.hook.feeTierCount(), "feeIdx >= feeTierCount");
        assertTrue(f < c && c < e, "invalid role ordering");
        assertTrue(feeIdx >= f && feeIdx <= e, "feeIdx out of range");

        uint24 fee = s.hook.currentFeeBips();
        assertEq(fee, s.hook.feeTiers(uint256(feeIdx)), "fee tier mismatch");

        // Packed fields must stay inside bit-width bounds.
        (
            uint8 dFeeIdx,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak,,,,
        ) = s.hook.getStateDebug();
        assertEq(dFeeIdx, feeIdx, "debug fee idx mismatch");
        assertTrue(holdRemaining <= 31, "hold overflow");
        assertTrue(upExtremeStreak <= 3, "up streak overflow");
        assertTrue(downStreak <= 7, "down streak overflow");
        assertTrue(emergencyStreak <= 3, "emergency streak overflow");

        // Telemetry values are saturating unsigned and must be bounded.
        assertTrue(pv <= type(uint64).max, "periodVol overflow");
        assertTrue(ema <= type(uint96).max, "ema overflow");
    }

    function testFuzz_randomSequence_invariantsHold(uint256 seed) public {
        Scenario storage s = _pick(seed);

        uint256 expectedHookFees1;
        (, expectedHookFees1) = s.hook.hookFeesAccrued();

        for (uint256 i = 0; i < 100; ++i) {
            uint256 r = _rand(seed ^ i);
            uint256 action = r % 9;
            uint128 amt = uint128(bound(r >> 16, 0, 10_000_000_000));
            uint32 dt = uint32((r >> 160) % (PERIOD_SECONDS * 8));

            if (action <= 3) {
                manager.callAfterSwap(s.hook, s.key, _deltaStableAbs(s.stableIsCurrency0, amt));
                if (manager.lastAfterSwapDelta() > 0) {
                    expectedHookFees1 += uint256(uint128(manager.lastAfterSwapDelta()));
                }
            } else if (action == 4) {
                vm.warp(block.timestamp + PERIOD_SECONDS + (dt % 10));
                manager.callAfterSwap(s.hook, s.key, _deltaZero());
            } else if (action == 5) {
                vm.warp(block.timestamp + (dt % 30));
            } else if (action == 6) {
                s.hook.pause();
            } else if (action == 7) {
                s.hook.unpause();
            } else {
                if (s.hook.isPaused()) {
                    if ((r & 1) == 0) s.hook.emergencyResetToFloor();
                    else s.hook.emergencyResetToCash();
                }
            }

            (, uint256 fees1) = s.hook.hookFeesAccrued();
            assertEq(fees1, expectedHookFees1, "hook fee accrual drift");
            _assertInvariants(s);
        }
    }

    function testFuzz_pending_timelock_state_consistent(uint16 targetPercent, uint256 warpForward) public {
        Scenario storage s = _pick(uint256(keccak256(abi.encodePacked(targetPercent, warpForward))));

        targetPercent = uint16(bound(targetPercent, 0, 10));
        s.hook.scheduleHookFeePercentChange(targetPercent);

        (bool exists, uint16 nextValue, uint64 executeAfter) = s.hook.pendingHookFeePercentChange();
        assertTrue(exists);
        assertEq(nextValue, targetPercent);
        assertEq(executeAfter, uint64(block.timestamp) + 48 hours);

        uint256 jump = bound(warpForward, 0, 3 days);
        vm.warp(block.timestamp + jump);

        if (jump < 48 hours) {
            vm.expectRevert();
            s.hook.executeHookFeePercentChange();
            s.hook.cancelHookFeePercentChange();
        } else {
            s.hook.executeHookFeePercentChange();
            assertEq(s.hook.hookFeePercent(), targetPercent);
        }

        (exists,,) = s.hook.pendingHookFeePercentChange();
        assertFalse(exists);
    }
}
