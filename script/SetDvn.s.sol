// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";

import {LzConfig} from "./LzConfig.sol";

/// @notice Pins an explicit LayerZero security stack for this chain's TokenBridge and LaunchRelay on every peer
///         path: SendUln302 / ReceiveUln302 as the libraries and a required-DVN set (default: LayerZero Labs +
///         Nethermind, 2-of-2) instead of the endpoint's single-DVN default. Run on every chain after Wire.s.sol,
///         while the deployer is still the OApps' delegate (before Handover.s.sol).
///
/// env:
///   DEPLOYER_PRIVATE_KEY   the OApps' LayerZero delegate (the deployer until Handover.s.sol)
///   PEER_CHAIN_IDS         comma-separated EVM peer chain ids (their eid comes from deployments/<id>.json)
///   SOLANA_EID             optional: also configure the path to the Solana OApp (token bridge only)
///   DVNS                   optional comma-separated DVN addresses on THIS chain (default: LzConfig.sol pair)
///   CONFIRMATIONS          optional block confirmations (0 = the library default for that path)
///   SEND_LIB / RECEIVE_LIB optional overrides of LzConfig.sol
contract SetDvn is Script {
    using stdJson for string;

    uint32 constant CONFIG_TYPE_ULN = 2;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory local = _read(block.chainid);
        address bridge = local.readAddress(".bridge");
        address relay = local.readAddress(".relay");
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(local.readAddress(".lzEndpoint"));
        require(bridge != address(0) && relay != address(0), "no LayerZero modules here");

        LzConfig.Libs memory libs = LzConfig.get(block.chainid);
        address sendLib = vm.envOr("SEND_LIB", libs.sendUln302);
        address receiveLib = vm.envOr("RECEIVE_LIB", libs.receiveUln302);
        require(sendLib != address(0) && receiveLib != address(0), "no ULN302 libraries known for this chain");

        address[] memory dvns = vm.envOr("DVNS", ",", new address[](0));
        if (dvns.length == 0) {
            require(libs.dvnLayerZeroLabs != address(0) && libs.dvnNethermind != address(0), "no DVNs known here");
            dvns = new address[](2);
            dvns[0] = libs.dvnLayerZeroLabs;
            dvns[1] = libs.dvnNethermind;
        }
        _sort(dvns);
        uint64 confirmations = uint64(vm.envOr("CONFIRMATIONS", uint256(0)));

        uint256[] memory peers = vm.envUint("PEER_CHAIN_IDS", ",");
        uint32 solanaEid = uint32(vm.envOr("SOLANA_EID", uint256(0)));
        uint32[] memory eids = new uint32[](peers.length + (solanaEid != 0 ? 1 : 0));
        uint256 n;
        for (uint256 i = 0; i < peers.length; i++) {
            if (peers[i] == block.chainid) continue;
            eids[n++] = uint32(_read(peers[i]).readUint(".lzEid"));
        }
        if (solanaEid != 0) eids[n++] = solanaEid;

        console2.log("chain", block.chainid, "send lib", sendLib);
        console2.log("receive lib", receiveLib);
        for (uint256 i = 0; i < dvns.length; i++) console2.log("required DVN", dvns[i]);

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < n; i++) {
            uint32 eid = eids[i];
            bool relayToo = eid != solanaEid; // Solana legs are never relayed
            _configure(endpoint, bridge, eid, sendLib, receiveLib, dvns, confirmations);
            if (relayToo) _configure(endpoint, relay, eid, sendLib, receiveLib, dvns, confirmations);
            console2.log("configured eid", eid, relayToo ? "(bridge + relay)" : "(bridge only)");
        }
        vm.stopBroadcast();
    }

    function _configure(
        ILayerZeroEndpointV2 endpoint,
        address oapp,
        uint32 eid,
        address sendLib,
        address receiveLib,
        address[] memory dvns,
        uint64 confirmations
    ) internal {
        endpoint.setSendLibrary(oapp, eid, sendLib);
        endpoint.setReceiveLibrary(oapp, eid, receiveLib, 0);

        UlnConfig memory uln = UlnConfig({
            confirmations: confirmations,
            requiredDVNCount: uint8(dvns.length),
            optionalDVNCount: type(uint8).max, // NIL: explicitly no optional DVNs (0 would mean "library default")
            optionalDVNThreshold: 0,
            requiredDVNs: dvns,
            optionalDVNs: new address[](0)
        });
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({eid: eid, configType: CONFIG_TYPE_ULN, config: abi.encode(uln)});
        endpoint.setConfig(oapp, sendLib, params);
        endpoint.setConfig(oapp, receiveLib, params);
    }

    /// UlnBase requires required DVNs sorted ascending with no duplicates.
    function _sort(address[] memory a) internal pure {
        for (uint256 i = 1; i < a.length; i++) {
            for (uint256 j = i; j > 0 && a[j - 1] >= a[j]; j--) {
                require(a[j - 1] != a[j], "duplicate DVN");
                (a[j - 1], a[j]) = (a[j], a[j - 1]);
            }
        }
    }

    function _read(uint256 chainId) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/deployments/", vm.toString(chainId), ".json"));
    }
}
