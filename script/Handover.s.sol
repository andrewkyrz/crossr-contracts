// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {TokenBridge} from "../src/bridge/TokenBridge.sol";
import {LaunchRelay} from "../src/bridge/LaunchRelay.sol";

/// EndpointV2 exposes the delegate mapping as a public getter that is not part of ILayerZeroEndpointV2.
interface IEndpointDelegates {
    function delegates(address oapp) external view returns (address);
}

/// @notice Last deployer action on a chain: hands the LayerZero delegate role of the TokenBridge and LaunchRelay to
///         OWNER (the OApp constructor registers the deployer as delegate, and the delegate — not the owner — is who
///         the endpoint lets change libraries / DVNs / peers' security), offers ownership of every contract to OWNER
///         if that has not happened yet, and prints what OWNER still has to accept.
///
/// Run after Deploy → Wire → SetQuote → SetDvn, once nothing else needs the deployer key on this chain.
///
/// env:
///   DEPLOYER_PRIVATE_KEY   current owner of the contracts
///   OWNER                  multisig (required; must differ from the deployer)
contract Handover is Script {
    using stdJson for string;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envAddress("OWNER");
        require(owner != deployer && owner != address(0), "OWNER must be a different account (multisig)");
        string memory j =
            vm.readFile(string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json"));

        string[7] memory names = ["factory", "escrow", "locker", "hook", "launchpad", "bridge", "relay"];
        address[] memory targets = new address[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            targets[i] = j.readAddress(string.concat(".", names[i]));
        }
        IEndpointDelegates endpoint = IEndpointDelegates(j.readAddress(".lzEndpoint"));

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == address(0)) continue;
            Ownable2Step c = Ownable2Step(targets[i]);
            if (c.owner() == owner) {
                console2.log(names[i], targets[i], "already owned by OWNER");
                continue;
            }
            require(c.owner() == deployer, string.concat(names[i], ": deployer is not the owner"));
            if (c.pendingOwner() != owner) c.transferOwnership(owner);
            console2.log(names[i], targets[i], "-> OWNER must acceptOwnership()");
        }
        address bridge = j.readAddress(".bridge");
        address relay = j.readAddress(".relay");
        if (bridge != address(0) && endpoint.delegates(bridge) != owner) TokenBridge(bridge).setDelegate(owner);
        if (relay != address(0) && endpoint.delegates(relay) != owner) LaunchRelay(relay).setDelegate(owner);
        vm.stopBroadcast();

        console2.log("LayerZero delegate of bridge + relay is now", owner);
        console2.log("Next: from OWNER, call acceptOwnership() on every contract listed above.");
    }
}
