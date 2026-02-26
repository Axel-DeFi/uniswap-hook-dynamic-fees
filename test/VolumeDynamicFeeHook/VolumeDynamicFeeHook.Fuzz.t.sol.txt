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
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

/// @notice Scenario-based fuzz tests designed to be run many times.
/// @dev "Full" becomes heavier by increasing fuzz runs and by covering multiple valid scenarios.
contract VolumeDynamicFeeHookFuzzTest is Test {
    struct Scenario {
        VolumeDynamicFeeHook hook;
        PoolKey key;
        bool stableIsCurrency0;
        int24 tickSpacing;
    }

    MockPoolManager internal manager;
    Scenario[] internal scenarios;

    uint8 internal constant INITIAL_FEE_IDX = 3;
    uint8 internal constant FLOOR_IDX = 0;
    uint8 internal constant CAP_IDX = 6;
    uint8 internal constant PAUSE_FEE_IDX = 3;

    uint32 internal constant PERIOD_SECONDS = 300; // fixed by requirement
    uint8 internal constant EMA_PERIODS = 8;
    uint16 internal constant DEADBAND_BPS = 500;
    uint32 internal constant LULL_RESET_SECONDS = 3600; // >= PERIOD_SECONDS

    uint8 internal constant STABLE_DECIMALS = 6;

    function setUp() public {
        manager = new MockPoolManager();

        // Deterministic addresses (currency0 must be < currency1).
        address token0 = address(0x0000000000000000000000000000000000001111);
        address token1 = address(0x0000000000000000000000000000000000002222);

        Currency c0 = Currency.wrap(token0);
        Currency c1 = Currency.wrap(token1);

        // 4 scenarios: stable side x tick spacing.
        _deployScenario(c0, c1, true, 10);
        _deployScenario(c0, c1, false, 10);
        _deployScenario(c0, c1, true, 60);
        _deployScenario(c0, c1, false, 60);
    }

    function _deployScenario(Currency c0, Currency c1, bool stableIsCurrency0, int24 tickSpacing) internal {
        Currency usd = stableIsCurrency0 ? c0 : c1;

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

        (address mined, bytes32 salt) =
            HookMiner.find(address(this), flags, type(VolumeDynamicFeeHook).creationCode, constructorArgs);

        VolumeDynamicFeeHook hook = new VolumeDynamicFeeHook{salt: salt}(
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
        if (stableIsCurrency0) {
            return toBalanceDelta(-int128(amountStable6), 0);
        }
        return toBalanceDelta(0, -int128(amountStable6));
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
        (uint64 pv, uint96 ema, uint64 ps, uint8 feeIdx, uint8 lastDir) = s.hook.unpackedState();

        assertTrue(ps != 0, "periodStart==0");
        assertTrue(feeIdx >= FLOOR_IDX && feeIdx <= CAP_IDX, "feeIdx out of bounds");
        assertTrue(lastDir <= 2, "lastDir out of range");

        if (s.hook.isPaused()) {
            assertEq(feeIdx, PAUSE_FEE_IDX, "paused feeIdx mismatch");
            assertEq(pv, 0, "paused pv must be 0");
            assertEq(ema, 0, "paused ema must be 0");
        }

        uint24 fee = s.hook.currentFeeBips();
        assertEq(fee, s.hook.feeTiers(uint256(feeIdx)), "fee tier mismatch");
    }

    /// @notice Randomized long sequence: swaps + time jumps + pause/unpause.
    function testFuzz_randomSequence_invariantsHold(uint256 seed) public {
        Scenario storage s = _pick(seed);
        if (s.hook.isPaused()) s.hook.unpause();

        for (uint256 i = 0; i < 80; i++) {
            uint256 r = _rand(seed ^ i);
            uint256 action = r % 6;

            uint128 amt = uint128((r >> 16) % 5_000_000_000); // up to 5,000 stable (6d)
            uint32 dt = uint32((r >> 160) % (PERIOD_SECONDS * 6)); // up to 6 periods

            if (action == 0) {
                manager.callAfterSwap(s.hook, s.key, _deltaStableAbs(s.stableIsCurrency0, amt));
            } else if (action == 1) {
                vm.warp(block.timestamp + PERIOD_SECONDS + (dt % 10));
                manager.callAfterSwap(s.hook, s.key, _deltaZero());
            } else if (action == 2) {
                vm.warp(block.timestamp + (dt % 30));
            } else if (action == 3) {
                vm.warp(block.timestamp + dt);
            } else if (action == 4) {
                s.hook.pause();
            } else {
                s.hook.unpause();
            }

            _assertInvariants(s);
        }
    }

    /// @notice Lull reset must always restore initial fee and clear EMA.
    function testFuzz_lullReset_restoresInitialAndClearsEma(uint256 seed) public {
        Scenario storage s = _pick(seed);

        // Seed EMA.
        uint128 vol = uint128(bound(seed, 2_000_000, 5_000_000_000));
        manager.callAfterSwap(s.hook, s.key, _deltaStableAbs(s.stableIsCurrency0, vol));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(s.hook, s.key, _deltaZero());

        // Close another period with zero volume (move down by one).
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(s.hook, s.key, _deltaZero());

        (, uint96 emaBefore,, uint8 feeBefore,) = s.hook.unpackedState();
        assertTrue(emaBefore > 0, "EMA should be seeded");
        assertTrue(feeBefore != INITIAL_FEE_IDX, "fee should differ before lull");

        // Warp beyond lull threshold and trigger.
        vm.warp(block.timestamp + LULL_RESET_SECONDS + 1);
        manager.callAfterSwap(s.hook, s.key, _deltaZero());

        (, uint96 emaAfter,, uint8 feeAfter, uint8 dirAfter) = s.hook.unpackedState();
        assertEq(feeAfter, INITIAL_FEE_IDX, "fee must reset to initial");
        assertEq(emaAfter, 0, "EMA must clear on lull reset");
        assertEq(dirAfter, 0, "dir must reset on lull reset");
    }

    /// @notice Within deadband around EMA, fee should not change.
    function testFuzz_deadband_keepsFeeUnchanged(uint256 seed) public {
        Scenario storage s = _pick(seed);

        uint128 base = uint128(bound(seed, 2_000_000, 5_000_000_000));
        uint16 bps = uint16(seed % (DEADBAND_BPS + 1));

        manager.callAfterSwap(s.hook, s.key, _deltaStableAbs(s.stableIsCurrency0, base));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(s.hook, s.key, _deltaZero());

        uint256 scaled = (uint256(base) * (10_000 - uint256(bps))) / 10_000;
        manager.callAfterSwap(s.hook, s.key, _deltaStableAbs(s.stableIsCurrency0, uint128(scaled)));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(s.hook, s.key, _deltaZero());

        (,,, uint8 feeIdx, uint8 lastDir) = s.hook.unpackedState();
        assertEq(feeIdx, INITIAL_FEE_IDX, "fee must stay unchanged within deadband");
        assertEq(lastDir, 0, "dir must be NONE within deadband");
    }

    /// @notice Reversal lock: after moving down, an immediate up signal must be blocked.
    function testFuzz_reversalLock_blocksImmediateFlip(uint256 seed) public {
        Scenario storage s = _pick(seed);

        uint128 seedVol = uint128(bound(seed, 2_000_000, 5_000_000_000));
        uint128 highVol = uint128(bound(seedVol + 1_000_000, 2_000_000, 10_000_000_000));

        // Seed EMA.
        manager.callAfterSwap(s.hook, s.key, _deltaStableAbs(s.stableIsCurrency0, seedVol));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(s.hook, s.key, _deltaZero());

        // Zero close -> DOWN.
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(s.hook, s.key, _deltaZero());

        (,,, uint8 feeAfterDown, uint8 dirAfterDown) = s.hook.unpackedState();
        assertEq(feeAfterDown, INITIAL_FEE_IDX - 1, "expected one step down");
        assertEq(dirAfterDown, 2, "expected DOWN dir");

        // High close would signal UP, but must be blocked.
        manager.callAfterSwap(s.hook, s.key, _deltaStableAbs(s.stableIsCurrency0, highVol));
        vm.warp(block.timestamp + PERIOD_SECONDS);
        manager.callAfterSwap(s.hook, s.key, _deltaZero());

        (,,, uint8 feeAfterAttempt, uint8 dirAfterAttempt) = s.hook.unpackedState();
        assertEq(feeAfterAttempt, INITIAL_FEE_IDX - 1, "reversal lock must block flip");
        assertEq(dirAfterAttempt, 0, "dir must reset after blocked reversal");
    }
}
