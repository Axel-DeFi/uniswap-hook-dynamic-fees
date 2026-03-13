// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {OpsTypes} from "../types/OpsTypes.sol";

library RangeSafetyLib {
    uint256 internal constant BPS = 10_000;

    function validateRange(OpsTypes.CoreConfig memory cfg)
        internal
        pure
        returns (OpsTypes.RangeCheck memory check)
    {
        check.minPriceUsdE18 = cfg.liqRangeMinUsdE18;
        check.maxPriceUsdE18 = cfg.liqRangeMaxUsdE18;
        check.initPriceUsdE18 = cfg.initPriceUsdE18;

        if (cfg.liqRangeMinUsdE18 == 0 || cfg.liqRangeMaxUsdE18 == 0) {
            check.ok = false;
            check.reason = "missing liquidity range";
            return check;
        }

        if (cfg.liqRangeMinUsdE18 >= cfg.liqRangeMaxUsdE18) {
            check.ok = false;
            check.reason = "invalid liquidity range order";
            return check;
        }

        check.centeredPriceUsdE18 = centeredPrice(cfg.liqRangeMinUsdE18, cfg.liqRangeMaxUsdE18);

        if (cfg.initPriceUsdE18 == 0) {
            check.ok = false;
            check.reason = "missing INIT_PRICE_USD";
            return check;
        }

        if (cfg.initPriceUsdE18 <= cfg.liqRangeMinUsdE18 || cfg.initPriceUsdE18 >= cfg.liqRangeMaxUsdE18) {
            check.ok = false;
            check.reason = "init price outside liquidity range";
            return check;
        }

        uint256 halfWidth = (cfg.liqRangeMaxUsdE18 - cfg.liqRangeMinUsdE18) / 2;
        uint256 distanceToCenter =
            cfg.initPriceUsdE18 > check.centeredPriceUsdE18
                ? cfg.initPriceUsdE18 - check.centeredPriceUsdE18
                : check.centeredPriceUsdE18 - cfg.initPriceUsdE18;

        // Margin 20% of half-range keeps operational headroom for repeated swaps.
        uint256 maxDistance = (halfWidth * 8_000) / BPS;
        if (distanceToCenter > maxDistance) {
            check.ok = false;
            check.reason = "init price too close to range edge";
            check.marginBps = distanceToCenter == 0 ? BPS : (maxDistance * BPS) / distanceToCenter;
            return check;
        }

        check.marginBps = halfWidth == 0 ? 0 : ((halfWidth - distanceToCenter) * BPS) / halfWidth;
        check.maxSwapStableRaw = clampSwap(cfg.swapBudgetStableRaw, cfg.maxSwapFractionBps);
        check.ok = true;
        check.reason = "ok";
    }

    function clampSwap(uint256 desiredSwapRaw, uint256 maxSwapFractionBps) internal pure returns (uint256) {
        if (desiredSwapRaw == 0) return 0;
        if (maxSwapFractionBps == 0 || maxSwapFractionBps >= BPS) return desiredSwapRaw;
        return (desiredSwapRaw * maxSwapFractionBps) / BPS;
    }

    function centeredPrice(uint256 minPriceUsdE18, uint256 maxPriceUsdE18) internal pure returns (uint256) {
        return (minPriceUsdE18 + maxPriceUsdE18) / 2;
    }
}
