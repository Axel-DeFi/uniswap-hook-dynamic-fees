// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

library NativeRecipientValidationLib {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant NATIVE = address(0);
    uint256 internal constant PROBE_VALUE_WEI = 1;

    function validateHookFeeRecipientForNativePool(
        address token0,
        address token1,
        address hookFeeRecipient,
        address payoutSender
    ) internal returns (bool ok, string memory reason) {
        if (!_poolHasNativeCurrency(token0, token1)) {
            return (true, "ok");
        }

        if (hookFeeRecipient == address(0)) {
            return (false, "HOOK_FEE_ADDRESS invalid for native pool");
        }

        // EOAs are always compatible with native transfers.
        if (hookFeeRecipient.code.length == 0) {
            return (true, "ok");
        }

        if (payoutSender == address(0)) {
            return (false, "native payout sender missing");
        }

        vm.deal(payoutSender, PROBE_VALUE_WEI);
        vm.prank(payoutSender);
        (bool success,) = payable(hookFeeRecipient).call{value: PROBE_VALUE_WEI}("");
        if (!success) {
            return (false, "HOOK_FEE_ADDRESS cannot receive native payout from hook");
        }

        return (true, "ok");
    }

    function poolHasNativeCurrency(address token0, address token1) internal pure returns (bool) {
        return _poolHasNativeCurrency(token0, token1);
    }

    function _poolHasNativeCurrency(address token0, address token1) private pure returns (bool) {
        return token0 == NATIVE || token1 == NATIVE;
    }
}
