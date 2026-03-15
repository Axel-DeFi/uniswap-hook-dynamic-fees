// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

abstract contract VolumeDynamicFeeHookV2DeployHelper {
    uint64 internal constant V2_MIN_VOLUME_TO_ENTER_CASH_USD6 = 1_000 * 1e6;
    uint16 internal constant V2_CASH_ENTER_TRIGGER_BPS = 18_500;
    uint8 internal constant V2_CASH_HOLD_PERIODS = 4;

    uint64 internal constant V2_MIN_VOLUME_TO_ENTER_EXTREME_USD6 = 4_000 * 1e6;
    uint16 internal constant V2_EXTREME_ENTER_TRIGGER_BPS = 40_500;
    uint8 internal constant V2_UP_EXTREME_CONFIRM_PERIODS = 2;
    uint8 internal constant V2_EXTREME_HOLD_PERIODS = 4;

    uint16 internal constant V2_EXTREME_EXIT_TRIGGER_BPS = 12_500;
    uint8 internal constant V2_DOWN_EXTREME_CONFIRM_PERIODS = 2;
    uint16 internal constant V2_CASH_EXIT_TRIGGER_BPS = 12_500;
    uint8 internal constant V2_DOWN_CASH_CONFIRM_PERIODS = 3;

    uint64 internal constant V2_EMERGENCY_FLOOR_TRIGGER_USD6 = 600 * 1e6;
    uint8 internal constant V2_EMERGENCY_CONFIRM_PERIODS = 3;

    uint16 internal constant V2_INITIAL_HOOK_FEE_PERCENT = 3;

    uint24 internal constant V2_DEFAULT_FLOOR_FEE = 400;
    uint24 internal constant V2_DEFAULT_CASH_FEE = 2_500;
    uint24 internal constant V2_DEFAULT_EXTREME_FEE = 9_000;

    function _constructorArgsV2(
        IPoolManager poolManager,
        Currency currency0,
        Currency currency1,
        int24 tickSpacing,
        Currency stableCurrency,
        uint8 stableDecimals,
        uint24 floorFee,
        uint24 cashFee,
        uint24 extremeFee,
        uint32 periodSeconds,
        uint8 emaPeriods,
        uint32 lullResetSeconds,
        address owner,
        uint16 hookFeePercent
    ) internal pure returns (bytes memory) {
        return abi.encode(
            poolManager,
            currency0,
            currency1,
            tickSpacing,
            stableCurrency,
            stableDecimals,
            floorFee,
            cashFee,
            extremeFee,
            periodSeconds,
            emaPeriods,
            lullResetSeconds,
            owner,
            hookFeePercent,
            V2_MIN_VOLUME_TO_ENTER_CASH_USD6,
            V2_CASH_ENTER_TRIGGER_BPS,
            V2_CASH_HOLD_PERIODS,
            V2_MIN_VOLUME_TO_ENTER_EXTREME_USD6,
            V2_EXTREME_ENTER_TRIGGER_BPS,
            V2_UP_EXTREME_CONFIRM_PERIODS,
            V2_EXTREME_HOLD_PERIODS,
            V2_EXTREME_EXIT_TRIGGER_BPS,
            V2_DOWN_EXTREME_CONFIRM_PERIODS,
            V2_CASH_EXIT_TRIGGER_BPS,
            V2_DOWN_CASH_CONFIRM_PERIODS,
            V2_EMERGENCY_FLOOR_TRIGGER_USD6,
            V2_EMERGENCY_CONFIRM_PERIODS
        );
    }

    function _deployHookV2(
        IPoolManager poolManager,
        Currency currency0,
        Currency currency1,
        int24 tickSpacing,
        Currency stableCurrency,
        uint8 stableDecimals,
        uint24 floorFee,
        uint24 cashFee,
        uint24 extremeFee,
        uint32 periodSeconds,
        uint8 emaPeriods,
        uint32 lullResetSeconds,
        address owner,
        uint16 hookFeePercent
    ) internal returns (VolumeDynamicFeeHook hook) {
        hook = new VolumeDynamicFeeHook(
            poolManager,
            currency0,
            currency1,
            tickSpacing,
            stableCurrency,
            stableDecimals,
            floorFee,
            cashFee,
            extremeFee,
            periodSeconds,
            emaPeriods,
            lullResetSeconds,
            owner,
            hookFeePercent,
            V2_MIN_VOLUME_TO_ENTER_CASH_USD6,
            V2_CASH_ENTER_TRIGGER_BPS,
            V2_CASH_HOLD_PERIODS,
            V2_MIN_VOLUME_TO_ENTER_EXTREME_USD6,
            V2_EXTREME_ENTER_TRIGGER_BPS,
            V2_UP_EXTREME_CONFIRM_PERIODS,
            V2_EXTREME_HOLD_PERIODS,
            V2_EXTREME_EXIT_TRIGGER_BPS,
            V2_DOWN_EXTREME_CONFIRM_PERIODS,
            V2_CASH_EXIT_TRIGGER_BPS,
            V2_DOWN_CASH_CONFIRM_PERIODS,
            V2_EMERGENCY_FLOOR_TRIGGER_USD6,
            V2_EMERGENCY_CONFIRM_PERIODS
        );
    }

    function _deployHookV2(
        bytes32 salt,
        IPoolManager poolManager,
        Currency currency0,
        Currency currency1,
        int24 tickSpacing,
        Currency stableCurrency,
        uint8 stableDecimals,
        uint24 floorFee,
        uint24 cashFee,
        uint24 extremeFee,
        uint32 periodSeconds,
        uint8 emaPeriods,
        uint32 lullResetSeconds,
        address owner,
        uint16 hookFeePercent
    ) internal returns (VolumeDynamicFeeHook hook) {
        hook = new VolumeDynamicFeeHook{salt: salt}(
            poolManager,
            currency0,
            currency1,
            tickSpacing,
            stableCurrency,
            stableDecimals,
            floorFee,
            cashFee,
            extremeFee,
            periodSeconds,
            emaPeriods,
            lullResetSeconds,
            owner,
            hookFeePercent,
            V2_MIN_VOLUME_TO_ENTER_CASH_USD6,
            V2_CASH_ENTER_TRIGGER_BPS,
            V2_CASH_HOLD_PERIODS,
            V2_MIN_VOLUME_TO_ENTER_EXTREME_USD6,
            V2_EXTREME_ENTER_TRIGGER_BPS,
            V2_UP_EXTREME_CONFIRM_PERIODS,
            V2_EXTREME_HOLD_PERIODS,
            V2_EXTREME_EXIT_TRIGGER_BPS,
            V2_DOWN_EXTREME_CONFIRM_PERIODS,
            V2_CASH_EXIT_TRIGGER_BPS,
            V2_DOWN_CASH_CONFIRM_PERIODS,
            V2_EMERGENCY_FLOOR_TRIGGER_USD6,
            V2_EMERGENCY_CONFIRM_PERIODS
        );
    }
}
