// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

/// @notice Pure reference implementation of the hook fee model for unit tests.
library FeeModelRef {
    uint24 internal constant MIN_FEE = 100;
    uint24 internal constant MAX_FEE = 10_000;
    uint256 internal constant Q32 = 2 ** 32;

    function absAmount(int256 amountSpecified) internal pure returns (uint256) {
        if (amountSpecified == 0) return 0;
        return uint256(amountSpecified < 0 ? -amountSpecified : amountSpecified);
    }

    function selectReserve(uint256 R0, uint256 R1, bool zeroForOne, int256 amountSpecified)
        internal
        pure
        returns (uint256)
    {
        bool exactIn = amountSpecified < 0;
        if (exactIn) {
            return zeroForOne ? R0 : R1;
        } else {
            return zeroForOne ? R1 : R0;
        }
    }

    /// @notice Fee from (A, R) where:
    ///         A = abs(amountSpecified), R = selected virtual reserve.
    function feeFromAmountAndReserve(uint256 A, uint256 R) internal pure returns (uint24) {
        if (A == 0) return MIN_FEE;

        uint256 uQ;
        if (R == 0) {
            uQ = Q32; // u=1
        } else {
            uint256 denom = R + A;
            uQ = (A * Q32) / denom; // u in Q32.32
        }

        uint256 scoreQ = (uQ * uQ) / Q32; // u^2 in Q32.32

        uint256 range = uint256(MAX_FEE - MIN_FEE);
        uint256 feeU = uint256(MIN_FEE) + (range * scoreQ) / Q32;

        if (feeU < MIN_FEE) return MIN_FEE;
        if (feeU > MAX_FEE) return MAX_FEE;
        return uint24(feeU);
    }
}

contract StatelessDynamicFeeHookMathTest is Test {
    function test_A_zero_fee_is_min() public {
        uint24 fee = FeeModelRef.feeFromAmountAndReserve(0, 1e18);
        assertEq(fee, FeeModelRef.MIN_FEE);
    }

    function test_R_zero_fee_is_max() public {
        uint24 fee = FeeModelRef.feeFromAmountAndReserve(1e18, 0);
        assertEq(fee, FeeModelRef.MAX_FEE);
    }

    function test_fee_always_clamped(uint256 A, uint256 R) public {
        // Bound to avoid overflow in A*Q32
        A = bound(A, 0, type(uint128).max);
        R = bound(R, 0, type(uint128).max);

        uint24 fee = FeeModelRef.feeFromAmountAndReserve(A, R);
        assertGe(fee, FeeModelRef.MIN_FEE);
        assertLe(fee, FeeModelRef.MAX_FEE);
    }

    function test_monotonic_in_A_for_fixed_R() public {
        uint256 R = 1e18;

        uint24 f1 = FeeModelRef.feeFromAmountAndReserve(1e12, R);
        uint24 f2 = FeeModelRef.feeFromAmountAndReserve(1e15, R);
        uint24 f3 = FeeModelRef.feeFromAmountAndReserve(1e18, R);

        assertLe(f1, f2);
        assertLe(f2, f3);
    }

    function test_reserve_selection_exactIn_zeroForOne() public {
        uint256 R0 = 111;
        uint256 R1 = 222;

        // exactIn (negative), zeroForOne => token0 specified => R0
        uint256 R = FeeModelRef.selectReserve(R0, R1, true, -1);
        assertEq(R, R0);
    }

    function test_reserve_selection_exactIn_oneForZero() public {
        uint256 R0 = 111;
        uint256 R1 = 222;

        // exactIn (negative), !zeroForOne => token1 specified => R1
        uint256 R = FeeModelRef.selectReserve(R0, R1, false, -1);
        assertEq(R, R1);
    }

    function test_reserve_selection_exactOut_zeroForOne() public {
        uint256 R0 = 111;
        uint256 R1 = 222;

        // exactOut (positive), zeroForOne => token1 specified => R1
        uint256 R = FeeModelRef.selectReserve(R0, R1, true, 1);
        assertEq(R, R1);
    }

    function test_reserve_selection_exactOut_oneForZero() public {
        uint256 R0 = 111;
        uint256 R1 = 222;

        // exactOut (positive), !zeroForOne => token0 specified => R0
        uint256 R = FeeModelRef.selectReserve(R0, R1, false, 1);
        assertEq(R, R0);
    }
}
