// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {OpsTypes} from "../types/OpsTypes.sol";

import {TokenValidationLib} from "./TokenValidationLib.sol";

library BudgetLib {
    function snapshot(OpsTypes.CoreConfig memory cfg, address account)
        internal
        view
        returns (OpsTypes.BalanceSnapshot memory balances)
    {
        balances.ethWei = account.balance;
        balances.stableRaw = TokenValidationLib.balanceOf(cfg.stableToken, account);
        balances.volatileRaw = TokenValidationLib.balanceOf(cfg.volatileToken, account);
    }

    function checkBeforeBroadcast(OpsTypes.CoreConfig memory cfg, address account)
        internal
        view
        returns (OpsTypes.BudgetCheck memory check)
    {
        check.snapshot = snapshot(cfg, account);

        check.requiredStableRaw = cfg.minStableBalanceRaw + cfg.liquidityBudgetStableRaw + cfg.swapBudgetStableRaw;
        check.requiredVolatileRaw =
            cfg.minVolatileBalanceRaw + cfg.liquidityBudgetVolatileRaw + cfg.swapBudgetVolatileRaw;

        uint256 nativeBudgetFromToken = 0;
        if (cfg.volatileToken == address(0)) {
            nativeBudgetFromToken += cfg.liquidityBudgetVolatileRaw + cfg.swapBudgetVolatileRaw;
        }
        if (cfg.stableToken == address(0)) {
            nativeBudgetFromToken += cfg.liquidityBudgetStableRaw + cfg.swapBudgetStableRaw;
        }

        check.requiredEthWei = cfg.minEthBalanceWei + cfg.safetyBufferEthWei + nativeBudgetFromToken;

        if (check.snapshot.ethWei < check.requiredEthWei) {
            check.ok = false;
            check.reason = "insufficient ETH budget";
            return check;
        }

        if (cfg.stableToken != address(0) && check.snapshot.stableRaw < check.requiredStableRaw) {
            check.ok = false;
            check.reason = "insufficient stable budget";
            return check;
        }

        if (cfg.volatileToken != address(0) && check.snapshot.volatileRaw < check.requiredVolatileRaw) {
            check.ok = false;
            check.reason = "insufficient volatile budget";
            return check;
        }

        check.ok = true;
        check.reason = "ok";
    }
}
