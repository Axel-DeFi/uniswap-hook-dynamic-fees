// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "ops/tests/mocks/MockPoolManager.sol";

contract VolumeDynamicFeeHookScriptHarness is VolumeDynamicFeeHook {
    constructor(
        IPoolManager _poolManager,
        Currency _poolCurrency0,
        Currency _poolCurrency1,
        int24 _poolTickSpacing,
        Currency _stableCurrency,
        uint8 stableDecimals,
        uint8 _floorIdx,
        uint24[] memory _feeTiers,
        uint32 _periodSeconds,
        uint8 _emaPeriods,
        uint16 _deadbandBps,
        uint32 _lullResetSeconds,
        address ownerAddr,
        address hookFeeRecipientAddr,
        uint16 hookFeePercent,
        uint24 _cashTier,
        uint64 _minCloseVolToCashUsd6,
        uint16 _upRToCashBps,
        uint8 _cashHoldPeriods,
        uint24 _extremeTier,
        uint64 _minCloseVolToExtremeUsd6,
        uint16 _upRToExtremeBps,
        uint8 _upExtremeConfirmPeriods,
        uint8 _extremeHoldPeriods,
        uint16 _downRFromExtremeBps,
        uint8 _downExtremeConfirmPeriods,
        uint16 _downRFromCashBps,
        uint8 _downCashConfirmPeriods,
        uint64 _emergencyFloorCloseVolUsd6,
        uint8 _emergencyConfirmPeriods
    )
        VolumeDynamicFeeHook(
            _poolManager,
            _poolCurrency0,
            _poolCurrency1,
            _poolTickSpacing,
            _stableCurrency,
            stableDecimals,
            _floorIdx,
            _feeTiers,
            _periodSeconds,
            _emaPeriods,
            _deadbandBps,
            _lullResetSeconds,
            ownerAddr,
            hookFeeRecipientAddr,
            hookFeePercent,
            _cashTier,
            _minCloseVolToCashUsd6,
            _upRToCashBps,
            _cashHoldPeriods,
            _extremeTier,
            _minCloseVolToExtremeUsd6,
            _upRToExtremeBps,
            _upExtremeConfirmPeriods,
            _extremeHoldPeriods,
            _downRFromExtremeBps,
            _downExtremeConfirmPeriods,
            _downRFromCashBps,
            _downCashConfirmPeriods,
            _emergencyFloorCloseVolUsd6,
            _emergencyConfirmPeriods
        )
    {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract MeasureGasLocal is Script {
    address internal constant TOKEN0 = address(0x0000000000000000000000000000000000001111);
    address internal constant TOKEN1 = address(0x0000000000000000000000000000000000002222);

    function run() external {
        uint256 defaultPk = uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);
        uint256 pk = vm.envOr("PRIVATE_KEY", defaultPk);
        address owner = vm.addr(pk);

        uint24[] memory tiers = new uint24[](3);
        tiers[0] = 400;
        tiers[1] = 2500;
        tiers[2] = 9000;

        vm.startBroadcast(pk);

        MockPoolManager manager = new MockPoolManager();

        VolumeDynamicFeeHook hook = new VolumeDynamicFeeHookScriptHarness(
            IPoolManager(address(manager)),
            Currency.wrap(TOKEN0),
            Currency.wrap(TOKEN1),
            10,
            Currency.wrap(TOKEN0),
            6,
            0,
            tiers,
            300,
            8,
            500,
            3600,
            owner,
            owner,
            3,
            2500,
            1_000 * 1e6,
            18_000,
            4,
            9000,
            4_000 * 1e6,
            40_000,
            2,
            4,
            13_000,
            2,
            13_000,
            3,
            600 * 1e6,
            3
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        // create/init pool path
        manager.callAfterInitialize(hook, key);

        // normal swap without rollover
        manager.callAfterSwap(hook, key, _deltaStable(10_000_000));

        // swap that closes period
        vm.warp(block.timestamp + 301);
        manager.callAfterSwap(hook, key, toBalanceDelta(0, 0));

        // swap after lull reset threshold
        vm.warp(block.timestamp + 3601);
        manager.callAfterSwap(hook, key, _deltaStable(10_000_000));

        // pause / unpause path
        hook.pause();
        hook.unpause();

        // emergency reset path (paused-only)
        hook.pause();
        hook.emergencyResetToFloor();
        hook.unpause();

        // accrue one more swap before claim
        manager.callAfterSwap(hook, key, _deltaStable(10_000_000));
        hook.claimAllHookFees();

        vm.stopBroadcast();
    }

    function _deltaStable(uint256 amountStable6) private pure returns (BalanceDelta) {
        require(amountStable6 <= uint256(type(uint128).max >> 1), "amount too large");
        int128 amt = int128(uint128(amountStable6));
        uint256 otherRaw = (amountStable6 * 95) / 100;
        require(otherRaw <= uint256(type(uint128).max >> 1), "other amount too large");
        int128 other = int128(uint128(otherRaw));
        return toBalanceDelta(-amt, other);
    }
}
