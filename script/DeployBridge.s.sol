// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {Launchpad} from "../src/Launchpad.sol";
import {TokenBridge} from "../src/bridge/TokenBridge.sol";
import {ILaunchpad} from "../src/interfaces/ILaunchpad.sol";

/// @notice Redeploys only the TokenBridge on the current chain (e.g. after a message-format change), points the
///         Launchpad at it and updates deployments/<chainId>.json. Re-run Wire.s.sol on every chain afterwards.
///
/// env:
///   DEPLOYER_PRIVATE_KEY  owner key of this chain's Launchpad
///   OWNER                 optional, defaults to deployer (ownership of the new bridge is offered to it)
contract DeployBridge is Script {
    using stdJson for string;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", deployer);
        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        string memory j = vm.readFile(path);
        Launchpad pad = Launchpad(payable(j.readAddress(".launchpad")));
        address lzEndpoint = j.readAddress(".lzEndpoint");
        require(lzEndpoint != address(0), "no LayerZero endpoint on this chain");

        vm.startBroadcast(pk);
        TokenBridge bridge = new TokenBridge(lzEndpoint, deployer, ILaunchpad(address(pad)));
        pad.setModules(address(bridge), address(pad.relay()), address(pad.locker()), address(pad.escrow()), pad.treasury());
        if (owner != deployer) bridge.transferOwnership(owner);
        vm.stopBroadcast();

        vm.writeJson(vm.toString(address(bridge)), path, ".bridge");
        console2.log("chain", block.chainid, "new bridge", address(bridge));
    }
}
