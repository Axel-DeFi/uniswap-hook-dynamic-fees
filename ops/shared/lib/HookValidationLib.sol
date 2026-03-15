// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {OpsTypes} from "../types/OpsTypes.sol";

library HookValidationLib {
    using Hooks for IHooks;

    function validateHook(OpsTypes.CoreConfig memory cfg)
        internal
        view
        returns (OpsTypes.HookValidation memory validation)
    {
        validation.ok = true;

        if (cfg.hookAddress == address(0)) {
            validation.ok = false;
            validation.reason = "HOOK_ADDRESS missing";
            return validation;
        }

        validation.codeSize = cfg.hookAddress.code.length;
        if (validation.codeSize == 0) {
            validation.ok = false;
            validation.reason = "hook has no code";
            return validation;
        }

        IVolumeHook hook = IVolumeHook(cfg.hookAddress);

        Hooks.Permissions memory perms = hook.getHookPermissions();
        validation.permissionFlagsMatch = _declaredPermissionsMatch(perms) && _addressPermissionsMatch(IHooks(cfg.hookAddress));
        if (!validation.permissionFlagsMatch) {
            validation.ok = false;
            validation.reason = "hook permissions mismatch";
            return validation;
        }

        address c0 = Currency.unwrap(hook.poolCurrency0());
        address c1 = Currency.unwrap(hook.poolCurrency1());
        validation.poolBindingMatch =
            (c0 == cfg.token0 && c1 == cfg.token1 && hook.poolTickSpacing() == cfg.tickSpacing);
        validation.stableInPool = (Currency.unwrap(hook.stableCurrency()) == cfg.stableToken);

        if (address(hook.poolManager()) != cfg.poolManager) {
            validation.ok = false;
            validation.reason = "hook PoolManager mismatch";
            return validation;
        }

        if (!validation.poolBindingMatch) {
            validation.ok = false;
            validation.reason = "hook pool binding mismatch";
            return validation;
        }

        if (!validation.stableInPool) {
            validation.ok = false;
            validation.reason = "hook stable token mismatch";
            return validation;
        }

        if (hook.owner() != cfg.owner) {
            validation.ok = false;
            validation.reason = "hook owner mismatch";
            return validation;
        }

        if (hook.pendingOwner() != address(0)) {
            validation.ok = false;
            validation.reason = "hook pending owner exists";
            return validation;
        }

        if (hook.stableDecimals() != cfg.stableDecimals) {
            validation.ok = false;
            validation.reason = "hook stable decimals mismatch";
            return validation;
        }

        if (hook.hookFeePercent() != cfg.hookFeePercent) {
            validation.ok = false;
            validation.reason = "hook HookFee percent mismatch";
            return validation;
        }

        if (hook.minCountedSwapUsd6() != cfg.minCountedSwapUsd6) {
            validation.ok = false;
            validation.reason = "hook min counted swap mismatch";
            return validation;
        }

        if (
            hook.floorFee() != cfg.floorFeePips || hook.cashFee() != cfg.cashFeePips
                || hook.extremeFee() != cfg.extremeFeePips
        ) {
            validation.ok = false;
            validation.reason = "hook regime fee mismatch";
            return validation;
        }

        if (
            hook.periodSeconds() != cfg.periodSeconds || hook.emaPeriods() != cfg.emaPeriods
                || hook.lullResetSeconds() != cfg.lullResetSeconds
        ) {
            validation.ok = false;
            validation.reason = "hook timing config mismatch";
            return validation;
        }

        if (
            hook.minCloseVolToCashUsd6() != cfg.minCloseVolToCashUsd6 || hook.cashEnterTriggerBps() != cfg.cashEnterTriggerBps
                || hook.cashHoldPeriods() != cfg.cashHoldPeriods
                || hook.minCloseVolToExtremeUsd6() != cfg.minCloseVolToExtremeUsd6
                || hook.extremeEnterTriggerBps() != cfg.extremeEnterTriggerBps
                || hook.upExtremeConfirmPeriods() != cfg.upExtremeConfirmPeriods
                || hook.extremeHoldPeriods() != cfg.extremeHoldPeriods
                || hook.extremeExitTriggerBps() != cfg.extremeExitTriggerBps
                || hook.downExtremeConfirmPeriods() != cfg.downExtremeConfirmPeriods
                || hook.cashExitTriggerBps() != cfg.cashExitTriggerBps
                || hook.downCashConfirmPeriods() != cfg.downCashConfirmPeriods
                || hook.emergencyFloorCloseVolUsd6() != cfg.emergencyFloorCloseVolUsd6
                || hook.emergencyConfirmPeriods() != cfg.emergencyConfirmPeriods
        ) {
            validation.ok = false;
            validation.reason = "hook controller config mismatch";
            return validation;
        }

        (bool hasPendingHookFeePercent,,) = hook.pendingHookFeePercentChange();
        if (hasPendingHookFeePercent) {
            validation.ok = false;
            validation.reason = "hook pending HookFee percent change exists";
            return validation;
        }

        (bool hasPendingMinCountedSwap,) = hook.pendingMinCountedSwapUsd6Change();
        if (hasPendingMinCountedSwap) {
            validation.ok = false;
            validation.reason = "hook pending min counted swap change exists";
            return validation;
        }

        validation.reason = "ok";
    }

    function _declaredPermissionsMatch(Hooks.Permissions memory perms) private pure returns (bool) {
        return !perms.beforeInitialize && perms.afterInitialize && !perms.beforeAddLiquidity
            && !perms.afterAddLiquidity && !perms.beforeRemoveLiquidity && !perms.afterRemoveLiquidity
            && !perms.beforeSwap && perms.afterSwap && !perms.beforeDonate && !perms.afterDonate
            && !perms.beforeSwapReturnDelta && perms.afterSwapReturnDelta
            && !perms.afterAddLiquidityReturnDelta && !perms.afterRemoveLiquidityReturnDelta;
    }

    function _addressPermissionsMatch(IHooks hook) private pure returns (bool) {
        return !hook.hasPermission(Hooks.BEFORE_INITIALIZE_FLAG) && hook.hasPermission(Hooks.AFTER_INITIALIZE_FLAG)
            && !hook.hasPermission(Hooks.BEFORE_ADD_LIQUIDITY_FLAG)
            && !hook.hasPermission(Hooks.AFTER_ADD_LIQUIDITY_FLAG)
            && !hook.hasPermission(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG)
            && !hook.hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG)
            && !hook.hasPermission(Hooks.BEFORE_SWAP_FLAG) && hook.hasPermission(Hooks.AFTER_SWAP_FLAG)
            && !hook.hasPermission(Hooks.BEFORE_DONATE_FLAG) && !hook.hasPermission(Hooks.AFTER_DONATE_FLAG)
            && !hook.hasPermission(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
            && hook.hasPermission(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
            && !hook.hasPermission(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
            && !hook.hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
    }
}

interface IVolumeHook {
    function getHookPermissions() external pure returns (Hooks.Permissions memory);
    function poolManager() external view returns (IPoolManager);
    function poolCurrency0() external view returns (Currency);
    function poolCurrency1() external view returns (Currency);
    function poolTickSpacing() external view returns (int24);
    function stableCurrency() external view returns (Currency);
    function stableDecimals() external view returns (uint8);
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function hookFeePercent() external view returns (uint16);
    function minCountedSwapUsd6() external view returns (uint64);
    function pendingHookFeePercentChange() external view returns (bool, uint16, uint64);
    function pendingMinCountedSwapUsd6Change() external view returns (bool, uint64);
    function floorFee() external view returns (uint24);
    function cashFee() external view returns (uint24);
    function extremeFee() external view returns (uint24);
    function periodSeconds() external view returns (uint32);
    function emaPeriods() external view returns (uint8);
    function lullResetSeconds() external view returns (uint32);
    function minCloseVolToCashUsd6() external view returns (uint64);
    function cashEnterTriggerBps() external view returns (uint16);
    function cashHoldPeriods() external view returns (uint8);
    function minCloseVolToExtremeUsd6() external view returns (uint64);
    function extremeEnterTriggerBps() external view returns (uint16);
    function upExtremeConfirmPeriods() external view returns (uint8);
    function extremeHoldPeriods() external view returns (uint8);
    function extremeExitTriggerBps() external view returns (uint16);
    function downExtremeConfirmPeriods() external view returns (uint8);
    function cashExitTriggerBps() external view returns (uint16);
    function downCashConfirmPeriods() external view returns (uint8);
    function emergencyFloorCloseVolUsd6() external view returns (uint64);
    function emergencyConfirmPeriods() external view returns (uint8);
}
