// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";

import {Launchpad} from "../src/Launchpad.sol";
import {TokenBridge} from "../src/bridge/TokenBridge.sol";
import {LaunchRelay} from "../src/bridge/LaunchRelay.sol";

/// @notice Wires this chain's bridge + relay to peers on other chains, using deployments/<id>.json
///         of each peer. Run once per chain after every chain has been deployed.
///
/// env:
///   DEPLOYER_PRIVATE_KEY   owner key of this chain's contracts
///   PEER_CHAIN_IDS         comma-separated chain ids, e.g. "56,8453"
///   PEER_QUOTES_<chainId>  optional comma-separated quote addresses allowed on that peer (native always allowed)
///   SOLANA_EID / SOLANA_OAPP  optional: LayerZero eid of the Solana cluster and the crossr_bridge OApp store
///                          (bytes32, from packages/solana/deployments/<id>.json "bridgeHex"); wires the token
///                          bridge only (Solana legs are created directly, never relayed)
contract Wire is Script {
    using stdJson for string;
    using OptionsBuilder for bytes;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory local = _read(block.chainid);
        Launchpad pad = Launchpad(payable(local.readAddress(".launchpad")));
        TokenBridge bridge = TokenBridge(local.readAddress(".bridge"));
        LaunchRelay relay = LaunchRelay(local.readAddress(".relay"));
        require(address(bridge) != address(0) && address(relay) != address(0), "no LayerZero modules here");

        uint256[] memory peers = vm.envUint("PEER_CHAIN_IDS", ",");
        vm.startBroadcast(pk);
        for (uint256 i = 0; i < peers.length; i++) {
            uint256 peerChain = peers[i];
            if (peerChain == block.chainid) continue;
            string memory p = _read(peerChain);
            uint32 eid = uint32(p.readUint(".lzEid"));
            address peerBridge = p.readAddress(".bridge");
            address peerRelay = p.readAddress(".relay");
            require(eid != 0 && peerBridge != address(0) && peerRelay != address(0), "peer has no LZ modules");

            bridge.setPeer(eid, bytes32(uint256(uint160(peerBridge))));
            relay.setPeer(eid, bytes32(uint256(uint160(peerRelay))));
            relay.mapChain(uint64(peerChain), eid);
            pad.setRemoteQuote(uint64(peerChain), address(0), true);

            // Enforce a sane minimum executor gas for bridge receives so users cannot under-gas a mint.
            EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](1);
            opts[0] = EnforcedOptionParam({
                eid: eid, msgType: bridge.MSG_TYPE(), options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(150_000, 0)
            });
            bridge.setEnforcedOptions(opts);
            // Relayed leg creation deploys a token + initializes a curve: enforce enough gas.
            EnforcedOptionParam[] memory relayOpts = new EnforcedOptionParam[](1);
            relayOpts[0] = EnforcedOptionParam({
                eid: eid, msgType: relay.MSG_TYPE(), options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(3_000_000, 0)
            });
            relay.setEnforcedOptions(relayOpts);

            string memory key = string.concat("PEER_QUOTES_", vm.toString(peerChain));
            address[] memory quotes = vm.envOr(key, ",", new address[](0));
            for (uint256 q = 0; q < quotes.length; q++) {
                pad.setRemoteQuote(uint64(peerChain), quotes[q], true);
            }
            console2.log("wired peer chain", peerChain, "eid", eid);
        }

        uint32 solanaEid = uint32(vm.envOr("SOLANA_EID", uint256(0)));
        bytes32 solanaOApp = vm.envOr("SOLANA_OAPP", bytes32(0));
        if (solanaEid != 0 && solanaOApp != bytes32(0)) {
            bridge.setPeer(solanaEid, solanaOApp);
            // lz_receive on Solana: compute units + lamports for the recipient's token account rent
            EnforcedOptionParam[] memory solOpts = new EnforcedOptionParam[](1);
            solOpts[0] = EnforcedOptionParam({
                eid: solanaEid,
                msgType: bridge.MSG_TYPE(),
                options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(SOLANA_RECEIVE_CU, SOLANA_RECEIVE_LAMPORTS)
            });
            bridge.setEnforcedOptions(solOpts);
            console2.log("wired solana eid", solanaEid);
        }
        vm.stopBroadcast();
    }

    /// Compute units and lamports (rent of a Token-2022 ATA) enforced for bridge receives on Solana.
    uint128 constant SOLANA_RECEIVE_CU = 300_000;
    uint128 constant SOLANA_RECEIVE_LAMPORTS = 2_500_000;

    function _read(uint256 chainId) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/deployments/", vm.toString(chainId), ".json"));
    }
}
