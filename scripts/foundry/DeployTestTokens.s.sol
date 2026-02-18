// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {MintableERC20} from "src/mocks/MintableERC20.sol";

/// @notice Deploys a pair of mintable ERC20 tokens and mints initial balances.
/// @dev Intended for real-testnet integration flows where faucet liquidity is not guaranteed.
contract DeployTestTokens is Script {
    function run() external {
        address mintTo = vm.envAddress("TOKEN_MINT_TO");

        string memory stableName = vm.envOr("TEST_STABLE_NAME", string("USD Stable Test"));
        string memory stableSymbol = vm.envOr("TEST_STABLE_SYMBOL", string("USDX"));
        uint8 stableDecimals = uint8(vm.envOr("TEST_STABLE_DECIMALS", uint256(6)));
        uint256 stableMintAmount = vm.envOr("TEST_STABLE_MINT_AMOUNT", uint256(5_000_000 * 10 ** 6));

        string memory volatileName = vm.envOr("TEST_VOLATILE_NAME", string("Wrapped Ether Test"));
        string memory volatileSymbol = vm.envOr("TEST_VOLATILE_SYMBOL", string("WETHT"));
        uint8 volatileDecimals = uint8(vm.envOr("TEST_VOLATILE_DECIMALS", uint256(18)));
        uint256 volatileMintAmount = vm.envOr("TEST_VOLATILE_MINT_AMOUNT", uint256(5_000 * 10 ** 18));

        vm.startBroadcast();

        MintableERC20 stable = new MintableERC20(stableName, stableSymbol, stableDecimals);
        MintableERC20 volatileToken = new MintableERC20(volatileName, volatileSymbol, volatileDecimals);

        stable.mint(mintTo, stableMintAmount);
        volatileToken.mint(mintTo, volatileMintAmount);

        vm.stopBroadcast();

        console2.log("Stable token:", address(stable));
        console2.log("Volatile token:", address(volatileToken));
        console2.log("Mint recipient:", mintTo);
        console2.log("Stable mint amount:", stableMintAmount);
        console2.log("Volatile mint amount:", volatileMintAmount);

        string memory out = vm.serializeAddress("tokens", "stable", address(stable));
        out = vm.serializeAddress("tokens", "volatile", address(volatileToken));
        out = vm.serializeAddress("tokens", "mintTo", mintTo);
        out = vm.serializeUint("tokens", "stableMintAmount", stableMintAmount);
        out = vm.serializeUint("tokens", "volatileMintAmount", volatileMintAmount);
        vm.writeJson(out, vm.envOr("DEPLOY_TOKENS_JSON_PATH", string("scripts/out/tokens.json")));
    }
}
