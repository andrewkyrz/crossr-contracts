// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

/// @notice Deploys a Uniswap v4 PoolManager on chains without an official one (OP Sepolia, BSC testnet).
///         Pass its address as POOL_MANAGER to Deploy.s.sol. Testnet use only.
contract DeployPoolManager is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envOr("OWNER", vm.addr(pk));
        vm.startBroadcast(pk);
        PoolManager pm = new PoolManager(owner);
        vm.stopBroadcast();
        console2.log("chain", block.chainid);
        console2.log("POOL_MANAGER", address(pm));
    }
}
