// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Launchpad} from "../src/Launchpad.sol";

/// @notice Enables an ERC20 quote asset on this chain's launchpad (e.g. a BEP-20 coin on BNB Chain).
/// env: DEPLOYER_PRIVATE_KEY, QUOTE (address), PHANTOM (raw units), TARGET (raw units), ENABLED (default true)
contract SetQuote is Script {
    using stdJson for string;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory local =
            vm.readFile(string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json"));
        Launchpad pad = Launchpad(payable(local.readAddress(".launchpad")));
        address quote = vm.envAddress("QUOTE");
        uint128 phantom = uint128(vm.envUint("PHANTOM"));
        uint128 target = uint128(vm.envUint("TARGET"));
        bool enabled = vm.envOr("ENABLED", true);
        vm.startBroadcast(pk);
        pad.setQuoteConfig(quote, enabled, phantom, target);
        vm.stopBroadcast();
        console2.log("quote configured", quote);
    }
}
