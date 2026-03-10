// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {NativeRecipientValidationLib} from "ops/shared/lib/NativeRecipientValidationLib.sol";

error NativeRejected();

contract RejectsNativeRecipient {
    receive() external payable {
        revert NativeRejected();
    }
}

contract AcceptsNativeRecipient {
    receive() external payable {}
}

contract NativeRecipientValidationLibTest is Test {
    address internal constant TOKEN_A = address(0x0000000000000000000000000000000000001111);
    address internal constant TOKEN_B = address(0x0000000000000000000000000000000000002222);
    address internal constant SENDER = address(0x000000000000000000000000000000000000bEEF);
    address internal constant EOA_RECIPIENT = address(0x000000000000000000000000000000000000cafE);

    function test_nativePool_eoaRecipient_passes() public {
        (bool ok, string memory reason) = NativeRecipientValidationLib.validateHookFeeRecipientForNativePool(
            address(0), TOKEN_A, EOA_RECIPIENT, SENDER
        );

        assertTrue(ok);
        assertEq(reason, "ok");
    }

    function test_nativePool_rejectingContractRecipient_fails() public {
        RejectsNativeRecipient recipient = new RejectsNativeRecipient();

        (bool ok, string memory reason) = NativeRecipientValidationLib.validateHookFeeRecipientForNativePool(
            TOKEN_A, address(0), address(recipient), SENDER
        );

        assertFalse(ok);
        assertEq(reason, "HOOK_FEE_ADDRESS cannot receive native payout from hook");
    }

    function test_nativePool_acceptingContractRecipient_passes() public {
        AcceptsNativeRecipient recipient = new AcceptsNativeRecipient();
        uint256 beforeBalance = address(recipient).balance;

        (bool ok, string memory reason) = NativeRecipientValidationLib.validateHookFeeRecipientForNativePool(
            TOKEN_A, address(0), address(recipient), SENDER
        );

        assertTrue(ok);
        assertEq(reason, "ok");
        assertEq(address(recipient).balance, beforeBalance + 1);
    }

    function test_nonNativePool_skips_nativeRecipientRequirement() public {
        RejectsNativeRecipient recipient = new RejectsNativeRecipient();

        (bool ok, string memory reason) = NativeRecipientValidationLib.validateHookFeeRecipientForNativePool(
            TOKEN_A, TOKEN_B, address(recipient), SENDER
        );

        assertTrue(ok);
        assertEq(reason, "ok");
    }
}
