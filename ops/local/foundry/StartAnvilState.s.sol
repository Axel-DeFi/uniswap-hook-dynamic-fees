// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {MockPoolManager} from "../../tests/mocks/MockPoolManager.sol";
import {EnvLib} from "../../shared/lib/EnvLib.sol";
import {JsonReportLib} from "../../shared/lib/JsonReportLib.sol";

contract LocalMintableToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _spend(msg.sender, amount);
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 current = allowance[from][msg.sender];
        require(current >= amount, "allowance");
        allowance[from][msg.sender] = current - amount;
        _spend(from, amount);
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function _spend(address from, uint256 amount) private {
        uint256 bal = balanceOf[from];
        require(bal >= amount, "balance");
        balanceOf[from] = bal - amount;
    }
}

contract StartAnvilState is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint8 stableDecimals = EnvLib.envOrUint8("STABLE_DECIMALS", 6);
        string memory statePath = vm.envOr(
            "OPS_LOCAL_STATE_PATH", string.concat(vm.projectRoot(), "/ops/local/out/state/local.addresses.json")
        );

        vm.startBroadcast(pk);
        MockPoolManager manager = new MockPoolManager();
        LocalMintableToken volatileToken = new LocalMintableToken("Local Volatile", "LVOL", 18);
        LocalMintableToken stableToken = new LocalMintableToken("Local Stable", "LUSD", stableDecimals);

        volatileToken.mint(deployer, 1_000_000 ether);
        stableToken.mint(deployer, 50_000_000 * (10 ** stableDecimals));
        vm.stopBroadcast();

        JsonReportLib.writeAddressState(
            statePath, address(manager), address(0), address(volatileToken), address(stableToken)
        );

        console2.log("state written", statePath);
        console2.log("poolManager", address(manager));
        console2.log("volatile", address(volatileToken));
        console2.log("stable", address(stableToken));
    }
}
