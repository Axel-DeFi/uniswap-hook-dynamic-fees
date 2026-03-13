// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {ErrorLib} from "./ErrorLib.sol";

library EnvLib {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function hasKey(string memory key) internal view returns (bool) {
        try vm.envString(key) returns (string memory value) {
            return bytes(value).length != 0;
        } catch {
            return false;
        }
    }

    function requireAddress(string memory key, bool allowZero) internal view returns (address value) {
        if (!hasKey(key)) revert ErrorLib.MissingEnv(key);
        value = vm.envAddress(key);
        if (!allowZero && value == address(0)) {
            revert ErrorLib.InvalidEnv(key, "zero address");
        }
    }

    function envOrAddress(string memory key, address fallbackValue) internal view returns (address value) {
        if (!hasKey(key)) return fallbackValue;
        value = vm.envAddress(key);
    }

    function requireUint(string memory key) internal view returns (uint256 value) {
        if (!hasKey(key)) revert ErrorLib.MissingEnv(key);
        value = vm.envUint(key);
    }

    function requireUint8(string memory key) internal view returns (uint8 value) {
        value = toUint8Checked(requireUint(key), key);
    }

    function requireUint16(string memory key) internal view returns (uint16 value) {
        value = toUint16Checked(requireUint(key), key);
    }

    function requireUint24(string memory key) internal view returns (uint24 value) {
        value = toUint24Checked(requireUint(key), key);
    }

    function requireUint32(string memory key) internal view returns (uint32 value) {
        value = toUint32Checked(requireUint(key), key);
    }

    function requireUint64(string memory key) internal view returns (uint64 value) {
        value = toUint64Checked(requireUint(key), key);
    }

    function requireInt24(string memory key) internal view returns (int24 value) {
        if (!hasKey(key)) revert ErrorLib.MissingEnv(key);
        int256 raw = vm.envInt(key);
        if (raw < type(int24).min || raw > type(int24).max) {
            revert ErrorLib.InvalidEnv(key, "value out of int24 range");
        }
        value = int24(raw);
    }

    function requirePositiveInt24(string memory key) internal view returns (int24 value) {
        value = toPositiveInt24Checked(requireUint(key), key);
    }

    function envOrUint(string memory key, uint256 fallbackValue) internal view returns (uint256 value) {
        if (!hasKey(key)) return fallbackValue;
        value = vm.envUint(key);
    }

    function envOrUint8(string memory key, uint8 fallbackValue) internal view returns (uint8 value) {
        if (!hasKey(key)) return fallbackValue;
        value = toUint8Checked(vm.envUint(key), key);
    }

    function envOrUint16(string memory key, uint16 fallbackValue) internal view returns (uint16 value) {
        if (!hasKey(key)) return fallbackValue;
        value = toUint16Checked(vm.envUint(key), key);
    }

    function envOrUint24(string memory key, uint24 fallbackValue) internal view returns (uint24 value) {
        if (!hasKey(key)) return fallbackValue;
        value = toUint24Checked(vm.envUint(key), key);
    }

    function envOrUint32(string memory key, uint32 fallbackValue) internal view returns (uint32 value) {
        if (!hasKey(key)) return fallbackValue;
        value = toUint32Checked(vm.envUint(key), key);
    }

    function envOrUint64(string memory key, uint64 fallbackValue) internal view returns (uint64 value) {
        if (!hasKey(key)) return fallbackValue;
        value = toUint64Checked(vm.envUint(key), key);
    }

    function envOrPositiveInt24(string memory key, int24 fallbackValue) internal view returns (int24 value) {
        if (!hasKey(key)) return fallbackValue;
        value = toPositiveInt24Checked(vm.envUint(key), key);
    }

    function envOrBool(string memory key, bool fallbackValue) internal view returns (bool value) {
        if (!hasKey(key)) return fallbackValue;
        try vm.envBool(key) returns (bool parsed) {
            return parsed;
        } catch {
            string memory raw = vm.envString(key);
            bytes memory b = bytes(_toLower(raw));
            if (_eqBytes(b, bytes("1")) || _eqBytes(b, bytes("true")) || _eqBytes(b, bytes("yes"))) {
                return true;
            }
            if (_eqBytes(b, bytes("0")) || _eqBytes(b, bytes("false")) || _eqBytes(b, bytes("no"))) {
                return false;
            }
            return fallbackValue;
        }
    }

    function envOrString(string memory key, string memory fallbackValue) internal view returns (string memory value) {
        if (!hasKey(key)) return fallbackValue;
        value = vm.envString(key);
    }

    function envOrDecimalE18(string memory key, uint256 fallbackValue) internal view returns (uint256) {
        if (!hasKey(key)) return fallbackValue;
        return parseDecimalToE18(vm.envString(key), key);
    }

    function requireDecimalE18(string memory key) internal view returns (uint256) {
        if (!hasKey(key)) revert ErrorLib.MissingEnv(key);
        return parseDecimalToE18(vm.envString(key), key);
    }

    function parseDecimalToE18(string memory raw, string memory key) internal pure returns (uint256) {
        bytes memory b = bytes(raw);
        if (b.length == 0) revert ErrorLib.InvalidEnv(key, "empty decimal");

        uint256 integerPart = 0;
        uint256 fractionalPart = 0;
        uint256 fractionalDigits = 0;
        bool dotSeen = false;

        for (uint256 i = 0; i < b.length; i++) {
            bytes1 ch = b[i];
            if (ch == ".") {
                if (dotSeen) revert ErrorLib.InvalidEnv(key, "multiple dots");
                dotSeen = true;
                continue;
            }

            if (ch < "0" || ch > "9") {
                revert ErrorLib.InvalidEnv(key, "non-digit decimal char");
            }

            uint256 digit = uint8(ch) - 48;
            if (!dotSeen) {
                integerPart = integerPart * 10 + digit;
            } else if (fractionalDigits < 18) {
                fractionalPart = fractionalPart * 10 + digit;
                fractionalDigits++;
            } else {
                // Ignore precision beyond 18 decimals for deterministic truncation.
            }
        }

        uint256 scale = 10 ** (18 - fractionalDigits);
        return integerPart * 1e18 + fractionalPart * scale;
    }

    function _toLower(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) {
                b[i] = bytes1(uint8(b[i]) + 32);
            }
        }
        return string(b);
    }

    function _eqBytes(bytes memory a, bytes memory b) private pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function toUint8Checked(uint256 raw, string memory key) internal pure returns (uint8 value) {
        if (raw > type(uint8).max) revert ErrorLib.InvalidEnv(key, "value too large for uint8");
        value = uint8(raw);
    }

    function toUint16Checked(uint256 raw, string memory key) internal pure returns (uint16 value) {
        if (raw > type(uint16).max) revert ErrorLib.InvalidEnv(key, "value too large for uint16");
        value = uint16(raw);
    }

    function toUint24Checked(uint256 raw, string memory key) internal pure returns (uint24 value) {
        if (raw > type(uint24).max) revert ErrorLib.InvalidEnv(key, "value too large for uint24");
        value = uint24(raw);
    }

    function toUint32Checked(uint256 raw, string memory key) internal pure returns (uint32 value) {
        if (raw > type(uint32).max) revert ErrorLib.InvalidEnv(key, "value too large for uint32");
        value = uint32(raw);
    }

    function toUint64Checked(uint256 raw, string memory key) internal pure returns (uint64 value) {
        if (raw > type(uint64).max) revert ErrorLib.InvalidEnv(key, "value too large for uint64");
        value = uint64(raw);
    }

    function toPositiveInt24Checked(uint256 raw, string memory key) internal pure returns (int24 value) {
        if (raw > uint256(uint24(type(int24).max))) {
            revert ErrorLib.InvalidEnv(key, "must fit positive int24");
        }
        value = int24(uint24(raw));
    }
}
