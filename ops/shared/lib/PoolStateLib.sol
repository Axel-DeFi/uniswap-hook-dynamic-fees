// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {OpsTypes} from "../types/OpsTypes.sol";

library PoolStateLib {
    function snapshotHook(address hookAddress) internal view returns (OpsTypes.PoolSnapshot memory snap) {
        if (hookAddress == address(0) || hookAddress.code.length == 0) {
            return snap;
        }

        IHookState hook = IHookState(hookAddress);
        (snap.periodVolUsd6, snap.emaVolUsd6Scaled, snap.periodStart, snap.feeIdx) = hook.unpackedState();
        snap.paused = hook.isPaused();
        snap.initialized = (snap.periodStart != 0);

        try hook.currentFeeBips() returns (uint24 fee) {
            snap.currentFeeBips = fee;
        } catch {
            snap.currentFeeBips = 0;
        }
        try hook.floorFee() returns (uint24 fee) {
            snap.floorFeeBips = fee;
        } catch {
            snap.floorFeeBips = 0;
        }
        try hook.cashFee() returns (uint24 fee) {
            snap.cashFeeBips = fee;
        } catch {
            snap.cashFeeBips = 0;
        }
        try hook.extremeFee() returns (uint24 fee) {
            snap.extremeFeeBips = fee;
        } catch {
            snap.extremeFeeBips = 0;
        }
    }

    function rangeDistanceBps(uint256 price, uint256 minPrice, uint256 maxPrice)
        internal
        pure
        returns (uint256 lowerDistanceBps, uint256 upperDistanceBps)
    {
        if (price <= minPrice || price >= maxPrice || minPrice >= maxPrice) {
            return (0, 0);
        }

        uint256 width = maxPrice - minPrice;
        lowerDistanceBps = ((price - minPrice) * 10_000) / width;
        upperDistanceBps = ((maxPrice - price) * 10_000) / width;
    }
}

interface IHookState {
    function unpackedState() external view returns (uint64, uint96, uint64, uint8);
    function isPaused() external view returns (bool);
    function currentFeeBips() external view returns (uint24);
    function floorFee() external view returns (uint24);
    function cashFee() external view returns (uint24);
    function extremeFee() external view returns (uint24);
}
