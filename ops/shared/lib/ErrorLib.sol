// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

library ErrorLib {
    error MissingEnv(string key);
    error InvalidEnv(string key, string reason);
    error ChainIdMismatch(uint256 expected, uint256 actual);
    error StaleAddress(string name, address value);
    error ValidationFailed(string component, string reason);
    error BudgetInsufficient(string reason, uint256 have, uint256 need);
    error InvalidRange(string reason);
}
