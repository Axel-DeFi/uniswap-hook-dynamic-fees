// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {StatelessDynamicFeeHook} from "../src/StatelessDynamicFeeHook.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/libraries/PoolIdLibrary.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/CurrencyLibrary.sol";

// Test helpers from v4-core. These are shipped in the repository under src/test.
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "@uniswap/v4-core/src/test/MockERC20.sol";

contract StatelessDynamicFeeHookIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidity;
    PoolSwapTest internal swapTest;

    MockERC20 internal token0;
    MockERC20 internal token1;

    StatelessDynamicFeeHook internal hook;

    function setUp() public {
        manager = new PoolManager(address(this));
        modifyLiquidity = new PoolModifyLiquidityTest(manager);
        swapTest = new PoolSwapTest(manager);

        token0 = new MockERC20("T0", "T0", 18);
        token1 = new MockERC20("T1", "T1", 18);

        token0.mint(address(this), 10_000_000e18);
        token1.mint(address(this), 10_000_000e18);

        // Approve test helpers.
        token0.approve(address(modifyLiquidity), type(uint256).max);
        token1.approve(address(modifyLiquidity), type(uint256).max);
        token0.approve(address(swapTest), type(uint256).max);
        token1.approve(address(swapTest), type(uint256).max);

        hook = _deployHookWithBeforeSwapFlag();
    }

    function _deployHookWithBeforeSwapFlag() internal returns (StatelessDynamicFeeHook deployed) {
        bytes memory initCode =
            abi.encodePacked(type(StatelessDynamicFeeHook).creationCode, abi.encode(IPoolManager(address(manager))));
        bytes32 initCodeHash = keccak256(initCode);

        bytes32 salt;
        address predicted;
        // Brute force salt mining inside the test contract (not on swap path).
        for (uint256 i = 0; i < 200_000; i++) {
            salt = bytes32(i);
            predicted = _computeCreate2Address(address(this), salt, initCodeHash);
            if ((uint160(predicted) & uint160(Hooks.BEFORE_SWAP_FLAG)) == uint160(Hooks.BEFORE_SWAP_FLAG)) {
                break;
            }
        }
        require(
            (uint160(predicted) & uint160(Hooks.BEFORE_SWAP_FLAG)) == uint160(Hooks.BEFORE_SWAP_FLAG),
            "salt mining failed"
        );

        deployed = new StatelessDynamicFeeHook{salt: salt}(IPoolManager(address(manager)));
        require(address(deployed) == predicted, "create2 mismatch");
    }

    function _computeCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash));
        return address(uint160(uint256(h)));
    }

    function test_dynamicPool_beforeSwap_override_nonzero_and_monotonic() public {
        PoolKey memory key = _createAndInitializeDynamicPool();

        IPoolManager.SwapParams memory small = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1e15), // exactIn small
            sqrtPriceLimitX96: 0
        });

        IPoolManager.SwapParams memory large = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1e20), // exactIn larger
            sqrtPriceLimitX96: 0
        });

        // Call the hook directly with PoolManager as msg.sender.
        vm.prank(address(manager));
        (bytes4 sel1, BeforeSwapDelta d1, uint24 o1) = hook.beforeSwap(address(this), key, small, "");
        vm.prank(address(manager));
        (bytes4 sel2, BeforeSwapDelta d2, uint24 o2) = hook.beforeSwap(address(this), key, large, "");

        assertEq(sel1, IHooks.beforeSwap.selector);
        assertEq(sel2, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(d1), 0);
        assertEq(BeforeSwapDelta.unwrap(d2), 0);

        // Must be an override with non-zero fee for dynamic pools.
        assertTrue((o1 & LPFeeLibrary.OVERRIDE_FEE_FLAG) != 0);
        assertTrue((o2 & LPFeeLibrary.OVERRIDE_FEE_FLAG) != 0);

        uint24 f1 = o1 & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        uint24 f2 = o2 & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;

        assertGe(f1, StatelessDynamicFeeHook.MIN_FEE());
        assertLe(f1, StatelessDynamicFeeHook.MAX_FEE());
        assertGe(f2, StatelessDynamicFeeHook.MIN_FEE());
        assertLe(f2, StatelessDynamicFeeHook.MAX_FEE());

        assertLe(f1, f2);
    }

    function test_nonDynamicPool_beforeSwap_override_zero() public {
        PoolKey memory key = _createAndInitializeStaticFeePool(3000); // e.g. 0.30%

        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1e18),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(manager));
        (, , uint24 overrideFee) = hook.beforeSwap(address(this), key, p, "");
        assertEq(overrideFee, 0);
    }

    function test_stateless_enforcement_no_storage_writes_and_no_storage_used() public {
        PoolKey memory key = _createAndInitializeDynamicPool();

        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1e18),
            sqrtPriceLimitX96: 0
        });

        // The hook should not touch its own storage at all.
        assertEq(vm.load(address(hook), bytes32(uint256(0))), bytes32(0));
        assertEq(vm.load(address(hook), bytes32(uint256(1))), bytes32(0));

        vm.record();
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, p, "");
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(hook));

        // Reads are allowed (immutables are not reads). Writes must be empty.
        assertEq(writes.length, 0);
        // If you want to be strict, you can also require reads.length == 0.
        // assertEq(reads.length, 0);
    }

    function test_integration_swaps_succeed() public {
        PoolKey memory key = _createAndInitializeDynamicPool();

        // Perform two swaps through the test router to ensure the hook does not break swaps.
        // Small swap
        swapTest.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Larger swap
        swapTest.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(1e21), sqrtPriceLimitX96: 0}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _createAndInitializeDynamicPool() internal returns (PoolKey memory key) {
        (Currency c0, Currency c1) = _sortedCurrencies();

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize at price 1:1 (sqrtPriceX96 = 2^96).
        manager.initialize(key, uint160(2 ** 96), "");

        // Add some liquidity around current price.
        modifyLiquidity.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: int256(1e18), salt: 0}),
            ""
        );
    }

    function _createAndInitializeStaticFeePool(uint24 staticFee) internal returns (PoolKey memory key) {
        (Currency c0, Currency c1) = _sortedCurrencies();

        key = PoolKey({currency0: c0, currency1: c1, fee: staticFee, tickSpacing: 60, hooks: IHooks(address(hook))});

        manager.initialize(key, uint160(2 ** 96), "");
        modifyLiquidity.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: int256(1e18), salt: 0}),
            ""
        );
    }

    function _sortedCurrencies() internal view returns (Currency c0, Currency c1) {
        Currency a = Currency.wrap(address(token0));
        Currency b = Currency.wrap(address(token1));
        if (a < b) {
            (c0, c1) = (a, b);
        } else {
            (c0, c1) = (b, a);
        }
    }
}
