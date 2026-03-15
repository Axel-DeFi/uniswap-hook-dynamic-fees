// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ErrorLib} from "./ErrorLib.sol";
import {OpsTypes} from "../types/OpsTypes.sol";

library InitPriceLib {
    uint256 internal constant Q192 = 1 << 192;
    uint256 internal constant E18 = 1e18;
    address internal constant NATIVE = address(0);

    function requireInitSqrtPriceX96(OpsTypes.CoreConfig memory cfg)
        internal
        view
        returns (uint160 sqrtPriceX96)
    {
        if (cfg.initPriceUsdE18 == 0) {
            revert ErrorLib.InvalidEnv("INIT_PRICE_USD", "must be > 0");
        }

        uint8 stableDecimals = cfg.stableDecimals;
        uint8 volatileDecimals =
            cfg.volatileToken == NATIVE ? 18 : IERC20MetadataLike(cfg.volatileToken).decimals();

        uint256 ratioX192 = cfg.stableToken == cfg.token1
            ? FullMath.mulDiv(
                cfg.initPriceUsdE18, Q192 * (10 ** stableDecimals), E18 * (10 ** volatileDecimals)
            )
            : FullMath.mulDiv(
                Q192 * E18, 10 ** volatileDecimals, cfg.initPriceUsdE18 * (10 ** stableDecimals)
            );

        if (ratioX192 == 0) {
            revert ErrorLib.InvalidEnv("INIT_PRICE_USD", "computed sqrt price is zero");
        }

        uint256 sqrtPriceRaw = Math.sqrt(ratioX192);
        if (sqrtPriceRaw < TickMath.MIN_SQRT_PRICE || sqrtPriceRaw >= TickMath.MAX_SQRT_PRICE) {
            revert ErrorLib.InvalidEnv("INIT_PRICE_USD", "computed sqrt price outside TickMath bounds");
        }

        sqrtPriceX96 = uint160(sqrtPriceRaw);
    }
}

interface IERC20MetadataLike {
    function decimals() external view returns (uint8);
}
