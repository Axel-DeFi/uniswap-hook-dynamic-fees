// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {OpsTypes} from "../types/OpsTypes.sol";

library TokenValidationLib {
    address internal constant NATIVE = address(0);

    function validateTokens(OpsTypes.CoreConfig memory cfg)
        internal
        view
        returns (OpsTypes.TokenValidation memory validation)
    {
        validation.ok = true;
        validation.volatileOk = (cfg.volatileToken == NATIVE || cfg.volatileToken.code.length > 0);
        validation.stableOk = (cfg.stableToken != NATIVE && cfg.stableToken.code.length > 0);
        validation.stableDecimalsExpected = cfg.stableDecimals;
        validation.stableDecimalsOnchain = validation.stableOk ? _decimals(cfg.stableToken) : 0;

        if (!validation.volatileOk) {
            validation.ok = false;
            validation.reason = "volatile token missing code";
            return validation;
        }

        if (!validation.stableOk) {
            validation.ok = false;
            validation.reason = "stable token missing code";
            return validation;
        }

        if (validation.stableDecimalsOnchain != validation.stableDecimalsExpected) {
            validation.ok = false;
            validation.reason = "stable decimals mismatch";
            return validation;
        }

        validation.reason = "ok";
    }

    function balanceOf(address token, address account) internal view returns (uint256) {
        if (token == NATIVE) return account.balance;
        return IERC20Like(token).balanceOf(account);
    }

    function _decimals(address token) private view returns (uint8) {
        return IERC20MetadataLike(token).decimals();
    }
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20MetadataLike {
    function decimals() external view returns (uint8);
}
