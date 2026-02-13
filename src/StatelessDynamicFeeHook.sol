// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/libraries/PoolIdLibrary.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title StatelessDynamicFeeHook
/// @notice A stateless Uniswap v4 hook that overrides Dynamic LP Fees per swap
///         using an "impact vs depth" model based only on current pool state and swap params.
/// @dev No mutable storage is used. No SSTORE occurs on the swap path.
contract StatelessDynamicFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Fixed minimum fee (0.01%) in hundredths of a bip (1e-6).
    uint24 public constant MIN_FEE = 100;

    /// @notice Fixed maximum fee (1.00%) in hundredths of a bip (1e-6).
    uint24 public constant MAX_FEE = 10_000;

    /// @dev Q96 constant for sqrt price math.
    uint256 internal constant Q96 = 2 ** 96;

    /// @dev Scale for utilization u in Q32.32.
    uint256 internal constant Q32 = 2 ** 32;

    /// @param _poolManager Uniswap v4 PoolManager
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        // Only override on dynamic-fee pools.
        if (!LPFeeLibrary.isDynamicFee(key.fee)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        uint24 fee = _computeFee(key, params);
        uint24 lpFeeOverride = LPFeeLibrary.OVERRIDE_FEE_FLAG | fee;

        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), lpFeeOverride);
    }

    /// @dev Computes a fee in [MIN_FEE, MAX_FEE] using only current pool state and swap params.
    function _computeFee(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        internal
        view
        returns (uint24)
    {
        uint256 A = _absAmount(params.amountSpecified);
        if (A == 0) return MIN_FEE;

        PoolId id = key.toId();

        // Read pool state from the PoolManager.
        // NOTE: We only need sqrtPriceX96 and liquidity for this model.
        (uint160 sqrtPriceX96,,,,,) = poolManager.getSlot0(id);
        uint128 L = poolManager.getLiquidity(id);

        if (L == 0 || sqrtPriceX96 == 0) {
            // No depth => treat as max utilization.
            return MAX_FEE;
        }

        // Virtual reserves at the current price.
        // R0 = L * Q96 / S
        // R1 = L * S / Q96
        uint256 S = uint256(sqrtPriceX96);
        uint256 R0 = FullMath.mulDiv(uint256(L), Q96, S);
        uint256 R1 = FullMath.mulDiv(uint256(L), S, Q96);

        uint256 R = _selectReserve(R0, R1, params.zeroForOne, params.amountSpecified);

        // u = A / (R + A) in Q32.32
        uint256 uQ;
        unchecked {
            if (R == 0) {
                uQ = Q32;
            } else {
                uint256 denom = R + A;
                // denom > 0 always here
                uQ = (A * Q32) / denom;
            }
        }

        // score = u^2 in Q32.32
        uint256 scoreQ = (uQ * uQ) / Q32;

        // fee = MIN + (MAX-MIN)*score
        uint256 range = uint256(MAX_FEE - MIN_FEE);
        uint256 feeU = uint256(MIN_FEE) + (range * scoreQ) / Q32;

        if (feeU < MIN_FEE) return MIN_FEE;
        if (feeU > MAX_FEE) return MAX_FEE;
        return uint24(feeU);
    }

    /// @dev Selects the relevant virtual reserve based on exactIn/exactOut and swap direction.
    function _selectReserve(uint256 R0, uint256 R1, bool zeroForOne, int256 amountSpecified)
        internal
        pure
        returns (uint256)
    {
        bool exactIn = amountSpecified < 0;

        // Direction mapping:
        // zeroForOne == true  => token0 -> token1
        // zeroForOne == false => token1 -> token0
        //
        // exactIn: specified token is input
        // exactOut: specified token is output
        if (exactIn) {
            // exactIn: specified token = input
            return zeroForOne ? R0 : R1;
        } else {
            // exactOut: specified token = output
            return zeroForOne ? R1 : R0;
        }
    }

    /// @dev Absolute value of amountSpecified as uint256.
    function _absAmount(int256 amountSpecified) internal pure returns (uint256) {
        if (amountSpecified == 0) return 0;
        // amountSpecified fits into int256; abs fits into uint256
        return uint256(amountSpecified < 0 ? -amountSpecified : amountSpecified);
    }
}
