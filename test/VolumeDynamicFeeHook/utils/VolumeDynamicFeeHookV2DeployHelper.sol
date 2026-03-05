// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

abstract contract VolumeDynamicFeeHookV2DeployHelper {
    uint64 internal constant V2_MIN_CLOSEVOL_TO_CASH_USD6 = 1_000 * 1e6;
    uint16 internal constant V2_UP_R_TO_CASH_BPS = 18_000;
    uint8 internal constant V2_CASH_HOLD_PERIODS = 4;

    uint64 internal constant V2_MIN_CLOSEVOL_TO_EXTREME_USD6 = 4_000 * 1e6;
    uint16 internal constant V2_UP_R_TO_EXTREME_BPS = 40_000;
    uint8 internal constant V2_UP_EXTREME_CONFIRM_PERIODS = 2;
    uint8 internal constant V2_EXTREME_HOLD_PERIODS = 6;

    uint16 internal constant V2_DOWN_R_FROM_EXTREME_BPS = 12_000;
    uint8 internal constant V2_DOWN_EXTREME_CONFIRM_PERIODS = 3;
    uint16 internal constant V2_DOWN_R_FROM_CASH_BPS = 10_500;
    uint8 internal constant V2_DOWN_CASH_CONFIRM_PERIODS = 3;

    uint64 internal constant V2_EMERGENCY_FLOOR_CLOSEVOL_USD6 = 600 * 1e6;
    uint8 internal constant V2_EMERGENCY_CONFIRM_PERIODS = 2;

    uint24 internal constant V2_DEFAULT_CASH_TIER = 2_500;
    uint24 internal constant V2_DEFAULT_EXTREME_TIER = 9_000;

    function _defaultFeeTiersV2() internal pure returns (uint24[] memory tiers) {
        tiers = new uint24[](3);
        tiers[0] = 400;
        tiers[1] = 2500;
        tiers[2] = 9000;
    }

    function _resolveCashTier(uint24[] memory feeTiers) internal pure returns (uint24 cashTier) {
        cashTier = V2_DEFAULT_CASH_TIER;
        uint256 len = feeTiers.length;
        for (uint256 i = 0; i < len; ++i) {
            if (feeTiers[i] == V2_DEFAULT_CASH_TIER) return feeTiers[i];
        }
        if (len > 1) return feeTiers[1];
        if (len == 1) return feeTiers[0];
    }

    function _resolveExtremeTier(uint24[] memory feeTiers) internal pure returns (uint24 extremeTier) {
        extremeTier = V2_DEFAULT_EXTREME_TIER;
        uint256 len = feeTiers.length;
        for (uint256 i = 0; i < len; ++i) {
            if (feeTiers[i] == V2_DEFAULT_EXTREME_TIER) return feeTiers[i];
        }
        if (len > 0) return feeTiers[len - 1];
    }

    function _constructorArgsV2(
        IPoolManager poolManager,
        Currency currency0,
        Currency currency1,
        int24 tickSpacing,
        Currency stableCurrency,
        uint8 stableDecimals,
        uint8 floorIdx,
        uint8 capIdx,
        uint24[] memory feeTiers,
        uint32 periodSeconds,
        uint8 emaPeriods,
        uint16 deadbandBps,
        uint32 lullResetSeconds,
        address guardian,
        address creator,
        uint16 creatorFeeBps
    ) internal pure returns (bytes memory) {
        return abi.encode(
            poolManager,
            currency0,
            currency1,
            tickSpacing,
            stableCurrency,
            stableDecimals,
            floorIdx,
            capIdx,
            feeTiers,
            periodSeconds,
            emaPeriods,
            deadbandBps,
            lullResetSeconds,
            guardian,
            creator,
            creatorFeeBps,
            _resolveCashTier(feeTiers),
            V2_MIN_CLOSEVOL_TO_CASH_USD6,
            V2_UP_R_TO_CASH_BPS,
            V2_CASH_HOLD_PERIODS,
            _resolveExtremeTier(feeTiers),
            V2_MIN_CLOSEVOL_TO_EXTREME_USD6,
            V2_UP_R_TO_EXTREME_BPS,
            V2_UP_EXTREME_CONFIRM_PERIODS,
            V2_EXTREME_HOLD_PERIODS,
            V2_DOWN_R_FROM_EXTREME_BPS,
            V2_DOWN_EXTREME_CONFIRM_PERIODS,
            V2_DOWN_R_FROM_CASH_BPS,
            V2_DOWN_CASH_CONFIRM_PERIODS,
            V2_EMERGENCY_FLOOR_CLOSEVOL_USD6,
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
        uint8 floorIdx,
        uint8 capIdx,
        uint24[] memory feeTiers,
        uint32 periodSeconds,
        uint8 emaPeriods,
        uint16 deadbandBps,
        uint32 lullResetSeconds,
        address guardian,
        address creator,
        uint16 creatorFeeBps
    ) internal returns (VolumeDynamicFeeHook hook) {
        hook = new VolumeDynamicFeeHook(
            poolManager,
            currency0,
            currency1,
            tickSpacing,
            stableCurrency,
            stableDecimals,
            floorIdx,
            capIdx,
            feeTiers,
            periodSeconds,
            emaPeriods,
            deadbandBps,
            lullResetSeconds,
            guardian,
            creator,
            creatorFeeBps,
            _resolveCashTier(feeTiers),
            V2_MIN_CLOSEVOL_TO_CASH_USD6,
            V2_UP_R_TO_CASH_BPS,
            V2_CASH_HOLD_PERIODS,
            _resolveExtremeTier(feeTiers),
            V2_MIN_CLOSEVOL_TO_EXTREME_USD6,
            V2_UP_R_TO_EXTREME_BPS,
            V2_UP_EXTREME_CONFIRM_PERIODS,
            V2_EXTREME_HOLD_PERIODS,
            V2_DOWN_R_FROM_EXTREME_BPS,
            V2_DOWN_EXTREME_CONFIRM_PERIODS,
            V2_DOWN_R_FROM_CASH_BPS,
            V2_DOWN_CASH_CONFIRM_PERIODS,
            V2_EMERGENCY_FLOOR_CLOSEVOL_USD6,
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
        uint8 floorIdx,
        uint8 capIdx,
        uint24[] memory feeTiers,
        uint32 periodSeconds,
        uint8 emaPeriods,
        uint16 deadbandBps,
        uint32 lullResetSeconds,
        address guardian,
        address creator,
        uint16 creatorFeeBps
    ) internal returns (VolumeDynamicFeeHook hook) {
        hook = new VolumeDynamicFeeHook{salt: salt}(
            poolManager,
            currency0,
            currency1,
            tickSpacing,
            stableCurrency,
            stableDecimals,
            floorIdx,
            capIdx,
            feeTiers,
            periodSeconds,
            emaPeriods,
            deadbandBps,
            lullResetSeconds,
            guardian,
            creator,
            creatorFeeBps,
            _resolveCashTier(feeTiers),
            V2_MIN_CLOSEVOL_TO_CASH_USD6,
            V2_UP_R_TO_CASH_BPS,
            V2_CASH_HOLD_PERIODS,
            _resolveExtremeTier(feeTiers),
            V2_MIN_CLOSEVOL_TO_EXTREME_USD6,
            V2_UP_R_TO_EXTREME_BPS,
            V2_UP_EXTREME_CONFIRM_PERIODS,
            V2_EXTREME_HOLD_PERIODS,
            V2_DOWN_R_FROM_EXTREME_BPS,
            V2_DOWN_EXTREME_CONFIRM_PERIODS,
            V2_DOWN_R_FROM_CASH_BPS,
            V2_DOWN_CASH_CONFIRM_PERIODS,
            V2_EMERGENCY_FLOOR_CLOSEVOL_USD6,
            V2_EMERGENCY_CONFIRM_PERIODS
        );
    }
}
