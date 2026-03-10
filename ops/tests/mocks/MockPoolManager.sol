// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

/// @notice Minimal unlock callback interface used by PoolManager.unlock().
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @notice Minimal PoolManager mock used by unit/fuzz tests.
/// @dev Not a full IPoolManager implementation; only methods required by this repository tests.
contract MockPoolManager {
    uint24 public lastFee;
    uint256 public updateCount;
    uint256 public unlockCount;
    uint256 public takeCount;
    uint256 public mintCount;
    uint256 public burnCount;
    bool public skipUnlockCallback;
    mapping(address account => mapping(uint256 id => uint256 amount)) public claimBalances;

    uint64 public observedPeriodVolUsd6;
    uint96 public observedEmaVolUsd6Scaled;
    uint64 public observedPeriodStart;
    uint8 public observedFeeIdx;

    bytes4 public lastAfterSwapSelector;
    int128 public lastAfterSwapDelta;
    bool public lastZeroForOne;
    int256 public lastAmountSpecified;

    error NotHook();

    // forge-lint: disable-next-line(mixed-case-function)
    function updateDynamicLPFee(PoolKey calldata key, uint24 newFee) external {
        if (msg.sender != address(key.hooks)) revert NotHook();
        lastFee = newFee;
        updateCount += 1;

        (observedPeriodVolUsd6, observedEmaVolUsd6Scaled, observedPeriodStart, observedFeeIdx) =
            VolumeDynamicFeeHook(payable(address(key.hooks))).unpackedState();
    }

    /// @notice Mimics PoolManager.unlock by calling back into caller.
    function unlock(bytes calldata data) external returns (bytes memory) {
        unlockCount += 1;
        if (skipUnlockCallback) return "";
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function setSkipUnlockCallback(bool v) external {
        skipUnlockCallback = v;
    }

    function exttload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function exttload(bytes32[] calldata slots) external pure returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
    }

    function take(Currency currency, address to, uint256 amount) external {
        takeCount += 1;
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            if (amount > 0) {
                (bool ok,) = payable(to).call{value: amount}("");
                require(ok, "native transfer failed");
            }
            return;
        }

        if (token.code.length == 0 || amount == 0) return;
        require(IERC20Minimal(token).transfer(to, amount), "erc20 transfer failed");
    }

    function mint(address to, uint256 id, uint256 amount) external {
        claimBalances[to][id] += amount;
        mintCount += 1;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        uint256 balance = claimBalances[from][id];
        require(balance >= amount, "insufficient claim balance");
        claimBalances[from][id] = balance - amount;
        burnCount += 1;
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    receive() external payable {}

    function callAfterInitialize(VolumeDynamicFeeHook hook, PoolKey calldata key) external {
        hook.afterInitialize(address(0xBEEF), key, 0, 0);
    }

    function callAfterSwap(VolumeDynamicFeeHook hook, PoolKey calldata key, BalanceDelta delta) external {
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        _callAfterSwap(hook, key, params, delta);
    }

    function callAfterSwapWithParams(
        VolumeDynamicFeeHook hook,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta
    ) external {
        _callAfterSwap(hook, key, params, delta);
    }

    function _callAfterSwap(
        VolumeDynamicFeeHook hook,
        PoolKey calldata key,
        SwapParams memory params,
        BalanceDelta delta
    ) internal {
        (bytes4 selector, int128 afterSwapDelta) = hook.afterSwap(address(0xBEEF), key, params, delta, "");
        lastAfterSwapSelector = selector;
        lastAfterSwapDelta = afterSwapDelta;
        lastZeroForOne = params.zeroForOne;
        lastAmountSpecified = params.amountSpecified;

        (observedPeriodVolUsd6, observedEmaVolUsd6Scaled, observedPeriodStart, observedFeeIdx) =
            hook.unpackedState();
    }
}
