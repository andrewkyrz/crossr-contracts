// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OAppOptionsType3} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {LaunchTypes, ILaunchpad} from "../interfaces/ILaunchpad.sol";
import {ILaunchRelay} from "../interfaces/ILaunchRelay.sol";

/// @title LaunchRelay
/// @notice LayerZero OApp that carries a launch Manifest to another chain, where the peer relay asks
///         that chain's Launchpad to create the corresponding leg. Lets a creator launch on every chain
///         with a single transaction on the home chain.
contract LaunchRelay is ILaunchRelay, OApp, OAppOptionsType3, Ownable2Step {
    error NotLaunchpad();
    error ChainUnsupported();

    event ChainMapped(uint64 indexed chainId, uint32 indexed eid);
    event LegSent(bytes32 indexed guid, bytes32 indexed launchId, uint8 legIndex, uint32 dstEid);
    event LegReceived(bytes32 indexed guid, bytes32 indexed launchId, uint8 legIndex, uint32 srcEid);

    uint16 public constant MSG_TYPE = 1;
    ILaunchpad public launchpad;
    mapping(uint64 chainId => uint32 eid) public eidOf;
    mapping(uint32 eid => uint64 chainId) public chainIdOf;

    constructor(address endpoint, address owner_) OApp(endpoint, owner_) Ownable(owner_) {}

    function setLaunchpad(ILaunchpad launchpad_) external onlyOwner {
        launchpad = launchpad_;
    }

    function mapChain(uint64 chainId, uint32 eid) external onlyOwner {
        eidOf[chainId] = eid;
        chainIdOf[eid] = chainId;
        emit ChainMapped(chainId, eid);
    }

    function isSupported(uint64 chainId) external view returns (bool) {
        uint32 eid = eidOf[chainId];
        return eid != 0 && peers[eid] != bytes32(0);
    }

    function quoteLeg(LaunchTypes.Manifest calldata manifest, uint8 legIndex, bytes calldata options)
        external
        view
        returns (uint256 nativeFee)
    {
        uint32 eid = _eid(manifest.legs[legIndex].chainId);
        MessagingFee memory fee =
            _quote(eid, abi.encode(manifest, legIndex), combineOptions(eid, MSG_TYPE, options), false);
        return fee.nativeFee;
    }

    function sendLeg(LaunchTypes.Manifest calldata manifest, uint8 legIndex, bytes calldata options, address refundTo)
        external
        payable
    {
        if (msg.sender != address(launchpad)) revert NotLaunchpad();
        uint32 eid = _eid(manifest.legs[legIndex].chainId);
        bytes32 launchId = LaunchTypes.hash(manifest);
        bytes32 guid = _lzSend(
            eid, abi.encode(manifest, legIndex), combineOptions(eid, MSG_TYPE, options), MessagingFee(msg.value, 0), refundTo
        ).guid;
        emit LegSent(guid, launchId, legIndex, eid);
    }

    function _lzReceive(Origin calldata origin, bytes32 guid, bytes calldata message, address, bytes calldata)
        internal
        override
    {
        (LaunchTypes.Manifest memory manifest, uint8 legIndex) = abi.decode(message, (LaunchTypes.Manifest, uint8));
        launchpad.createLegFromRelay(manifest, legIndex);
        emit LegReceived(guid, LaunchTypes.hash(manifest), legIndex, origin.srcEid);
    }

    function _eid(uint64 chainId) internal view returns (uint32 eid) {
        eid = eidOf[chainId];
        if (eid == 0) revert ChainUnsupported();
    }

    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) onlyOwner {
        Ownable2Step.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        Ownable2Step._transferOwnership(newOwner);
    }
}
