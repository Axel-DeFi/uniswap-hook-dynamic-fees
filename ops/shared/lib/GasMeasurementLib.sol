// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

library GasMeasurementLib {
    uint256 internal constant BPS_SCALE = 10_000;
    uint256 internal constant EMA_SCALE = 1_000_000;

    enum Operation {
        NormalSwap,
        PeriodClose,
        FloorToCash,
        CashToExtreme,
        ExtremeToCash,
        CashToFloor,
        LullReset,
        Pause,
        Unpause,
        EmergencyResetToFloor,
        EmergencyResetToCash,
        ClaimAllHookFees
    }

    error UnsupportedGasOperation(string operation);
    error InvalidStableDecimals(uint8 stableDecimals);
    error InvalidPassThreshold(uint16 passThresholdBps);
    error DownPassVolumeUnavailable(uint64 minRequiredUsd6, uint64 maxPassUsd6);

    function parseOperation(string memory raw) internal pure returns (Operation op) {
        bytes32 id = keccak256(bytes(raw));

        if (id == keccak256("normal_swap")) return Operation.NormalSwap;
        if (id == keccak256("period_close")) return Operation.PeriodClose;
        if (id == keccak256("floor_to_cash")) return Operation.FloorToCash;
        if (id == keccak256("cash_to_extreme")) return Operation.CashToExtreme;
        if (id == keccak256("extreme_to_cash")) return Operation.ExtremeToCash;
        if (id == keccak256("cash_to_floor")) return Operation.CashToFloor;
        if (id == keccak256("lull_reset")) return Operation.LullReset;
        if (id == keccak256("pause")) return Operation.Pause;
        if (id == keccak256("unpause")) return Operation.Unpause;
        if (id == keccak256("emergency_reset_to_floor")) return Operation.EmergencyResetToFloor;
        if (id == keccak256("emergency_reset_to_cash")) return Operation.EmergencyResetToCash;
        if (id == keccak256("claim_all_hook_fees")) return Operation.ClaimAllHookFees;

        revert UnsupportedGasOperation(raw);
    }

    function label(Operation op) internal pure returns (string memory) {
        if (op == Operation.NormalSwap) return "normal_swap";
        if (op == Operation.PeriodClose) return "period_close";
        if (op == Operation.FloorToCash) return "floor_to_cash";
        if (op == Operation.CashToExtreme) return "cash_to_extreme";
        if (op == Operation.ExtremeToCash) return "extreme_to_cash";
        if (op == Operation.CashToFloor) return "cash_to_floor";
        if (op == Operation.LullReset) return "lull_reset";
        if (op == Operation.Pause) return "pause";
        if (op == Operation.Unpause) return "unpause";
        if (op == Operation.EmergencyResetToFloor) return "emergency_reset_to_floor";
        if (op == Operation.EmergencyResetToCash) return "emergency_reset_to_cash";
        return "claim_all_hook_fees";
    }

    function updateEmaScaled(uint96 emaBeforeScaled, uint64 closeVolUsd6, uint8 emaPeriods)
        internal
        pure
        returns (uint96)
    {
        if (emaBeforeScaled == 0) {
            uint256 seeded = uint256(closeVolUsd6) * EMA_SCALE;
            if (seeded > type(uint96).max) return type(uint96).max;
            return uint96(seeded);
        }

        uint256 updated =
            (uint256(emaBeforeScaled) * (uint256(emaPeriods) - 1) + uint256(closeVolUsd6) * EMA_SCALE)
                / uint256(emaPeriods);
        if (updated > type(uint96).max) return type(uint96).max;
        return uint96(updated);
    }

    function minUpPassCloseVolUsd6(
        uint96 emaBeforeScaled,
        uint8 emaPeriods,
        uint16 passThresholdBps,
        uint64 minCloseVolUsd6
    ) internal pure returns (uint64 closeVolUsd6) {
        if (uint256(passThresholdBps) >= uint256(emaPeriods) * BPS_SCALE) {
            revert InvalidPassThreshold(passThresholdBps);
        }

        if (emaBeforeScaled == 0) {
            return minCloseVolUsd6;
        }

        uint256 denominator = uint256(emaPeriods) * BPS_SCALE - uint256(passThresholdBps);
        uint256 numerator =
            uint256(passThresholdBps) * uint256(emaBeforeScaled) * uint256(emaPeriods - 1);
        uint256 raw = numerator / (denominator * EMA_SCALE);
        if (numerator % (denominator * EMA_SCALE) != 0) {
            raw += 1;
        }

        // Leave a small margin above the exact threshold to avoid rounding-induced misses.
        raw = (raw * 105) / 100 + 1;
        if (raw < minCloseVolUsd6) {
            raw = minCloseVolUsd6;
        }
        if (raw > type(uint64).max) {
            raw = type(uint64).max;
        }
        closeVolUsd6 = uint64(raw);
    }

    function maxDownPassCloseVolUsd6(uint96 emaBeforeScaled, uint8 emaPeriods, uint16 passThresholdBps)
        internal
        pure
        returns (uint64 closeVolUsd6)
    {
        if (uint256(passThresholdBps) >= uint256(emaPeriods) * BPS_SCALE) {
            revert InvalidPassThreshold(passThresholdBps);
        }
        if (emaBeforeScaled == 0) {
            return 0;
        }

        uint256 denominator = uint256(emaPeriods) * BPS_SCALE - uint256(passThresholdBps);
        uint256 raw =
            (uint256(passThresholdBps) * uint256(emaBeforeScaled) * uint256(emaPeriods - 1))
                / (denominator * EMA_SCALE);
        if (raw > type(uint64).max) {
            raw = type(uint64).max;
        }
        closeVolUsd6 = uint64(raw);
    }

    function chooseDownPassCloseVolUsd6(
        uint96 emaBeforeScaled,
        uint8 emaPeriods,
        uint16 passThresholdBps,
        uint64 minCountedSwapUsd6,
        uint64 emergencyFloorCloseVolUsd6
    ) internal pure returns (uint64 closeVolUsd6) {
        uint64 floorRequired = minCountedSwapUsd6;
        if (emergencyFloorCloseVolUsd6 >= floorRequired) {
            unchecked {
                floorRequired = emergencyFloorCloseVolUsd6 + 1;
            }
        }

        uint64 maxPass = maxDownPassCloseVolUsd6(emaBeforeScaled, emaPeriods, passThresholdBps);
        if (maxPass < floorRequired) {
            revert DownPassVolumeUnavailable(floorRequired, maxPass);
        }

        uint256 candidate = (uint256(maxPass) * 80) / 100;
        if (candidate < floorRequired) {
            candidate = floorRequired;
        }
        if (candidate > type(uint64).max) {
            candidate = type(uint64).max;
        }
        closeVolUsd6 = uint64(candidate);
    }

    function usd6ToStableRaw(uint64 amountUsd6, uint8 stableDecimals) internal pure returns (uint256 amountRaw) {
        if (stableDecimals == 6) {
            return uint256(amountUsd6);
        }
        if (stableDecimals == 18) {
            return uint256(amountUsd6) * 1e12;
        }
        revert InvalidStableDecimals(stableDecimals);
    }
}
