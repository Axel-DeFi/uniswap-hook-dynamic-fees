// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {OpsTypes} from "../types/OpsTypes.sol";

library RangeSafetyLib {
    function validateRange(OpsTypes.CoreConfig memory cfg)
        internal
        pure
        returns (OpsTypes.RangeCheck memory check)
    {
        check.initPriceUsdE18 = cfg.initPriceUsdE18;
        check.maxSwapStableRaw = cfg.swapBudgetStableRaw;

        if (cfg.initPriceUsdE18 == 0) {
            check.ok = false;
            check.reason = "missing INIT_PRICE_USD";
            return check;
        }

        check.ok = true;
        check.reason = "ok";
    }
}
