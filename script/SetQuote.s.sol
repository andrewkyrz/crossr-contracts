// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Launchpad} from "../src/Launchpad.sol";

/// @notice Enables ERC20 quote assets on this chain's launchpad (tokenized stocks on Robinhood Chain, CAKE on BNB, …)
/// and/or allows quotes of a remote chain for relayed legs. `packages/solana/scripts/quotes.ts` builds the env from the
/// shared registry.
/// env: DEPLOYER_PRIVATE_KEY
///      QUOTES        comma-separated `address:phantom:target[:enabled]` (raw units for a full leg; enabled defaults 1)
///      REMOTE_CHAIN  + REMOTE_QUOTES (comma-separated addresses) — allow those quotes for legs on that chain
///      QUOTE / PHANTOM / TARGET / ENABLED — single-quote form kept for hand use
contract SetQuote is Script {
    using stdJson for string;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory local =
            vm.readFile(string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json"));
        Launchpad pad = Launchpad(payable(local.readAddress(".launchpad")));
        vm.startBroadcast(pk);

        string[] memory quotes = vm.envOr("QUOTES", ",", new string[](0));
        for (uint256 i = 0; i < quotes.length; i++) {
            string[] memory f = vm.split(quotes[i], ":");
            require(f.length == 3 || f.length == 4, "QUOTES entry: address:phantom:target[:enabled]");
            address quote = vm.parseAddress(f[0]);
            bool enabled = f.length == 4 ? vm.parseUint(f[3]) == 1 : true;
            pad.setQuoteConfig(quote, enabled, uint128(vm.parseUint(f[1])), uint128(vm.parseUint(f[2])));
            console2.log(enabled ? "quote enabled" : "quote disabled", quote);
        }

        address single = vm.envOr("QUOTE", address(0));
        if (single != address(0)) {
            bool enabled = vm.envOr("ENABLED", true);
            pad.setQuoteConfig(single, enabled, uint128(vm.envUint("PHANTOM")), uint128(vm.envUint("TARGET")));
            console2.log(enabled ? "quote enabled" : "quote disabled", single);
        }

        uint64 remoteChain = uint64(vm.envOr("REMOTE_CHAIN", uint256(0)));
        if (remoteChain != 0) {
            address[] memory remote = vm.envOr("REMOTE_QUOTES", ",", new address[](0));
            bool allowed = vm.envOr("REMOTE_ALLOWED", true);
            for (uint256 i = 0; i < remote.length; i++) {
                pad.setRemoteQuote(remoteChain, remote[i], allowed);
                console2.log("remote quote", remoteChain, remote[i]);
            }
        }
        vm.stopBroadcast();
    }
}
