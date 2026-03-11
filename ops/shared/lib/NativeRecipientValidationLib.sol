// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

library NativeRecipientValidationLib {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant NATIVE = address(0);
    uint256 internal constant PROBE_VALUE_WEI = 1;

    function validatePayoutRecipientForNativePool(
        address token0,
        address token1,
        address payoutRecipient,
        address payoutSender
    ) internal returns (bool ok, string memory reason) {
        if (!_poolHasNativeCurrency(token0, token1)) {
            return (true, "ok");
        }

        if (payoutRecipient == address(0)) {
            return (false, "payout recipient invalid for native pool");
        }

        // EOAs are always compatible with native transfers.
        if (payoutRecipient.code.length == 0) {
            return (true, "ok");
        }

        if (payoutSender == address(0)) {
            return (false, "native payout sender missing");
        }

        vm.deal(payoutSender, PROBE_VALUE_WEI);
        vm.prank(payoutSender);
        (bool success,) = payable(payoutRecipient).call{value: PROBE_VALUE_WEI}("");
        if (!success) {
            return (false, "payout recipient cannot receive native payout from pool manager");
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
